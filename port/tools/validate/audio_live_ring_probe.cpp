// audio_live_ring_probe.cpp - concurrent live assembly tracker/ring gate.

#include "audio_mod_abi.h"
#include "audio_mix_abi.h"
#include "audio_ring_abi.h"
#include "audio_tick_abi.h"
#include "audio_tracker_abi.h"

#include <windows.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
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
constexpr uint32_t kConsumerPattern[] = {257, 1024, 4096, 127, 777, 2048};
constexpr uint64_t kExpectedPcmFnv = 0x18C7451650A7C772ull;
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

bool basicRingChecks() {
    int16_t storage[8 * kOutputChannels]{};
    AudioRingMarker markers[4]{};
    AudioPcmRing ring{};
    if (asm_audio_ring_init(&ring, storage, 8, markers, 4) != 0)
        return false;

    int16_t input[12 * kOutputChannels]{};
    for (int i = 0; i < 12 * kOutputChannels; ++i)
        input[i] = static_cast<int16_t>(i + 1);
    int16_t output[10 * kOutputChannels]{};
    const uint32_t firstPush = asm_audio_ring_push(&ring, input, 8);
    const uint32_t fullPush = asm_audio_ring_push(&ring, input + 16, 1);
    if (firstPush != 8 || fullPush != 0 || ring.overrunEvents == 0)
        return false;
    const uint32_t firstPop = asm_audio_ring_pop(&ring, output, 3);
    if (firstPop != 3 ||
        std::memcmp(output, input, 3 * kOutputChannels * sizeof(int16_t)) != 0)
        return false;
    const uint32_t wrapPush = asm_audio_ring_push(&ring, input + 16, 3);
    const uint32_t wrapPop = asm_audio_ring_pop(&ring, output, 8);
    if (wrapPush != 3 || wrapPop != 8 ||
        std::memcmp(output, input + 6,
                    5 * kOutputChannels * sizeof(int16_t)) != 0 ||
        std::memcmp(output + 10, input + 16,
                    3 * kOutputChannels * sizeof(int16_t)) != 0)
        return false;
    const uint32_t m0 = asm_audio_ring_push_marker(&ring, 0, 0x100);
    const uint32_t m1 = asm_audio_ring_push_marker(&ring, 8, 0x200);
    const uint32_t m2 = asm_audio_ring_push_marker(&ring, 16, 0x300);
    const uint32_t m3 = asm_audio_ring_push_marker(&ring, 24, 0x400);
    const uint32_t m4 = asm_audio_ring_push_marker(&ring, 32, 0x500);
    if (m0 != 1 || m1 != 1 || m2 != 1 || m3 != 1 || m4 != 0 ||
        ring.markerOverruns == 0) {
        std::cerr << "basic: markers=" << m0 << ',' << m1 << ',' << m2
                  << ',' << m3 << ',' << m4 << " overrun="
                  << ring.markerOverruns << "\n";
        return false;
    }
    AudioRingMarker marker{};
    if (asm_audio_ring_pop_marker(&ring, 7, &marker) != 1 ||
        marker.frame != 0 || marker.modpos != 0x100 ||
        asm_audio_ring_pop_marker(&ring, 7, &marker) != 0 ||
        asm_audio_ring_pop_marker(&ring, 8, &marker) != 1 ||
        marker.frame != 8 || marker.modpos != 0x200)
        return false;
    asm_audio_ring_close(&ring);
    const uint32_t closedPush = asm_audio_ring_push(&ring, input, 1);
    const uint32_t closedMarker =
        asm_audio_ring_push_marker(&ring, 32, 0x500);
    return closedPush == 0 && closedMarker == 0;
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
    volatile LONG failed = 0;
    uint32_t producedStates = 0;
    uint32_t mixedFrames = 0;
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
        asm_audio_ring_close(args->ring);
        return 1;
    }

    uint32_t stateFrame = 0;
    while (stateFrame < args->stateFrames) {
        const uint32_t chunkStates = std::min(
            kTickChunk, args->stateFrames - stateFrame);
        if (chunkStates > args->stateScratchCapacity) {
            InterlockedExchange(&args->failed, 1);
            break;
        }

        uint32_t chunkFrames = 0;
        for (uint32_t i = 0; i < chunkStates; ++i) {
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
        if (InterlockedCompareExchange(&args->failed, 0, 0) != 0)
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
        while (pushed < mixed) {
            const uint32_t got = asm_audio_ring_push(
                args->ring,
                args->pcmScratch + static_cast<size_t>(pushed) * kOutputChannels,
                std::min(kPushChunk, mixed - pushed));
            ++args->pushCalls;
            if (!got) {
                ++args->backpressure;
                if (args->ring->closed) {
                    InterlockedExchange(&args->failed, 1);
                    break;
                }
                Sleep(0);
                continue;
            }
            pushed += got;
        }
        if (InterlockedCompareExchange(&args->failed, 0, 0) != 0)
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

    if (InterlockedCompareExchange(&args->failed, 0, 0) == 0 &&
        (tracker.finished != 1 || tracker.frames != args->stateFrames)) {
        InterlockedExchange(&args->failed, 1);
    }
    asm_audio_ring_close(args->ring);
    return InterlockedCompareExchange(&args->failed, 0, 0) == 0 ? 0 : 1;
}

struct ConsumerArgs {
    const uint32_t* tickStarts;
    const uint32_t* modposByTick;
    uint32_t stateFrames;
    uint32_t expectedFrames;
    AudioPcmRing* ring;
    int16_t* pcmScratch;
    uint32_t pcmScratchCapacity;
    volatile LONG failed = 0;
    uint32_t consumedFrames = 0;
    uint32_t markers = 0;
    uint32_t pops = 0;
    uint32_t emptyPolls = 0;
    uint32_t markerMismatches = 0;
    Fnv64 hash;
};

DWORD WINAPI consumerThread(void* raw) {
    auto* args = static_cast<ConsumerArgs*>(raw);
    uint32_t pattern = 0;
    while (args->consumedFrames < args->expectedFrames) {
        const uint32_t write = args->ring->writeFrame;
        const uint32_t read = args->ring->readFrame;
        const uint32_t available = write - read;
        if (!available) {
            if (args->ring->closed)
                break;
            ++args->emptyPolls;
            Sleep(0);
            continue;
        }

        const uint32_t wanted = std::min(
            available, kConsumerPattern[pattern %
                (sizeof(kConsumerPattern) / sizeof(kConsumerPattern[0]))]);
        const uint32_t got = asm_audio_ring_pop(
            args->ring, args->pcmScratch, wanted);
        ++args->pops;
        if (got != wanted) {
            InterlockedExchange(&args->failed, 1);
            break;
        }
        args->hash.add(args->pcmScratch,
                       static_cast<size_t>(got) * kOutputChannels * sizeof(int16_t));
        args->consumedFrames += got;
        ++pattern;

        AudioRingMarker marker{};
        while (asm_audio_ring_pop_marker(
                   args->ring, args->consumedFrames, &marker) == 1) {
            if (args->markers >= args->stateFrames ||
                marker.frame != args->tickStarts[args->markers] ||
                marker.modpos != args->modposByTick[args->markers]) {
                ++args->markerMismatches;
                InterlockedExchange(&args->failed, 1);
                break;
            }
            ++args->markers;
        }
        if (InterlockedCompareExchange(&args->failed, 0, 0) != 0)
            break;

        if ((args->pops & 63u) == 0)
            Sleep(1);                       // force producer back-pressure
    }

    AudioRingMarker marker{};
    while (InterlockedCompareExchange(&args->failed, 0, 0) == 0 &&
           asm_audio_ring_pop_marker(
               args->ring, args->consumedFrames, &marker) == 1) {
        if (args->markers >= args->stateFrames ||
            marker.frame != args->tickStarts[args->markers] ||
            marker.modpos != args->modposByTick[args->markers]) {
            ++args->markerMismatches;
            InterlockedExchange(&args->failed, 1);
            break;
        }
        ++args->markers;
    }
    if (args->consumedFrames != args->expectedFrames ||
        args->markers != args->stateFrames) {
        InterlockedExchange(&args->failed, 1);
    }
    return InterlockedCompareExchange(&args->failed, 0, 0) == 0 ? 0 : 1;
}

} // namespace

