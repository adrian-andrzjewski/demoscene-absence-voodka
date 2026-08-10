// timeline.cpp - optional per-frame A/V synchronization witness.
//
// This is intentionally a diagnostics-only path.  It records the same
// ModPos value consumed by the assembly scene code at the same 70 Hz choke
// point used for visual pacing.  The production renderer/audio behavior is
// unchanged when --timeline is not supplied.

#include "platform_abi.h"

#include <cstdio>
#include <cstdint>

namespace vk {

namespace {
FILE* g_file = nullptr;
}

void timelineInit(const char* path) {
    if (!path || !path[0]) return;
    g_file = std::fopen(path, "wb");
    if (!g_file) {
        logPrint("[timeline] cannot open '%s'\n", path);
        return;
    }
    std::fprintf(g_file,
                 "# frame qpc_us modpos audio_elapsed_us\n");
    std::fflush(g_file);
    logPrint("[timeline] writing '%s'\n", path);
}

void timelineFrame(uint64_t frame, uint64_t qpcUs, uint32_t modpos) {
    if (!g_file) return;
    const uint64_t audioUs =
        static_cast<uint64_t>(audioElapsedSec() * 1000000.0);
    std::fprintf(g_file, "%llu %llu %u %llu\n",
                 static_cast<unsigned long long>(frame),
                 static_cast<unsigned long long>(qpcUs), modpos,
                 static_cast<unsigned long long>(audioUs));
}

void timelineClose() {
    if (!g_file) return;
    std::fflush(g_file);
    std::fclose(g_file);
    g_file = nullptr;
}

} // namespace vk
