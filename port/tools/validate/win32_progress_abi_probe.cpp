// win32_progress_abi_probe.cpp - decorated vk:: progress ABI witness.

#include "platform_abi.h"

#include <cstdarg>
#include <cstdio>
#include <cstring>

namespace {
uint32_t g_modpos = 0;
uint64_t g_frame = 17;
uint64_t g_qpc = 123456;
double g_elapsed = 12.5;
int g_timeline_calls = 0;
uint64_t g_last_frame = 0;
uint64_t g_last_qpc = 0;
uint32_t g_last_modpos = 0;
int g_log_calls = 0;
char g_log[512] = {};
}

namespace vk {

uint32_t getModPos() { return g_modpos; }
uint64_t getFrameCounter() { return g_frame; }
uint64_t getQpcUs() { return g_qpc; }
void timelineFrame(uint64_t frame, uint64_t qpcUs, uint32_t modpos) {
    ++g_timeline_calls;
    g_last_frame = frame;
    g_last_qpc = qpcUs;
    g_last_modpos = modpos;
}
double audioElapsedSec() { return g_elapsed; }

}  // namespace vk

extern "C" void vk_log_printf(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    std::vsnprintf(g_log, sizeof g_log, fmt, ap);
    va_end(ap);
    ++g_log_calls;
}

int main() {
    vk::progressInit(nullptr);
    vk::progressUpdate();
    if (g_timeline_calls != 1 || g_last_frame != 17 ||
        g_last_qpc != 123456 || g_last_modpos != 0) return 1;
    if (g_log_calls != 1) return 2;
    if (std::strcmp(g_log,
        "[scene] part=1/8 scene=\"oko + szklo\" effect=\"Znik fade-in\" "
        "elapsed=00:12.5 modpos=0x0 scene_index=1\n") != 0)
        return 3;

    // Timeline emission is per frame, but scene logging is transition-only.
    ++g_frame;
    ++g_qpc;
    vk::progressUpdate();
    if (g_timeline_calls != 2 || g_log_calls != 1) return 4;

    g_modpos = 0x0100;
    g_elapsed = 65.7;
    ++g_frame;
    ++g_qpc;
    vk::progressUpdate();
    if (g_timeline_calls != 3 || g_last_modpos != 0x0100 || g_log_calls != 2)
        return 5;
    if (std::strcmp(g_log,
        "[scene] part=1/8 scene=\"oko + szklo\" effect=\"Texture-mapped head\" "
        "elapsed=01:05.7 modpos=0x100 scene_index=2\n") != 0)
        return 6;
    return 0;
}
