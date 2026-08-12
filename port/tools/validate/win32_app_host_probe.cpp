// win32_app_host_probe.cpp - deterministic NASM production-host witness.

#include "platform_abi.h"
#include <cstdint>
#include <cstring>

extern "C" int asm_parse_command_line(const char* commandLine);
extern "C" int asm_voodka_arg_fullscreen(void);
extern "C" int asm_voodka_host_main(void* hInst, const char*, int);

namespace {

struct State {
    char sequence[96]{};
    int length = 0;
    int windowResult = 1;
    int startupResult = 1;
    int runResult = 73;
    int logCalls = 0;
    void* window = reinterpret_cast<void*>(0x1234);
    vk::AppStartupConfig startup{};
    uint64_t runBase = 0;
    uint64_t runSize = 0;
};

State g;

void reset() {
    g = {};
    g.windowResult = 1;
    g.startupResult = 1;
    g.runResult = 73;
    g.window = reinterpret_cast<void*>(0x1234);
}

void mark(char c) {
    if (g.length < static_cast<int>(sizeof(g.sequence) - 1))
        g.sequence[g.length++] = c;
    g.sequence[g.length] = '\0';
}

bool seq(const char* expected) { return std::strcmp(g.sequence, expected) == 0; }

} // namespace

extern "C" void asm_log_init() { mark('J'); }
extern "C" void vk_log_printf(const char*, ...) { mark('L'); g.logCalls++; }
extern "C" const char* vk_app_resolve_music_path(const char* overridePath) {
    mark('M');
    static const char resolved[] = "resolved.mod";
    return overridePath && overridePath[0] ? overridePath : resolved;
}
extern "C" void* asm_create_voodka_window(void*) {
    mark('W');
    return g.windowResult ? g.window : nullptr;
}
extern "C" void asm_shutdown_set_window(void*, void*) { mark('H'); }
extern "C" void asm_shutdown_all() { mark('S'); }
extern "C" int asm_voodka_initialize_subsystems(
    const vk::AppStartupConfig* config) {
    mark('I');
    g.startup = *config;
    return g.startupResult;
}
extern "C" int asm_voodka_apply_entry_seek() { mark('K'); return 1; }
extern "C" uint64_t vk_arena_get() { mark('A'); return 0x10000000ull; }
extern "C" int asm_voodka_run_mode(uint8_t* base, uint64_t size) {
    mark('R');
    g.runBase = reinterpret_cast<uint64_t>(base);
    g.runSize = size;
    return g.runResult;
}

int main() {
    if (!asm_parse_command_line(
            "--record capture --diag readback --timeline av.raw "
            "--music override.mod --libxmp-audio --auto-pause-ms 125 "
            "--auto-close-ms 900 --fullscreen-1920x1080")) return 1;
    if (asm_voodka_arg_fullscreen() == 0) return 9;
    reset();
    if (asm_voodka_host_main(reinterpret_cast<void*>(0xBEEF), nullptr, 0) != 73 ||
        !seq("JLLLLLLLLLMWHIKARS") ||
        g.startup.hwnd != g.window ||
        std::strcmp(g.startup.recDir, "capture") != 0 ||
        std::strcmp(g.startup.diagDir, "readback") != 0 ||
        std::strcmp(g.startup.timelinePath, "av.raw") != 0 ||
        std::strcmp(g.startup.musicPath, "override.mod") != 0 ||
        g.startup.asmAudio != 0 || g.startup.referenceAudio != 1 ||
        g.startup.asmPresenter != 1 || g.startup.autoPauseMs != 125 ||
        g.startup.autoCloseMs != 900 || g.runBase != 0x10000000ull ||
        g.runSize != 0x04000000ull) return 2;

    if (!asm_parse_command_line("")) return 3;
    if (asm_voodka_arg_fullscreen() != 0) return 10;
    reset();
    if (asm_voodka_host_main(reinterpret_cast<void*>(0xBEEF), nullptr, 0) != 73 ||
        !seq("JLLLLLMWHIKARS") ||
        g.startup.asmAudio != 1 || g.startup.referenceAudio != 0 ||
        g.startup.recDir != nullptr || g.startup.diagDir != nullptr ||
        g.startup.timelinePath != nullptr ||
        std::strcmp(g.startup.musicPath, "resolved.mod") != 0) return 4;

    if (!asm_parse_command_line("--record capture")) return 5;
    reset();
    g.windowResult = 0;
    if (asm_voodka_host_main(reinterpret_cast<void*>(0xBEEF), nullptr, 0) != 1 ||
        !seq("JLLLLLMWLS")) return 6;

    if (!asm_parse_command_line("--record capture")) return 7;
    reset();
    g.startupResult = 0;
    if (asm_voodka_host_main(reinterpret_cast<void*>(0xBEEF), nullptr, 0) != 0 ||
        !seq("JLLLLLMWHI")) return 8;

    return 0;
}
