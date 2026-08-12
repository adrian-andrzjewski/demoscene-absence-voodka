#pragma once

#include <cstddef>
#include <cstdint>

#pragma pack(push, 1)
struct AudioEvent {
    uint8_t note;
    uint8_t instrument;
    uint8_t volume;
    uint8_t effect;
    uint8_t parameter;
    uint8_t secondaryEffect;
    uint8_t secondaryParameter;
    uint8_t flags;
};
#pragma pack(pop)

static_assert(sizeof(AudioEvent) == 8);
static_assert(offsetof(AudioEvent, effect) == 3);
static_assert(offsetof(AudioEvent, parameter) == 4);

extern "C" uint32_t asm_audio_decode_event(const uint8_t* raw4,
                                             AudioEvent* out);
