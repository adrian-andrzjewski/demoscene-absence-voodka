#pragma once

#include "audio_service_abi.h"
#include "audio_thread_abi.h"

#include <cstddef>
#include <cstdint>

// Assembly view of the loader-zeroed audio runtime block. HANDLE and LONG
// are represented by size-compatible portable fields so the ABI can be used
// by probes without making the assembly controller depend on windows.h.
struct AudioControllerRuntimeView {
    AudioAssemblyStorage storage;              // 0
    AudioAssemblyProducerArgs producerArgs;    // 112
    AudioPcmRing ring;                          // 224
    AudioLiveControl control;                   // 288
    AudioRingThreadArgs workerArgs;             // 328
    AudioAssemblyWorkerArgs workerServiceArgs; // 352
    AudioRingThreadReport workerReport;         // 376
    void* producerHandle;                       // 528
    void* workerControllerHandle;               // 536
    int32_t producerStop;                       // 544
    int32_t producerFailed;                     // 548
    int32_t workerControllerResult;             // 552
    int32_t producerDone;                       // 556
    int32_t producerError;                      // 560
    int32_t initialized;                        // 564
    int32_t shuttingDown;                       // 568
    int32_t playing;                            // 572
    uint32_t lastControlState;                  // 576
    uint32_t lastControlSequence;               // 580
    uint32_t seekBaseFrame;                     // 584
    uint32_t seekSourceTick;                    // 588
    double seekTimeBase;                        // 592
};

static_assert(offsetof(AudioControllerRuntimeView, producerArgs) == 112);
static_assert(offsetof(AudioControllerRuntimeView, ring) == 224);
static_assert(offsetof(AudioControllerRuntimeView, control) == 288);
static_assert(offsetof(AudioControllerRuntimeView, workerReport) == 376);
static_assert(offsetof(AudioControllerRuntimeView, initialized) == 564);
static_assert(offsetof(AudioControllerRuntimeView, playing) == 572);
static_assert(offsetof(AudioControllerRuntimeView, seekTimeBase) == 592);
static_assert(sizeof(AudioControllerRuntimeView) == 600);

extern "C" unsigned char asm_audio_runtime_state[0x2000];
