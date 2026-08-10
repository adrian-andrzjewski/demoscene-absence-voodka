#pragma once

#include "audio_mix_abi.h"
#include "audio_thread_abi.h"

#include <cstddef>
#include <cstdint>

// Fixed-width handoff from the transitional host shim to the native assembly
// producer thread.  The pointers reference storage whose lifetime is owned by
// the caller and remains fixed until the thread has joined.
struct AudioAssemblyProducerArgs {
    const uint8_t* module;             // 0
    uint32_t moduleSize;               // 8
    uint32_t stateFrames;              // 12
    uint32_t maxTickFrames;            // 16
    uint32_t scratchFrames;            // 20
    const uint32_t* tickStarts;        // 24
    const uint32_t* modposByTick;      // 32
    AudioPcmRing* ring;                // 40
    AudioLiveControl* control;         // 48
    AudioTickState* states;            // 56
    int16_t* pcm;                      // 64
    AudioMixerHistory* history;        // 72
    volatile uint32_t* producerStop;   // 80
    volatile uint32_t* producerFailed; // 88
    volatile uint32_t* producerDone;   // 96
    volatile uint32_t* producerError;  // 104
};

static_assert(offsetof(AudioAssemblyProducerArgs, moduleSize) == 8);
static_assert(offsetof(AudioAssemblyProducerArgs, stateFrames) == 12);
static_assert(offsetof(AudioAssemblyProducerArgs, scratchFrames) == 20);
static_assert(offsetof(AudioAssemblyProducerArgs, tickStarts) == 24);
static_assert(offsetof(AudioAssemblyProducerArgs, ring) == 40);
static_assert(offsetof(AudioAssemblyProducerArgs, control) == 48);
static_assert(offsetof(AudioAssemblyProducerArgs, states) == 56);
static_assert(offsetof(AudioAssemblyProducerArgs, history) == 72);
static_assert(offsetof(AudioAssemblyProducerArgs, producerDone) == 96);
static_assert(offsetof(AudioAssemblyProducerArgs, producerError) == 104);
static_assert(sizeof(AudioAssemblyProducerArgs) == 112);

// DWORD WINAPI-compatible entry point for CreateThread.  It returns 0 on a
// clean stop or 1 after publishing producerFailed.
extern "C" uint32_t __stdcall asm_audio_producer_thread(void* args);

// Assembly-owned Win32 thread entry for the assembly WASAPI service. The
// host still supplies fixed argument/report records and joins the handle, but
// no C++ function sits between CreateThread and the assembly probe.
struct AudioAssemblyWorkerArgs {
    const AudioRingThreadArgs* args; // 0
    AudioRingThreadReport* report;   // 8
    volatile uint32_t* result;       // 16
};

static_assert(offsetof(AudioAssemblyWorkerArgs, report) == 8);
static_assert(offsetof(AudioAssemblyWorkerArgs, result) == 16);
static_assert(sizeof(AudioAssemblyWorkerArgs) == 24);

extern "C" uint32_t __stdcall asm_audio_ring_thread_entry(void* args);
