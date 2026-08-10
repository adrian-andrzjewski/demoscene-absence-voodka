// app.cpp - application lifecycle: window, arena, audio, main loop.
//
// Flow:
//   WinMain -> create window -> init arena + archive -> init present ----
//   -> init audio -> call DemoStart32 (the assembly demo core) on the main
//   thread; the demo loop itself drives waitVbl/presentFrame. When it returns
//   we wind down cleanly.

#include "platform_abi.h"
#include "demo_entry.h"
#include <windows.h>
#include <cstdio>
#include <cstring>
#include <cstdlib>

// Very small crash logger: print exception address + register state then let
// the OS terminate. Gives the exact faulting RIP without a debugger attached.
static LONG WINAPI CrashFilter(EXCEPTION_POINTERS* ep) {
    EXCEPTION_RECORD* er = ep->ExceptionRecord;
    CONTEXT* cx = ep->ContextRecord;
    vk::logPrint("[CRASH] code=0x%08x at %p\n", er->ExceptionCode, er->ExceptionAddress);
    vk::logPrint("[CRASH] rax=%p rbx=%p rcx=%p rdx=%p\n",
                 (void*)cx->Rax, (void*)cx->Rbx, (void*)cx->Rcx, (void*)cx->Rdx);
    vk::logPrint("[CRASH] rsi=%p rdi=%p rbp=%p rsp=%p rip=%p\n",
                 (void*)cx->Rsi, (void*)cx->Rdi, (void*)cx->Rbp, (void*)cx->Rsp, (void*)cx->Rip);
    vk::logFlush();
    return EXCEPTION_CONTINUE_SEARCH;
}
#include <string>
#include <vector>

// bridge symbols (extern "C"): select which part the assembly core runs
extern "C" void vk_set_entry_part(int part);

namespace {
constexpr const wchar_t* kWinClass = L"VOODKA";
// 1280x800 = 320x200 logic upscaled exactly 4x; the presenter point-samples
// (nearest-neighbour, no filtering), so each source texel is a clean 4x4 block.
constexpr int kWinW = 1280;
constexpr int kWinH = 800;
HWND g_hwnd = nullptr;
HINSTANCE g_hInst = nullptr;
volatile LONG g_shutdownStarted = 0;

// Opt-in lifecycle automation used by the runtime gates.  It injects the
// same window messages a user would generate, so pause/resume and close are
// exercised through the real Win32 path instead of a private test shortcut.
struct AutomationState {
    HWND hwnd = nullptr;
    HANDLE stop = nullptr;
    HANDLE thread = nullptr;
    DWORD pauseAtMs = INFINITE;
    DWORD closeAtMs = INFINITE;
};
AutomationState g_automation;

void postSpace(HWND hwnd) {
    constexpr LPARAM kSpaceDown = static_cast<LPARAM>(0x00390000);
    constexpr LPARAM kSpaceUp = static_cast<LPARAM>(0xC0390000);
    PostMessageW(hwnd, WM_KEYDOWN, VK_SPACE, kSpaceDown);
    PostMessageW(hwnd, WM_KEYUP, VK_SPACE, kSpaceUp);
}

DWORD WINAPI automationThreadProc(void* opaque) {
    auto* state = static_cast<AutomationState*>(opaque);
    const ULONGLONG start = GetTickCount64();
    bool paused = false;
    bool resumed = false;
    for (;;) {
        if (WaitForSingleObject(state->stop, 5) == WAIT_OBJECT_0)
            return 0;
        const ULONGLONG elapsed = GetTickCount64() - start;
        if (!paused && state->pauseAtMs != INFINITE &&
            elapsed >= state->pauseAtMs) {
            postSpace(state->hwnd);
            paused = true;
        }
        if (paused && !resumed &&
            elapsed >= static_cast<ULONGLONG>(state->pauseAtMs) + 1000) {
            postSpace(state->hwnd);
            resumed = true;
        }
        if (state->closeAtMs != INFINITE && elapsed >= state->closeAtMs) {
            PostMessageW(state->hwnd, WM_CLOSE, 0, 0);
            return 0;
        }
    }
}

bool startAutomation(HWND hwnd, long pauseAtMs, long closeAtMs) {
    if (pauseAtMs < 0 && closeAtMs < 0) return true;
    g_automation = {};
    g_automation.hwnd = hwnd;
    g_automation.pauseAtMs = pauseAtMs >= 0 ? static_cast<DWORD>(pauseAtMs)
                                            : INFINITE;
    g_automation.closeAtMs = closeAtMs >= 0 ? static_cast<DWORD>(closeAtMs)
                                            : INFINITE;
    g_automation.stop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!g_automation.stop) return false;
    g_automation.thread = CreateThread(nullptr, 0, automationThreadProc,
                                       &g_automation, 0, nullptr);
    if (!g_automation.thread) {
        CloseHandle(g_automation.stop);
        g_automation.stop = nullptr;
        return false;
    }
    vk::logPrint("[app] lifecycle automation: pause=%s close=%s\n",
                 pauseAtMs >= 0 ? "enabled" : "off",
                 closeAtMs >= 0 ? "enabled" : "off");
    return true;
}

