// win32_app_startup_probe.cpp - deterministic NASM startup-coordinator witness.

#include "platform_abi.h"
#include <cstdint>
#include <cstring>

extern "C" int asm_voodka_initialize_subsystems(
    const vk::AppStartupConfig* config);

namespace {

struct State {
    char sequence[64]{};
    int length = 0;
    int inputResult = 1;
    int platformResult = 1;
    int audioResult = 1;
    int presentResult = 1;
    int lifecycleResult = 1;
    int quitResult = 0;
    void* hwnd = nullptr;
    const char* timeline = nullptr;
    const char* rec = nullptr;
    const char* music = nullptr;
    const char* diag = nullptr;
    int audioMode = -1;
    int audioRate = 0;
    int audioFailureReference = -1;
    int presenter = -1;
    int presentWidth = 0;
    int presentHeight = 0;
    int lifecyclePause = 0;
    int lifecycleClose = 0;
    int automationPause = 0;
    int automationClose = 0;
};

State g;

void reset() { g = {}; g.inputResult = g.platformResult = 1;
    g.audioResult = g.presentResult = g.lifecycleResult = 1;
}

void mark(char value) {
    if (g.length < static_cast<int>(sizeof(g.sequence) - 1))
        g.sequence[g.length++] = value;
    g.sequence[g.length] = '\0';
}

bool sequenceIs(const char* expected) {
    return std::strcmp(g.sequence, expected) == 0;
}

vk::AppStartupConfig config() {
    static const char rec[] = "capture";
    static const char diag[] = "readback";
    static const char timeline[] = "timeline.raw";
    static const char music[] = "amnezja2.mod";
    return {reinterpret_cast<void*>(0x1234), rec, diag, timeline, music,
            1, 0, 1, 125, 900};
}

} // namespace

extern "C" void vk_app_progress_init(void* hwnd) {
    mark('P'); g.hwnd = hwnd;
}
extern "C" int vk_app_input_init(void* hwnd) {
    mark('I'); g.hwnd = hwnd; return g.inputResult;
}
extern "C" int vk_app_platform_init() { mark('A'); return g.platformResult; }
extern "C" int vk_app_quit_requested() { mark('Q'); return g.quitResult; }
extern "C" void vk_app_shutdown_all() { mark('S'); }
extern "C" void vk_app_shutdown_and_exit() { mark('X'); }
extern "C" void vk_app_timer_init() { mark('T'); }
extern "C" void vk_app_timeline_init(const char* path) {
    mark('L'); g.timeline = path;
}
extern "C" void vk_app_rec_init(const char* path) {
    mark('R'); g.rec = path;
}
extern "C" void vk_app_log_music(const char* path) {
    mark('M'); g.music = path;
}
extern "C" void vk_app_audio_set_mode(int enabled) {
    mark('m'); g.audioMode = enabled;
}
extern "C" int vk_app_audio_init(const char* path, int sampleRate) {
    mark('a'); g.music = path; g.audioRate = sampleRate; return g.audioResult;
}
extern "C" void vk_app_log_input_failure() { mark('f'); }
extern "C" void vk_app_log_arena_failure() { mark('b'); }
extern "C" void vk_app_log_audio_failure(int referenceAudio) {
    mark('F'); g.audioFailureReference = referenceAudio;
}
extern "C" void vk_app_set_assembly_presenter(int enabled) {
    mark('p'); g.presenter = enabled;
}
extern "C" int vk_app_present_init(void* hwnd, int width, int height) {
    mark('D'); g.hwnd = hwnd; g.presentWidth = width; g.presentHeight = height;
    return g.presentResult;
}
extern "C" void vk_app_diag_init(const char* path) {
    mark('G'); g.diag = path;
}
extern "C" void vk_app_log_present_failure() { mark('e'); }
extern "C" void vk_app_log_automation_failure() { mark('z'); }
extern "C" void vk_app_log_automation(int32_t pauseMs, int32_t closeMs) {
    mark('O'); g.automationPause = pauseMs; g.automationClose = closeMs;
}
extern "C" int asm_lifecycle_start(void* hwnd, int32_t pauseMs,
                                    int32_t closeMs) {
    mark('C'); g.hwnd = hwnd; g.lifecyclePause = pauseMs;
    g.lifecycleClose = closeMs; return g.lifecycleResult;
}

int main() {
    const auto startup = config();

    reset();
    if (asm_voodka_initialize_subsystems(&startup) != 1 ||
        !sequenceIs("PIAQTLRMmaQpDGQCO") ||
        g.hwnd != reinterpret_cast<void*>(0x1234) ||
        g.timeline != startup.timelinePath || g.rec != startup.recDir ||
        g.music != startup.musicPath || g.diag != startup.diagDir ||
        g.audioMode != 1 || g.audioRate != 44100 || g.presenter != 1 ||
        g.presentWidth != 1280 || g.presentHeight != 800 ||
        g.lifecyclePause != 125 || g.lifecycleClose != 900 ||
        g.automationPause != 125 || g.automationClose != 900) return 1;

    reset();
    g.inputResult = 0;
    if (asm_voodka_initialize_subsystems(&startup) != 0 ||
        !sequenceIs("PIfS")) return 2;

    reset();
    g.platformResult = 0;
    if (asm_voodka_initialize_subsystems(&startup) != 0 ||
        !sequenceIs("PIAbS")) return 3;

    reset();
    g.audioResult = 0;
    auto referenceAudio = startup;
    referenceAudio.referenceAudio = 1;
    if (asm_voodka_initialize_subsystems(&referenceAudio) != 0 ||
        !sequenceIs("PIAQTLRMmaFS") || g.audioFailureReference != 1) return 4;

    reset();
    g.presentResult = 0;
    if (asm_voodka_initialize_subsystems(&startup) != 0 ||
        !sequenceIs("PIAQTLRMmaQpDeS")) return 5;

    reset();
    g.lifecycleResult = 0;
    if (asm_voodka_initialize_subsystems(&startup) != 0 ||
        !sequenceIs("PIAQTLRMmaQpDGQCzS")) return 6;

    return 0;
}
