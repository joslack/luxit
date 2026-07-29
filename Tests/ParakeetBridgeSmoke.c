#include "../Sources/Luxit/WhisperBridge.h"

#include <stdio.h>
#include <stdlib.h>

static int run_profile(
    const char * label,
    int use_gpu,
    const char * model_path,
    const char * wav_path,
    const char * vad_model_path
) {
    void * context = ew_parakeet_load(
        model_path,
        "/opt/homebrew/opt/whisper-cpp/lib/libparakeet.dylib",
        use_gpu,
        0
    );
    if (!context) {
        fprintf(stderr, "load: %s\n", ew_whisper_last_error());
        return 0;
    }

    char * text = ew_parakeet_transcribe(
        context,
        wav_path,
        vad_model_path,
        4
    );
    if (!text) {
        fprintf(stderr, "transcribe: %s\n", ew_whisper_last_error());
        ew_parakeet_free(context);
        return 0;
    }

    printf("%s: %s\n", label, text);
    ew_whisper_string_free(text);
    ew_parakeet_free(context);
    return 1;
}

int main(int argc, char ** argv) {
    if (argc != 5) {
        fprintf(
            stderr,
            "usage: %s metal|cpu|sequence MODEL WAV VAD_MODEL\n",
            argv[0]
        );
        return 2;
    }

    if (argv[1][0] == 's') {
        if (!run_profile("cpu", 0, argv[2], argv[3], argv[4])) return 1;
        if (!run_profile("metal", 1, argv[2], argv[3], argv[4])) return 1;
        return 0;
    }

    return run_profile(
        argv[1],
        argv[1][0] == 'm',
        argv[2],
        argv[3],
        argv[4]
    ) ? 0 : 1;
}
