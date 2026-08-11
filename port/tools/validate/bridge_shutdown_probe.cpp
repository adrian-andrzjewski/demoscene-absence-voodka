// bridge_shutdown_probe.cpp - production shutdown adapter dispatch witness.

#include <cstdint>
#include <cstdio>

extern "C" {
void vk_shutdown_input();
void vk_shutdown_audio();
void vk_shutdown_recording();
void vk_shutdown_diagnostics();
void vk_shutdown_timeline();
void vk_shutdown_present();
void vk_shutdown_selectors();
void vk_shutdown_platform();
void vk_shutdown_log_flush();
void vk_shutdown_log_shutdown();
void asm_input_shutdown();
void asm_arena_platform_shutdown();
}

namespace {
uint32_t g_order[16]{};
uint32_t g_count = 0;

void mark(uint32_t id) {
    if (g_count < 16) g_order[g_count++] = id;
}
}

extern "C" void asm_input_shutdown() { mark(1); }
extern "C" void asm_arena_platform_shutdown() { mark(8); }

namespace vk {
void audioShutdown() { mark(2); }
void recClose() { mark(3); }
void diagReadbackShutdown() { mark(4); }
void timelineClose() { mark(5); }
void shutdownPresent() { mark(6); }
void resetSelectors() { mark(7); }
void logFlush() { mark(9); }
void logShutdown() { mark(10); }
} // namespace vk

static bool check(bool condition, const char* message) {
    if (!condition) std::fprintf(stderr, "bridge shutdown: %s\n", message);
    return condition;
}

int main() {
    vk_shutdown_input();
    vk_shutdown_audio();
    vk_shutdown_recording();
    vk_shutdown_diagnostics();
    vk_shutdown_timeline();
    vk_shutdown_present();
    vk_shutdown_selectors();
    vk_shutdown_platform();
    vk_shutdown_log_flush();
    vk_shutdown_log_shutdown();

    const uint32_t expected[] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10};
    bool ok = check(g_count == 10, "every shutdown adapter dispatches once");
    for (uint32_t i = 0; i < 10 && ok; ++i)
        ok &= check(g_order[i] == expected[i], "teardown service mapping/order");
    return ok ? 0 : 1;
}
