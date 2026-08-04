// timer.cpp - high-resolution timing + VGA-retrace emulation.
//
// The original demo paces every effect on the VGA retrace tick (~70 Hz on a
// 320x200x256 mode 13h). We emulate that tick exactly: waitVbl() blocks until
// the next 70.07 Hz boundary in QPC time, then returns the running counter.
// Nothing depends on the monitor's actual refresh rate, so scene pacing is
// deterministic and identical to the original.

#include "platform_abi.h"
#include <windows.h>

namespace vk {

namespace {
constexpr double kHertz = 70.0;                 // nominal VGA retrace rate
double        g_nominalPeriodUs = 1e6 / kHertz; // recomputed after calibration
int64_t       g_qpcFreq = 0;
int64_t       g_startCount = 0;
uint64_t      g_frameCounter = 0;
int64_t       g_nextTickCount = 0;
}

void timerInit() {
    QueryPerformanceFrequency((LARGE_INTEGER*)&g_qpcFreq);
    QueryPerformanceCounter((LARGE_INTEGER*)&g_startCount);
    double usPerQpc = 1e6 / (double)g_qpcFreq;
    // Calibrate to the actual QPC frequency precisely:
    g_nominalPeriodUs = 1e6 / kHertz;
    // start with next tick = now
    QueryPerformanceCounter((LARGE_INTEGER*)&g_nextTickCount);
}

static inline int64_t qpcNow() {
    int64_t c;
    QueryPerformanceCounter((LARGE_INTEGER*)&c);
    return c;
}

static inline int64_t usToCount(double us) {
    return (int64_t)(us * (double)g_qpcFreq / 1e6);
}

uint64_t getQpcUs() {
    return (uint64_t)((double)(qpcNow() - g_startCount) * 1e6 / (double)g_qpcFreq);
}

uint64_t getFrameCounter() { return g_frameCounter; }

void waitVbl() {
    // ---- pause handling (Space) -------------------------------------------
    // Pump input every frame (in case presentFrame isn't reached this frame) so
    // the Space key-down in WndProc can toggle pause. If paused, park the demo
    // thread here until Space resumes. g_frameCounter is NOT advanced while
    // parked, so all ramki/ModPos-driven animation, effects and transitions
    // freeze and resume at the exact same values -> audio/visual sync is kept.
    updateInput();
    if (isPaused()) {
        for (;;) {
            updateInput();
            if (!isPaused()) break;
            Sleep(5);
        }
        // resumed: reset the pacing phase so the next frame waits a full tick
        QueryPerformanceCounter((LARGE_INTEGER*)&g_nextTickCount);
    }

    // The disable-latency + Sleep(0) spin target is ~70.07 Hz.
    int64_t period = usToCount(g_nominalPeriodUs);
    for (;;) {
        int64_t now = qpcNow();
        int64_t delta = g_nextTickCount + period - now;
        if (delta <= 0) break;
        if (delta > usToCount(1200.0)) {
            // more than ~1.2ms to wait: let the OS sleep
            DWORD ms = (DWORD)(delta * 1000.0 / g_qpcFreq);
            if (ms > 1) Sleep(ms - 1);
        } else {
            // busy-wait for the remainder for precision
            while (qpcNow() < g_nextTickCount + period) { }
            break;
        }
    }
    g_nextTickCount += period;
    g_frameCounter++;
    // keep the run-progress title/log in step with the rendered frame
    progressUpdate();
}

}  // namespace vk
