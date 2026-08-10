#pragma once

#include "audio_event_abi.h"

#include <cstddef>
#include <cstdint>

#pragma pack(push, 1)
struct AudioVoiceState {
    AudioEvent event;
    uint8_t note;
    uint8_t instrument;
    uint8_t sample;
    uint8_t sampleVolume;
};
#pragma pack(pop)

static_assert(sizeof(AudioVoiceState) == 12);
static_assert(offsetof(AudioVoiceState, note) == 8);
static_assert(offsetof(AudioVoiceState, sampleVolume) == 11);

extern "C" uint32_t asm_audio_trace_voice_rows(const uint8_t* data,
                                                 uint32_t size,
                                                 AudioVoiceState* out,
                                                 uint32_t capacity);
