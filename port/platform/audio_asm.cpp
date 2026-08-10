// audio_asm.cpp - production orchestration for the dedicated assembly player.
//
// The tracker, mixer, PCM ring, timeline markers, and WASAPI render worker
// are native x64 assembly.  This file is intentionally only the transitional
// host shim: it loads the module, owns Win32 thread handles and vectors, and
// translates the existing platform audio ABI into the assembly contracts.
// The old audio.cpp/libxmp path remains available as the behavioral oracle.

#include "platform_abi.h"
#include "../tools/validate/audio_mix_abi.h"
#include "../tools/validate/audio_mod_abi.h"
#include "../tools/validate/audio_ring_abi.h"
#include "../tools/validate/audio_service_abi.h"
#include "../tools/validate/audio_thread_abi.h"
#include "../tools/validate/audio_tick_abi.h"
#include "../tools/validate/audio_tracker_abi.h"

#include <windows.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <limits>
#include <vector>

namespace vk {

namespace {

constexpr uint32_t kChannels = 14;
constexpr uint32_t kOutputChannels = 2;
constexpr uint32_t kStateCapacity = 20000;
constexpr uint32_t kTickChunk = 31;
constexpr uint32_t kRingCapacity = 16384;
constexpr uint32_t kMarkerCapacity = 16384;
constexpr uint32_t kPrebufferFrames = 8192;
constexpr uint32_t kSampleRate = 44100;

struct Runtime {
    std::vector<uint8_t> module;
    std::vector<uint32_t> tickStarts;
    std::vector<uint32_t> modposByTick;
    std::vector<uint32_t> tickTimesMs;
    uint32_t stateFrames = 0;
    uint32_t totalFrames = 0;
    uint32_t maxTickFrames = 0;
    uint32_t orderCount = 0;

