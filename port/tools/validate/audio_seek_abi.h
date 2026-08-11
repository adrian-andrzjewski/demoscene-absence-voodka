#pragma once

#include "audio_ring_abi.h"
#include "audio_thread_abi.h"

#include <cstddef>
#include <cstdint>

// Controller-side seek transaction shared by audio_asm.cpp and audio_seek.asm.
// The producer and WASAPI worker remain independent threads; this record only
// carries their fixed synchronization records and the cached state pointers.
struct AudioSeekTransactionArgs {
    AudioLiveControl* control;            // 0
    AudioPcmRing* ring;                   // 8
    volatile uint32_t* producerFailed;    // 16
    uint32_t targetTick;                  // 24
    uint32_t padding;                     // 28
    uint32_t* lastState;                  // 32
    uint32_t* lastSequence;               // 40
    uint32_t* baseConsumedOut;            // 48
    uint32_t* seekSequenceOut;            // 56
};

static_assert(offsetof(AudioSeekTransactionArgs, control) == 0);
static_assert(offsetof(AudioSeekTransactionArgs, ring) == 8);
static_assert(offsetof(AudioSeekTransactionArgs, targetTick) == 24);
static_assert(offsetof(AudioSeekTransactionArgs, lastState) == 32);
static_assert(offsetof(AudioSeekTransactionArgs, baseConsumedOut) == 48);
static_assert(offsetof(AudioSeekTransactionArgs, seekSequenceOut) == 56);
static_assert(sizeof(AudioSeekTransactionArgs) == 64);

// 0 = transaction failed before resume, 1 = complete success,
// 2 = commit/prebuffer completed but resume acknowledgement failed.
extern "C" uint32_t asm_audio_seek_transaction(
    const AudioSeekTransactionArgs* args);
