// bridge_services_probe.cpp - production assembly bridge-service witness.

#include <cstdint>
#include <cstdio>
#include <cstring>

extern "C" {
extern uint64_t sel_base_table[512];
uint16_t vk_selector_alloc(uint64_t base, uint64_t limit);
void vk_selector_free(uint16_t handle);
uint64_t vk_selector_base(uint16_t handle);
void vk_set_palette(const uint8_t* rgb);
void vk_get_palette(uint8_t* out);
void vk_set_palette_range(const uint8_t* src, uint32_t start, uint32_t count);
void vk_present_frame();
void* vk_backbuffer_ptr();
void* vk_framebuffer_ptr();
uint32_t vk_framebuffer_offset();
uint32_t vk_backbuffer_offset();
}

namespace {
uint8_t g_palette[768]{};
uint8_t g_setRed[256]{};
uint8_t g_setGreen[256]{};
uint8_t g_setBlue[256]{};
uint32_t g_presentCalls = 0;
}

extern "C" uint8_t* asm_arena_base() {
    return reinterpret_cast<uint8_t*>(0x10000000ull);
}

extern "C" uint32_t asm_arena_alloc(uint32_t) {
    return 0x1234;
}

extern "C" void asm_arena_free(uint32_t) {
}

namespace vk {

void setPalette(const uint8_t* const red, const uint8_t* const green,
                const uint8_t* const blue) {
    std::memcpy(g_setRed, red, sizeof g_setRed);
    std::memcpy(g_setGreen, green, sizeof g_setGreen);
    std::memcpy(g_setBlue, blue, sizeof g_setBlue);
    for (uint32_t i = 0; i < 256; ++i) {
        g_palette[i * 3 + 0] = red[i];
        g_palette[i * 3 + 1] = green[i];
        g_palette[i * 3 + 2] = blue[i];
    }
}

void currentPalette(uint8_t* const out) {
    std::memcpy(out, g_palette, sizeof g_palette);
}

void presentFrame() {
    ++g_presentCalls;
}

} // namespace vk

static bool check(bool condition, const char* message) {
    if (!condition) std::fprintf(stderr, "bridge services: %s\n", message);
    return condition;
}

int main() {
    bool ok = true;
    std::memset(sel_base_table, 0, sizeof sel_base_table);

    const uint16_t first = vk_selector_alloc(0x11110000, 0xffff);
    const uint16_t second = vk_selector_alloc(0x22220000, 0xffff);
    ok &= check(first == 1 && second == 2 &&
                    vk_selector_base(first) == 0x11110000 &&
                    vk_selector_base(second) == 0x22220000,
                "selector allocation and base lookup");
    vk_selector_free(first);
    const uint16_t reused = vk_selector_alloc(0x33330000, 0xffff);
    ok &= check(reused == first && vk_selector_base(0xffff) == 0,
                "selector reuse and invalid lookup");

    uint8_t input[768];
    for (uint32_t i = 0; i < sizeof input; ++i) input[i] = uint8_t(i * 13);
    vk_set_palette(input);
    uint8_t output[768]{};
    vk_get_palette(output);
    ok &= check(std::memcmp(input, output, sizeof input) == 0,
                "interleaved-to-planar palette conversion");

    for (uint32_t i = 0; i < sizeof g_palette; ++i) g_palette[i] = uint8_t(i);
    uint8_t range[18];
    for (uint32_t i = 0; i < sizeof range; ++i) range[i] = uint8_t(0xa0 + i);
    uint8_t expected[768];
    std::memcpy(expected, g_palette, sizeof expected);
    std::memcpy(expected + 10 * 3, range, sizeof range);
    vk_set_palette_range(range, 10, 6);
    ok &= check(std::memcmp(g_palette, expected, sizeof expected) == 0,
                "palette range preservation and update");

    vk_set_palette_range(range, 254, 20);
    ok &= check(g_palette[254 * 3] == range[0] &&
                    g_palette[255 * 3 + 2] == range[5],
                "palette range upper clamp");

    vk_present_frame();
    ok &= check(g_presentCalls == 1 && vk_backbuffer_offset() == 0x10000 &&
                    vk_framebuffer_offset() == 0x20000 &&
                    vk_backbuffer_ptr() == reinterpret_cast<void*>(0x10010000) &&
                    vk_framebuffer_ptr() == reinterpret_cast<void*>(0x10020000),
                "present and fixed arena overlay pointers");
    return ok ? 0 : 1;
}
