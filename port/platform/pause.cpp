// pause.cpp - C++ reference pause/resume oracle for the whole demo (Space).
//
// Pausing stops every animated/overtime element at once by freezing the two
// clocks the demo runs on:
//   * the VGA-retrace emulation (waitVbl parks the demo thread and stops
//     advancing g_frameCounter -> ramki-driven animation freezes), and
//   * the music player (the render thread feeds silence instead of
//     xmp_play_buffer, so libxmp's position/row never moves).
// Because both are frozen at the exact same instant and resumed from those
// same values, audio and visuals stay synchronized across any number of
// pause/resume cycles with no drift.
//
// Toggling is driven from WndProc on a fresh Space key *down* (edge, ignoring
// auto-repeat), so each physical press toggles exactly once.

#include "platform_abi.h"
#include <windows.h>

namespace vk {

namespace {
volatile long g_paused = 0;            // 1 = paused (read by audio + timer)
volatile long g_toggleCount = 0;       // total pause/resume toggles (diagnostic)
}

bool isPaused() { return g_paused != 0; }

void pauseToggle() {
    long n = _InterlockedIncrement(&g_toggleCount);
    if (!g_paused) {
        _InterlockedExchange(&g_paused, 1);
        logPrint("[pause] PAUSED  ModPos=0x%x elapsed=%.2fs toggle=%ld\n",
                 getModPos(), audioElapsedSec(), n);
    } else {
        _InterlockedExchange(&g_paused, 0);
        logPrint("[pause] RESUMED ModPos=0x%x elapsed=%.2fs toggle=%ld\n",
                 getModPos(), audioElapsedSec(), n);
    }
    // The assembly worker does not observe the C++ pause flag asynchronously;
    // send the state transition immediately, before waitVbl parks the demo.
    audioPump();
}

} // namespace vk
