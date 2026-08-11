// win32_app_modes_probe.cpp - deterministic NASM app-mode witness.

#include <cstdint>

extern "C" int asm_parse_command_line(const char* commandLine);
extern "C" int asm_voodka_apply_entry_seek(void);
extern "C" int asm_voodka_run_mode(void* arenaBase, uint64_t arenaSize);

namespace {

struct State {
    int seekKind = 0;
    int32_t seekValue = 0;
    uint32_t seekPart = 0;
    uint32_t seekModPos = 0;
    int noEntrySeek = 0;
    int selftestLog = 0;
    int selftestPattern = 0;
    int presentCalls = 0;
    int audioLogSeconds = 0;
    int audioCheckSeconds = 0;
    int crashFilter = 0;
    uint64_t demoArena = 0;
    uint64_t demoSize = 0;
};

State g;

void resetState() {
    g = {};
}

bool parse(const char* commandLine) {
    return asm_parse_command_line(commandLine) != 0;
}

}  // namespace

extern "C" void vk_app_seek_modpos(uint32_t requested) {
    g.seekKind = 1;
    g.seekValue = static_cast<int32_t>(requested);
}

extern "C" void vk_app_seek_ms(int ms) {
    g.seekKind = 2;
    g.seekValue = ms;
}

extern "C" void vk_app_seek_order(int order) {
    g.seekKind = 3;
    g.seekValue = order;
}

extern "C" void vk_app_seek_part(uint32_t part, uint32_t modpos) {
    g.seekKind = 4;
    g.seekPart = part;
    g.seekModPos = modpos;
}

extern "C" void vk_app_no_entry_seek() {
    g.noEntrySeek = 1;
}

extern "C" void vk_app_log_selftest() {
    g.selftestLog++;
}

extern "C" void vk_app_selftest_pattern() {
    g.selftestPattern++;
}

extern "C" int vk_app_diag_readback_enabled() {
    return g.presentCalls < 3 ? 1 : 0;
}

extern "C" void vk_app_present_frame() {
    g.presentCalls++;
}

extern "C" void vk_app_log_audio_check(int seconds) {
    g.audioLogSeconds = seconds;
}

extern "C" int vk_app_audio_self_check(int seconds) {
    g.audioCheckSeconds = seconds;
    return 900 + seconds;
}

extern "C" void vk_app_log_demo_start(uint64_t arenaBase) {
    g.demoArena = arenaBase;
}

extern "C" void asm_install_crash_filter() {
    g.crashFilter++;
}

extern "C" int DemoStart32(uint8_t* arenaBase, uint64_t arenaSize) {
    g.demoArena = reinterpret_cast<uint64_t>(arenaBase);
    g.demoSize = arenaSize;
    return 73;
}

int main() {
    if (!parse("--modpos 4660 --ms 7 --order 2 --part 5")) return 1;
    resetState();
    if (asm_voodka_apply_entry_seek() != 1 || g.seekKind != 1 ||
        g.seekValue != 4660) return 2;

    if (!parse("--ms 77 --order 2 --part 3")) return 3;
    resetState();
    if (asm_voodka_apply_entry_seek() != 1 || g.seekKind != 2 ||
        g.seekValue != 77) return 4;

    if (!parse("--order 5 --part 2")) return 5;
    resetState();
    if (asm_voodka_apply_entry_seek() != 1 || g.seekKind != 3 ||
        g.seekValue != 5) return 6;

    if (!parse("--part 5")) return 7;
    resetState();
    if (asm_voodka_apply_entry_seek() != 1 || g.seekKind != 4 ||
        g.seekPart != 5 || g.seekModPos != 0x1400) return 8;

    if (!parse("--part 9")) return 9;
    resetState();
    if (asm_voodka_apply_entry_seek() != 0 || !g.noEntrySeek) return 10;

    if (!parse("")) return 11;
    resetState();
    if (asm_voodka_apply_entry_seek() != 0 || !g.noEntrySeek) return 12;

    if (!parse("--selftest --audiocheck 7")) return 13;
    resetState();
    if (asm_voodka_run_mode(reinterpret_cast<void*>(0x1234), 0x04000000) != 0 ||
        g.selftestLog != 1 || g.selftestPattern != 1 || g.presentCalls != 3 ||
        g.audioCheckSeconds != 0) return 14;

    if (!parse("--audiocheck 7")) return 15;
    resetState();
    if (asm_voodka_run_mode(nullptr, 0) != 907 ||
        g.audioLogSeconds != 7 || g.audioCheckSeconds != 7) return 16;

    if (!parse("--audiocheck")) return 17;
    resetState();
    if (asm_voodka_run_mode(nullptr, 0) != 920 ||
        g.audioLogSeconds != 20 || g.audioCheckSeconds != 20) return 18;

    if (!parse("")) return 19;
    resetState();
    if (asm_voodka_run_mode(reinterpret_cast<void*>(0x1234), 0x04000000) != 73 ||
        g.crashFilter != 1 || g.demoArena != 0x1234 ||
        g.demoSize != 0x04000000) return 20;
    return 0;
}
