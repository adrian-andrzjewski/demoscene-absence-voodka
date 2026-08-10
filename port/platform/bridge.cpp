// bridge.cpp - C ABI exposed to the NASM dispatcher (eos_dispatch.asm).
//
// These are the only C symbols the assembly core may reference. They wrap
// the namespace-vk platform layer so NASM never needs C++ name mangling.
//
// Selector emulation: the original demo mapped texture/screen buffers via
// segment selectors (mov fs,sel / fs:[...]). Since user-mode x64 forbids
// setting arbitrary segment bases, alloc_selector just records the real
// 64-bit base pointer in an array. Ported texture mappers load that base
// pointer from sel_base_table and do base+index addressing.

#include "platform_abi.h"
#include "pal_range.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <cmath>
#include <cstddef>

using std::uint16_t;
using std::uint32_t;
using std::uint64_t;

extern "C" {
// public table NASM can index:  sel_base_table[handle*8] = base pointer.
// size matches EOS_MAX_SELECTORS in eos_dispatch.asm.
uint64_t sel_base_table[512];

uint64_t vk_arena_get(void)             { return (uint64_t)(uintptr_t)vk::arena(); }
uint32_t vk_arena_alloc(uint32_t bytes) { return vk::arenaAlloc(bytes); }
void     vk_arena_free(uint32_t off)    { vk::arenaFree(off); }

// alloc_selector(realPointer, limit) -> handle.  We never run out: the demo
// allocates a handful (<32). Returns 16-bit handle or 0xFFFF on error.
uint16_t vk_selector_alloc(uint64_t base, uint64_t limit) {
    (void)limit;
    for (int i = 1; i < 512; i++) {
        if (sel_base_table[i] == 0) {
            sel_base_table[i] = base;
            return (uint16_t)i;
        }
    }
    return 0xFFFF;
}
void vk_selector_free(uint16_t handle) {
    if (handle && handle < 512) sel_base_table[handle] = 0;
}
uint64_t vk_selector_base(uint16_t handle) {
    if (handle < 512) return sel_base_table[handle];
    return 0;
}

// Original EOS wait_vbl returns the ticks SINCE THE PREVIOUS CALL (~1 per
// frame), not the absolute retrace counter: every part stores the result into
// ramki/frames and uses it as a per-frame delta multiplier. Returning the
// absolute counter made camera paths and sprite animations advance
// quadratically fast (and P8's sun_step ran past its 19-frame sprite table
// and faulted reading past the arena). The absolute counter stays available
// to the platform via vk::getFrameCounter() (progress reporting).
uint64_t vk_wait_vbl() {
    static uint64_t prev = 0;
    vk::waitVbl();
    uint64_t now = vk::getFrameCounter();
    uint64_t delta = now - prev;    // first call after boot/seek: one big delta,
    prev = now;                     // exactly like the original EOS after a stall
    return delta;
}
uint32_t vk_get_modpos()    { vk::audioPump(); return vk::getModPos(); }
uint32_t vk_load_internal_file(const char* name) { return vk::loadInternalFile(name); }

// palette + present helpers: take 768-byte buffer / nothing.
void vk_set_palette(const uint8_t* rgb) {
    uint8_t r[256], g[256], b[256];
    for (int i = 0; i < 256; i++) {
        r[i] = rgb[i * 3 + 0];
        g[i] = rgb[i * 3 + 1];
        b[i] = rgb[i * 3 + 2];
    }
    vk::setPalette(r, g, b);
}
void vk_get_palette(uint8_t* out) {
    vk::currentPalette(out);
}
// set only a range of palette entries, preserving the rest (the `set_pal`
// macro backs onto this). src carries the full entry stream; start/count are
// 0-based palette indices.
void vk_set_palette_range(const uint8_t* src, uint32_t start, uint32_t count) {
    uint8_t cur[768];
    vk::currentPalette(cur);
    applyPaletteRange(cur, src, start, count);
    vk_set_palette(cur);
}
void vk_present_frame(void) { vk::presentFrame(); }
void* vk_backbuffer_ptr(void) { return vk::arena() + vk::kBackbufferOffset; }
void* vk_framebuffer_ptr(void) { return vk::arena() + vk::kFramebufferOffset; }
uint32_t vk_framebuffer_offset(void) { return vk::kFramebufferOffset; }
uint32_t vk_backbuffer_offset(void) { return vk::kBackbufferOffset; }

int  vk_audio_play()        { return vk::audioPlay(); }
int  vk_audio_stop()        { return vk::audioStop(); }
void vk_audio_clear()       { }
void vk_audio_set_pattern(int pos) { (void)pos; }

// seeking: returns actual ModPos ((order<<8)|row) reached.
uint32_t vk_audio_seek_rows(uint32_t rows) { return vk::audioSeekRows(rows); }
uint32_t vk_audio_seek_ms(int ms)           { return vk::audioSeekMs(ms); }
uint32_t vk_audio_seek_order(int order)     { return vk::audioSeekOrder(order); }

// entry-part selector: 0 = run the full part1..part8 sequence (default),
// 1..8 = run only that part. Set by app.cpp before DemoStart32.
static int g_entry_part = 0;
void vk_set_entry_part(int part) { g_entry_part = part; }
int  vk_get_entry_part()         { return g_entry_part; }

// Native x64 production WndProc wrappers. The reference executable keeps
// app.cpp's C++ callback for differential validation; VOODKA's callback calls
// these fixed C ABI names from win32_app_wndproc.asm.
void vk_key_down(uint32_t scancode) {
    vk::keyDown(static_cast<uint8_t>(scancode));
}
void vk_key_up(uint32_t scancode) {
    vk::keyUp(static_cast<uint8_t>(scancode));
}
void vk_pause_toggle() {
    vk::pauseToggle();
}
void vk_request_quit() {
    vk::requestQuit();
}

// trace hook from NASM (simple %s/%x/%d formatting via platform logger)
void vk_log_printf(const char* fmt, ...) {
    char buf[512];
    va_list ap; va_start(ap, fmt);
    std::vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    vk::logPrint("%s", buf);
}

struct P4DrawArgs {
    int32_t xy[6];
    uint32_t uv[3];
    const uint8_t* texture;
    uint8_t* screen;
    uint32_t color;
};
static_assert(offsetof(P4DrawArgs, texture) == 40);
static_assert(offsetof(P4DrawArgs, screen) == 48);
static_assert(offsetof(P4DrawArgs, color) == 56);

// P4's triangle contract, expressed as a bounded scan conversion. UV values
// are the original 8.8 packed words; the texture is a 256-byte stride and
// wraps through the same 16-bit texel index as the DOS mapper.
void vk_p4_draw_triangle(const P4DrawArgs* a) {
    struct V { double x, y, u, v; } v[3] = {
        {double(a->xy[0]), double(a->xy[1]),
         double((a->uv[0] >> 8) & 0xff), double((a->uv[0] >> 24) & 0xff)},
        {double(a->xy[2]), double(a->xy[3]),
         double((a->uv[1] >> 8) & 0xff), double((a->uv[1] >> 24) & 0xff)},
        {double(a->xy[4]), double(a->xy[5]),
         double((a->uv[2] >> 8) & 0xff), double((a->uv[2] >> 24) & 0xff)}
    };
    if (v[1].y < v[0].y) std::swap(v[0], v[1]);
    if (v[2].y < v[0].y) std::swap(v[0], v[2]);
    if (v[2].y < v[1].y) std::swap(v[1], v[2]);
    const int y0 = (std::max)(0, (int)std::ceil(v[0].y));
    const int y1 = (std::min)(199, (int)std::floor(v[2].y));
    if (y0 > y1) return;
    const double area = (v[2].x - v[0].x) * (v[1].y - v[0].y) -
                        (v[2].y - v[0].y) * (v[1].x - v[0].x);
    if (area == 0.0) return;
    auto edge = [](const V& a, const V& b, double y) {
        const double t = (b.y == a.y) ? 0.0 : (y - a.y) / (b.y - a.y);
        return V{a.x + (b.x - a.x) * t, y,
                 a.u + (b.u - a.u) * t, a.v + (b.v - a.v) * t};
    };
    for (int y = y0; y <= y1; ++y) {
        const double yy = double(y);
        const V longEdge = edge(v[0], v[2], yy);
        const V shortEdge = (yy < v[1].y) ? edge(v[0], v[1], yy)
                                          : edge(v[1], v[2], yy);
        V left = longEdge, right = shortEdge;
        if (left.x > right.x) std::swap(left, right);
        const int xa = (std::max)(0, (int)std::ceil(left.x));
        const int xb = (std::min)(319, (int)std::floor(right.x));
        if (xa > xb) continue;
        const double width = right.x - left.x;
        for (int x = xa; x <= xb; ++x) {
            const double t = width == 0.0 ? 0.0 :
                (double(x) - left.x) / width;
            const int u = (int)(left.u + (right.u - left.u) * t);
            const int vv = (int)(left.v + (right.v - left.v) * t);
            const uint8_t texel = a->texture[((vv & 0xff) << 8) | (u & 0xff)];
            a->screen[y * 320 + x] = uint8_t(texel + a->color);
        }
    }
}

// copy the platform key map (128 PC scancodes, 1=pressed) into dst
void vk_key_map_copy(uint8_t* dst) {
    const uint8_t* src = vk::rawKeyMap();
    for (int i = 0; i < 128; i++) dst[i] = src[i] ? 1 : 0;
}

} // extern "C"

namespace vk {
void resetSelectors() {
    std::memset(sel_base_table, 0, sizeof sel_base_table);
}
} // namespace vk
