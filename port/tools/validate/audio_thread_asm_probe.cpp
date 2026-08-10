// audio_thread_asm_probe.cpp - host assertions for the assembly audio thread.
//
// The worker owns COM, WASAPI, and the callback event. This executable only
// supplies a duration, receives a fixed-width report, and checks that the
// worker joined after servicing real endpoint wakeups.

#include <cstddef>
#include <cstdint>
#include <cstdio>

struct AudioThreadAsmProbeReport {
    uint32_t threadCreated;
    uint32_t threadPriority;
    uint32_t threadWait;
    uint32_t comHr;
    uint32_t enumeratorHr;
    uint32_t endpointHr;
    uint32_t activateHr;
    uint32_t formatHr;
    uint32_t initializeHr;
    uint32_t bufferSize;
    uint32_t eventCreated;
    uint32_t setEventHr;
    uint32_t serviceHr;
    uint32_t startHr;
    uint32_t firstWait;
    uint32_t paddingHr;
    uint32_t paddingFrames;
    uint32_t getBufferHr;
    uint32_t releaseHr;
    uint32_t stopHr;
    uint32_t resetHr;
    uint32_t eventWakeups;
    uint32_t frames;
    uint32_t timeouts;
    uint32_t workerExit;
    uint32_t durationMs;
};

static_assert(sizeof(AudioThreadAsmProbeReport) == 104);
static_assert(offsetof(AudioThreadAsmProbeReport, firstWait) == 56);
static_assert(offsetof(AudioThreadAsmProbeReport, paddingFrames) == 64);
static_assert(offsetof(AudioThreadAsmProbeReport, eventWakeups) == 84);
static_assert(offsetof(AudioThreadAsmProbeReport, durationMs) == 100);

extern "C" uint32_t asm_audio_thread_probe(
    uint32_t durationMs, AudioThreadAsmProbeReport* report);

int main() {
    constexpr uint32_t kDurationMs = 1000;
    AudioThreadAsmProbeReport report{};
    const uint32_t result = asm_audio_thread_probe(kDurationMs, &report);

    std::printf(
        "audio_thread_asm_probe result=%u thread=%u priority=%u wait=%08X "
        "com=%08X enum=%08X endpoint=%08X activate=%08X format=%08X "
        "init=%08X buffer=%u event=%u set_event=%08X service=%08X "
        "start=%08X first_wait=%08X padding=%08X/%u get=%08X release=%08X "
        "stop=%08X reset=%08X wakeups=%u frames=%u timeouts=%u "
        "worker_exit=%u duration=%u\n",
        result, report.threadCreated, report.threadPriority,
        report.threadWait, report.comHr, report.enumeratorHr,
        report.endpointHr, report.activateHr, report.formatHr,
        report.initializeHr, report.bufferSize, report.eventCreated,
        report.setEventHr, report.serviceHr, report.startHr,
        report.firstWait, report.paddingHr, report.paddingFrames,
        report.getBufferHr,
        report.releaseHr, report.stopHr, report.resetHr,
        report.eventWakeups, report.frames, report.timeouts,
        report.workerExit, report.durationMs);

    const bool ok =
        result == 0 && report.threadCreated == 1 &&
        report.threadPriority == 1 && report.threadWait == 0 &&
        report.comHr == 0 && report.enumeratorHr == 0 &&
        report.endpointHr == 0 && report.activateHr == 0 &&
        report.formatHr == 0 && report.initializeHr == 0 &&
        report.bufferSize > 0 && report.eventCreated == 1 &&
        report.setEventHr == 0 && report.serviceHr == 0 &&
        report.startHr == 0 && report.firstWait == 1 &&
        report.paddingHr == 0 && report.getBufferHr == 0 &&
        report.releaseHr == 0 && report.stopHr == 0 &&
        report.resetHr == 0 && report.eventWakeups > 0 &&
        report.frames > 0 && report.workerExit == 0 &&
        report.durationMs == kDurationMs;
    return ok ? 0 : 1;
}
