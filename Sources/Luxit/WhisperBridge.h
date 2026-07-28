#ifndef EDGE_WHISPER_BRIDGE_H
#define EDGE_WHISPER_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

void * ew_whisper_load(const char * model_path);
void ew_whisper_set_strategy(int strategy);
void * ew_parakeet_load(
    const char * model_path,
    const char * library_path,
    int use_gpu,
    int gpu_device
);
char * ew_whisper_transcribe(
    void * context,
    const char * wav_path,
    const char * prompt,
    const char * vad_model_path
);
char * ew_parakeet_transcribe(
    void * context,
    const char * wav_path,
    int n_threads
);
void ew_whisper_string_free(char * value);
void ew_whisper_free(void * context);
void ew_parakeet_free(void * context);
const char * ew_whisper_last_error(void);
int ew_set_caps_lock_led(int enabled);
typedef void (*ew_caps_lock_press_callback)(void * context);
void * ew_caps_lock_listener_create(
    ew_caps_lock_press_callback callback,
    void * context
);
void ew_caps_lock_listener_destroy(void * listener);

#ifdef __cplusplus
}
#endif

#endif
