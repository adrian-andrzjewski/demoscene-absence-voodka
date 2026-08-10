// audio_live_wasapi_probe.cpp - live assembly tracker/mixer into the
// assembly-owned WASAPI worker through the bounded PCM/ModPos ring.

#include "audio_mix_abi.h"
#include "audio_mod_abi.h"
#include "audio_ring_abi.h"
#include "audio_thread_abi.h"
#include "audio_tick_abi.h"
#include "audio_tracker_abi.h"

#include <windows.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <limits>
#include <vector>

namespace {

constexpr uint32_t kChannels = 14;
constexpr uint32_t kOutputChannels = 2;
constexpr uint32_t kStateCapacity = 20000;
constexpr uint32_t kTickChunk = 31;
constexpr uint32_t kRingCapacity = 16384;
constexpr uint32_t kMarkerCapacity = 16384;
constexpr uint32_t kPrebufferFrames = 8192;
constexpr uint32_t kPushChunk = 1024;
constexpr uint32_t kDurationMs = 1000;
constexpr uint64_t kFnvOffset = 14695981039346656037ull;
constexpr uint64_t kFnvPrime = 1099511628211ull;

struct Fnv64 {
    uint64_t value = kFnvOffset;

    void add(const void* data, size_t bytes) {
        const auto* p = static_cast<const uint8_t*>(data);
        for (size_t i = 0; i < bytes; ++i) {
            value ^= p[i];
            value *= kFnvPrime;
        }
    }
};

bool readFile(const char* path, std::vector<uint8_t>* out) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) return false;
    const std::streamoff size = file.tellg();
    if (size <= 0) return false;
    out->resize(static_cast<size_t>(size));
    file.seekg(0, std::ios::beg);
    return static_cast<bool>(file.read(reinterpret_cast<char*>(out->data()), size));
}

bool checkedFrameTotal(const std::vector<AudioTickState>& states,
                       uint32_t stateFrames,
                       std::vector<uint32_t>* tickStarts,
                       uint32_t* totalFrames,
                       uint32_t* maxTickFrames) {
    if (!stateFrames || states.size() <
            static_cast<size_t>(stateFrames) * kChannels) {
        return false;
    }
    tickStarts->resize(static_cast<size_t>(stateFrames) + 1);
    uint64_t total = 0;
    uint32_t maxTick = 0;
    for (uint32_t frame = 0; frame < stateFrames; ++frame) {
        const uint32_t tickFrames =
            states[static_cast<size_t>(frame) * kChannels].tickFrames;
        if (!tickFrames) return false;
        (*tickStarts)[frame] = static_cast<uint32_t>(total);
        total += tickFrames;
        maxTick = std::max(maxTick, tickFrames);
        if (total > std::numeric_limits<uint32_t>::max()) return false;
    }
    (*tickStarts)[stateFrames] = static_cast<uint32_t>(total);
    *totalFrames = static_cast<uint32_t>(total);
    *maxTickFrames = maxTick;
    return *totalFrames != 0;
}

bool buildModPosTimeline(const uint8_t* module, uint32_t moduleSize,
                         uint32_t stateFrames,
                         std::vector<uint32_t>* modposByTick) {
    audio_abi::Summary summary{};
    if (asm_audio_parse_mod(module, moduleSize, &summary) != 0 ||
        summary.status != 0 || summary.rowsPerLoop == 0) {
        return false;
    }
    std::vector<AudioTraceEntry> rows(summary.rowsPerLoop);
    const uint32_t rowCount = asm_audio_trace_rows(
        module, moduleSize, rows.data(), summary.rowsPerLoop);
    if (rowCount != summary.rowsPerLoop || rows.empty() || rows[0].frame != 0)
        return false;

    modposByTick->resize(stateFrames);
    size_t row = 0;
    for (uint32_t frame = 0; frame < stateFrames; ++frame) {
        while (row + 1 < rows.size() && rows[row + 1].frame <= frame)
            ++row;
        (*modposByTick)[frame] = (rows[row].position << 8) | rows[row].row;
    }
    return true;
}