void stopAutomation() {
    if (!g_automation.stop) return;
    SetEvent(g_automation.stop);
    if (g_automation.thread) {
        WaitForSingleObject(g_automation.thread, INFINITE);
        CloseHandle(g_automation.thread);
    }
    CloseHandle(g_automation.stop);
    g_automation = {};
}
}

// ---- music module path resolution ------------------------------------------
// Order: --music <path> override, then next to the exe (music\amnezja2.mod,
// amnezja2.mod), then the dev-tree copy under VOODKA_REPO_ROOT. Missing file
// is tolerated: audioInit falls back to a headless (silent) timeline.
static std::string resolveMusicPath(const char* overridePath) {
    if (overridePath && overridePath[0]) return overridePath;
    wchar_t exePath[MAX_PATH] = {};
    GetModuleFileNameW(nullptr, exePath, MAX_PATH);
    std::wstring dir(exePath);
    auto slash = dir.find_last_of(L"\\/");
    if (slash != std::wstring::npos) dir = dir.substr(0, slash + 1);
    auto exists = [](const std::wstring& p) {
        DWORD a = GetFileAttributesW(p.c_str());
        return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
    };
    std::vector<std::wstring> cands = {
        dir + L"music\\amnezja2.mod",
        dir + L"amnezja2.mod",
    };
    // dev-tree fallback (configure-time repo root; ASCII-safe widening)
    std::wstring dev(VOODKA_REPO_ROOT, VOODKA_REPO_ROOT + strlen(VOODKA_REPO_ROOT));
    cands.push_back(dev + L"/music/amnezja2.mod");
    for (auto& c : cands) {
        if (exists(c)) {
            // the module filename is ASCII, so narrowing is lossless here
            return std::string(c.begin(), c.end());
        }
    }
    return std::string();
}

