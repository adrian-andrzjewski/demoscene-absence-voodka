#pragma once

#include <cstddef>
#include <cstdint>

#pragma pack(push, 1)
struct AudioTraceEntry {
    uint32_t frame;
    uint32_t timeMs;
    uint32_t position;
    uint32_t pattern;
    uint32_t row;
    uint32_t rows;
    uint32_t speed;
    uint32_t bpm;
    uint32_t frameTimeUs;
};
#pragma pack(pop)

static_assert(sizeof(AudioTraceEntry) == 36);
static_assert(offsetof(AudioTraceEntry, frameTimeUs) == 32);

extern "C" uint32_t asm_audio_trace_rows(const uint8_t* data,
                                          uint32_t size,
                                          AudioTraceEntry* out,
                                          uint32_t capacity);
