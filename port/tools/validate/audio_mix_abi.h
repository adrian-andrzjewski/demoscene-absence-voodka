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
