#pragma once

#include "audio_mix_abi.h"
#include "audio_thread_abi.h"

#include <cstddef>
#include <cstdint>

// Fixed-capacity storage owned by audio_service.asm. The descriptor is
// populated before any producer or WASAPI thread is created and remains valid
// until the host has joined both threads.
struct AudioAssemblyStorage {
    const uint8_t* module;              // 0
    uint32_t moduleSize;                // 8
    uint32_t stateFrames;               // 12
    uint32_t totalFrames;               // 16
    uint32_t maxTickFrames;             // 20
    uint32_t orderCount;                // 24
    uint32_t rowsPerLoop;               // 28
    uint32_t scratchFrames;             // 32
    const uint32_t* tickStarts;         // 40
    const uint32_t* modposByTick;       // 48
    const uint32_t* tickTimesMs;        // 56
    AudioTickState* states;             // 64
    int16_t* ringSamples;               // 72
    AudioRingMarker* ringMarkers;       // 80
    AudioTickState* producerStates;     // 88
    int16_t* producerPcm;               // 96
    AudioMixerHistory* producerHistory; // 104
};

static_assert(offsetof(AudioAssemblyStorage, moduleSize) == 8);
static_assert(offsetof(AudioAssemblyStorage, scratchFrames) == 32);
static_assert(offsetof(AudioAssemblyStorage, tickStarts) == 40);
static_assert(offsetof(AudioAssemblyStorage, states) == 64);
static_assert(offsetof(AudioAssemblyStorage, producerHistory) == 104);
static_assert(sizeof(AudioAssemblyStorage) == 112);

// Loads the MOD through Win32 from native assembly and prepares the fixed
// tracker/timeline storage without C++ allocation or file-I/O code.
extern "C" uint32_t asm_audio_service_storage_init(
    const char* modulePath, AudioAssemblyStorage* storage);

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
