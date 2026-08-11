#pragma once

#include <cstddef>
#include <cstdint>

// Fixed ABI record shared by the production audio runtime and the lifecycle
// probe.  Entry points are stored as integers so this header remains free of
// Windows headers; NASM passes them directly to CreateThread.
struct AudioWorkerLifecycleArgs {
    void** producerHandle;             // 0
    uint64_t producerEntry;            // 8
    void* producerArgs;                // 16
    void* ring;                         // 24
    volatile uint32_t* producerFailed; // 32
    void** workerHandle;                // 40
    uint64_t workerEntry;              // 48
    void* workerArgs;                  // 56
    void* control;                      // 64
    volatile uint32_t* producerStop;   // 72
};

static_assert(offsetof(AudioWorkerLifecycleArgs, producerEntry) == 8);
static_assert(offsetof(AudioWorkerLifecycleArgs, ring) == 24);
static_assert(offsetof(AudioWorkerLifecycleArgs, workerHandle) == 40);
static_assert(offsetof(AudioWorkerLifecycleArgs, workerArgs) == 56);
static_assert(offsetof(AudioWorkerLifecycleArgs, producerStop) == 72);
static_assert(sizeof(AudioWorkerLifecycleArgs) == 80);

extern "C" uint32_t asm_audio_start_workers(
    const AudioWorkerLifecycleArgs* args);
extern "C" uint32_t asm_audio_stop_workers(
    const AudioWorkerLifecycleArgs* args);
