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

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE, LPSTR, int) {
    vk::logInit();
    vk::logPrint("[app] VOODKA x64 port starting\n");

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
    vk::audioInit("D:/Project/voodka2/music/amnezja2.mod", 44100);
    if (!vk::initPresent(hwnd, kWinW, kWinH)) {
        vk::logPrint("[app] D3D11 init failed\n");
        return 1;
    }

    // ---- run the demo core (assembly) --------------------------------------
    // demo core is provided by the NASM objects (Phases 3-4). Fallback here is
    // a software test pattern so the platform builds/runs standalone.
    int rcode = DemoStart32(nullptr, 0);

    vk::audioShutdown();
    vk::logFlush();
    return rcode;
}
