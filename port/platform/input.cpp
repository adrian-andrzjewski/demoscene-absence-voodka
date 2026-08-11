// input.cpp - maps Win32 keyboard messages to the EOS Key_Map model.
//
// The demo reads Key_Map[scancode] (0xFF internal table, set to On/Off).
// We keep a 128-entry byte array of PC scancode -> pressed state mirroring
// the original EOS keyboard hook. Escape is a platform-global cancellation
// request, independent of the active scene or the assembly's Key_Map users.

#include "platform_abi.h"
#include <windows.h>
#include <cstring>

#if !defined(VOODKA_REFERENCE_BUILD)
extern "C" int asm_input_init(void* hwnd);
extern "C" void asm_input_shutdown(void);
extern "C" uint8_t* asm_input_key_map(void);
extern "C" void asm_input_key_down(uint32_t scancode);
extern "C" void asm_input_key_up(uint32_t scancode);
extern "C" void asm_input_key_reset(void);
extern "C" int asm_input_key_is_down(int scancode);
extern "C" void asm_input_clear_escape(void);
extern "C" int asm_input_escape_queued(void);
extern "C" void asm_input_update(void);
#endif

namespace vk {

void requestQuit();

namespace {
// PC/AT scancode set 1 pressed->released-translated map, indexed by raw code.
uint8_t g_keyPressed[128] = {};   // 1 = currently held
bool    g_escapeQueued = false;
// Set by ESC, WM_CLOSE/WM_QUIT, or the asynchronous key watcher. The demo
// core runs on the main thread, so teardown is performed at its next safe
// platform boundary rather than from a foreign worker thread.
volatile LONG g_quitRequested = 0;

HWND   g_inputWindow = nullptr;
HANDLE g_inputStop = nullptr;
HANDLE g_inputThread = nullptr;

DWORD WINAPI inputWatchThread(LPVOID) {
    bool wasDown = false;
    for (;;) {
        if (WaitForSingleObject(g_inputStop, 8) == WAIT_OBJECT_0)
            break;

        // The main thread normally pumps the window queue once per frame, but
        // the assembly core can spend a long time in startup/asset work
        // without dispatching messages. GetAsyncKeyState keeps ESC global to
        // the port during those intervals as well.
        bool down = (GetAsyncKeyState(VK_ESCAPE) & 0x8000) != 0;
        if (down && !wasDown) {
            requestQuit();
            if (g_inputWindow)
                PostMessageW(g_inputWindow, WM_CLOSE, 0, 0);
        }
        wasDown = down;
    }
    return 0;
}
}

bool inputInit(void* hwnd) {
#if !defined(VOODKA_REFERENCE_BUILD)
    return asm_input_init(hwnd) != 0;
#else
    if (g_inputThread) return true;
    g_inputWindow = (HWND)hwnd;
    g_inputStop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!g_inputStop) {
        g_inputWindow = nullptr;
        return false;
    }
    g_inputThread = CreateThread(nullptr, 0, inputWatchThread, nullptr, 0, nullptr);
    if (!g_inputThread) {
        CloseHandle(g_inputStop);
        g_inputStop = nullptr;
        g_inputWindow = nullptr;
        return false;
    }
    return true;
#endif
}

void inputShutdown() {
#if !defined(VOODKA_REFERENCE_BUILD)
    asm_input_shutdown();
#else
    if (g_inputStop) SetEvent(g_inputStop);
    if (g_inputThread) WaitForSingleObject(g_inputThread, INFINITE);
    if (g_inputThread) CloseHandle(g_inputThread);
    if (g_inputStop) CloseHandle(g_inputStop);
    g_inputThread = nullptr;
    g_inputStop = nullptr;
    g_inputWindow = nullptr;
#endif
}

void requestQuit()      { _InterlockedExchange(&g_quitRequested, 1); }
bool quitRequested()    { return _InterlockedCompareExchange(&g_quitRequested, 0, 0) != 0; }

void keyDown(uint8_t sc) {
#if !defined(VOODKA_REFERENCE_BUILD)
    asm_input_key_down(sc);
#else
    if (sc < 128) {
        g_keyPressed[sc] = 1;
        if (sc == 1) {
            g_escapeQueued = true;
            requestQuit();
        }
    }
#endif
}
void keyUp(uint8_t sc) {
#if !defined(VOODKA_REFERENCE_BUILD)
    asm_input_key_up(sc);
#else
    if (sc < 128) g_keyPressed[sc] = 0;
#endif
}
void keyReset() {
#if !defined(VOODKA_REFERENCE_BUILD)
    asm_input_key_reset();
#else
    std::memset(g_keyPressed, 0, sizeof g_keyPressed);
#endif
}
uint8_t* rawKeyMap() {
#if !defined(VOODKA_REFERENCE_BUILD)
    return asm_input_key_map();
#else
    return g_keyPressed;
#endif
}
void clearEscapeQueue() {
#if !defined(VOODKA_REFERENCE_BUILD)
    asm_input_clear_escape();
#else
    g_escapeQueued = false;
#endif
}
bool escapeQueued() {
#if !defined(VOODKA_REFERENCE_BUILD)
    return asm_input_escape_queued() != 0;
#else
    return g_escapeQueued;
#endif
}

int isKeyDown(int scancode) {
#if !defined(VOODKA_REFERENCE_BUILD)
    return asm_input_key_is_down(scancode);
#else
    if (scancode < 0 || scancode >= 128) return 0;
    return g_keyPressed[scancode] != 0;
#endif
}

void updateInput() {
#if !defined(VOODKA_REFERENCE_BUILD)
    asm_input_update();
#else
    // process any queued Windows messages (drives keyDown/keyUp)
    MSG msg;
    while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
        if (msg.message == WM_QUIT) {
            // The X button (WM_CLOSE -> WM_DESTROY -> PostQuitMessage) lands
            // here as a queue-only WM_QUIT (no window). Record it; the demo
            // core runs on this thread, so the per-frame choke points turn it
            // into a full teardown + process exit. Do not dispatch: WM_QUIT
            // has no window, and once queued it must not pile up.
            requestQuit();
            continue;
        }
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
#endif
}

}  // namespace vk
