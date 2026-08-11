// audio_dispatch_probe.cpp - differential witness for the NASM audio ABI shim.

#include "platform_abi.h"

#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {
int g_initCalls = 0;
int g_shutdownCalls = 0;
int g_playCalls = 0;
int g_stopCalls = 0;
int g_pumpCalls = 0;
int g_seekRowsCalls = 0;
int g_seekMsCalls = 0;
int g_seekOrderCalls = 0;
int g_selfCheckCalls = 0;
int g_logCalls = 0;
const char* g_lastPath = nullptr;
int g_lastRate = 0;
uint32_t g_lastValue = 0;
int g_lastSigned = 0;
}

extern "C" void vk_log_printf(const char* fmt, ...) {
    ++g_logCalls;
    if (!fmt || std::strcmp(fmt,
            "[audio] libxmp reference path is unavailable in VOODKA.exe\n") != 0) {
        std::fprintf(stderr, "unexpected audio dispatch log format\n");
        std::fflush(stderr);
        std::abort();
    }
}

namespace vk {

int audioAsmInit(const char* path, int rate) {
    ++g_initCalls;
    g_lastPath = path;
    g_lastRate = rate;
    return 17;
}
void audioAsmShutdown() { ++g_shutdownCalls; }
int audioAsmPlay() { ++g_playCalls; return 19; }
int audioAsmStop() { ++g_stopCalls; return 23; }
uint32_t audioAsmModPos() { return 0x1234u; }
uint32_t audioAsmModLength() { return 0x56u; }
double audioAsmElapsedSec() { return 12.5; }
void audioAsmPump() { ++g_pumpCalls; }
uint32_t audioAsmSeekRows(uint32_t value) {
    ++g_seekRowsCalls;
    g_lastValue = value;
    return value + 1;
}
uint32_t audioAsmSeekMs(int value) {
    ++g_seekMsCalls;
    g_lastSigned = value;
    return static_cast<uint32_t>(value + 2);
}
uint32_t audioAsmSeekOrder(int value) {
    ++g_seekOrderCalls;
    g_lastSigned = value;
    return static_cast<uint32_t>(value + 3);
}
int audioAsmSelfCheck(int value) {
    ++g_selfCheckCalls;
    g_lastSigned = value;
    return 29;
}

} // namespace vk

static bool check(bool condition, const char* message) {
    if (!condition) std::fprintf(stderr, "audio dispatch: %s\n", message);
    return condition;
}

int main() {
    const char* path = "probe.mod";
    bool ok = true;

    ok &= check(vk::audioInit(path, 44100) == 17, "init result");
    ok &= check(g_initCalls == 1 && g_lastPath == path && g_lastRate == 44100,
                "init forwarding");
    ok &= check(vk::audioPlay() == 19 && vk::audioStop() == 23,
                "play/stop forwarding");
    vk::audioPump();
    ok &= check(g_pumpCalls == 1, "pump forwarding");
    ok &= check(vk::getModPos() == 0x1234u && vk::getModLength() == 0x56u,
                "position forwarding");
    ok &= check(vk::audioElapsedSec() == 12.5, "elapsed forwarding");
    ok &= check(vk::audioSeekRows(0x200) == 0x201 && g_lastValue == 0x200,
                "row seek forwarding");
    ok &= check(vk::audioSeekMs(500) == 502 && g_lastSigned == 500,
                "millisecond seek forwarding");
    ok &= check(vk::audioSeekOrder(7) == 10 && g_lastSigned == 7,
                "order seek forwarding");
    ok &= check(vk::audioSelfCheck(4) == 29 && g_lastSigned == 4,
                "self-check forwarding");

    vk::audioSetAssemblyMode(false);
    ok &= check(vk::audioInit(path, 22050) == 0, "disabled init result");
    ok &= check(vk::audioPlay() == 0 && vk::audioStop() == 0,
                "disabled play/stop result");
    vk::audioPump();
    ok &= check(vk::getModPos() == 0 && vk::getModLength() == 0,
                "disabled scalar result");
    ok &= check(vk::audioElapsedSec() == 0.0, "disabled elapsed result");
    ok &= check(vk::audioSeekRows(1) == 0 && vk::audioSeekMs(2) == 0 &&
                    vk::audioSeekOrder(3) == 0,
                "disabled seek result");
    ok &= check(vk::audioSelfCheck(4) == 1, "disabled self-check result");
    ok &= check(g_logCalls == 1 && g_initCalls == 1 && g_pumpCalls == 1,
                "disabled calls do not reach player");

    vk::audioShutdown();
    ok &= check(g_shutdownCalls == 1, "shutdown always forwards");
    return ok ? 0 : 1;
}
