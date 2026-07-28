#include "WhisperBridge.h"
#include <ggml-backend.h>
#include <whisper.h>

#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDUsageTables.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <IOKit/hidsystem/IOHIDParameter.h>
#include <IOKit/hidsystem/IOHIDShared.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <parakeet.h>

static char ew_error[512] = {0};
static enum whisper_sampling_strategy ew_whisper_sampling_strategy =
    WHISPER_SAMPLING_BEAM_SEARCH;

struct ew_caps_lock_listener {
    IOHIDManagerRef manager;
    ew_caps_lock_press_callback callback;
    void * context;
};

static void ew_caps_lock_input_value(
    void * context,
    IOReturn result,
    void * sender,
    IOHIDValueRef value
) {
    (void) sender;
    if (result != kIOReturnSuccess || !context || !value) {
        return;
    }
    IOHIDElementRef element = IOHIDValueGetElement(value);
    if (!element ||
        IOHIDElementGetUsagePage(element) != kHIDPage_KeyboardOrKeypad ||
        IOHIDElementGetUsage(element) != kHIDUsage_KeyboardCapsLock ||
        IOHIDValueGetIntegerValue(value) == 0) {
        return;
    }
    struct ew_caps_lock_listener * listener = context;
    if (listener->callback) {
        listener->callback(listener->context);
    }
}

void * ew_caps_lock_listener_create(
    ew_caps_lock_press_callback callback,
    void * context
) {
    if (!callback) {
        return NULL;
    }

    struct ew_caps_lock_listener * listener =
        calloc(1, sizeof(struct ew_caps_lock_listener));
    if (!listener) {
        return NULL;
    }

    listener->manager = IOHIDManagerCreate(
        kCFAllocatorDefault,
        kIOHIDOptionsTypeNone
    );
    listener->callback = callback;
    listener->context = context;
    if (!listener->manager) {
        free(listener);
        return NULL;
    }

    int usage_page = kHIDPage_KeyboardOrKeypad;
    int usage = kHIDUsage_KeyboardCapsLock;
    CFNumberRef usage_page_number = CFNumberCreate(
        kCFAllocatorDefault,
        kCFNumberIntType,
        &usage_page
    );
    CFNumberRef usage_number = CFNumberCreate(
        kCFAllocatorDefault,
        kCFNumberIntType,
        &usage
    );
    CFMutableDictionaryRef matching = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        2,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    if (!usage_page_number || !usage_number || !matching) {
        if (usage_page_number) CFRelease(usage_page_number);
        if (usage_number) CFRelease(usage_number);
        if (matching) CFRelease(matching);
        CFRelease(listener->manager);
        free(listener);
        return NULL;
    }

    CFDictionarySetValue(
        matching,
        CFSTR(kIOHIDElementUsagePageKey),
        usage_page_number
    );
    CFDictionarySetValue(
        matching,
        CFSTR(kIOHIDElementUsageKey),
        usage_number
    );
    IOHIDManagerSetInputValueMatching(listener->manager, matching);
    IOHIDManagerRegisterInputValueCallback(
        listener->manager,
        ew_caps_lock_input_value,
        listener
    );
    IOHIDManagerScheduleWithRunLoop(
        listener->manager,
        CFRunLoopGetMain(),
        kCFRunLoopCommonModes
    );

    CFRelease(matching);
    CFRelease(usage_page_number);
    CFRelease(usage_number);

    IOReturn opened = IOHIDManagerOpen(
        listener->manager,
        kIOHIDOptionsTypeNone
    );
    if (opened != kIOReturnSuccess) {
        IOHIDManagerUnscheduleFromRunLoop(
            listener->manager,
            CFRunLoopGetMain(),
            kCFRunLoopCommonModes
        );
        CFRelease(listener->manager);
        free(listener);
        return NULL;
    }
    return listener;
}

