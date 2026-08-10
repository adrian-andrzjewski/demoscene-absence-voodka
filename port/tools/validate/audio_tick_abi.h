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

// Persistent state owned by the assembly tracker entry points. The internal
// 80-byte channel records are intentionally opaque to the host validator; the
// fixed prefix is retained here so ABI drift is caught at compile time.
#pragma pack(push, 1)
struct AudioLiveTrackerContext {
    const uint8_t* module;
    uint32_t moduleSize;
    uint32_t orderCount;
    uint32_t order;
    uint32_t row;
    uint32_t tick;
    uint32_t speed;
    uint32_t bpm;
    uint32_t finished;
    uint64_t frames;
    uint8_t reserved[16];
    uint8_t internalState[14 * 80];
};
#pragma pack(pop)

static_assert(offsetof(AudioLiveTrackerContext, moduleSize) == 8);
static_assert(offsetof(AudioLiveTrackerContext, order) == 16);
static_assert(offsetof(AudioLiveTrackerContext, tick) == 24);
static_assert(offsetof(AudioLiveTrackerContext, frames) == 40);
static_assert(offsetof(AudioLiveTrackerContext, internalState) == 64);
static_assert(sizeof(AudioLiveTrackerContext) == 1184);

extern "C" uint32_t asm_audio_trace_tick_states(const uint8_t* data,
                                                  uint32_t size,
                                                  AudioTickState* out,
                                                  uint32_t frameCapacity);

extern "C" uint32_t asm_audio_live_init(const uint8_t* data,
                                          uint32_t size,
                                          AudioLiveTrackerContext* context);

extern "C" uint32_t asm_audio_live_next(AudioLiveTrackerContext* context,
                                          AudioTickState* out);
