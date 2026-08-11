// timer_asm_probe.cpp - timing/pause ABI witness for the production timer.

#include <cstdint>
#include <cstdio>

namespace vk {

void timerInit();
uint64_t getQpcUs();
uint64_t getFrameCounter();
void waitVbl();

namespace {
bool g_paused = false;
bool g_quit = false;
uint32_t g_inputUpdates = 0;
uint32_t g_progressUpdates = 0;
}

void updateInput() {
    ++g_inputUpdates;
    if (g_paused && g_inputUpdates >= 3) g_paused = false;
}

bool isPaused() {
    return g_paused;
}

bool quitRequested() {
    return g_quit;
}

void shutdownAndExit() {
    g_quit = true;
}

void progressUpdate() {
    ++g_progressUpdates;
}

} // namespace vk

static bool check(bool condition, const char* message) {
    if (!condition) std::fprintf(stderr, "timer asm: %s\n", message);
    return condition;
}

int main() {
    bool ok = true;
    vk::timerInit();
    const uint64_t before = vk::getQpcUs();
    vk::waitVbl();
    const uint64_t after = vk::getQpcUs();
    const uint64_t firstFrame = vk::getFrameCounter();
    vk::waitVbl();
    const uint64_t secondFrame = vk::getFrameCounter();
    ok &= check(after >= before && firstFrame == 1 && secondFrame == 2,
                "QPC monotonicity and 70 Hz frame publication");
    ok &= check(vk::g_progressUpdates == 2 && vk::g_inputUpdates >= 2,
                "per-frame input and progress hooks");

    vk::g_paused = true;
    vk::g_inputUpdates = 0;
    const uint64_t pausedStart = vk::getFrameCounter();
    vk::waitVbl();
    ok &= check(vk::getFrameCounter() == pausedStart + 1 &&
                    vk::g_inputUpdates >= 3,
                "pause parking and resume boundary");

    return ok ? 0 : 1;
}
