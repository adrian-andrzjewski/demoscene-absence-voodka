// audio_pcm_thread_probe.cpp - native assembly PCM handoff into the assembly
// WASAPI worker, with an assembly-owned playback timeline snapshot.

#include "audio_mix_abi.h"
#include "audio_mod_abi.h"
#include "audio_thread_abi.h"
#include "audio_tracker_abi.h"

#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <limits>
#include <vector>

namespace {

constexpr uint32_t kStateCapacity = 20000;
constexpr uint32_t kDurationMs = 1000;
constexpr uint32_t kChannels = 2;
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
                       uint32_t stateFrames, uint32_t channels,
                       std::vector<uint32_t>* tickStarts,
                       uint32_t* totalFrames) {
    if (!stateFrames || !channels || states.size() <
            static_cast<size_t>(stateFrames) * channels) {
        return false;
    }

    tickStarts->resize(static_cast<size_t>(stateFrames) + 1);
    uint64_t total = 0;
    for (uint32_t frame = 0; frame < stateFrames; ++frame) {
        if (states[static_cast<size_t>(frame) * channels].tickFrames == 0)
            return false;
        (*tickStarts)[frame] = static_cast<uint32_t>(total);
        total += states[static_cast<size_t>(frame) * channels].tickFrames;
        if (total > std::numeric_limits<uint32_t>::max()) return false;
    }
    (*tickStarts)[stateFrames] = static_cast<uint32_t>(total);
    *totalFrames = static_cast<uint32_t>(total);
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

} // namespace

int main(int argc, char** argv) {
    if (argc != 2) {
        std::cerr << "usage: audio_pcm_thread_probe <module.mod>\n";
        return 2;
    }

    std::vector<uint8_t> module;
    if (!readFile(argv[1], &module)) {
        std::cerr << "audio_pcm_thread_probe: cannot read module\n";
        return 1;
    }

    audio_abi::Summary summary{};
    if (asm_audio_parse_mod(module.data(), static_cast<uint32_t>(module.size()),
                            &summary) != 0 || summary.status != 0) {
        std::cerr << "audio_pcm_thread_probe: NASM parser failed\n";
        return 1;
    }

    std::vector<AudioTickState> states(
        static_cast<size_t>(kStateCapacity) * summary.channelCount);
    const uint32_t stateFrames = asm_audio_trace_tick_states(
        module.data(), static_cast<uint32_t>(module.size()), states.data(),
        kStateCapacity);
    if (!stateFrames || stateFrames > kStateCapacity) {
        std::cerr << "audio_pcm_thread_probe: native state trace failed\n";
        return 1;
    }

    std::vector<uint32_t> tickStarts;
    uint32_t totalFrames = 0;
    if (!checkedFrameTotal(states, stateFrames, summary.channelCount,
                           &tickStarts, &totalFrames)) {
        std::cerr << "audio_pcm_thread_probe: invalid tick timing\n";
        return 1;
    }

    std::vector<int16_t> pcm(static_cast<size_t>(totalFrames) * kChannels);
    const uint32_t mixedFrames = asm_audio_mix_tick_states(
        module.data(), static_cast<uint32_t>(module.size()), states.data(),
        stateFrames, pcm.data(), totalFrames);
    if (mixedFrames != totalFrames) {
        std::cerr << "audio_pcm_thread_probe: native mixer frames="
                  << mixedFrames << " expected=" << totalFrames << '\n';
        return 1;
    }

    std::vector<uint32_t> modposByTick;
    if (!buildModPosTimeline(module.data(), static_cast<uint32_t>(module.size()),
                             stateFrames, &modposByTick)) {
        std::cerr << "audio_pcm_thread_probe: native timeline failed\n";
        return 1;
    }

    AudioPcmThreadArgs args{
        pcm.data(), totalFrames, tickStarts.data(), modposByTick.data(),
        stateFrames, kDurationMs};
    AudioPcmThreadReport report{};
    const uint32_t result = asm_audio_pcm_thread_probe(&args, &report);

    Fnv64 pcmHash;
    pcmHash.add(pcm.data(), pcm.size() * sizeof(int16_t));
    const auto& common = report.common;
    std::printf(
        "audio_pcm_thread_probe result=%u prerender_frames=%u states=%u "
        "pcm_fnv=0x%016llX thread=%u wait=%08X start=%08X wakeups=%u "
        "device_frames=%u timeouts=%u published_tick=%u modpos=%04X "
        "published_frame=%u snapshots=%u source_loops=%u worker_exit=%u\n",
        result, totalFrames, stateFrames,
        static_cast<unsigned long long>(pcmHash.value),
        common.threadCreated, common.threadWait, common.startHr,
        common.eventWakeups, common.frames, common.timeouts,
        report.publishedTick, report.publishedModPos,
        report.publishedPcmFrame, report.snapshotUpdates,
        report.sourceLoops, common.workerExit);

    const bool hresultsOk =
        common.comHr == 0 && common.enumeratorHr == 0 &&
        common.endpointHr == 0 && common.activateHr == 0 &&
        common.formatHr == 0 && common.initializeHr == 0 &&
        common.setEventHr == 0 && common.serviceHr == 0 &&
        common.startHr == 0 && common.paddingHr == 0 &&
        common.getBufferHr == 0 && common.releaseHr == 0 &&
        common.stopHr == 0 && common.resetHr == 0;
    const bool threadOk =
        result == 0 && common.threadCreated == 1 &&
        common.threadPriority == 1 && common.threadWait == 0 &&
        common.bufferSize > 0 && common.eventCreated == 1 &&
        common.firstWait == 1 && common.eventWakeups > 0 &&
        common.frames > 0 && common.frames <= totalFrames &&
        common.timeouts == 0 && common.workerExit == 0 &&
        common.durationMs == kDurationMs;
    const bool timelineOk =
        report.sourceLoops == 0 && report.snapshotUpdates > 0 &&
        report.publishedPcmFrame == common.frames &&
        report.publishedTick < stateFrames &&
        report.publishedModPos == modposByTick[report.publishedTick];
    if (!hresultsOk || !threadOk || !timelineOk) {
        std::cerr << "audio_pcm_thread_probe: FAIL hresults=" << hresultsOk
                  << " thread=" << threadOk
                  << " timeline=" << timelineOk << '\n';
        return 1;
    }
    return 0;
}
