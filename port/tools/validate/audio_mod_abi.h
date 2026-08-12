#pragma once

#include <cstddef>
#include <cstdint>

namespace audio_abi {

#pragma pack(push, 1)
struct Sample {
    uint32_t length;
    uint32_t loopStart;
    uint32_t loopEnd;
    uint32_t flags;
};

struct Effect {
    uint32_t count;
    uint8_t minParam;
    uint8_t maxParam;
    uint16_t reserved;
};

struct Summary {
    uint32_t status;
    uint32_t moduleBytes;
    uint32_t headerBytes;
    uint32_t patternDataOffset;
    uint32_t sampleDataOffset;
    uint32_t sampleDataBytes;
    uint32_t trailingBytes;
    uint32_t rowsPerLoop;
    uint32_t modposPerLoop;
    uint32_t orderCount;
    uint32_t patternCount;
    uint32_t channelCount;
    uint32_t instrumentCount;
    uint32_t populatedEvents;
    uint32_t noteEvents;
    uint32_t instrumentEvents;
    uint32_t volumeEvents;
    uint8_t orders[128];
    uint32_t patternRows[64];
    Sample samples[31];
    Effect primaryEffects[16];
    Effect secondaryEffects[16];
};
#pragma pack(pop)

static_assert(sizeof(Sample) == 16);
static_assert(sizeof(Effect) == 8);
static_assert(offsetof(Summary, orders) == 68);
static_assert(offsetof(Summary, patternRows) == 196);
static_assert(offsetof(Summary, samples) == 452);
static_assert(offsetof(Summary, primaryEffects) == 948);
static_assert(offsetof(Summary, secondaryEffects) == 1076);
static_assert(sizeof(Summary) == 1204);

} // namespace audio_abi

extern "C" uint32_t asm_audio_parse_mod(const uint8_t* data,
                                          uint32_t size,
                                          audio_abi::Summary* out);
