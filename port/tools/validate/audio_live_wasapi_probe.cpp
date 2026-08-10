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
#include <cstring>
#include <fstream>
#include <iostream>
#include <iterator>
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
constexpr uint32_t kLongRunDurationMs = 15000;
constexpr uint32_t kControlDurationMs = 2200;
constexpr uint32_t kSeekDurationMs = 3200;
constexpr uint32_t kSeekStressDurationMs = 6500;
constexpr uint32_t kSeekTargetTick = 1024;
constexpr uint32_t kSeekStressPauseCount = 3;
constexpr uint32_t kSeekStressTargets[kSeekStressPauseCount] = {
    1024, 4096, 8192};
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
    AudioLiveControl* control;
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

struct AudioSeekCheckpoint {
    uint32_t segmentStart;
    uint32_t segmentTick;
    uint32_t consumed;
    uint32_t publishedFrame;
    uint32_t publishedModPos;
};

struct AudioSeekSegment {
    uint32_t start;
    uint32_t sourceTick;
};

struct AudioTimelineSample {
    uint64_t elapsedUs;
    uint32_t consumedFrames;
    uint32_t publishedFrame;
    uint32_t modpos;
    uint32_t paused;
};

struct AudioTimelineArgs {
    AudioRingThreadReport* report;
    AudioLiveControl* control;
    std::vector<AudioTimelineSample>* samples;
    volatile LONG stop;
    int64_t qpcStart;
    int64_t qpcFrequency;
};

int64_t qpcNow() {
    LARGE_INTEGER value{};
    QueryPerformanceCounter(&value);
    return value.QuadPart;
}

DWORD WINAPI timelineThread(void* raw) {
    auto* args = static_cast<AudioTimelineArgs*>(raw);
    while (InterlockedCompareExchange(&args->stop, 0, 0) == 0) {
        const int64_t now = qpcNow();
        const uint64_t elapsed = now >= args->qpcStart
            ? static_cast<uint64_t>(
                (now - args->qpcStart) * 1000000.0 /
                static_cast<double>(args->qpcFrequency))
            : 0;
        MemoryBarrier();
        const uint32_t consumed = args->control
            ? args->control->workerConsumedFrames
            : args->report->publishedPcmFrame;
        const uint32_t published = args->report->publishedPcmFrame;
        const uint32_t modpos = args->report->publishedModPos;
        const uint32_t paused = args->control
            ? args->control->acknowledgedState : 0;
        args->samples->push_back({elapsed, consumed, published, modpos,
                                  paused});
        Sleep(10);
    }
    return 0;
}

bool writeTimeline(const char* path,
                   const std::vector<AudioTimelineSample>& samples) {
    if (!path || !path[0]) return true;
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    if (!file) return false;
    file << "# elapsed_us consumed_frames published_frame modpos paused\n";
    for (const auto& sample : samples) {
        file << sample.elapsedUs << ' ' << sample.consumedFrames << ' '
             << sample.publishedFrame << ' ' << sample.modpos << ' '
             << sample.paused << '\n';
    }
    return static_cast<bool>(file);
}