void ew_caps_lock_listener_destroy(void * raw_listener) {
    struct ew_caps_lock_listener * listener = raw_listener;
    if (!listener) {
        return;
    }
    IOHIDManagerRegisterInputValueCallback(listener->manager, NULL, NULL);
    IOHIDManagerUnscheduleFromRunLoop(
        listener->manager,
        CFRunLoopGetMain(),
        kCFRunLoopCommonModes
    );
    IOHIDManagerClose(listener->manager, kIOHIDOptionsTypeNone);
    CFRelease(listener->manager);
    free(listener);
}

static uint16_t read_u16(const unsigned char * p) {
    return (uint16_t) p[0] | ((uint16_t) p[1] << 8);
}

static uint32_t read_u32(const unsigned char * p) {
    return (uint32_t) p[0] |
           ((uint32_t) p[1] << 8) |
           ((uint32_t) p[2] << 16) |
           ((uint32_t) p[3] << 24);
}

static void set_error(const char * message) {
    snprintf(ew_error, sizeof(ew_error), "%s", message ? message : "Unknown error");
}

void ew_whisper_set_strategy(int strategy) {
    switch (strategy) {
    case WHISPER_SAMPLING_GREEDY:
        ew_whisper_sampling_strategy = WHISPER_SAMPLING_GREEDY;
        break;
    case WHISPER_SAMPLING_BEAM_SEARCH:
        ew_whisper_sampling_strategy = WHISPER_SAMPLING_BEAM_SEARCH;
        break;
    default:
        ew_whisper_sampling_strategy = WHISPER_SAMPLING_BEAM_SEARCH;
        break;
    }
    ew_error[0] = '\0';
}

const char * ew_whisper_last_error(void) {
    return ew_error;
}

void * ew_whisper_load(const char * model_path) {
    ew_error[0] = '\0';
    if (access("/opt/homebrew/opt/ggml/libexec", R_OK) == 0) {
        ggml_backend_load_all_from_path("/opt/homebrew/opt/ggml/libexec");
    } else if (access("/usr/local/opt/ggml/libexec", R_OK) == 0) {
        ggml_backend_load_all_from_path("/usr/local/opt/ggml/libexec");
    } else {
        ggml_backend_load_all();
    }
    struct whisper_context_params params = whisper_context_default_params();
    params.use_gpu = true;
    params.flash_attn = true;

    struct whisper_context * context =
        whisper_init_from_file_with_params(model_path, params);
    if (!context) {
        set_error("Whisper could not load the model.");
    }
    return context;
}

static int ew_parakeet_load_ggml_backends(int use_gpu) {
    const char * cpu_backends[] = {
        "/opt/homebrew/opt/ggml/libexec/libggml-blas.so",
        "/opt/homebrew/opt/ggml/libexec/libggml-cpu-apple_m2_m3.so",
    };
    const char * gpu_backends[] = {
        "/opt/homebrew/opt/ggml/libexec/libggml-blas.so",
        "/opt/homebrew/opt/ggml/libexec/libggml-cpu-apple_m2_m3.so",
        "/opt/homebrew/opt/ggml/libexec/libggml-metal.so",
    };

    const char ** backends = use_gpu ? gpu_backends : cpu_backends;
    const size_t backend_count = use_gpu
        ? sizeof(gpu_backends) / sizeof(gpu_backends[0])
        : sizeof(cpu_backends) / sizeof(cpu_backends[0]);

    for (size_t index = 0; index < backend_count; ++index) {
        const char * candidate = backends[index];
        if (!candidate || access(candidate, R_OK) != 0) {
            continue;
        }
        if (!ggml_backend_load(candidate)) {
            set_error("ggml backend failed to load");
            return -1;
        }
    }
    return 0;
}

