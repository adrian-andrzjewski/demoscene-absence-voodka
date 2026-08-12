// win32_application_abi_probe.cpp - direct oracle for bridge_application.asm.
//
// The probe supplies tiny namespace-vk stubs, then exercises every production
// application adapter without creating a window, device, audio endpoint, or
// worker thread.  This keeps the C++ implementation available as an oracle
// while making the shipped NASM bridge independently testable.

#include <cstdint>
#include <cstdio>
#include <cstdarg>
#include <cstdlib>
#include <cstring>

extern "C" {
uint32_t vk_app_seek_modpos(uint32_t requested);
uint32_t vk_app_seek_ms(int ms);
uint32_t vk_app_seek_order(int order);
uint32_t vk_app_seek_part(uint32_t part, uint32_t modpos);
uint32_t vk_app_seek_scene(uint32_t part, uint32_t modpos);
int vk_scene_part_from_name(const char* token);
void vk_app_no_entry_seek();
void vk_app_log_selftest();
void vk_app_selftest_pattern();
int vk_app_diag_readback_enabled();
void vk_app_present_frame();
void vk_app_log_audio_check(int seconds);
int vk_app_audio_self_check(int seconds);
void vk_app_log_demo_start(uint64_t arenaBase);
void vk_app_progress_init(void* hwnd);
int vk_app_input_init(void* hwnd);
int vk_app_platform_init();
int vk_app_quit_requested();
void vk_app_shutdown_all();
void vk_app_shutdown_and_exit();
void vk_app_timer_init();
void vk_app_timeline_init(const char* path);
void vk_app_rec_init(const char* dir);
void vk_app_log_music(const char* path);
void vk_app_audio_set_mode(int enabled);
int vk_app_audio_init(const char* path, int sampleRate);
void vk_app_log_input_failure();
void vk_app_log_arena_failure();
void vk_app_log_audio_failure(int referenceAudio);
void vk_app_set_assembly_presenter(int enabled);
int vk_app_present_init(void* hwnd, int width, int height);
void vk_app_diag_init(const char* dir);
void vk_app_log_present_failure();
void vk_app_log_automation_failure();
void vk_app_log_automation(int32_t pauseMs, int32_t closeMs);
const char* vk_app_resolve_music_path(const char* overridePath);
void vk_set_entry_scene(int scenePart);
int vk_get_entry_scene();
void vk_key_down(uint32_t scancode);
void vk_key_up(uint32_t scancode);
void vk_pause_toggle();
void vk_request_quit();
void vk_platform_update_input();
int vk_platform_quit_requested();

void vk_log_printf(const char* fmt, ...);
void asm_shutdown_all();
void asm_shutdown_and_exit();
const char* asm_voodka_resolve_music_path(const char* overridePath,
                                          const char* repoRoot);
}

namespace vk {
void shutdownAll();

static uint32_t seekRowsArg;
static int seekMsArg;
static int seekOrderArg;
static void* progressHwnd;
static void* inputHwnd;
static bool quitState;
static bool initInputResult;
static bool initPlatformResult;
static bool diagEnabled;
static bool audioInitResult;
static int audioSelfCheckResult;
static int audioSelfCheckArg;
static bool audioMode;
static const char* timelinePath;
static const char* recDir;
static const char* audioPath;
static int audioRate;
static bool presenter;
static void* volatile presentHwnd;
static volatile int presentWidth;
static volatile int presentHeight;
static const char* diagDir;
static int keyDownArg;
static int keyUpArg;
static int pauseToggles;
static int requestQuits;
static int inputUpdates;
static int selfTests;
static int presents;
static int shutdowns;
static int timerInits;

uint32_t audioSeekRows(uint32_t rows) {
    seekRowsArg = rows;
    return rows + 0x33u;
}
uint32_t audioSeekMs(int ms) {
    seekMsArg = ms;
    return 0x5151u;
}
uint32_t audioSeekOrder(int order) {
    seekOrderArg = order;
    return 0x6262u;
}
void progressInit(void* hwnd) { progressHwnd = hwnd; }
bool inputInit(void* hwnd) { inputHwnd = hwnd; return initInputResult; }
bool platformInit() { return initPlatformResult; }
bool quitRequested() { return quitState; }
void timerInit() { ++timerInits; }
void timelineInit(const char* path) { timelinePath = path; }
void recInit(const char* dir) { recDir = dir; }
void audioSetAssemblyMode(bool enabled) { audioMode = enabled; }
int audioInit(const char* path, int sampleRate) {
    audioPath = path;
    audioRate = sampleRate;
    return audioInitResult ? 1 : 0;
}
void setAssemblyPresenter(bool enabled) { presenter = enabled; }
bool initPresent(void* hwnd, int width, int height) {
    presentHwnd = hwnd;
    presentWidth = width;
    presentHeight = height;
    return true;
}
void diagReadbackInit(const char* dir) { diagDir = dir; }
void selfTestPattern() { ++selfTests; }
bool diagReadbackEnabled() { return diagEnabled; }
void presentFrame() { ++presents; }
int audioSelfCheck(int seconds) {
    audioSelfCheckArg = seconds;
    return audioSelfCheckResult;
}
void keyDown(uint8_t scancode) { keyDownArg = scancode; }
void keyUp(uint8_t scancode) { keyUpArg = scancode; }
void pauseToggle() { ++pauseToggles; }
void requestQuit() { ++requestQuits; }
void updateInput() { ++inputUpdates; }

} // namespace vk

