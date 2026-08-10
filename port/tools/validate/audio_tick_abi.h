#pragma once

#include "audio_event_abi.h"

#include <cstddef>
#include <cstdint>

#pragma pack(push, 1)
struct AudioTickState {
    uint32_t period;
    int16_t pitchbend;
    uint8_t note;
    uint8_t instrument;
    uint8_t sample;
    uint8_t volume;
    uint8_t pan;
    uint8_t reserved;
    AudioEvent event;
    // Logical source-frame position; mixing/interpolation is a later gate.
    double samplePosition;
};
#pragma pack(pop)

static_assert(sizeof(AudioTickState) == 28);
static_assert(offsetof(AudioTickState, pitchbend) == 4);
static_assert(offsetof(AudioTickState, event) == 12);
static_assert(offsetof(AudioTickState, samplePosition) == 20);

extern "C" uint32_t asm_audio_trace_tick_states(const uint8_t* data,
                                                  uint32_t size,
                                                  AudioTickState* out,
                                                  uint32_t frameCapacity);