void * ew_parakeet_load(
    const char * model_path,
    const char * library_path,
    int use_gpu,
    int gpu_device
) {
    if (!model_path || !model_path[0]) {
        set_error("Missing parakeet model path.");
        return NULL;
    }

    const char * effective_library_path = library_path != NULL && library_path[0]
        ? library_path
        : "/opt/homebrew/opt/whisper-cpp/lib/libparakeet.dylib";
    if (access(effective_library_path, R_OK) != 0) {
        set_error("Missing parakeet library dependency path");
        return NULL;
    }
    if (access("/opt/homebrew/opt/ggml/lib/libggml.0.dylib", R_OK) != 0) {
        set_error("Missing path: /opt/homebrew/opt/ggml/lib/libggml.0.dylib");
        return NULL;
    }
    if (ew_parakeet_load_ggml_backends(use_gpu != 0) != 0) {
        set_error(ew_error);
        return NULL;
    }
    struct parakeet_context_params params = {
        .use_gpu = use_gpu != 0,
        .gpu_device = gpu_device,
    };
    struct parakeet_context * context = parakeet_init_from_file_with_params(
        model_path,
        params
    );
    if (!context) {
        set_error("Parakeet could not initialize a context.");
        return NULL;
    }
    return context;
}

static float * load_pcm16_wav(const char * path, int * sample_count) {
    FILE * file = fopen(path, "rb");
    if (!file) {
        set_error("Could not open the converted audio.");
        return NULL;
    }

    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        set_error("Could not read the audio file.");
        return NULL;
    }
    const long file_size = ftell(file);
    rewind(file);

    if (file_size < 44) {
        fclose(file);
        set_error("The recorded audio is empty.");
        return NULL;
    }

    unsigned char * bytes = (unsigned char *) malloc((size_t) file_size);
    if (!bytes || fread(bytes, 1, (size_t) file_size, file) != (size_t) file_size) {
        free(bytes);
        fclose(file);
        set_error("Could not read the recorded audio.");
        return NULL;
    }
    fclose(file);

    if (memcmp(bytes, "RIFF", 4) != 0 || memcmp(bytes + 8, "WAVE", 4) != 0) {
        free(bytes);
        set_error("Audio conversion did not produce a WAV file.");
        return NULL;
    }

    uint16_t audio_format = 0;
    uint16_t channels = 0;
    uint16_t bits_per_sample = 0;
    uint32_t sample_rate = 0;
    const unsigned char * pcm = NULL;
    uint32_t pcm_size = 0;

    size_t offset = 12;
    while (offset + 8 <= (size_t) file_size) {
        const unsigned char * chunk = bytes + offset;
        const uint32_t chunk_size = read_u32(chunk + 4);
        const size_t data_offset = offset + 8;
        if (data_offset + chunk_size > (size_t) file_size) {
            break;
        }

        if (memcmp(chunk, "fmt ", 4) == 0 && chunk_size >= 16) {
            audio_format = read_u16(bytes + data_offset);
            channels = read_u16(bytes + data_offset + 2);
            sample_rate = read_u32(bytes + data_offset + 4);
            bits_per_sample = read_u16(bytes + data_offset + 14);
        } else if (memcmp(chunk, "data", 4) == 0) {
            pcm = bytes + data_offset;
            pcm_size = chunk_size;
        }
        offset = data_offset + chunk_size + (chunk_size & 1);
    }

    if (!pcm || audio_format != 1 || channels != 1 ||
        sample_rate != 16000 || bits_per_sample != 16) {
        free(bytes);
        set_error("Expected 16 kHz, mono, 16-bit PCM audio.");
        return NULL;
    }

    const int count = (int) (pcm_size / sizeof(int16_t));
    float * samples = (float *) malloc(sizeof(float) * (size_t) count);
    if (!samples) {
        free(bytes);
        set_error("Not enough memory for the recorded audio.");
        return NULL;
    }

    for (int i = 0; i < count; ++i) {
        const int16_t value = (int16_t) read_u16(pcm + (size_t) i * 2);
        samples[i] = (float) value / 32768.0f;
    }
    free(bytes);
    *sample_count = count;
    return samples;
}