LRESULT CALLBACK WndProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    switch (m) {
    case WM_KEYDOWN: {
        // translate virtual key to PC scancode (keyboard layout independent)
        UINT sc = (UINT)((l >> 16) & 0xFF);
        if (l & 0x01000000) sc |= 0x80;             // extended
        vk::keyDown((uint8_t)(sc & 0x7F));
        if (sc == 0x39 && !(l & 0x40000000))  // Space scancode, ignore auto-repeat
            vk::pauseToggle();
        vk::keyUp((uint8_t)(sc & 0x7F));
        // re-press semantics: report held while down via timer in EOS; for
        // the port we mirror held state each WM_KEYDOWN.
        return 0;
    }
    case WM_KEYUP: {
        UINT sc = (UINT)((l >> 16) & 0xFF);
        vk::keyUp((uint8_t)(sc & 0x7F));
        return 0;
    }
    case WM_PAINT: {
        PAINTSTRUCT ps; BeginPaint(h, &ps); EndPaint(h, &ps);
        return 0;
    }
    case WM_ACTIVATE:
        // Stay topmost for the whole lifetime: the window must always float
        // over other apps during development/testing/debugging.
        if (w != WA_INACTIVE)
            SetWindowPos(h, HWND_TOPMOST, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        break;
    case WM_CLOSE:
        // Explicitly close on the titlebar X (DefWindowProc's default path
        // also destroys, but spelling it out keeps the intent clear): the
        // window goes away immediately and WM_DESTROY -> PostQuitMessage
        // posts the WM_QUIT that the demo loop turns into a full shutdown.
        vk::requestQuit();
        DestroyWindow(h);
        return 0;
    case WM_DESTROY:
        // PostQuitMessage(0) posts WM_QUIT to the thread's queue. updateInput()
        // (per frame) picks it up and flags the pending quit; waitVbl /
        // presentFrame then run the teardown and terminate the process.
        vk::requestQuit();
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(h, m, w, l);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE, LPSTR lpCmd, int) {
    g_hInst = hInst;
    vk::logInit();
    vk::logPrint("[app] VOODKA x64 port starting\n");

    // Per-monitor DPI awareness: window geometry is expressed in physical
    // pixels, so centering stays consistent across DPI-scaled desktops.
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    // optional: --record <dir>  (deterministic frame+palette capture)
    //       and  --diag <dir>   (GPU readback diagnostics)
    const char* recDir = nullptr;
    const char* diagDir = nullptr;
    const char* musicOverride = nullptr;
    const char* timelinePath = nullptr;
    bool asmPresenter = false;
    bool asmAudio = false;
    long autoPauseMs = -1;
    long autoCloseMs = -1;
    auto argDirOf = [](const std::string& cmd, const char* flag) -> const char* {
        std::string f = "--" + std::string(flag);
        auto p = cmd.find(f);
        if (p == std::string::npos) return nullptr;
        std::string rest = cmd.substr(p + f.size());
        size_t st = rest.find_first_not_of(" \t\"");
        if (st == std::string::npos) return nullptr;
        size_t sp = rest.find_first_of(" \t", st + 1);
        std::string dir = rest.substr(st, sp == std::string::npos ? std::string::npos : sp - st);
        while (!dir.empty() && dir.back() == '"') dir.pop_back();
        return dir.empty() ? nullptr : _strdup(dir.c_str());
    };
    {
        std::string cmd = lpCmd ? lpCmd : "";
        recDir = argDirOf(cmd, "record");
        diagDir = argDirOf(cmd, "diag");
        musicOverride = argDirOf(cmd, "music");
        timelinePath = argDirOf(cmd, "timeline");
        asmPresenter = cmd.find("--asm-present") != std::string::npos;
        asmAudio = cmd.find("--asm-audio") != std::string::npos;
        auto parseMs = [&](const char* flag) -> long {
            auto p = cmd.find(flag);
            if (p == std::string::npos) return -1;
            std::string rest = cmd.substr(p + std::strlen(flag));
            size_t st = rest.find_first_not_of(" \t\"=");
            if (st == std::string::npos) return -1;
            char* end = nullptr;
            unsigned long value = strtoul(rest.c_str() + st, &end, 0);
            if (end == rest.c_str() + st || value > 0x7fffffffUL)
                return -1;
            return static_cast<long>(value);
        };
        autoPauseMs = parseMs("--auto-pause-ms");
        autoCloseMs = parseMs("--auto-close-ms");
        if (recDir) vk::logPrint("[app] recording to '%s'\n", recDir);
        else vk::logPrint("[app] no --record\n");
        if (diagDir) vk::logPrint("[app] readback diag to '%s'\n", diagDir);
        if (timelinePath) vk::logPrint("[app] A/V timeline to '%s'\n", timelinePath);
        if (asmPresenter) vk::logPrint("[app] --asm-present selected\n");
        if (asmAudio) vk::logPrint("[app] --asm-audio selected\n");
        if (autoPauseMs >= 0)
            vk::logPrint("[app] auto-pause after %ld ms (resume after 1 s)\n",
                         autoPauseMs);
        if (autoCloseMs >= 0)
            vk::logPrint("[app] auto-close after %ld ms\n", autoCloseMs);
    }

    // ---- register window ------------------------------------------------
    WNDCLASSW wc{};
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInst;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.lpszClassName = kWinClass;
    wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
    if (!RegisterClassW(&wc)) {
        vk::logPrint("[app] RegisterClassW failed\n");
        vk::shutdownAll();
        return 1;
    }
    RECT rc{0, 0, kWinW, kWinH};
    AdjustWindowRectEx(&rc, WS_OVERLAPPEDWINDOW, FALSE, WS_EX_TOPMOST);
    int winW = rc.right - rc.left;
    int winH = rc.bottom - rc.top;

    // Center the window on the primary (active/default) display's work area.
    // Derived from the primary monitor every launch, so placement is identical
    // regardless of monitor configuration/resolution (and never CW_USEDEFAULT's
    // cascade). rcWork keeps the taskbar visible; fall back to the whole
    // primary screen if GetMonitorInfo fails.
    {
        RECT wa{};
        POINT origin{0, 0};
        HMONITOR mon = MonitorFromPoint(origin, MONITOR_DEFAULTTOPRIMARY);
        MONITORINFO mi{};
        mi.cbSize = sizeof(mi);
        if (mon && GetMonitorInfoW(mon, &mi)) {
            wa = mi.rcWork;
        } else {
            wa.left = 0;
            wa.top = 0;
            wa.right = GetSystemMetrics(SM_CXSCREEN);
            wa.bottom = GetSystemMetrics(SM_CYSCREEN);
        }
        int x = wa.left + (wa.right - wa.left - winW) / 2;
        int y = wa.top + (wa.bottom - wa.top - winH) / 2;
        if (x < wa.left) x = wa.left;
        if (y < wa.top) y = wa.top;
        vk::logPrint("[app] primary work area %dx%d at %d,%d; window %dx%d at %d,%d\n",
                     wa.right - wa.left, wa.bottom - wa.top, wa.left, wa.top,
                     winW, winH, x, y);
        rc.left = x;
        rc.top = y;
        rc.right = x + winW;
        rc.bottom = y + winH;
    }

    // WS_EX_TOPMOST makes the window topmost from the very first frame; the
    // WM_ACTIVATE handler in WndProc then keeps it there for the whole process.
    HWND hwnd = CreateWindowExW(WS_EX_TOPMOST, kWinClass,
                                L"VOODKA (Absence 1996x - Windows x64 port)",
                                WS_OVERLAPPEDWINDOW,
                                rc.left, rc.top, winW, winH,
                                nullptr, nullptr, hInst, nullptr);
    if (!hwnd) {
        vk::logPrint("[app] CreateWindowW failed\n");
        vk::shutdownAll();
        return 1;
    }
    g_hwnd = hwnd;
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);
    // Cement the z-order and hand the window input focus so it comes up on top
    // and active even if another app was foreground at launch time.
    SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    SetForegroundWindow(hwnd);
    SetActiveWindow(hwnd);
    SetFocus(hwnd);
    vk::progressInit(hwnd);

    // Start before any archive/module/scene loading. The assembly core can
    // spend time in those paths without dispatching the window queue, so ESC
    // must not depend on a particular effect reaching its next frame.
    if (!vk::inputInit(hwnd)) {
        vk::logPrint("[app] input watcher init failed\n");
        vk::shutdownAll();
        return 1;
    }

    // ---- init subsystems ---------------------------------------------------
    if (!vk::platformInit()) {
        vk::logPrint("[app] arena init failed\n");
        vk::shutdownAll();
        return 1;
    }
    if (vk::quitRequested()) vk::shutdownAndExit();
    vk::timerInit();
    vk::timelineInit(timelinePath);
    vk::recInit(recDir);
    std::string musicPath = resolveMusicPath(musicOverride);
    vk::logPrint("[app] music module: '%s'\n", musicPath.empty() ? "(none)" : musicPath.c_str());
    vk::audioSetAssemblyMode(asmAudio);
    const int audioOk = vk::audioInit(musicPath.c_str(), 44100);
    if (asmAudio && !audioOk) {
        vk::logPrint("[app] assembly audio initialization failed\n");
        vk::shutdownAll();
        return 1;
    }
    if (vk::quitRequested()) vk::shutdownAndExit();
    vk::setAssemblyPresenter(asmPresenter);
    if (!vk::initPresent(hwnd, kWinW, kWinH)) {
        vk::logPrint("[app] D3D11 init failed\n");
        vk::shutdownAll();
        return 1;
    }
    vk::diagReadbackInit(diagDir);
    if (vk::quitRequested()) vk::shutdownAndExit();
    if (!startAutomation(hwnd, autoPauseMs, autoCloseMs)) {
        vk::logPrint("[app] lifecycle automation initialization failed\n");
        vk::shutdownAll();
        return 1;
    }

    // ---- entry-point seeking -----------------------------------------------
    // The demo may begin from a scene in the middle of the timeline; the music
    // must start at the matching song position. Units:
    //   --modpos N  absolute ModPos ((order<<8)|row; the demo's timeline)
    //   --ms N      milliseconds from the start of the module
    //   --order N   order-list index (pattern start, row 0)
    //   --part N    scene/part index (maps to a ModPos, see table below)
    // At most one seek selector is honored; the first present wins.
    {
        std::string cmd = lpCmd ? lpCmd : "";
        auto numAfter = [&](const char* flag) -> long {
            auto p = cmd.find(flag);
            if (p == std::string::npos) return -1;
            std::string rest = cmd.substr(p + std::strlen(flag));
            size_t st = rest.find_first_not_of(" \t\"=");
            if (st == std::string::npos) return -1;
            return (long)strtoul(rest.c_str() + st, nullptr, 0);
        };
        // Scene start ModPos (calibration): part N begins where part N-1 ends.
        // Values follow the parts' own exit thresholds in the assembly.
        static const uint32_t kPartStartModPos[9] = {
            0x0000,  // part 1
            0x0400,  // part 2
            0x0B40,  // part 3
            0x0D40,  // part 4 (restored 2026-08-06)
            0x1400,  // part 5
            0x1B40,  // part 6
            0x1C40,  // part 7
            0x2040,  // part 8
            0x2640,  // end
        };
        long v;
        if ((v = numAfter("--modpos")) >= 0) {
            uint32_t reached = vk::audioSeekRows((uint32_t)v);
            vk::logPrint("[app] seek --modpos %ld -> reached ModPos %u\n", v, reached);
        } else if ((v = numAfter("--ms")) >= 0) {
            uint32_t reached = vk::audioSeekMs((int)v);
            vk::logPrint("[app] seek --ms %ld -> reached ModPos %u\n", v, reached);
        } else if ((v = numAfter("--order")) >= 0) {
            uint32_t reached = vk::audioSeekOrder((int)v);
            vk::logPrint("[app] seek --order %ld -> reached ModPos %u\n", v, reached);
        } else if ((v = numAfter("--part")) >= 1 && v <= 8) {
            uint32_t reached = vk::audioSeekRows(kPartStartModPos[v - 1]);
            vk::logPrint("[app] seek --part %ld -> ModPos 0x%x reached %u\n", v,
                         kPartStartModPos[v - 1], reached);
            vk_set_entry_part((int)v);
        } else {
            vk::logPrint("[app] no entry seek (module starts at beginning)\n");
        }
    }

    // ---- self-test or run the demo core (assembly) --------------------------
    uint8_t* ab = vk::arena();
    int rcode = 0;
    std::string cmdline = lpCmd ? lpCmd : "";
    bool selftest = cmdline.find("--selftest") != std::string::npos;
    if (selftest) {
        // present the built-in pattern a few times so the readback can be
        // compared 1:1; bypasses the demo entirely
        vk::logPrint("[app] SELF-TEST: rendering known pattern\n");
        vk::selfTestPattern();
        for (int i = 0; i < 60 && vk::diagReadbackEnabled(); i++) {
            vk::presentFrame();
            Sleep(16);
        }
        rcode = 0;
    } else if (cmdline.find("--audiocheck") != std::string::npos) {
        // run the audio subsystem self-check; no demo rendering.
        int secs = 20;
        std::string flag = "--audiocheck";
        auto p = cmdline.find(flag);
        std::string rest = cmdline.substr(p + flag.size());
        size_t st = rest.find_first_not_of(" \t\"=");
        if (st != std::string::npos) {
            std::string tok = rest.substr(st);
            size_t sp = tok.find_first_of(" \t");
            tok = tok.substr(0, sp == std::string::npos ? std::string::npos : sp);
            long v = strtol(tok.c_str(), nullptr, 0);
            if (v > 0) secs = (int)v;
        }
        vk::logPrint("[app] AUDIO CHECK: running %d s\n", secs);
        rcode = vk::audioSelfCheck(secs);
    } else {
        vk::logPrint("[app] arena=%p starting demo core\n", (void*)ab);
        SetUnhandledExceptionFilter(&CrashFilter);
        rcode = DemoStart32(ab, 64ull * 1024 * 1024);
    }

    vk::shutdownAll();
    return rcode;
}

