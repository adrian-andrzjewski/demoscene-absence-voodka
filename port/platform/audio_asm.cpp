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
#include "../tools/validate/audio_workers_abi.h"

#include <windows.h>

#include <cstdint>
#include <cstdio>

extern "C" uint32_t asm_audio_lower_bound_u32(const uint32_t* values,
                                                uint32_t count,
                                                uint32_t key);
extern "C" unsigned char asm_audio_runtime_state[0x2000];
extern "C" uint32_t asm_audio_issue_state(AudioLiveControl* control,
                                             uint32_t state,
                                             uint32_t* lastState,
                                             uint32_t* lastSequence,
                                             uint32_t* sequenceOut);

namespace vk {

namespace {

constexpr uint32_t kSampleRate = 44100;
constexpr uint32_t kRingCapacity = 16384;
constexpr uint32_t kMarkerCapacity = 16384;

struct Runtime {
    AudioAssemblyStorage storage{};
    AudioAssemblyProducerArgs producerArgs{};
    AudioPcmRing ring{};
    AudioLiveControl control{};
    AudioRingThreadArgs workerArgs{};
    AudioAssemblyWorkerArgs workerServiceArgs{};
    AudioRingThreadReport workerReport{};

    HANDLE producerHandle = nullptr;
    HANDLE workerControllerHandle = nullptr;
    volatile LONG producerStop = 0;
    volatile LONG producerFailed = 0;
    volatile LONG workerControllerResult = 1;
    volatile LONG producerDone = 0;
    volatile LONG producerError = 0;

    volatile LONG initialized = 0;
    volatile LONG shuttingDown = 0;
    volatile LONG playing = 1;
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

void clearRuntime() {
    if (g_runtime.ring.samples) asm_audio_ring_close(&g_runtime.ring);
    g_runtime = Runtime{};
}

} // namespace

void audioAsmShutdown();

int audioAsmInit(const char* modPath, int) {
    if (g_runtime.initialized) return 1;
    char forcedFailure[4] = {};
    if (GetEnvironmentVariableA("VOODKA_ASM_AUDIO_FAIL_DEVICE",
                                forcedFailure, sizeof(forcedFailure)) != 0) {
        logPrint("[audio-asm] forced device failure injection\n");
        return 0;
    }
    const uint32_t storageStatus = modPath
        ? asm_audio_service_storage_init(modPath, &g_runtime.storage) : 1;
    if (storageStatus != 0) {
        logPrint("[audio-asm] native module/storage preparation failed "
                 "status=%u\n", storageStatus);
        clearRuntime();
        return 0;
    }

    if (asm_audio_ring_init(&g_runtime.ring,
                            g_runtime.storage.ringSamples,
                            kRingCapacity,
                            g_runtime.storage.ringMarkers,
                            kMarkerCapacity) != 0) {
        logPrint("[audio-asm] ring initialization failed\n");
        clearRuntime();
        return 0;
    }

    g_runtime.producerArgs = {
        g_runtime.storage.module,
        g_runtime.storage.moduleSize,
        g_runtime.storage.stateFrames,
        g_runtime.storage.maxTickFrames,
        g_runtime.storage.scratchFrames,
        g_runtime.storage.tickStarts,
        g_runtime.storage.modposByTick,
        &g_runtime.ring,
        &g_runtime.control,
        g_runtime.storage.producerStates,
        g_runtime.storage.producerPcm,
        g_runtime.storage.producerHistory,
        reinterpret_cast<volatile uint32_t*>(&g_runtime.producerStop),
        reinterpret_cast<volatile uint32_t*>(&g_runtime.producerFailed),
        reinterpret_cast<volatile uint32_t*>(&g_runtime.producerDone),
        reinterpret_cast<volatile uint32_t*>(&g_runtime.producerError),
    };
    g_runtime.workerArgs = {&g_runtime.ring, 0, &g_runtime.control};
    g_runtime.workerServiceArgs = {
        &g_runtime.workerArgs,
        &g_runtime.workerReport,
        reinterpret_cast<volatile uint32_t*>(&g_runtime.workerControllerResult),
    };
    const AudioWorkerLifecycleArgs workerLifecycle{
        reinterpret_cast<void**>(&g_runtime.producerHandle),
        reinterpret_cast<uint64_t>(asm_audio_producer_thread),
        &g_runtime.producerArgs,
        &g_runtime.ring,
        reinterpret_cast<volatile uint32_t*>(&g_runtime.producerFailed),
        reinterpret_cast<void**>(&g_runtime.workerControllerHandle),
        reinterpret_cast<uint64_t>(asm_audio_ring_thread_entry),
        &g_runtime.workerServiceArgs,
        &g_runtime.control,
        reinterpret_cast<volatile uint32_t*>(&g_runtime.producerStop),
    };
    const uint32_t workerStatus = asm_audio_start_workers(&workerLifecycle);
    if (workerStatus != 0) {
        if (workerStatus == 1) {
            logPrint("[audio-asm] producer prebuffer failed failed=%ld done=%ld "
                     "error=%ld write=%u read=%u\n",
                     g_runtime.producerFailed, g_runtime.producerDone,
                     g_runtime.producerError,
                     g_runtime.ring.writeFrame, g_runtime.ring.readFrame);
        } else if (workerStatus == 2) {
            logPrint("[audio-asm] worker controller creation failed\n");
        } else {
            logPrint("[audio-asm] assembly WASAPI worker exited during startup\n");
        }
        audioAsmShutdown();
        return 0;
    }

    InterlockedExchange(&g_runtime.playing, 1);
    InterlockedExchange(&g_runtime.initialized, 1);
    logPrint("[audio-asm] dedicated player active, orders=%u, 44100Hz stereo\n",
             g_runtime.storage.orderCount);
    return 1;
}

void audioAsmShutdown() {
    if (g_runtime.shuttingDown) return;
    InterlockedExchange(&g_runtime.shuttingDown, 1);
    InterlockedExchange(&g_runtime.playing, 0);
    const AudioWorkerLifecycleArgs workerLifecycle{
        reinterpret_cast<void**>(&g_runtime.producerHandle),
        0,
        nullptr,
        nullptr,
        reinterpret_cast<volatile uint32_t*>(&g_runtime.producerFailed),
        reinterpret_cast<void**>(&g_runtime.workerControllerHandle),
        0,
        nullptr,
        &g_runtime.control,
        reinterpret_cast<volatile uint32_t*>(&g_runtime.producerStop),
    };
    asm_audio_stop_workers(&workerLifecycle);
    if (g_runtime.ring.samples) asm_audio_ring_close(&g_runtime.ring);
    logPrint("[audio-asm] stopped: device_frames=%u underruns=%u markers=%u\n",
             g_runtime.workerReport.common.frames,
             g_runtime.workerReport.underrunEvents,
             g_runtime.workerReport.snapshotUpdates);
    clearRuntime();
}

int audioAsmPlay() {
    InterlockedExchange(&g_runtime.playing, 1);
    return 1;
}

int audioAsmStop() {
    InterlockedExchange(&g_runtime.playing, 0);
    return 1;
}

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