static int vad_has_speech(
    const char * vad_model_path,
    const float * samples,
    int sample_count,
    float threshold
) {
    struct whisper_vad_context_params context_params =
        whisper_vad_default_context_params();
    context_params.n_threads = 4;
    context_params.use_gpu = false;
    struct whisper_vad_context * vad = whisper_vad_init_from_file_with_params(
        vad_model_path,
        context_params
    );
    if (!vad) {
        set_error("The voice-activity model could not be loaded.");
        return -1;
    }

    // Each recording is an independent utterance. A fresh context plus an
    // explicit reset guarantees that Silero's recurrent LSTM state can never
    // leak from one recording into the next.
    whisper_vad_reset_state(vad);
    if (!whisper_vad_detect_speech(vad, samples, sample_count)) {
        whisper_vad_free(vad);
        set_error("Voice-activity detection failed.");
        return -1;
    }

    struct whisper_vad_params params = whisper_vad_default_params();
    params.threshold = threshold;
    params.min_speech_duration_ms = 180;
    params.min_silence_duration_ms = 100;
    params.speech_pad_ms = 80;
    struct whisper_vad_segments * segments =
        whisper_vad_segments_from_probs(vad, params);
    if (!segments) {
        whisper_vad_free(vad);
        set_error("Voice-activity segmentation failed.");
        return -1;
    }

    const int has_speech = whisper_vad_segments_n_segments(segments) > 0;
    whisper_vad_free_segments(segments);
    whisper_vad_free(vad);
    return has_speech;
}

char * ew_whisper_transcribe(
    void * raw_context,
    const char * wav_path,
    const char * prompt,
    const char * vad_model_path
) {
    ew_error[0] = '\0';
    struct whisper_context * context = (struct whisper_context *) raw_context;
    if (!context) {
        set_error("The Whisper model is not ready.");
        return NULL;
    }

    int sample_count = 0;
    float * samples = load_pcm16_wav(wav_path, &sample_count);
    if (!samples) {
        return NULL;
    }

    if (vad_model_path && vad_model_path[0]) {
        int has_speech = vad_has_speech(
            vad_model_path,
            samples,
            sample_count,
            0.60f
        );
        // A second independent pass at a more permissive threshold protects
        // quiet real speech without ever reusing recurrent VAD state.
        if (has_speech == 0) {
            has_speech = vad_has_speech(
                vad_model_path,
                samples,
                sample_count,
                0.35f
            );
        }
        if (has_speech < 0) {
            free(samples);
            return NULL;
        }
        if (!has_speech) {
            free(samples);
            return (char *) calloc(1, 1);
        }
    }

    struct whisper_full_params params =
        whisper_full_default_params(ew_whisper_sampling_strategy);
    params.n_threads = 6;
    params.translate = false;
    params.no_context = true;
    params.no_timestamps = true;
    params.single_segment = false;
    params.print_special = false;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.language = "en";
    params.detect_language = false;
    params.suppress_blank = true;
    params.suppress_nst = true;
    params.temperature = 0.0f;
    params.temperature_inc = 0.2f;
    params.no_speech_thold = 0.6f;
    params.beam_search.beam_size = 5;
    params.beam_search.patience = 1.0f;
    params.initial_prompt = (prompt && prompt[0]) ? prompt : NULL;

    const int result = whisper_full(context, params, samples, sample_count);
    free(samples);
    if (result != 0) {
        set_error("Whisper could not transcribe the recording.");
        return NULL;
    }

    const int segment_count = whisper_full_n_segments(context);
    size_t length = 1;
    for (int i = 0; i < segment_count; ++i) {
        if (whisper_full_get_segment_no_speech_prob(context, i) >= 0.80f) {
            continue;
        }
        const char * segment = whisper_full_get_segment_text(context, i);
        if (segment) {
            length += strlen(segment);
        }
    }

    char * transcript = (char *) calloc(length, 1);
    if (!transcript) {
        set_error("Not enough memory for the transcript.");
        return NULL;
    }
    for (int i = 0; i < segment_count; ++i) {
        if (whisper_full_get_segment_no_speech_prob(context, i) >= 0.80f) {
            continue;
        }
        const char * segment = whisper_full_get_segment_text(context, i);
        if (segment) {
            strcat(transcript, segment);
        }
    }
    return transcript;
}