static char g_log[8192];
static unsigned g_logUsed;
static const char* g_resolveOverride;
static const char* g_resolveRoot;
static int g_resolveCalls;

extern "C" void vk_log_printf(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    const int remaining = static_cast<int>(sizeof(g_log) - g_logUsed);
    if (remaining > 1) {
        const int n = std::vsnprintf(g_log + g_logUsed,
                                     static_cast<size_t>(remaining), fmt, ap);
        if (n > 0) {
            const unsigned written = static_cast<unsigned>(n);
            g_logUsed += written < static_cast<unsigned>(remaining - 1)
                              ? written
                              : static_cast<unsigned>(remaining - 1);
        }
    }
    va_end(ap);
}

extern "C" void asm_shutdown_all() { ++vk::shutdowns; }
extern "C" void asm_shutdown_and_exit() {
    std::fprintf(stderr, "unexpected asm_shutdown_and_exit call\n");
    std::abort();
}
extern "C" const char* asm_voodka_resolve_music_path(const char* overridePath,
                                                       const char* repoRoot) {
    g_resolveOverride = overridePath;
    g_resolveRoot = repoRoot;
    ++g_resolveCalls;
    return overridePath && overridePath[0] ? overridePath : repoRoot;
}

static int failures;

#define CHECK(condition, message) \
    do { \
        if (!(condition)) { \
            std::fprintf(stderr, "FAIL: %s\n", message); \
            ++failures; \
        } \
    } while (0)

static bool logHas(const char* text) {
    return std::strstr(g_log, text) != nullptr;
}

static void resetLog() {
    g_logUsed = 0;
    g_log[0] = 0;
}