bool producerHandleSeek(ProducerArgs* args,
                        AudioLiveTrackerContext* tracker,
                        AudioMixerHistory* history,
                        uint32_t* stateFrame,
                        uint32_t* lastSeekSequence,
                        uint32_t* segmentBaseTick,
                        uint32_t* segmentRingBase,
                        bool* seekSegment) {
    if (!args->control) return true;
    const uint32_t sequence = args->control->seekSequence;
    if (sequence == *lastSeekSequence) return true;

    // Stop producing before the controller flushes the consumer-owned ring.
    InterlockedExchange(
        reinterpret_cast<volatile LONG*>(&args->control->producerSeekAckSequence),
        static_cast<LONG>(sequence));
    while (args->control->seekCommitSequence != sequence) {
        if (InterlockedCompareExchange(&args->stopRequested, 0, 0) != 0)
            return false;
        Sleep(1);
    }

    uint32_t target = args->control->requestedSeekTick;
    if (target >= args->stateFrames) target = args->stateFrames - 1;
    AudioLiveTrackerContext fresh{};
    if (asm_audio_live_init(args->module, args->moduleSize, &fresh) != 0) {
        InterlockedExchange(&args->failed, 1);
        return false;
    }
    AudioTickState discarded[kChannels]{};
    for (uint32_t i = 0; i < target; ++i) {
        if (asm_audio_live_next(&fresh, discarded) != 1) {
            InterlockedExchange(&args->failed, 1);
            return false;
        }
    }
    *tracker = fresh;
    *history = AudioMixerHistory{};
    *stateFrame = target;
    *segmentBaseTick = target;
    *segmentRingBase = args->control->seekRingBaseFrame;
    *seekSegment = true;
    *lastSeekSequence = sequence;
    return true;
}

struct ProbeThreadArgs {
    AudioRingThreadArgs* args;
    AudioRingThreadReport* report;
    volatile LONG result = 1;
};

DWORD WINAPI probeThread(void* raw) {
    auto* args = static_cast<ProbeThreadArgs*>(raw);
    const uint32_t result = asm_audio_ring_thread_probe(
        args->args, args->report);
    InterlockedExchange(&args->result, static_cast<LONG>(result));
    return result;
}

bool issueControl(AudioLiveControl* control, uint32_t state,
                  uint32_t* sequenceOut) {
    if (!control) return false;
    InterlockedExchange(
        reinterpret_cast<volatile LONG*>(&control->requestedState),
        static_cast<LONG>(state));
    const LONG sequence = InterlockedIncrement(
        reinterpret_cast<volatile LONG*>(&control->requestSequence));
    for (uint32_t i = 0; i < 5000; ++i) {
        const uint32_t ackSequence = control->acknowledgedSequence;
        const uint32_t ackState = control->acknowledgedState;
        if (ackSequence == static_cast<uint32_t>(sequence) &&
            ackState == state) {
            if (sequenceOut) *sequenceOut = static_cast<uint32_t>(sequence);
            return true;
        }
        Sleep(1);
    }
    return false;
}

bool issueSeek(AudioLiveControl* control, uint32_t targetTick,
               uint32_t* sequenceOut) {
    if (!control) return false;
    InterlockedExchange(
        reinterpret_cast<volatile LONG*>(&control->requestedSeekTick),
        static_cast<LONG>(targetTick));
    const LONG sequence = InterlockedIncrement(
        reinterpret_cast<volatile LONG*>(&control->seekSequence));
    for (uint32_t i = 0; i < 5000; ++i) {
        if (control->producerSeekAckSequence ==
            static_cast<uint32_t>(sequence)) {
            if (sequenceOut) *sequenceOut = static_cast<uint32_t>(sequence);
            return true;
        }
        if (control->seekSequence != static_cast<uint32_t>(sequence))
            return false;
        Sleep(1);
    }
    return false;
}

