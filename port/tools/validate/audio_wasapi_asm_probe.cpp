// audio_wasapi_asm_probe.cpp - host-side assertions for the NASM WASAPI gate.
//
// The host deliberately owns no COM or WASAPI objects. The assembly entry
// point performs the complete endpoint activation, event callback, render
// buffer, and teardown sequence and returns fixed-width diagnostics here.

#include <cstddef>
#include <cstdint>
#include <cstdio>

struct WasapiAsmProbeReport {
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
    uint32_t waitResult;
    uint32_t paddingHr;
    uint32_t paddingFrames;
    uint32_t getBufferHr;
    uint32_t releaseHr;
    uint32_t stopHr;
    uint32_t resetHr;
    uint32_t formatTag;
    uint32_t sampleRate;
    uint32_t channels;
    uint32_t frames;
};

static_assert(sizeof(WasapiAsmProbeReport) == 88);
static_assert(offsetof(WasapiAsmProbeReport, paddingHr) == 48);
static_assert(offsetof(WasapiAsmProbeReport, paddingFrames) == 52);
static_assert(offsetof(WasapiAsmProbeReport, frames) == 84);

extern "C" uint32_t asm_audio_wasapi_probe(WasapiAsmProbeReport* report);

int main() {
    WasapiAsmProbeReport report{};
    const uint32_t result = asm_audio_wasapi_probe(&report);

    std::printf(
        "audio_wasapi_asm_probe result=%u com=%08X enum=%08X endpoint=%08X "
        "activate=%08X format=%08X init=%08X buffer=%u event=%u "
        "set_event=%08X service=%08X start=%08X wait=%08X padding=%08X/%u "
        "get=%08X release=%08X stop=%08X reset=%08X fmt=%u/%uHz/%uch "
        "frames=%u\n",
        result, report.comHr, report.enumeratorHr, report.endpointHr,
        report.activateHr, report.formatHr, report.initializeHr,
        report.bufferSize, report.eventCreated, report.setEventHr,
        report.serviceHr, report.startHr, report.waitResult,
        report.paddingHr, report.paddingFrames, report.getBufferHr,
        report.releaseHr, report.stopHr, report.resetHr, report.formatTag,
        report.sampleRate, report.channels, report.frames);

    const bool ok =
        result == 0 &&
        report.enumeratorHr == 0 && report.endpointHr == 0 &&
        report.activateHr == 0 && report.formatHr == 0 &&
        report.initializeHr == 0 && report.bufferSize > 0 &&
        report.eventCreated == 1 && report.setEventHr == 0 &&
        report.serviceHr == 0 && report.startHr == 0 &&
        report.waitResult == 0 && report.paddingHr == 0 &&
        report.getBufferHr == 0 && report.releaseHr == 0 &&
        report.stopHr == 0 && report.resetHr == 0 &&
        report.formatTag == 1 && report.sampleRate == 44100 &&
        report.channels == 2 && report.frames > 0;
    return ok ? 0 : 1;
}