int main() {
    using namespace vk;
    const auto hwnd = reinterpret_cast<void*>(0x12345678ull);



    CHECK(vk_scene_part_from_name("OKO_SZKLO") == 1,
          "scene parser must be case-insensitive and normalize underscores");
    CHECK(vk_scene_part_from_name("gratki-woda") == 7,
          "scene parser must recognize the water selector");
    CHECK(vk_scene_part_from_name("nad_CZERWONYM_lampa") == 8,
          "scene parser must normalize every selector separator");
    CHECK(vk_scene_part_from_name(nullptr) == 0,
          "scene parser must reject null");
    CHECK(vk_scene_part_from_name("not-a-scene") == 0,
          "scene parser must reject unknown selectors");

    resetLog();
    CHECK(vk_app_seek_modpos(0x1200) == 0x1233,
          "modpos seek must return the audio reached position");
    CHECK(seekRowsArg == 0x1200, "modpos seek argument forwarding");
    CHECK(logHas("seek --modpos 4608 -> reached ModPos 4659"),
          "modpos seek diagnostic");

    CHECK(vk_app_seek_ms(-250) == 0x5151, "millisecond seek result forwarding");
    CHECK(seekMsArg == -250, "millisecond seek argument forwarding");
    CHECK(logHas("seek --ms -250 -> reached ModPos 20817"),
          "millisecond seek diagnostic");

    CHECK(vk_app_seek_order(-3) == 0x6262, "order seek result forwarding");
    CHECK(seekOrderArg == -3, "order seek argument forwarding");
    CHECK(logHas("seek --order -3 -> reached ModPos 25186"),
          "order seek diagnostic");

    CHECK(vk_app_seek_part(5, 0x1400) == 0x1433,
          "part seek must return the audio reached position");
    CHECK(vk_get_entry_scene() == 5, "part seek must set entry scene");
    CHECK(logHas("seek --part 5 (torus ustep village) -> ModPos 0x1400 reached 5171"),
          "part seek diagnostic");

    CHECK(vk_app_seek_scene(8, 0x2040) == 0x2073,
          "scene seek must return the audio reached position");
    CHECK(vk_get_entry_scene() == 8, "scene seek must set entry scene");
    CHECK(logHas("seek --scene nad czerwonym lampa -> ModPos 0x2040 reached 8307"),
          "scene seek diagnostic");

    resetLog();
    vk_app_no_entry_seek();
    vk_app_log_selftest();
    vk_app_log_audio_check(12);
    vk_app_log_demo_start(0x1122334455667788ull);
    vk_app_log_music(nullptr);
    vk_app_log_music("music/test.mod");
    vk_app_log_input_failure();
    vk_app_log_arena_failure();
    vk_app_log_audio_failure(0);
    vk_app_log_audio_failure(1);
    vk_app_log_present_failure();
    vk_app_log_automation_failure();
    vk_app_log_automation(-1, 2000);
    CHECK(logHas("no entry seek"), "no-seek logging adapter");
    CHECK(logHas("SELF-TEST"), "self-test logging adapter");
    CHECK(logHas("AUDIO CHECK: running 12 s"), "audio-check logging adapter");
    CHECK(logHas("arena=1122334455667788 starting demo core"),
          "demo-start logging adapter");
    CHECK(logHas("music module: '(none)'"), "null music path logging adapter");
    CHECK(logHas("music module: 'music/test.mod'"), "music path logging adapter");
    CHECK(logHas("assembly audio initialization failed"), "assembly failure logging adapter");
    CHECK(logHas("reference audio initialization failed"), "reference failure logging adapter");
    CHECK(logHas("pause=off close=enabled"), "automation logging adapter");

    initInputResult = true;
    initPlatformResult = true;
    audioInitResult = true;
    audioSelfCheckResult = 37;
    diagEnabled = true;
    vk_app_progress_init(hwnd);
    CHECK(progressHwnd == hwnd, "progress init forwarding");
    CHECK(vk_app_input_init(hwnd) == 1 && inputHwnd == hwnd,
          "input init forwarding");
    CHECK(vk_app_platform_init() == 1, "platform init forwarding");
    quitState = true;
    CHECK(vk_app_quit_requested() == 1, "quit query forwarding");
    vk_app_timer_init();
    CHECK(timerInits == 1, "timer init forwarding");
    vk_app_timeline_init("timeline.raw");
    CHECK(std::strcmp(timelinePath, "timeline.raw") == 0,
          "timeline path forwarding");
    vk_app_rec_init("frames");
    CHECK(std::strcmp(recDir, "frames") == 0, "record path forwarding");
    vk_app_audio_set_mode(1);
    CHECK(audioMode, "audio mode forwarding");
    CHECK(vk_app_audio_init(nullptr, 48000) == 1,
          "audio init result forwarding");
    CHECK(audioPath && audioPath[0] == 0 && audioRate == 48000,
          "null audio path must become an empty string");
    vk_app_set_assembly_presenter(1);
    CHECK(presenter, "presenter mode forwarding");
    const int presentResult = vk_app_present_init(hwnd, 1280, 800);
    CHECK(presentResult == 1, "present initialization result forwarding");
    CHECK(presentHwnd == hwnd && presentWidth == 1280 && presentHeight == 800,
          "present initialization arguments forwarding");
    vk_app_diag_init("diag");
    CHECK(std::strcmp(diagDir, "diag") == 0, "diagnostic path forwarding");
    CHECK(vk_app_diag_readback_enabled() == 1,
          "diagnostic enabled query forwarding");
    vk_app_selftest_pattern();
    vk_app_present_frame();
    CHECK(selfTests == 1 && presents == 1, "render helper forwarding");
    CHECK(vk_app_audio_self_check(9) == 37 && audioSelfCheckArg == 9,
          "audio self-check forwarding");

    vk_app_shutdown_all();
    CHECK(shutdowns == 1, "shutdown-all forwarding");
    shutdownAll();
    CHECK(shutdowns == 2, "decorated vk shutdownAll must be assembly-owned");

    vk_key_down(0x1ff);
    vk_key_up(0x2fe);
    CHECK(keyDownArg == 0xff && keyUpArg == 0xfe,
          "key wrappers must preserve the low scancode byte");
    vk_pause_toggle();
    vk_request_quit();
    vk_platform_update_input();
    CHECK(pauseToggles == 1 && requestQuits == 1 && inputUpdates == 1,
          "WndProc/input wrappers must forward exactly once");
    quitState = false;
    CHECK(vk_platform_quit_requested() == 0, "platform quit query forwarding");

    const char* fallback = vk_app_resolve_music_path(nullptr);
    CHECK(g_resolveCalls == 1 && g_resolveOverride == nullptr &&
              g_resolveRoot == nullptr && fallback == g_resolveRoot,
          "music resolver must use the embedded module without a repository root");
    const char* overridePath = "C:/music/custom.mod";
    CHECK(vk_app_resolve_music_path(overridePath) == overridePath &&
              g_resolveCalls == 2 && g_resolveOverride == overridePath,
          "music resolver must preserve explicit override identity");

    if (failures) {
        std::fprintf(stderr, "%d application ABI checks failed\n", failures);
        return 1;
    }
    std::puts("win32 application ABI probe: PASS");
    return 0;
}