DWORD WINAPI producerThread(void* raw) {
    auto* args = static_cast<ProducerArgs*>(raw);
    AudioLiveTrackerContext tracker{};
    AudioMixerHistory history{};
    if (asm_audio_live_init(args->module, args->moduleSize, &tracker) != 0) {
        InterlockedExchange(&args->failed, 1);
        return 1;
    }

    uint32_t stateFrame = 0;
    uint32_t lastSeekSequence = 0;
    uint32_t segmentBaseTick = 0;
    uint32_t segmentRingBase = 0;
    bool seekSegment = false;
    while (stateFrame < args->stateFrames &&
           InterlockedCompareExchange(&args->stopRequested, 0, 0) == 0) {
        if (!producerHandleSeek(args, &tracker, &history, &stateFrame,
                                &lastSeekSequence, &segmentBaseTick,
                                &segmentRingBase, &seekSegment)) {
            break;
        }
        const uint32_t chunkStates = std::min(
            kTickChunk, args->stateFrames - stateFrame);
        if (chunkStates > args->stateScratchCapacity) {
            InterlockedExchange(&args->failed, 1);
            break;
        }

        uint32_t chunkFrames = 0;
        bool seekChanged = false;
        for (uint32_t i = 0; i < chunkStates; ++i) {
            if (InterlockedCompareExchange(&args->stopRequested, 0, 0) != 0) {
                break;
            }
            if (args->control && args->control->seekSequence != lastSeekSequence) {
                seekChanged = true;
                break;
            }
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
        if (seekChanged) continue;
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
            if (args->control && args->control->seekSequence != lastSeekSequence) {
                seekChanged = true;
                break;
            }
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
        if (seekChanged) continue;

        for (uint32_t i = 0; i < chunkStates; ++i) {
            if (args->control && args->control->seekSequence != lastSeekSequence) {
                seekChanged = true;
                break;
            }
            uint32_t markerFrame = args->tickStarts[stateFrame + i];
            if (seekSegment) {
                markerFrame = segmentRingBase +
                    (markerFrame - args->tickStarts[segmentBaseTick]);
            }
            if (asm_audio_ring_push_marker(
                    args->ring, markerFrame,
                    args->modposByTick[stateFrame + i]) != 1) {
                InterlockedExchange(&args->failed, 1);
                break;
            }
            ++args->markers;
        }
        if (InterlockedCompareExchange(&args->failed, 0, 0) != 0)
            break;
        if (seekChanged) continue;
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

uint32_t expectedSegmentModPos(
    const std::vector<uint32_t>& tickStarts,
    const std::vector<uint32_t>& modposByTick,
    uint32_t stateFrames,
    const AudioSeekSegment& segment,
    uint32_t frame) {
    if (frame < segment.start) return 0;
    const uint32_t offset = frame - segment.start;
    const uint32_t sourceFrame = tickStarts[segment.sourceTick] + offset;
    return expectedModPos(tickStarts, modposByTick, stateFrames, sourceFrame);
}

} // namespace

int main(int argc, char** argv) {
    bool controlMode = false;
    bool seekMode = false;
    bool stressMode = false;
    bool longRunMode = false;
    const char* timelinePath = nullptr;
    for (int i = 2; i < argc; ++i) {
        if (std::strcmp(argv[i], "--control") == 0 &&
            !controlMode && !seekMode && !stressMode && !longRunMode) {
            controlMode = true;
        } else if (std::strcmp(argv[i], "--seek") == 0 &&
                   !controlMode && !seekMode && !stressMode && !longRunMode) {
            seekMode = true;
        } else if (std::strcmp(argv[i], "--stress") == 0 &&
                   !controlMode && !seekMode && !stressMode && !longRunMode) {
            stressMode = true;
        } else if (std::strcmp(argv[i], "--longrun") == 0 &&
                   !controlMode && !seekMode && !stressMode &&
                   !longRunMode) {
            longRunMode = true;
        } else if (std::strcmp(argv[i], "--timeline") == 0 &&
                   i + 1 < argc && !timelinePath) {
            timelinePath = argv[++i];
        } else {
            std::cerr << "usage: audio_live_wasapi_probe <module.mod> "
                         "[--control|--seek|--stress] "
                         "[--longrun] [--timeline <path>]\n";
            return 2;
        }
    }
    const bool seekCommandMode = seekMode || stressMode;
    const bool commandMode = controlMode || seekCommandMode;
    if (argc < 2 || !argv[1][0]) {
        std::cerr << "usage: audio_live_wasapi_probe <module.mod> "
                     "[--control|--seek|--stress] "
                     "[--longrun] [--timeline <path>]\n";
        return 2;
    }

    std::vector<uint32_t> seekTargets;
    if (seekMode) {
        seekTargets.push_back(kSeekTargetTick);
    } else if (stressMode) {
        seekTargets.assign(
            std::begin(kSeekStressTargets), std::end(kSeekStressTargets));
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
    const bool seekTargetsValid = std::all_of(
        seekTargets.begin(), seekTargets.end(),
        [stateFrames](uint32_t target) { return target < stateFrames; });
    if (!stateFrames || stateFrames > kStateCapacity || !seekTargetsValid ||
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
    AudioLiveControl control{};
    ProducerArgs producer{
        module.data(), static_cast<uint32_t>(module.size()), stateFrames,
        tickStarts.data(), modposByTick.data(), &ring, &control,
        stateScratch.data(), kTickChunk, pcmScratch.data(), scratchFrames};

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

    AudioRingThreadArgs args{
        &ring,
        controlMode ? kControlDurationMs :
            (longRunMode ? kLongRunDurationMs :
            (stressMode ? kSeekStressDurationMs :
                (seekMode ? kSeekDurationMs : kDurationMs))),
        commandMode ? &control : nullptr};
    AudioRingThreadReport report{};
    std::vector<AudioSeekCheckpoint> seekCheckpoints;
    std::vector<AudioSeekSegment> seekSegments;
    if (seekCommandMode) seekSegments.push_back({0, 0});
    uint32_t result = 1;
    bool controlOk = !commandMode;
    bool pausedStable = true;
    bool seekPrebuffered = true;
    uint32_t seekBaseConsumed = 0;
    uint32_t seekSequence = 0;
    DWORD probeWait = WAIT_OBJECT_0;
    std::vector<AudioTimelineSample> timelineSamples;
    AudioTimelineArgs timelineArgs{};
    HANDLE timelineHandle = nullptr;
    LARGE_INTEGER timelineFrequency{};
    QueryPerformanceFrequency(&timelineFrequency);
    if (prebuffered) {
        if (!commandMode && !timelinePath) {
            result = asm_audio_ring_thread_probe(&args, &report);
        } else {
            ProbeThreadArgs probe{&args, &report};
            HANDLE probeHandle = CreateThread(nullptr, 0, probeThread, &probe,
                                              0, nullptr);
            if (probeHandle) {
                if (timelinePath) {
                    timelineArgs.report = &report;
                    timelineArgs.control = commandMode ? &control : nullptr;
                    timelineArgs.samples = &timelineSamples;
                    timelineArgs.stop = 0;
                    timelineArgs.qpcStart = qpcNow();
                    timelineArgs.qpcFrequency = timelineFrequency.QuadPart;
                    timelineHandle = CreateThread(nullptr, 0, timelineThread,
                                                  &timelineArgs, 0, nullptr);
                    if (!timelineHandle) {
                        InterlockedExchange(&timelineArgs.stop, 1);
                        WaitForSingleObject(probeHandle, INFINITE);
                        CloseHandle(probeHandle);
                        probeHandle = nullptr;
                    }
                }
            }
            if (probeHandle) {
                Sleep(100);
                auto performSeek = [&](uint32_t targetTick,
                                       uint32_t segmentStart,
                                       uint32_t segmentTick,
                                       uint32_t* baseOut,
                                       uint32_t* sequenceOut) {
                    uint32_t pauseSequence = 0;
                    const bool pauseAck = issueControl(
                        &control, 1, &pauseSequence);
                    const uint32_t pausedAtAck = ring.readFrame;
                    MemoryBarrier();
                    const uint32_t baseConsumed = control.workerConsumedFrames;
                    Sleep(250);
                    const bool thisPausedStable = ring.readFrame == pausedAtAck;
                    pausedStable = pausedStable && thisPausedStable;
                    if (pauseAck && thisPausedStable) {
                        seekCheckpoints.push_back({
                            segmentStart, segmentTick, baseConsumed,
                            report.publishedPcmFrame,
                            report.publishedModPos});
                    }

                    bool producerAck = false;
                    bool thisPrebuffered = false;
                    if (pauseAck && thisPausedStable) {
                        InterlockedExchange(
                            reinterpret_cast<volatile LONG*>(
                                &control.seekRingBaseFrame),
                            static_cast<LONG>(baseConsumed));
                        producerAck = issueSeek(
                            &control, targetTick, sequenceOut);
                        if (producerAck) {
                            // Both owners are quiescent: the worker is
                            // paused at an audio boundary and the producer
                            // has acknowledged that it will not write again
                            // until commit.  Move both ring cursors together
                            // so old samples or markers cannot leak into the
                            // new stream segment.
                            MemoryBarrier();
                            ring.readFrame = ring.writeFrame;
                            ring.markerRead = ring.markerWrite;
                            MemoryBarrier();
                            InterlockedExchange(
                                reinterpret_cast<volatile LONG*>(
                                    &control.seekCommitSequence),
                                static_cast<LONG>(*sequenceOut));

                            for (uint32_t i = 0; i < 5000; ++i) {
                                if (ring.writeFrame - ring.readFrame >=
                                    kPrebufferFrames) {
                                    thisPrebuffered = true;
                                    break;
                                }
                                if (InterlockedCompareExchange(
                                        &producer.failed, 0, 0) != 0)
                                    break;
                                Sleep(1);
                            }
                        }
                    }
                    seekPrebuffered = seekPrebuffered && producerAck &&
                        thisPrebuffered;

                    uint32_t resumeSequence = 0;
                    const bool resumeAck = pauseAck && issueControl(
                        &control, 0, &resumeSequence);
                    if (resumeAck)
                        Sleep(stressMode ? 450 : 500);
                    if (baseOut) *baseOut = baseConsumed;
                    return pauseAck && thisPausedStable && producerAck &&
                        thisPrebuffered && resumeAck &&
                        pauseSequence != resumeSequence;
                };

                if (controlMode) {
                    uint32_t pauseSequence = 0;
                    const bool pauseAck = issueControl(
                        &control, 1, &pauseSequence);
                    const uint32_t pausedAtAck = ring.readFrame;
                    MemoryBarrier();
                    seekBaseConsumed = control.workerConsumedFrames;
                    Sleep(250);
                    pausedStable = ring.readFrame == pausedAtAck;
                    uint32_t resumeSequence = 0;
                    const bool resumeAck = issueControl(
                        &control, 0, &resumeSequence);
                    Sleep(500);
                    probeWait = WaitForSingleObject(probeHandle, INFINITE);
                    result = static_cast<uint32_t>(
                        InterlockedCompareExchange(&probe.result, 0, 0));
                    CloseHandle(probeHandle);
                    controlOk = pauseAck && resumeAck &&
                        pauseSequence != resumeSequence && pausedStable &&
                        probeWait == WAIT_OBJECT_0;
                } else {
                    bool commandSequenceOk = true;
                    uint32_t currentSegmentStart = 0;
                    uint32_t currentSegmentTick = 0;
                    for (const uint32_t targetTick : seekTargets) {
                        uint32_t baseConsumed = 0;
                        if (!performSeek(targetTick, currentSegmentStart,
                                         currentSegmentTick, &baseConsumed,
                                         &seekSequence)) {
                            commandSequenceOk = false;
                            break;
                        }
                        seekBaseConsumed = baseConsumed;
                        seekSegments.push_back({baseConsumed, targetTick});
                        currentSegmentStart = baseConsumed;
                        currentSegmentTick = targetTick;
                    }
                    probeWait = WaitForSingleObject(probeHandle, INFINITE);
                    result = static_cast<uint32_t>(
                        InterlockedCompareExchange(&probe.result, 0, 0));
                    CloseHandle(probeHandle);
                    controlOk = commandSequenceOk && seekPrebuffered &&
                        probeWait == WAIT_OBJECT_0;
                }
            } else {
                controlOk = false;
            }
        }
    }

    if (timelineHandle) {
        InterlockedExchange(&timelineArgs.stop, 1);
        WaitForSingleObject(timelineHandle, INFINITE);
        CloseHandle(timelineHandle);
    }
    if (!writeTimeline(timelinePath, timelineSamples)) {
        std::cerr << "audio_live_wasapi_probe: cannot write timeline\n";
        result = 1;
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
    bool expectedHashOk = true;
    auto addExpectedSegment = [&](const AudioSeekSegment& segment,
                                  uint32_t endFrame) {
        if (endFrame < segment.start || segment.sourceTick >= stateFrames)
            return false;
        const uint32_t segmentFrames = endFrame - segment.start;
        const uint32_t availableFrames =
            totalFrames - tickStarts[segment.sourceTick];
        if (segmentFrames > availableFrames) return false;
        if (segment.sourceTick == 0) {
            expectedPrefix.add(
                expectedPcm.data(), static_cast<size_t>(segmentFrames) *
                    kOutputChannels * sizeof(int16_t));
            return true;
        }

        std::vector<int16_t> segmentPcm(
            static_cast<size_t>(availableFrames) * kOutputChannels);
        const uint32_t mixed = asm_audio_mix_tick_states(
            module.data(), static_cast<uint32_t>(module.size()),
            reference.data() + static_cast<size_t>(segment.sourceTick) *
                kChannels,
            stateFrames - segment.sourceTick, segmentPcm.data(),
            availableFrames);
        if (mixed != availableFrames) return false;
        expectedPrefix.add(
            segmentPcm.data(), static_cast<size_t>(segmentFrames) *
                kOutputChannels * sizeof(int16_t));
        return true;
    };

    if (seekCommandMode) {
        if (seekSegments.empty()) {
            expectedHashOk = false;
        } else {
            for (size_t i = 0; i < seekSegments.size(); ++i) {
                const uint32_t endFrame = i + 1 < seekSegments.size()
                    ? seekSegments[i + 1].start : report.consumedFrames;
                expectedHashOk = addExpectedSegment(
                    seekSegments[i], endFrame) && expectedHashOk;
            }
        }
    } else if (report.consumedFrames <= totalFrames) {
        expectedPrefix.add(
            expectedPcm.data(), static_cast<size_t>(report.consumedFrames) *
                kOutputChannels * sizeof(int16_t));
    } else {
        expectedHashOk = false;
    }
    const uint32_t finalSegmentStart = seekCommandMode &&
        !seekSegments.empty() ? seekSegments.back().start : 0;
    const uint32_t postSeekFrames = seekCommandMode &&
        report.consumedFrames >= finalSegmentStart
        ? report.consumedFrames - finalSegmentStart : 0;
    std::printf(
        "audio_live_wasapi_probe result=%u prebuffered=%u states=%u "
        "produced_states=%u produced_frames=%u pushed_frames=%u markers=%u "
        "thread=%u wait=%08X start=%08X wakeups=%u device_frames=%u "
        "ring_frames=%u published_frame=%u modpos=%04X snapshots=%u "
        "underrun_events=%u overrun_events=%u marker_overrun=%u "
        "pcm_fnv=0x%016llX expected_fnv=0x%016llX control=%u "
        "pause_transitions=%u paused_frames=%u final_paused=%u "
        "seek_base=%u post_seek_frames=%u seek_sequence=%u seek_count=%u "
        "timeline_samples=%u "
        "paused_stable=%u probe_wait=%08X producer_wait=%08X "
        "producer_failed=%ld\n",
        result, prebuffered ? 1u : 0u, stateFrames, producer.producedStates,
        producer.mixedFrames, producer.pushedFrames, producer.markers,
        common.threadCreated, common.threadWait, common.startHr,
        common.eventWakeups, common.frames, report.consumedFrames,
        report.publishedPcmFrame, report.publishedModPos,
        report.snapshotUpdates, report.underrunEvents, report.overrunEvents,
        report.markerOverruns,
        static_cast<unsigned long long>(report.pcmFnv),
        static_cast<unsigned long long>(expectedPrefix.value),
        commandMode ? 1u : 0u, report.pauseTransitions, report.pausedFrames,
        report.finalPausedState, seekBaseConsumed, postSeekFrames,
        seekSequence, static_cast<uint32_t>(seekCheckpoints.size()),
        static_cast<uint32_t>(timelineSamples.size()),
        pausedStable ? 1u : 0u, probeWait, producerWait, producer.failed);

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
        common.durationMs ==
            (longRunMode ? kLongRunDurationMs :
            (controlMode ? kControlDurationMs :
                (stressMode ? kSeekStressDurationMs :
                    (seekMode ? kSeekDurationMs : kDurationMs))));
    const bool consumedRangeOk = !seekCommandMode
        ? report.consumedFrames <= totalFrames
        : expectedHashOk && !seekSegments.empty() &&
          report.consumedFrames >= finalSegmentStart &&
          postSeekFrames <=
              totalFrames - tickStarts[seekSegments.back().sourceTick];
    const uint32_t expectedPublishedModPos = seekCommandMode &&
        !seekSegments.empty()
        ? expectedSegmentModPos(
            tickStarts, modposByTick, stateFrames, seekSegments.back(),
            report.publishedPcmFrame)
        : expectedModPos(
            tickStarts, modposByTick, stateFrames, report.publishedPcmFrame);
    bool checkpointTimelineOk = true;
    for (const AudioSeekCheckpoint& checkpoint : seekCheckpoints) {
        const AudioSeekSegment segment{
            checkpoint.segmentStart, checkpoint.segmentTick};
        checkpointTimelineOk = checkpointTimelineOk &&
            checkpoint.publishedFrame >= checkpoint.segmentStart &&
            checkpoint.publishedFrame <= checkpoint.consumed &&
            checkpoint.publishedModPos == expectedSegmentModPos(
                tickStarts, modposByTick, stateFrames, segment,
                checkpoint.publishedFrame);
    }
    const uint32_t expectedPauseTransitions = controlMode ? 2u :
        (seekCommandMode ? static_cast<uint32_t>(seekTargets.size() * 2) : 0u);
    const bool transferOk =
        producer.failed == 0 && producer.producedStates > 0 &&
        producer.pushedFrames >= report.consumedFrames &&
        report.consumedFrames <= common.frames &&
        consumedRangeOk &&
        report.underrunEvents == 0 && ring.underrunEvents == 0 &&
        report.markerOverruns == 0 && ring.markerOverruns == 0 &&
        report.snapshotUpdates > 0 &&
        report.publishedPcmFrame <= report.consumedFrames &&
        expectedHashOk && report.pcmFnv == expectedPrefix.value &&
        (!seekCommandMode || (seekPrebuffered && checkpointTimelineOk &&
            !seekSegments.empty() &&
            report.publishedPcmFrame >= finalSegmentStart &&
            report.publishedPcmFrame - finalSegmentStart <
                totalFrames - tickStarts[seekSegments.back().sourceTick])) &&
        report.publishedModPos == expectedPublishedModPos;
    const bool controlReportOk =
        !commandMode ||
        (controlOk && report.pauseTransitions == expectedPauseTransitions &&
         report.pausedFrames > 0 && report.finalPausedState == 0);
    bool timelineOk = !timelinePath || timelineSamples.size() >= 2;
    for (size_t i = 1; i < timelineSamples.size(); ++i) {
        const auto& previous = timelineSamples[i - 1];
        const auto& current = timelineSamples[i];
        timelineOk = timelineOk && current.elapsedUs >= previous.elapsedUs &&
            current.consumedFrames >= previous.consumedFrames &&
            current.publishedFrame >= previous.publishedFrame;
    }
    if (!hresultsOk || !threadOk || !transferOk || !controlReportOk ||
        !timelineOk) {
        std::cerr << "audio_live_wasapi_probe: FAIL hresults=" << hresultsOk
                  << " thread=" << threadOk
                  << " transfer=" << transferOk
                  << " control=" << controlReportOk
                  << " timeline=" << timelineOk << '\n';
        return 1;
    }
    return 0;
}
