// bridge_timing_audio_probe.cpp - C ABI witness for the production timing/audio adapters.

#include <cstdint>
#include <cstdio>

extern "C" {
uint64_t vk_wait_vbl();
uint32_t vk_get_modpos();
uint64_t vk_audio_elapsed_us();
int vk_audio_play();
int vk_audio_stop();
void vk_audio_clear();
void vk_audio_set_pattern(int pos);
uint32_t vk_audio_seek_rows(uint32_t modpos);
uint32_t vk_audio_seek_ms(int milliseconds);
uint32_t vk_audio_seek_order(int order);
}

namespace {
uint32_t g_frameCounter = 0;
uint32_t g_modPos = 0;
double g_elapsedSeconds = 0.0;
uint32_t g_waitCalls = 0;
uint32_t g_pumpCalls = 0;
uint32_t g_lastRows = 0;
int g_lastMs = 0;
int g_lastOrder = 0;
}

namespace vk {

void waitVbl() {
    ++g_waitCalls;
}

uint64_t getFrameCounter() {
    return g_frameCounter;
}

void audioPump() {
    ++g_pumpCalls;
}

uint32_t getModPos() {
    return g_modPos;
}

double audioElapsedSec() {
    return g_elapsedSeconds;
}

int audioPlay() {
    return -7;
}

int audioStop() {
    return 13;
}

uint32_t audioSeekRows(uint32_t modpos) {
    g_lastRows = modpos;
    return modpos + 0x100;
}

uint32_t audioSeekMs(int milliseconds) {
    g_lastMs = milliseconds;
    return static_cast<uint32_t>(milliseconds + 7);
}

uint32_t audioSeekOrder(int order) {
    g_lastOrder = order;
    return static_cast<uint32_t>(order + 2);
}

} // namespace vk

static bool check(bool condition, const char* message) {
    if (!condition) std::fprintf(stderr, "bridge timing/audio: %s\n", message);
    return condition;
}

int main() {
    bool ok = true;

    g_frameCounter = 7;
    ok &= check(vk_wait_vbl() == 7, "first wait-vbl returns current counter");
    g_frameCounter = 9;
    ok &= check(vk_wait_vbl() == 2, "wait-vbl returns frame delta");
    ok &= check(g_waitCalls == 2, "wait-vbl forwards exactly once per call");
    ok &= check(vk_wait_vbl() == 0, "unchanged counter produces zero delta");

    g_modPos = 0x1234;
    ok &= check(vk_get_modpos() == 0x1234 && g_pumpCalls == 1,
                "ModPos query pumps audio before reading position");

    g_elapsedSeconds = 1.25;
    ok &= check(vk_audio_elapsed_us() == 1250000,
                "audio elapsed seconds convert to microseconds");
    ok &= check(vk_audio_play() == -7 && vk_audio_stop() == 13,
                "audio play/stop forwarding");

    vk_audio_clear();
    vk_audio_set_pattern(37);
    ok &= check(vk_audio_seek_rows(0x2345) == 0x2445 && g_lastRows == 0x2345,
                "row seek forwarding");
    ok &= check(vk_audio_seek_ms(-120) == static_cast<uint32_t>(-113) &&
                    g_lastMs == -120,
                "millisecond seek forwarding");
    ok &= check(vk_audio_seek_order(11) == 13 && g_lastOrder == 11,
                "order seek forwarding");

    return ok ? 0 : 1;
}
