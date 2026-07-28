#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void write_u16(FILE * file, uint16_t value) {
    fputc(value & 0xff, file);
    fputc((value >> 8) & 0xff, file);
}

static void write_u32(FILE * file, uint32_t value) {
    write_u16(file, value & 0xffff);
    write_u16(file, (value >> 16) & 0xffff);
}

int main(int argc, char ** argv) {
    if (argc != 3 ||
        (strcmp(argv[2], "silence") != 0 && strcmp(argv[2], "tone") != 0)) {
        fprintf(stderr, "usage: %s OUTPUT.wav silence|tone\n", argv[0]);
        return 2;
    }

    const uint32_t sample_rate = 16000;
    const uint32_t sample_count = sample_rate * 3;
    const uint32_t data_size = sample_count * 2;
    FILE * file = fopen(argv[1], "wb");
    if (!file) {
        perror("fopen");
        return 1;
    }

    fwrite("RIFF", 1, 4, file);
    write_u32(file, 36 + data_size);
    fwrite("WAVEfmt ", 1, 8, file);
    write_u32(file, 16);
    write_u16(file, 1);
    write_u16(file, 1);
    write_u32(file, sample_rate);
    write_u32(file, sample_rate * 2);
    write_u16(file, 2);
    write_u16(file, 16);
    fwrite("data", 1, 4, file);
    write_u32(file, data_size);

    uint32_t phase = 0;
    const int tone = strcmp(argv[2], "tone") == 0;
    for (uint32_t index = 0; index < sample_count; ++index) {
        int16_t sample = 0;
        if (tone) {
            phase = (phase + 440) % sample_rate;
            sample = phase < sample_rate / 2 ? 8192 : -8192;
        }
        write_u16(file, (uint16_t) sample);
    }

    fclose(file);
    return 0;
}