namespace vk {

// Full deterministic wind-down; the single teardown sequence shared by the
// normal end-of-demo path and the ESC/window-close exit path. It is idempotent
// because startup failures and the normal tail can both reach it.
void shutdownAll() {
    if (InterlockedExchange(&g_shutdownStarted, 1) != 0)
        return;

    vk::logPrint("[app] shutting down all subsystems\n");
    ::stopAutomation();
    vk::inputShutdown();
    vk::audioShutdown();
    vk::recClose();
    vk::diagReadbackShutdown();
    vk::timelineClose();
    vk::shutdownPresent();
    vk::resetSelectors();
    vk::platformShutdown();

    if (g_hwnd) {
        HWND h = g_hwnd;
        g_hwnd = nullptr;
        if (IsWindow(h)) DestroyWindow(h);
    }
    if (g_hInst) {
        UnregisterClassW(kWinClass, g_hInst);
        g_hInst = nullptr;
    }
    vk::logFlush();
    vk::logShutdown();
}

// Window closed mid-demo: called from the per-frame choke points (waitVbl /
// presentFrame) while the demo core is still on the stack. Runs the same
// teardown as the end-of-demo path, then terminates the process so no demo
// loop, audio thread or other background activity outlives the closed window.
void shutdownAndExit() {
    vk::logPrint("[app] quit requested (ESC/window close) - shutting down\n");
    vk::shutdownAll();
    ExitProcess(0);
}

}  // namespace vk
