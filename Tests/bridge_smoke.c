#include "../Sources/Luxit/WhisperBridge.h"
#include <stdio.h>

int main(int argc, char ** argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: bridge_smoke MODEL WAV\n");
        return 2;
    }
    void * context = ew_whisper_load(argv[1]);
    if (!context) {
        fprintf(stderr, "load: %s\n", ew_whisper_last_error());
        return 1;
    }
    char * text = ew_whisper_transcribe(
        context,
        argv[2],
        "Accurate English dictation with natural punctuation."
    );
    if (!text) {
        fprintf(stderr, "transcribe: %s\n", ew_whisper_last_error());
        ew_whisper_free(context);
        return 1;
    }
    printf("%s\n", text);
    ew_whisper_string_free(text);
    ew_whisper_free(context);
    return 0;
}
