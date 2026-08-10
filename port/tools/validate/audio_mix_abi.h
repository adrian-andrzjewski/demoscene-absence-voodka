#pragma once

#include "audio_tick_abi.h"

#include <cstdint>

// The mixer consumes the assembly-generated per-tick states and the original
// packed MOD bytes. It returns interleaved signed 16-bit stereo frames.
extern "C" uint32_t asm_audio_mix_tick_states(const uint8_t* module,
                                                uint32_t moduleSize,
                                                const AudioTickState* states,
                                                uint32_t stateFrames,
                                                int16_t* output,
                                                uint32_t outputCapacity);

// Persistent mixer history for bounded/live calls. The four arrays mirror
// the native mixer's per-channel anti-click and ramp state and are owned by
// the caller so consecutive chunks are sample-continuous.
#pragma pack(push, 1)
struct AudioMixerHistory {
    int32_t oldLeft[14];
    int32_t oldRight[14];
    int32_t sampleLeft[14];
    int32_t sampleRight[14];
};
#pragma pack(pop)

static_assert(sizeof(AudioMixerHistory) == 224);

extern "C" uint32_t asm_audio_mix_tick_states_continuous(
    const uint8_t* module,
    uint32_t moduleSize,
    const AudioTickState* states,
    uint32_t stateFrames,
    int16_t* output,
    uint32_t outputCapacity,
    AudioMixerHistory* history);