struct ProducerArgs {
    const uint8_t* module;
    uint32_t moduleSize;
    uint32_t stateFrames;
    const uint32_t* tickStarts;
    const uint32_t* modposByTick;
    AudioPcmRing* ring;
    AudioTickState* stateScratch;
    uint32_t stateScratchCapacity;
    int16_t* pcmScratch;
    uint32_t pcmScratchCapacity;
    volatile LONG stopRequested = 0;
    volatile LONG failed = 0;
    uint32_t producedStates = 0;
    uint32_t mixedFrames = 0;
    uint32_t pushedFrames = 0;
    uint32_t pushCalls = 0;
    uint32_t backpressure = 0;
    uint32_t markers = 0;
};

DWORD WINAPI producerThread(void* raw) {
    auto* args = static_cast<ProducerArgs*>(raw);
    AudioLiveTrackerContext tracker{};
    AudioMixerHistory history{};
    if (asm_audio_live_init(args->module, args->moduleSize, &tracker) != 0) {
        InterlockedExchange(&args->failed, 1);
        return 1;
    }

    uint32_t stateFrame = 0;
    while (stateFrame < args->stateFrames &&
           InterlockedCompareExchange(&args->stopRequested, 0, 0) == 0) {
        const uint32_t chunkStates = std::min(
            kTickChunk, args->stateFrames - stateFrame);
        if (chunkStates > args->stateScratchCapacity) {
            InterlockedExchange(&args->failed, 1);
            break;
        }

        uint32_t chunkFrames = 0;
        for (uint32_t i = 0; i < chunkStates; ++i) {
            if (InterlockedCompareExchange(&args->stopRequested, 0, 0) != 0)
                break;
            auto* state = args->stateScratch +
                static_cast<size_t>(i) * kChannels;
            if (asm_audio_live_next(&tracker, state) != 1 ||
                state[0].tickFrames == 0) {
                InterlockedExchange(&args->failed, 1);
                break;
            }
            for (uint32_t channel = 1; channel < kChannels; ++channel) {
                if (state[channel].tickFrames != state[0].tickFrames) {
                    InterlockedExchange(&args->failed, 1);
                    break;
                }
            }
            chunkFrames += state[0].tickFrames;
        }
        if (InterlockedCompareExchange(&args->failed, 0, 0) != 0 ||
            InterlockedCompareExchange(&args->stopRequested, 0, 0) != 0)
            break;
        if (chunkFrames > args->pcmScratchCapacity) {
            InterlockedExchange(&args->failed, 1);
            break;
        }

        const uint32_t mixed = asm_audio_mix_tick_states_continuous(
            args->module, args->moduleSize, args->stateScratch,
            chunkStates, args->pcmScratch, chunkFrames, &history);
        if (mixed != chunkFrames) {
            InterlockedExchange(&args->failed, 1);
            break;
        }

        uint32_t pushed = 0;
        while (pushed < mixed &&
               InterlockedCompareExchange(&args->stopRequested, 0, 0) == 0) {
            const uint32_t got = asm_audio_ring_push(
                args->ring,
                args->pcmScratch + static_cast<size_t>(pushed) * kOutputChannels,
                std::min(kPushChunk, mixed - pushed));
            ++args->pushCalls;
            if (!got) {
                ++args->backpressure;
                if (InterlockedCompareExchange(&args->stopRequested, 0, 0) != 0)
                    break;
                Sleep(1);
                continue;
            }
            pushed += got;
            args->pushedFrames += got;
        }
        if (InterlockedCompareExchange(&args->stopRequested, 0, 0) != 0)
            break;

        for (uint32_t i = 0; i < chunkStates; ++i) {
            if (asm_audio_ring_push_marker(
                    args->ring, args->tickStarts[stateFrame + i],
                    args->modposByTick[stateFrame + i]) != 1) {
                InterlockedExchange(&args->failed, 1);
                break;
            }
            ++args->markers;
        }
        if (InterlockedCompareExchange(&args->failed, 0, 0) != 0)
            break;
        stateFrame += chunkStates;
        args->producedStates = stateFrame;
        args->mixedFrames += mixed;
    }
    return InterlockedCompareExchange(&args->failed, 0, 0) == 0 ? 0 : 1;
}

uint32_t expectedModPos(const std::vector<uint32_t>& tickStarts,
                        const std::vector<uint32_t>& modposByTick,
                        uint32_t stateFrames, uint32_t frame) {
    if (!stateFrames) return 0;
    const auto end = tickStarts.begin() + stateFrames;
    const auto it = std::upper_bound(tickStarts.begin(), end, frame);
    const size_t index = it == tickStarts.begin() ? 0 :
        static_cast<size_t>((it - tickStarts.begin()) - 1);
    return modposByTick[index];
}

} // namespace