    std::vector<int16_t> ringSamples;
    std::vector<AudioRingMarker> ringMarkers;
    std::vector<AudioTickState> producerStates;
    std::vector<int16_t> producerPcm;
    AudioMixerHistory producerHistory{};
    AudioAssemblyProducerArgs producerArgs{};
    AudioPcmRing ring{};
    AudioLiveControl control{};
    AudioRingThreadArgs workerArgs{};
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

Runtime g_runtime;

bool readModule(const char* path, std::vector<uint8_t>* out) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) return false;
    const std::streamoff size = file.tellg();
    if (size <= 0 || size > std::numeric_limits<uint32_t>::max()) return false;
    out->resize(static_cast<size_t>(size));
    file.seekg(0, std::ios::beg);
    return static_cast<bool>(file.read(reinterpret_cast<char*>(out->data()), size));
}

bool checkedTiming(const std::vector<AudioTickState>& states,
                   uint32_t stateFrames, Runtime* runtime) {
    if (!stateFrames || states.size() <
            static_cast<size_t>(stateFrames) * kChannels) return false;
    runtime->tickStarts.resize(static_cast<size_t>(stateFrames) + 1);
    uint64_t total = 0;
    uint32_t maxTick = 0;
    for (uint32_t frame = 0; frame < stateFrames; ++frame) {
        const uint32_t tickFrames =
            states[static_cast<size_t>(frame) * kChannels].tickFrames;
        if (!tickFrames || total > std::numeric_limits<uint32_t>::max())
            return false;
        runtime->tickStarts[frame] = static_cast<uint32_t>(total);
        total += tickFrames;
        maxTick = std::max(maxTick, tickFrames);
    }
    if (total > std::numeric_limits<uint32_t>::max() || !total) return false;
    runtime->tickStarts[stateFrames] = static_cast<uint32_t>(total);
    runtime->totalFrames = static_cast<uint32_t>(total);
    runtime->maxTickFrames = maxTick;
    return true;
}

bool buildTimeline(const uint8_t* module, uint32_t moduleSize,
                   uint32_t stateFrames, Runtime* runtime) {
    audio_abi::Summary summary{};
    if (asm_audio_parse_mod(module, moduleSize, &summary) != 0 ||
        summary.status != 0 || !summary.rowsPerLoop) return false;
    runtime->orderCount = summary.orderCount;

    std::vector<AudioTraceEntry> rows(summary.rowsPerLoop);
    const uint32_t count = asm_audio_trace_rows(
        module, moduleSize, rows.data(), summary.rowsPerLoop);
    if (count != summary.rowsPerLoop || rows.empty() || rows[0].frame != 0)
        return false;

    runtime->modposByTick.resize(stateFrames);
    runtime->tickTimesMs.resize(stateFrames);
    size_t row = 0;
    for (uint32_t frame = 0; frame < stateFrames; ++frame) {
        while (row + 1 < rows.size() && rows[row + 1].frame <= frame)
            ++row;
        runtime->modposByTick[frame] =
            (rows[row].position << 8) | rows[row].row;
        runtime->tickTimesMs[frame] = rows[row].timeMs;
    }
    return true;
}

DWORD WINAPI workerControllerThread(void* raw) {
    auto* runtime = static_cast<Runtime*>(raw);
    const uint32_t result = asm_audio_ring_thread_probe(
        &runtime->workerArgs, &runtime->workerReport);
    InterlockedExchange(&runtime->workerControllerResult,
                        static_cast<LONG>(result));
    return result;
}

bool issueState(Runtime* runtime, uint32_t state, uint32_t* sequenceOut) {
    InterlockedExchange(
        reinterpret_cast<volatile LONG*>(&runtime->control.requestedState),
        static_cast<LONG>(state));
    const LONG sequence = InterlockedIncrement(
        reinterpret_cast<volatile LONG*>(&runtime->control.requestSequence));
    for (uint32_t i = 0; i < 5000; ++i) {
        if (runtime->control.acknowledgedSequence ==
                static_cast<uint32_t>(sequence) &&
            (state & 1) == runtime->control.acknowledgedState) {
            runtime->lastControlState = state & 1;
            runtime->lastControlSequence = static_cast<uint32_t>(sequence);
            if (sequenceOut) *sequenceOut = static_cast<uint32_t>(sequence);
            return true;
        }
        Sleep(1);
    }
    return false;
}

bool issueSeek(Runtime* runtime, uint32_t targetTick,
               uint32_t* sequenceOut) {
    InterlockedExchange(
        reinterpret_cast<volatile LONG*>(&runtime->control.requestedSeekTick),
        static_cast<LONG>(targetTick));
    const LONG sequence = InterlockedIncrement(
        reinterpret_cast<volatile LONG*>(&runtime->control.seekSequence));
    for (uint32_t i = 0; i < 5000; ++i) {
        if (runtime->control.producerSeekAckSequence ==
            static_cast<uint32_t>(sequence)) {
            if (sequenceOut) *sequenceOut = static_cast<uint32_t>(sequence);
            return true;
        }
        Sleep(1);
    }
    return false;
}

bool prebuffered(Runtime* runtime) {
    for (uint32_t i = 0; i < 5000; ++i) {
        if (runtime->ring.writeFrame - runtime->ring.readFrame >=
            kPrebufferFrames) return true;
        if (runtime->producerFailed) return false;
        Sleep(1);
    }
    return false;
}

bool seekTick(Runtime* runtime, uint32_t targetTick) {
    if (!issueState(runtime, 1, nullptr)) return false;
    MemoryBarrier();
    const uint32_t baseConsumed = runtime->control.workerConsumedFrames;
    InterlockedExchange(
        reinterpret_cast<volatile LONG*>(&runtime->control.seekRingBaseFrame),
        static_cast<LONG>(baseConsumed));
    uint32_t seekSequence = 0;
    if (!issueSeek(runtime, targetTick, &seekSequence)) return false;

    MemoryBarrier();
    runtime->ring.readFrame = runtime->ring.writeFrame;
    runtime->ring.markerRead = runtime->ring.markerWrite;
    MemoryBarrier();
    InterlockedExchange(
        reinterpret_cast<volatile LONG*>(&runtime->control.seekCommitSequence),
        static_cast<LONG>(seekSequence));
    if (!prebuffered(runtime)) return false;

    runtime->seekBaseFrame = baseConsumed;
    runtime->seekSourceTick = targetTick;
    runtime->seekTimeBase =
        static_cast<double>(runtime->tickStarts[targetTick]) / kSampleRate;
    return issueState(runtime, 0, nullptr);
}

uint32_t tickForModPos(const Runtime* runtime, uint32_t modpos) {
    const auto it = std::lower_bound(runtime->modposByTick.begin(),
                                     runtime->modposByTick.end(), modpos);
    if (it == runtime->modposByTick.end())
        return runtime->stateFrames - 1;
    return static_cast<uint32_t>(it - runtime->modposByTick.begin());
}

uint32_t tickForMs(const Runtime* runtime, uint32_t ms) {
    const auto it = std::lower_bound(runtime->tickTimesMs.begin(),
                                     runtime->tickTimesMs.end(), ms);
    if (it == runtime->tickTimesMs.end())
        return runtime->stateFrames - 1;
    return static_cast<uint32_t>(it - runtime->tickTimesMs.begin());
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
    if (!modPath || !readModule(modPath, &g_runtime.module)) return 0;

    audio_abi::Summary summary{};
    if (asm_audio_parse_mod(
            g_runtime.module.data(),
            static_cast<uint32_t>(g_runtime.module.size()), &summary) != 0 ||
        summary.status != 0 || summary.channelCount != kChannels) {
        logPrint("[audio-asm] NASM module parse failed\n");
        clearRuntime();
        return 0;
    }

    std::vector<AudioTickState> reference(
        static_cast<size_t>(kStateCapacity) * kChannels);
    g_runtime.stateFrames = asm_audio_trace_tick_states(
        g_runtime.module.data(), static_cast<uint32_t>(g_runtime.module.size()),
        reference.data(), kStateCapacity);
    if (!g_runtime.stateFrames || g_runtime.stateFrames > kStateCapacity ||
        !checkedTiming(reference, g_runtime.stateFrames, &g_runtime) ||
        !buildTimeline(g_runtime.module.data(),
                       static_cast<uint32_t>(g_runtime.module.size()),
                       g_runtime.stateFrames, &g_runtime)) {
        logPrint("[audio-asm] native timing preparation failed\n");
        clearRuntime();
        return 0;
    }

    g_runtime.ringSamples.resize(
        static_cast<size_t>(kRingCapacity) * kOutputChannels);
    g_runtime.ringMarkers.resize(kMarkerCapacity);
    g_runtime.producerStates.resize(
        static_cast<size_t>(kTickChunk) * kChannels);
    const uint32_t scratchFrames = g_runtime.maxTickFrames * kTickChunk;
    g_runtime.producerPcm.resize(
        static_cast<size_t>(scratchFrames) * kOutputChannels);
    if (asm_audio_ring_init(&g_runtime.ring, g_runtime.ringSamples.data(),
                            kRingCapacity, g_runtime.ringMarkers.data(),
                            kMarkerCapacity) != 0) {
        logPrint("[audio-asm] ring initialization failed\n");
        clearRuntime();
        return 0;
    }

    g_runtime.producerArgs = {
        g_runtime.module.data(),
        static_cast<uint32_t>(g_runtime.module.size()),
        g_runtime.stateFrames,
        g_runtime.maxTickFrames,
        scratchFrames,
        g_runtime.tickStarts.data(),
        g_runtime.modposByTick.data(),
        &g_runtime.ring,
        &g_runtime.control,
        g_runtime.producerStates.data(),
        g_runtime.producerPcm.data(),
        &g_runtime.producerHistory,
        reinterpret_cast<volatile uint32_t*>(&g_runtime.producerStop),
        reinterpret_cast<volatile uint32_t*>(&g_runtime.producerFailed),
        reinterpret_cast<volatile uint32_t*>(&g_runtime.producerDone),
        reinterpret_cast<volatile uint32_t*>(&g_runtime.producerError),
    };
    g_runtime.workerArgs = {&g_runtime.ring, 0, &g_runtime.control};
    g_runtime.producerHandle = CreateThread(
        nullptr, 0,
        reinterpret_cast<LPTHREAD_START_ROUTINE>(asm_audio_producer_thread),
        &g_runtime.producerArgs,
        0, nullptr);
    if (!g_runtime.producerHandle || !prebuffered(&g_runtime)) {
        logPrint("[audio-asm] producer prebuffer failed failed=%ld done=%ld "
                 "error=%ld write=%u read=%u\n",
                 g_runtime.producerFailed, g_runtime.producerDone,
                 g_runtime.producerError,
                 g_runtime.ring.writeFrame, g_runtime.ring.readFrame);
        audioAsmShutdown();
        return 0;
    }

    g_runtime.workerControllerHandle = CreateThread(
        nullptr, 0, workerControllerThread, &g_runtime, 0, nullptr);
    if (!g_runtime.workerControllerHandle) {
        logPrint("[audio-asm] worker controller creation failed\n");
        audioAsmShutdown();
        return 0;
    }
    Sleep(250);
    if (WaitForSingleObject(g_runtime.workerControllerHandle, 0) ==
        WAIT_OBJECT_0) {
        logPrint("[audio-asm] assembly WASAPI worker exited during startup\n");
        audioAsmShutdown();
        return 0;
    }

    InterlockedExchange(&g_runtime.playing, 1);
    InterlockedExchange(&g_runtime.initialized, 1);
    logPrint("[audio-asm] dedicated player active, orders=%u, 44100Hz stereo\n",
             g_runtime.orderCount);
    return 1;
}

void audioAsmShutdown() {
    if (g_runtime.shuttingDown) return;
    InterlockedExchange(&g_runtime.shuttingDown, 1);
    InterlockedExchange(&g_runtime.playing, 0);
    InterlockedExchange(&g_runtime.producerStop, 1);

    if (g_runtime.workerControllerHandle) {
        InterlockedExchange(
            reinterpret_cast<volatile LONG*>(&g_runtime.control.requestedState),
            2);
        InterlockedIncrement(
            reinterpret_cast<volatile LONG*>(&g_runtime.control.requestSequence));
        WaitForSingleObject(g_runtime.workerControllerHandle, INFINITE);
        CloseHandle(g_runtime.workerControllerHandle);
        g_runtime.workerControllerHandle = nullptr;
    }
    if (g_runtime.producerHandle) {
        WaitForSingleObject(g_runtime.producerHandle, INFINITE);
        CloseHandle(g_runtime.producerHandle);
        g_runtime.producerHandle = nullptr;
    }
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

void audioAsmPump() {
    if (!g_runtime.initialized || g_runtime.shuttingDown) return;
    const uint32_t desired =
        (InterlockedCompareExchange(&g_runtime.playing, 0, 0) == 0 ||
         isPaused()) ? 1u : 0u;
    if (desired != g_runtime.lastControlState)
        issueState(&g_runtime, desired, nullptr);
}

uint32_t audioAsmModPos() {
    if (!g_runtime.initialized) return 0;
    MemoryBarrier();
    return g_runtime.workerReport.publishedModPos;
}

uint32_t audioAsmModLength() {
    return g_runtime.initialized ? g_runtime.orderCount : 0;
}

double audioAsmElapsedSec() {
    if (!g_runtime.initialized) return 0.0;
    MemoryBarrier();
    const uint32_t frame = g_runtime.workerReport.publishedPcmFrame;
    const uint32_t delta = frame >= g_runtime.seekBaseFrame
        ? frame - g_runtime.seekBaseFrame : 0;
    return g_runtime.seekTimeBase +
        static_cast<double>(delta) / kSampleRate;
}

uint32_t audioAsmSeekRows(uint32_t modpos) {
    if (!g_runtime.initialized) return 0;
    const uint32_t tick = tickForModPos(&g_runtime, modpos);
    return seekTick(&g_runtime, tick)
        ? g_runtime.modposByTick[tick] : 0;
}

uint32_t audioAsmSeekMs(int ms) {
    if (!g_runtime.initialized || ms < 0) return 0;
    const uint32_t tick = tickForMs(&g_runtime, static_cast<uint32_t>(ms));
    return seekTick(&g_runtime, tick)
        ? g_runtime.modposByTick[tick] : 0;
}

uint32_t audioAsmSeekOrder(int order) {
    if (!g_runtime.initialized || order < 0) return 0;
    return audioAsmSeekRows(static_cast<uint32_t>(order) << 8);
}

int audioAsmSelfCheck(int seconds) {
    if (!g_runtime.initialized) return 1;
    if (seconds <= 0) seconds = 20;
    const uint64_t start = getQpcUs();
    while (getQpcUs() - start < static_cast<uint64_t>(seconds) * 1000000ull) {
        updateInput();
        if (quitRequested()) shutdownAndExit();
        audioAsmPump();
        Sleep(10);
    }
    MemoryBarrier();
    const auto& report = g_runtime.workerReport;
    logPrint("[audio-asm] self-check: %.2fs device_frames=%u underruns=%u "
             "markers=%u worker_exit=%u\n",
             audioAsmElapsedSec(), report.common.frames,
             report.underrunEvents, report.snapshotUpdates,
             report.common.workerExit);
    return report.underrunEvents == 0 && report.common.workerExit == 0
        ? 0 : 1;
}

} // namespace vk
