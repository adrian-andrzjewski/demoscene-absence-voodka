// win32_platform_abi_probe.cpp - production decorated C++ ABI witness.

#include "platform_abi.h"
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>

namespace {

struct State {
    int logInitCalls = 0;
    int logFlushCalls = 0;
    int logShutdownCalls = 0;
    int timelineOpenCalls = 0;
    int timelineFlushCalls = 0;
    int timelineCloseCalls = 0;
    int audioClockCalls = 0;
    int formatCalls = 0;
    int logPrintfCalls = 0;
    bool timelineOpen = false;
    char timelinePath[128]{};
    char timelineBytes[512]{};
    size_t timelineLength = 0;
    char logText[512]{};
    size_t logLength = 0;
};

State g;

void append(char* dst, size_t& length, size_t capacity,
            const char* bytes, size_t count) {
    if (length >= capacity) return;
    const size_t room = capacity - length;
    if (count > room) count = room;
    std::memcpy(dst + length, bytes, count);
    length += count;
}

} // namespace

extern "C" int asm_log_init() { g.logInitCalls++; return 1; }
extern "C" void asm_log_flush() { g.logFlushCalls++; }
extern "C" void asm_log_shutdown() { g.logShutdownCalls++; }
extern "C" void asm_log_write(const char* bytes, unsigned length) {
    append(g.logText, g.logLength, sizeof(g.logText), bytes, length);
}

extern "C" int asm_timeline_open(const char* path) {
    g.timelineOpenCalls++;
    g.timelineOpen = true;
    std::strncpy(g.timelinePath, path ? path : "", sizeof(g.timelinePath) - 1);
    return 1;
}
extern "C" int asm_timeline_write(const char* bytes, unsigned length) {
    if (!g.timelineOpen) return 0;
    append(g.timelineBytes, g.timelineLength, sizeof(g.timelineBytes), bytes, length);
    return 1;
}
extern "C" void asm_timeline_flush() { g.timelineFlushCalls++; }
extern "C" void asm_timeline_close() {
    g.timelineCloseCalls++;
    g.timelineOpen = false;
}

extern "C" void vk_log_printf(const char* fmt, ...) {
    g.logPrintfCalls++;
    char line[256]{};
    va_list ap;
    va_start(ap, fmt);
    std::vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    append(g.logText, g.logLength, sizeof(g.logText), line, std::strlen(line));
}

extern "C" uint64_t vk_audio_elapsed_us() {
    g.audioClockCalls++;
    return 987654;
}

extern "C" int asm_log_vformat(char* out, unsigned capacity, const char* fmt,
                                const char* vaListCursor) {
    g.formatCalls++;
    if (!fmt || std::strcmp(fmt, "%llu %llu %u %llu\n") != 0 ||
        !vaListCursor || capacity < 32) return -1;
    const uint64_t* args = reinterpret_cast<const uint64_t*>(vaListCursor);
    const int length = std::snprintf(out, capacity, "%llu %llu %u %llu\n",
                                     static_cast<unsigned long long>(args[0]),
                                     static_cast<unsigned long long>(args[1]),
                                     static_cast<unsigned>(args[2]),
                                     static_cast<unsigned long long>(args[3]));
    return length;
}

int main() {
    vk::logInit();
    vk::logPrint("probe %u\n", 7u);
    vk::logFlush();
    if (g.logInitCalls != 1 || g.logPrintfCalls != 2 ||
        g.logFlushCalls != 1 ||
        std::strstr(g.logText, "---- VOODKA x64 port session ----\n") == nullptr ||
        std::strstr(g.logText, "probe 7\n") == nullptr) return 1;

    vk::timelineInit("timeline.raw");
    vk::timelineFrame(42, 1000, 0x123);
    vk::timelineClose();
    const char expected[] =
        "# frame qpc_us modpos audio_elapsed_us\n"
        "42 1000 291 987654\n";
    if (g.timelineOpenCalls != 1 || g.timelineFlushCalls != 2 ||
        g.timelineCloseCalls != 1 || g.audioClockCalls != 1 ||
        g.formatCalls != 1 || std::strcmp(g.timelinePath, "timeline.raw") != 0 ||
        g.timelineLength != sizeof(expected) - 1 ||
        std::memcmp(g.timelineBytes, expected, sizeof(expected) - 1) != 0) return 2;

    vk::logShutdown();
    if (g.logShutdownCalls != 1) return 3;
    return 0;
}