int main(int argc, char** argv) {
    if (argc != 2) {
        std::cerr << "usage: audio_live_wasapi_probe <module.mod>\n";
        return 2;
    }

    std::vector<uint8_t> module;
    if (!readFile(argv[1], &module)) {
        std::cerr << "audio_live_wasapi_probe: cannot read module\n";
        return 1;
    }
    audio_abi::Summary summary{};
    if (asm_audio_parse_mod(module.data(), static_cast<uint32_t>(module.size()),
                            &summary) != 0 || summary.status != 0 ||
        summary.channelCount != kChannels) {
        std::cerr << "audio_live_wasapi_probe: NASM parser failed\n";
        return 1;
    }

    std::vector<AudioTickState> reference(
        static_cast<size_t>(kStateCapacity) * kChannels);
    const uint32_t stateFrames = asm_audio_trace_tick_states(
        module.data(), static_cast<uint32_t>(module.size()), reference.data(),
        kStateCapacity);
    std::vector<uint32_t> tickStarts;
    uint32_t totalFrames = 0;
    uint32_t maxTickFrames = 0;
    if (!stateFrames || stateFrames > kStateCapacity ||
        !checkedFrameTotal(reference, stateFrames, &tickStarts, &totalFrames,
                           &maxTickFrames)) {
        std::cerr << "audio_live_wasapi_probe: native timing failed\n";
        return 1;
    }
    std::vector<uint32_t> modposByTick;
    if (!buildModPosTimeline(module.data(), static_cast<uint32_t>(module.size()),
                             stateFrames, &modposByTick)) {
        std::cerr << "audio_live_wasapi_probe: native ModPos timeline failed\n";
        return 1;
    }

    // Keep an independent expected PCM prefix witness.  The producer uses
    // the same assembly tracker/mixer incrementally; this second render lets
    // the assembly worker prove that the exact bytes it popped into WASAPI
    // are the expected stream prefix, not merely a non-empty transfer.
    std::vector<int16_t> expectedPcm(
        static_cast<size_t>(totalFrames) * kOutputChannels);
    const uint32_t expectedMixed = asm_audio_mix_tick_states(
        module.data(), static_cast<uint32_t>(module.size()), reference.data(),
        stateFrames, expectedPcm.data(), totalFrames);
    if (expectedMixed != totalFrames) {
        std::cerr << "audio_live_wasapi_probe: native PCM witness failed\n";
        return 1;
    }

    std::vector<int16_t> ringSamples(
        static_cast<size_t>(kRingCapacity) * kOutputChannels);
    std::vector<AudioRingMarker> ringMarkers(kMarkerCapacity);
    AudioPcmRing ring{};
    if (asm_audio_ring_init(&ring, ringSamples.data(), kRingCapacity,
                            ringMarkers.data(), kMarkerCapacity) != 0) {
        std::cerr << "audio_live_wasapi_probe: ring init failed\n";
        return 1;
    }

    const uint32_t scratchFrames = maxTickFrames * kTickChunk;
    std::vector<AudioTickState> stateScratch(
        static_cast<size_t>(kTickChunk) * kChannels);
    std::vector<int16_t> pcmScratch(
        static_cast<size_t>(scratchFrames) * kOutputChannels);
    ProducerArgs producer{
        module.data(), static_cast<uint32_t>(module.size()), stateFrames,
        tickStarts.data(), modposByTick.data(), &ring, stateScratch.data(),
        kTickChunk, pcmScratch.data(), scratchFrames};

    HANDLE producerHandle = CreateThread(nullptr, 0, producerThread, &producer,
                                         0, nullptr);
    if (!producerHandle) {
        std::cerr << "audio_live_wasapi_probe: producer thread failed\n";
        return 1;
    }

    bool prebuffered = false;
    for (uint32_t i = 0; i < 5000; ++i) {
        if (ring.writeFrame - ring.readFrame >= kPrebufferFrames) {
            prebuffered = true;
            break;
        }
        if (InterlockedCompareExchange(&producer.failed, 0, 0) != 0)
            break;
        Sleep(1);
    }

    AudioRingThreadArgs args{&ring, kDurationMs};
    AudioRingThreadReport report{};
    uint32_t result = 1;
    if (prebuffered) {
        result = asm_audio_ring_thread_probe(&args, &report);
    }

    InterlockedExchange(&producer.stopRequested, 1);
    DWORD producerWait = WaitForSingleObject(producerHandle, 10000);
    if (producerWait != WAIT_OBJECT_0) {
        // A stuck producer must observe closure before the handle is closed;
        // never let a validation process abandon a live worker thread.
        asm_audio_ring_close(&ring);
        producerWait = WaitForSingleObject(producerHandle, INFINITE);
    }
    asm_audio_ring_close(&ring);
    CloseHandle(producerHandle);

    const auto& common = report.common;
    Fnv64 expectedPrefix;
    if (report.consumedFrames <= totalFrames) {
        expectedPrefix.add(
            expectedPcm.data(),
            static_cast<size_t>(report.consumedFrames) *
                kOutputChannels * sizeof(int16_t));
    }
    std::printf(
        "audio_live_wasapi_probe result=%u prebuffered=%u states=%u "
        "produced_states=%u produced_frames=%u pushed_frames=%u markers=%u "
        "thread=%u wait=%08X start=%08X wakeups=%u device_frames=%u "
        "ring_frames=%u published_frame=%u modpos=%04X snapshots=%u "
        "underrun_events=%u overrun_events=%u marker_overrun=%u "
        "pcm_fnv=0x%016llX expected_fnv=0x%016llX "
        "producer_wait=%08X producer_failed=%ld\n",
        result, prebuffered ? 1u : 0u, stateFrames, producer.producedStates,
        producer.mixedFrames, producer.pushedFrames, producer.markers,
        common.threadCreated, common.threadWait, common.startHr,
        common.eventWakeups, common.frames, report.consumedFrames,
        report.publishedPcmFrame, report.publishedModPos,
        report.snapshotUpdates, report.underrunEvents, report.overrunEvents,
        report.markerOverruns,
        static_cast<unsigned long long>(report.pcmFnv),
        static_cast<unsigned long long>(expectedPrefix.value), producerWait,
        producer.failed);

    const bool hresultsOk =
        common.comHr == 0 && common.enumeratorHr == 0 &&
        common.endpointHr == 0 && common.activateHr == 0 &&
        common.formatHr == 0 && common.initializeHr == 0 &&
        common.setEventHr == 0 && common.serviceHr == 0 &&
        common.startHr == 0 && common.paddingHr == 0 &&
        common.getBufferHr == 0 && common.releaseHr == 0 &&
        common.stopHr == 0 && common.resetHr == 0;
    const bool threadOk =
        result == 0 && prebuffered && common.threadCreated == 1 &&
        common.threadPriority == 1 && common.threadWait == 0 &&
        common.bufferSize > 0 && common.eventCreated == 1 &&
        common.firstWait == 1 && common.eventWakeups > 0 &&
        common.frames > 0 && common.timeouts == 0 && common.workerExit == 0 &&
        common.durationMs == kDurationMs;
    const bool transferOk =
        producer.failed == 0 && producer.producedStates > 0 &&
        producer.pushedFrames >= report.consumedFrames &&
        report.consumedFrames == common.frames &&
        report.consumedFrames <= totalFrames &&
        report.underrunEvents == 0 && ring.underrunEvents == 0 &&
        report.markerOverruns == 0 && ring.markerOverruns == 0 &&
        report.snapshotUpdates > 0 &&
        report.publishedPcmFrame <= report.consumedFrames &&
        [&]() {
            Fnv64 expectedPrefix;
            expectedPrefix.add(
                expectedPcm.data(),
                static_cast<size_t>(report.consumedFrames) *
                    kOutputChannels * sizeof(int16_t));
            return report.pcmFnv == expectedPrefix.value;
        }() &&
        report.publishedModPos == expectedModPos(
            tickStarts, modposByTick, stateFrames,
            report.publishedPcmFrame);
    if (!hresultsOk || !threadOk || !transferOk) {
        std::cerr << "audio_live_wasapi_probe: FAIL hresults=" << hresultsOk
                  << " thread=" << threadOk
                  << " transfer=" << transferOk << '\n';
        return 1;
    }
    return 0;
}
