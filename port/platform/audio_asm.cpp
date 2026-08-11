// audio_asm.cpp - production orchestration for the dedicated assembly player.
//
// The tracker, mixer, PCM ring, timeline markers, and WASAPI render worker
// are native x64 assembly.  This file is intentionally only the transitional
// host shim: it owns synchronization records and translates the existing
// platform audio ABI into the assembly contracts.  Worker creation, rollback,
// joining, and handle cleanup live in audio_workers.asm.
// The old audio.cpp/libxmp path remains available as the behavioral oracle.

#include "platform_abi.h"
#include "../tools/validate/audio_controller_abi.h"
#include "../tools/validate/audio_mix_abi.h"
#include "../tools/validate/audio_ring_abi.h"
#include "../tools/validate/audio_seek_abi.h"
#include "../tools/validate/audio_service_abi.h"
#include "../tools/validate/audio_thread_abi.h"
#include "../tools/validate/audio_tick_abi.h"

#include <cstdint>

extern "C" uint32_t asm_audio_lower_bound_u32(const uint32_t* values,
                                                uint32_t count,
                                                uint32_t key);
extern "C" unsigned char asm_audio_runtime_state[0x2000];

namespace vk {

namespace {

constexpr uint32_t kSampleRate = 44100;
struct Runtime {
    AudioAssemblyStorage storage{};
    AudioAssemblyProducerArgs producerArgs{};
    AudioPcmRing ring{};
    AudioLiveControl control{};
    AudioRingThreadArgs workerArgs{};
    AudioAssemblyWorkerArgs workerServiceArgs{};
    AudioRingThreadReport workerReport{};

    void* producerHandle = nullptr;
    void* workerControllerHandle = nullptr;
    volatile int32_t producerStop = 0;
    volatile int32_t producerFailed = 0;
    volatile int32_t workerControllerResult = 1;
    volatile int32_t producerDone = 0;
    volatile int32_t producerError = 0;

    volatile int32_t initialized = 0;
    volatile int32_t shuttingDown = 0;
    volatile int32_t playing = 1;
    uint32_t lastControlState = 0;
    uint32_t lastControlSequence = 0;
    uint32_t seekBaseFrame = 0;
    uint32_t seekSourceTick = 0;
    double seekTimeBase = 0.0;
};

static_assert(sizeof(Runtime) <= 0x2000,
              "assembly-owned audio runtime block is too small");
static_assert(sizeof(Runtime) == sizeof(AudioControllerRuntimeView));
static_assert(offsetof(Runtime, producerArgs) == 112);
static_assert(offsetof(Runtime, ring) == 224);
static_assert(offsetof(Runtime, control) == 288);
static_assert(offsetof(Runtime, workerReport) == 376);
static_assert(offsetof(Runtime, initialized) == 564);
static_assert(offsetof(Runtime, playing) == 572);
static_assert(offsetof(Runtime, seekTimeBase) == 592);

// The state layout remains described by this POD for now, but its storage is
// no longer a C++ global object.  The shipped and reference targets both use
// the same loader-zeroed NASM block, which removes one C++ data owner without
// changing any field offsets or orchestration behavior.
#define g_runtime (*reinterpret_cast<Runtime*>(asm_audio_runtime_state))

bool seekTick(Runtime* runtime, uint32_t targetTick) {
    uint32_t baseConsumed = 0;
    uint32_t seekSequence = 0;
    const AudioSeekTransactionArgs transaction{
        &runtime->control,
        &runtime->ring,
        reinterpret_cast<volatile uint32_t*>(&runtime->producerFailed),
        targetTick,
        0,
        &runtime->lastControlState,
        &runtime->lastControlSequence,
        &baseConsumed,
        &seekSequence,
    };
    const uint32_t transactionStatus =
        asm_audio_seek_transaction(&transaction);
    if (transactionStatus == 0) return false;

    runtime->seekBaseFrame = baseConsumed;
    runtime->seekSourceTick = targetTick;
    runtime->seekTimeBase =
        static_cast<double>(runtime->storage.tickStarts[targetTick]) /
        kSampleRate;
    return transactionStatus == 1;
}

uint32_t tickForModPos(const Runtime* runtime, uint32_t modpos) {
    return asm_audio_lower_bound_u32(runtime->storage.modposByTick,
                                     runtime->storage.stateFrames, modpos);
}

uint32_t tickForMs(const Runtime* runtime, uint32_t ms) {
    return asm_audio_lower_bound_u32(runtime->storage.tickTimesMs,
                                     runtime->storage.stateFrames, ms);
}

} // namespace

uint32_t audioAsmSeekRows(uint32_t modpos) {
    if (!g_runtime.initialized) return 0;
    const uint32_t tick = tickForModPos(&g_runtime, modpos);
    return seekTick(&g_runtime, tick)
        ? g_runtime.storage.modposByTick[tick] : 0;
}

uint32_t audioAsmSeekMs(int ms) {
    if (!g_runtime.initialized || ms < 0) return 0;
    const uint32_t tick = tickForMs(&g_runtime, static_cast<uint32_t>(ms));
    return seekTick(&g_runtime, tick)
        ? g_runtime.storage.modposByTick[tick] : 0;
}

uint32_t audioAsmSeekOrder(int order) {
    if (!g_runtime.initialized || order < 0) return 0;
    return audioAsmSeekRows(static_cast<uint32_t>(order) << 8);
}

} // namespace vk
