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
    uint8_t restart;
    AudioEvent event;
    // Logical source-frame position; mixing/interpolation is a later gate.
    double samplePosition;
    // Exact libxmp mixer step in source frames per output frame.
    double sampleStep;
    // Integer output frames rendered for this tracker tick.
    uint32_t tickFrames;
    // Private mixer volume. Public channel volume may be zero while a
    // retriggered voice still needs its internal volume for PCM rendering.
    uint8_t mixerVolume;
};
#pragma pack(pop)

static_assert(sizeof(AudioTickState) == 41);
static_assert(offsetof(AudioTickState, pitchbend) == 4);
static_assert(offsetof(AudioTickState, restart) == 11);
static_assert(offsetof(AudioTickState, event) == 12);
static_assert(offsetof(AudioTickState, samplePosition) == 20);
static_assert(offsetof(AudioTickState, sampleStep) == 28);
static_assert(offsetof(AudioTickState, tickFrames) == 36);
static_assert(offsetof(AudioTickState, mixerVolume) == 40);

extern "C" uint32_t asm_audio_trace_tick_states(const uint8_t* data,
                                                  uint32_t size,
                                                  AudioTickState* out,
                                                  uint32_t frameCapacity);
