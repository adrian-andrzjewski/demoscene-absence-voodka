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
}

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
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
}

}  // namespace vk
