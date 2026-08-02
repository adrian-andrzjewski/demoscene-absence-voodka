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
#include <string>

// bridge symbols (extern "C"): select which part the assembly core runs
extern "C" void vk_set_entry_part(int part);

namespace {
constexpr const wchar_t* kWinClass = L"VOODKA";
constexpr int kWinW = 960;
constexpr int kWinH = 600;
}

LRESULT CALLBACK WndProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    switch (m) {
    case WM_KEYDOWN: {
        // translate virtual key to PC scancode (keyboard layout independent)
        UINT sc = (UINT)((l >> 16) & 0xFF);
        if (l & 0x01000000) sc |= 0x80;             // extended
        vk::keyDown((uint8_t)(sc & 0x7F));
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
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(h, m, w, l);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE, LPSTR lpCmd, int) {
    vk::logInit();
    vk::logPrint("[app] VOODKA x64 port starting\n");

    // optional: --record <dir>  (deterministic frame+palette capture)
    //       and  --diag <dir>   (GPU readback diagnostics)
    const char* recDir = nullptr;
    const char* diagDir = nullptr;
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
        if (recDir) vk::logPrint("[app] recording to '%s'\n", recDir);
        else vk::logPrint("[app] no --record\n");
        if (diagDir) vk::logPrint("[app] readback diag to '%s'\n", diagDir);
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
        return 1;
    }
    RECT rc{0, 0, kWinW, kWinH};
    AdjustWindowRectEx(&rc, WS_OVERLAPPEDWINDOW, FALSE, 0);
    HWND hwnd = CreateWindowW(kWinClass, L"VOODKA (Absence 1996x - Windows x64 port)",
                              WS_OVERLAPPEDWINDOW,
                              CW_USEDEFAULT, CW_USEDEFAULT,
                              rc.right - rc.left, rc.bottom - rc.top,
                              nullptr, nullptr, hInst, nullptr);
    if (!hwnd) {
        vk::logPrint("[app] CreateWindowW failed\n");
        return 1;
    }
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);

    // ---- init subsystems ---------------------------------------------------
    if (!vk::platformInit()) {
        vk::logPrint("[app] arena init failed\n");
        return 1;
    }
    vk::timerInit();
    vk::recInit(recDir);
    vk::audioInit("D:/Project/voodka2/music/amnezja2.mod", 44100);
    if (!vk::initPresent(hwnd, kWinW, kWinH)) {
        vk::logPrint("[app] D3D11 init failed\n");
        return 1;
    }
    vk::diagReadbackInit(diagDir);

    // ---- entry-point seeking -----------------------------------------------
    // The demo may begin from a scene in the middle of the timeline; the music
    // must start at the matching song position. Units:
    //   --modpos N  absolute ModPos (cumulative rows; the demo's timeline)
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
            0x0D40,  // part 4
            0x1200,  // part 5
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
    bool selftest = std::string(lpCmd ? lpCmd : "").find("--selftest") != std::string::npos;
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
    } else {
        vk::logPrint("[app] arena=%p starting demo core\n", (void*)ab);
        rcode = DemoStart32(ab, 64ull * 1024 * 1024);
    }

    vk::recClose();
    vk::diagReadbackShutdown();
    vk::audioShutdown();
    vk::logFlush();
    return rcode;
}
