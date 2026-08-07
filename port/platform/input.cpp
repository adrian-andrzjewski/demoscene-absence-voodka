// input.cpp - maps Win32 keyboard messages to the EOS Key_Map model.
//
// The demo reads Key_Map[scancode] (0xFF internal table, set to On/Off).
// We keep a 128-entry byte array of PC scancode -> pressed state mirroring
// the original EOS keyboard hook, and a small FIFO for the Escape/exit path.

#include "platform_abi.h"
#include <windows.h>
#include <cstring>

namespace vk {

namespace {
// PC/AT scancode set 1 pressed->released-translated map, indexed by raw code.
uint8_t g_keyPressed[128] = {};   // 1 = currently held
bool    g_escapeQueued = false;
// Set when the window-close path (WM_QUIT) is observed. Read by the per-frame
// choke points (waitVbl / presentFrame) which run the teardown + exit.
bool    g_quitRequested = false;
}

void requestQuit()      { g_quitRequested = true; }
bool quitRequested()    { return g_quitRequested; }

void keyDown(uint8_t sc) { if (sc < 128) { g_keyPressed[sc] = 1; if (sc == 1) g_escapeQueued = true; } }
void keyUp(uint8_t sc)   { if (sc < 128) g_keyPressed[sc] = 0; }
void keyReset()          { std::memset(g_keyPressed, 0, sizeof g_keyPressed); }
uint8_t* rawKeyMap()     { return g_keyPressed; }
void clearEscapeQueue()  { g_escapeQueued = false; }
bool escapeQueued()      { return g_escapeQueued; }

int isKeyDown(int scancode) {
    if (scancode < 0 || scancode >= 128) return 0;
    return g_keyPressed[scancode] != 0;
}

void updateInput() {
    // process any queued Windows messages (drives keyDown/keyUp)
    MSG msg;
    while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
        if (msg.message == WM_QUIT) {
            // The X button (WM_CLOSE -> WM_DESTROY -> PostQuitMessage) lands
            // here as a queue-only WM_QUIT (no window). Record it; the demo
            // core runs on this thread, so the per-frame choke points turn it
            // into a full teardown + process exit. Do not dispatch: WM_QUIT
            // has no window, and once queued it must not pile up.
            g_quitRequested = true;
            continue;
        }
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
}

}  // namespace vk
