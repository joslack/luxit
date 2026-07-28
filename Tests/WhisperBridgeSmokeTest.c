#include "../Sources/Luxit/WhisperBridge.h"

#include <ctype.h>
#include <stdio.h>
#include <string.h>

static int has_visible_text(const char * text) {
    if (!text) {
        return 0;
    }
    while (*text) {
        if (!isspace((unsigned char) *text)) {
            return 1;
        }
        ++text;
    }
    return 0;
}

int main(int argc, char ** argv) {
    if (argc != 5) {
        fprintf(
            stderr,
            "usage: %s MODEL VAD_MODEL SILENCE.wav SPEECH.wav\n",
            argv[0]
        );
        return 2;
    }

    void * context = ew_whisper_load(argv[1]);
    if (!context) {
        fprintf(stderr, "model load failed: %s\n", ew_whisper_last_error());
        return 1;
    }

    for (int iteration = 0; iteration < 5; ++iteration) {
        char * silence = ew_whisper_transcribe(context, argv[3], "", argv[2]);
        if (!silence) {
            fprintf(stderr, "silence inference failed: %s\n", ew_whisper_last_error());
            ew_whisper_free(context);
            return 1;
        }
        if (has_visible_text(silence)) {
            fprintf(stderr, "silence produced text: %s\n", silence);
            ew_whisper_string_free(silence);
            ew_whisper_free(context);
            return 1;
        }
        ew_whisper_string_free(silence);

        char * speech = ew_whisper_transcribe(context, argv[4], "", argv[2]);
        if (!speech) {
            fprintf(stderr, "speech inference failed: %s\n", ew_whisper_last_error());
            ew_whisper_free(context);
            return 1;
        }
        if (!has_visible_text(speech)) {
            fprintf(stderr, "speech was incorrectly rejected on iteration %d\n", iteration);
            ew_whisper_string_free(speech);
            ew_whisper_free(context);
            return 1;
        }
        if (iteration == 4) {
            printf("WhisperBridgeSmokeTest passed: %s\n", speech);
        }
        ew_whisper_string_free(speech);
    }

    ew_whisper_free(context);
    return 0;
}