int main(int argc, char** argv) {
    if (argc != 2) {
        std::cerr << "usage: audio_live_ring_probe <module.mod>\n";
        return 2;
    }
    if (!basicRingChecks()) {
        std::cerr << "audio_live_ring_probe: basic ring checks failed\n";
        return 1;
    }

    std::vector<uint8_t> module;
    if (!readFile(argv[1], &module)) {
        std::cerr << "audio_live_ring_probe: cannot read module\n";
        return 1;
    }
    audio_abi::Summary summary{};
    if (asm_audio_parse_mod(module.data(), static_cast<uint32_t>(module.size()),
                            &summary) != 0 || summary.status != 0 ||
        summary.channelCount != kChannels) {
        std::cerr << "audio_live_ring_probe: NASM parser failed\n";
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
        std::cerr << "audio_live_ring_probe: native timing failed\n";
        return 1;
    }
    std::vector<uint32_t> modposByTick;
    if (!buildModPosTimeline(module.data(), static_cast<uint32_t>(module.size()),
                             stateFrames, &modposByTick)) {
        std::cerr << "audio_live_ring_probe: native ModPos timeline failed\n";
        return 1;
    }

    std::vector<int16_t> ringSamples(
        static_cast<size_t>(kRingCapacity) * kOutputChannels);
    std::vector<AudioRingMarker> ringMarkers(kMarkerCapacity);
    AudioPcmRing ring{};
    if (asm_audio_ring_init(&ring, ringSamples.data(), kRingCapacity,
                            ringMarkers.data(), kMarkerCapacity) != 0) {
        std::cerr << "audio_live_ring_probe: ring init failed\n";
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
    std::vector<int16_t> consumerScratch(4096 * kOutputChannels);
    ConsumerArgs consumer{
        tickStarts.data(), modposByTick.data(), stateFrames, totalFrames,
        &ring, consumerScratch.data(), 4096};

    HANDLE producerHandle = CreateThread(nullptr, 0, producerThread, &producer,
                                         0, nullptr);
    if (!producerHandle) {
        std::cerr << "audio_live_ring_probe: producer thread failed\n";
        return 1;
    }
    bool prebuffered = false;
    for (uint32_t i = 0; i < 5000; ++i) {
        if (ring.writeFrame - ring.readFrame >= kPrebufferFrames) {
            prebuffered = true;
            break;
        }
        if (ring.closed || InterlockedCompareExchange(&producer.failed, 0, 0))
            break;
        Sleep(1);
    }
    HANDLE consumerHandle = CreateThread(nullptr, 0, consumerThread, &consumer,
                                         0, nullptr);
    if (!consumerHandle) {
        asm_audio_ring_close(&ring);
        WaitForSingleObject(producerHandle, 30000);
        CloseHandle(producerHandle);
        std::cerr << "audio_live_ring_probe: consumer thread failed\n";
        return 1;
    }

    const DWORD producerWait = WaitForSingleObject(producerHandle, 60000);
    const DWORD consumerWait = WaitForSingleObject(consumerHandle, 60000);
    if (producerWait != WAIT_OBJECT_0 || consumerWait != WAIT_OBJECT_0) {
        asm_audio_ring_close(&ring);
        WaitForSingleObject(producerHandle, 5000);
        WaitForSingleObject(consumerHandle, 5000);
    }
    CloseHandle(producerHandle);
    CloseHandle(consumerHandle);

    std::printf(
        "audio_live_ring_probe: prebuffered=%u states=%u frames=%u "
        "pcm_fnv=0x%016llX pushes=%u backpressure=%u markers=%u "
        "pops=%u empty_polls=%u overrun_events=%u underrun_events=%u "
        "marker_overrun=%u marker_mismatches=%u producer_failed=%ld "
        "consumer_failed=%ld closed=%u\n",
        prebuffered ? 1u : 0u, producer.producedStates,
        consumer.consumedFrames,
        static_cast<unsigned long long>(consumer.hash.value),
        producer.pushCalls, producer.backpressure, consumer.markers,
        consumer.pops, consumer.emptyPolls, ring.overrunEvents,
        ring.underrunEvents, ring.markerOverruns, consumer.markerMismatches,
        producer.failed, consumer.failed, ring.closed);

    const bool ok =
        prebuffered && producer.failed == 0 && consumer.failed == 0 &&
        producer.producedStates == stateFrames &&
        producer.mixedFrames == totalFrames &&
        consumer.consumedFrames == totalFrames &&
        consumer.markers == stateFrames && consumer.hash.value == kExpectedPcmFnv &&
        ring.readFrame == ring.writeFrame &&
        ring.markerRead == ring.markerWrite && ring.closed == 1 &&
        ring.underrunEvents == 0 && ring.markerOverruns == 0 &&
        producerWait == WAIT_OBJECT_0 && consumerWait == WAIT_OBJECT_0;
    if (!ok) {
        std::cerr << "audio_live_ring_probe: FAIL\n";
        return 1;
    }
    return 0;
}