char * ew_parakeet_transcribe(
    void * raw_context,
    const char * wav_path,
    int n_threads
) {
    ew_error[0] = '\0';
    struct parakeet_context * context = (struct parakeet_context *) raw_context;
    if (!context) {
        set_error("The Parakeet model is not ready.");
        return NULL;
    }

    int sample_count = 0;
    float * samples = load_pcm16_wav(wav_path, &sample_count);
    if (!samples) {
        return NULL;
    }
    if (sample_count <= 0) {
        free(samples);
        set_error("No PCM samples found in audio path.");
        return NULL;
    }

    const int threads = (n_threads > 0) ? n_threads : 4;
    struct parakeet_full_params params = {
        .strategy = PARAKEET_SAMPLING_GREEDY,
        .n_threads = threads,
        .offset_ms = 0,
        .duration_ms = 0,
        .no_context = true,
        .audio_ctx = 0,
        .new_segment_callback = NULL,
        .new_segment_callback_user_data = NULL,
        .new_token_callback = NULL,
        .new_token_callback_user_data = NULL,
        .progress_callback = NULL,
        .progress_callback_user_data = NULL,
        .encoder_begin_callback = NULL,
        .encoder_begin_callback_user_data = NULL,
        .abort_callback = NULL,
        .abort_callback_user_data = NULL,
    };
    parakeet_reset_timings(context);
    const int rc = parakeet_full(
        context,
        params,
        samples,
        sample_count
    );
    free(samples);
    if (rc != 0) {
        set_error("Parakeet full transcribe failed.");
        return NULL;
    }

    const int segment_count = parakeet_full_n_segments(context);
    size_t length = 1;
    for (int i = 0; i < segment_count; ++i) {
        const char * segment = parakeet_full_get_segment_text(context, i);
        if (!segment) {
            continue;
        }
        const size_t segment_length = strlen(segment);
        length += segment_length;
    }
    char * transcript = (char *) calloc(length, 1);
    if (!transcript) {
        set_error("Not enough memory for the transcript.");
        return NULL;
    }
    for (int i = 0; i < segment_count; ++i) {
        const char * segment = parakeet_full_get_segment_text(context, i);
        if (!segment) {
            continue;
        }
        strcat(transcript, segment);
    }
    return transcript;
}

void ew_whisper_string_free(char * value) {
    free(value);
}

void ew_whisper_free(void * raw_context) {
    if (raw_context) {
        whisper_free((struct whisper_context *) raw_context);
    }
}

void ew_parakeet_free(void * raw_context) {
    if (!raw_context) {
        return;
    }
    parakeet_free((struct parakeet_context *) raw_context);
}

int ew_set_caps_lock_led(int enabled) {
    CFMutableDictionaryRef matching = IOServiceMatching(kIOHIDSystemClass);
    if (!matching) {
        return 0;
    }

    io_service_t service =
        IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (service == IO_OBJECT_NULL) {
        return 0;
    }

    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t result = IOServiceOpen(
        service,
        mach_task_self_,
        kIOHIDParamConnectType,
        &connection
    );
    IOObjectRelease(service);
    if (result != KERN_SUCCESS) {
        return 0;
    }

    result = IOHIDSetModifierLockState(
        connection,
        kIOHIDCapsLockState,
        enabled != 0
    );
    IOServiceClose(connection);
    return result == KERN_SUCCESS ? 1 : 0;
}
