#include "VoiceActivityBridge.h"
#include <whisper.h>
#include <ggml-backend.h>
#include <pthread.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <glob.h>
#include <dlfcn.h>
#include <limits.h>

// ggml's dynamic backend registry is process-global. Serialize model setup;
// inference and the visualization's streaming work never acquire this lock.
static pthread_mutex_t setup_mutex = PTHREAD_MUTEX_INITIALIZER;
void luxit_audio_backend_lock(void) { pthread_mutex_lock(&setup_mutex); }
void luxit_audio_backend_unlock(void) { pthread_mutex_unlock(&setup_mutex); }

static void voice_log(enum ggml_log_level level, const char * text, void * user_data) {
    (void) user_data;
    // Streaming VAD otherwise writes four informational lines every 32 ms.
    // Preserve model diagnostics and every warning/error from transcription.
    if (level <= GGML_LOG_LEVEL_INFO && strstr(text, "whisper_vad_detect_speech") == text) return;
    fputs(text, stderr);
}

static pthread_once_t backends_once = PTHREAD_ONCE_INIT;
static void prepare_backends(void) {
    whisper_log_set(voice_log, NULL);
    if (ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU)) return;
    // Loading all backends compiles Metal kernels even with use_gpu=false.
    // Use ggml's plugin score ABI to select this Mac's best CPU variant, without
    // registering an older CPU implementation ahead of the transcription model.
    const char * roots[] = {"/opt/homebrew/opt/ggml/libexec", "/usr/local/opt/ggml/libexec"};
    char best_path[PATH_MAX] = {0};
    int best_score = 0;
    for (unsigned r = 0; r < 2; ++r) {
        char pattern[PATH_MAX];
        snprintf(pattern, sizeof(pattern), "%s/libggml-cpu*", roots[r]);
        glob_t paths = {0};
        if (glob(pattern, 0, NULL, &paths) == 0) {
            for (size_t i = 0; i < paths.gl_pathc; ++i) {
                void * library = dlopen(paths.gl_pathv[i], RTLD_NOW | RTLD_LOCAL);
                if (!library) continue;
                int (*score_fn)(void) = (int (*)(void)) dlsym(library, "ggml_backend_score");
                int score = score_fn ? score_fn() : 1;
                if (score > best_score) {
                    best_score = score;
                    snprintf(best_path, sizeof(best_path), "%s", paths.gl_pathv[i]);
                }
                dlclose(library);
            }
        }
        globfree(&paths);
    }
    if (best_path[0]) ggml_backend_load(best_path);
}

void * luxit_voice_activity_create(const char * path) {
    luxit_audio_backend_lock();
    pthread_once(&backends_once, prepare_backends);
    if (!ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU)) {
        luxit_audio_backend_unlock();
        return NULL;
    }
    struct whisper_vad_context_params params = whisper_vad_default_context_params();
    params.n_threads = 1;
    params.use_gpu = false;
    void * context = whisper_vad_init_from_file_with_params(path, params);
    luxit_audio_backend_unlock();
    return context;
}

void luxit_voice_activity_reset(void * context) {
    if (context) whisper_vad_reset_state(context);
}

float luxit_voice_activity_probability(void * context, const float * samples, int count) {
    if (!context || count != 512 ||
        !whisper_vad_detect_speech_no_reset(context, samples, count)) return -1;
    const int n = whisper_vad_n_probs(context);
    const float * probabilities = whisper_vad_probs(context);
    return n > 0 && probabilities ? probabilities[n - 1] : -1;
}

void luxit_voice_activity_free(void * context) {
    if (context) whisper_vad_free(context);
}
