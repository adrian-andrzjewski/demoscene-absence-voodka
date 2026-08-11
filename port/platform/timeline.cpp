// timeline.cpp - optional per-frame A/V synchronization witness.
//
// This is intentionally a diagnostics-only path.  It records the same
// ModPos value consumed by the assembly scene code at the same 70 Hz choke
// point used for visual pacing.  The production renderer/audio behavior is
// unchanged when --timeline is not supplied.

#include "platform_abi.h"

#include <cstdio>
#include <cstdarg>
#include <cstdint>

#if defined(VOODKA_ASSEMBLY_PLATFORM)
extern "C" int asm_log_vformat(char*, unsigned, const char*, const char*);
extern "C" int asm_timeline_open(const char*);
extern "C" int asm_timeline_write(const char*, unsigned);
extern "C" void asm_timeline_flush(void);
extern "C" void asm_timeline_close(void);
#endif

namespace vk {

#if !defined(VOODKA_ASSEMBLY_PLATFORM)
namespace {
FILE* g_file = nullptr;
}
#endif

#if defined(VOODKA_ASSEMBLY_PLATFORM)
namespace {
int timelineFormat(char* out, unsigned capacity, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    const int length = asm_log_vformat(out, capacity, fmt, ap);
    va_end(ap);
    return length;
}
}
#endif

void timelineInit(const char* path) {
    if (!path || !path[0]) return;
#if defined(VOODKA_ASSEMBLY_PLATFORM)
    if (!asm_timeline_open(path)) {
        logPrint("[timeline] cannot open '%s'\n", path);
        return;
    }
    static constexpr char header[] =
        "# frame qpc_us modpos audio_elapsed_us\n";
    asm_timeline_write(header, static_cast<unsigned>(sizeof(header) - 1));
    asm_timeline_flush();
#else
    g_file = std::fopen(path, "wb");
    if (!g_file) {
        logPrint("[timeline] cannot open '%s'\n", path);
        return;
    }
    std::fprintf(g_file,
                 "# frame qpc_us modpos audio_elapsed_us\n");
    std::fflush(g_file);
#endif
    logPrint("[timeline] writing '%s'\n", path);
}

void timelineFrame(uint64_t frame, uint64_t qpcUs, uint32_t modpos) {
#if !defined(VOODKA_ASSEMBLY_PLATFORM)
    if (!g_file) return;
#endif
    const uint64_t audioUs =
        static_cast<uint64_t>(audioElapsedSec() * 1000000.0);
#if defined(VOODKA_ASSEMBLY_PLATFORM)
    char line[128];
    const int length = timelineFormat(
        line, sizeof line, "%llu %llu %u %llu\n",
        static_cast<unsigned long long>(frame),
        static_cast<unsigned long long>(qpcUs), modpos,
        static_cast<unsigned long long>(audioUs));
    if (length >= 0) asm_timeline_write(line, static_cast<unsigned>(length));
#else
    std::fprintf(g_file, "%llu %llu %u %llu\n",
                 static_cast<unsigned long long>(frame),
                 static_cast<unsigned long long>(qpcUs), modpos,
                 static_cast<unsigned long long>(audioUs));
#endif
}

void timelineClose() {
#if defined(VOODKA_ASSEMBLY_PLATFORM)
    asm_timeline_flush();
    asm_timeline_close();
#else
    if (!g_file) return;
    std::fflush(g_file);
    std::fclose(g_file);
    g_file = nullptr;
#endif
}

} // namespace vk
