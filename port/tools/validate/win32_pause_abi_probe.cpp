// win32_pause_abi_probe.cpp - decorated vk:: pause ABI witness.

#include "platform_abi.h"

#include <cstdarg>
#include <cstdio>
#include <cstring>

namespace {
uint32_t g_modpos = 0x1234;
double g_elapsed = 12.5;
int g_pumps = 0;
int g_log_calls = 0;
char g_log[256] = {};
}

namespace vk {

uint32_t getModPos() { return g_modpos; }
double audioElapsedSec() { return g_elapsed; }
void audioPump() { ++g_pumps; }

}  // namespace vk

extern "C" void vk_log_printf(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    std::vsnprintf(g_log, sizeof g_log, fmt, ap);
    va_end(ap);
    ++g_log_calls;
}

int main() {
    if (vk::isPaused()) return 1;

    vk::pauseToggle();
    if (!vk::isPaused() || g_pumps != 1 || g_log_calls != 1) return 2;
    if (std::strcmp(g_log,
                    "[pause] PAUSED  ModPos=0x1234 elapsed=12.50s toggle=1\n") != 0)
        return 3;

    vk::pauseToggle();
    if (vk::isPaused() || g_pumps != 2 || g_log_calls != 2) return 4;
    if (std::strcmp(g_log,
                    "[pause] RESUMED ModPos=0x1234 elapsed=12.50s toggle=2\n") != 0)
        return 5;
    return 0;
}
