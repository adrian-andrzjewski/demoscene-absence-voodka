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
#include <cstdint>
#include <cstdio>
#include <cstdarg>
#include <cstring>

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

void     vk_wait_vbl()      { vk::waitVbl(); }
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
void vk_present_frame(void) { vk::presentFrame(); }
void* vk_backbuffer_ptr(void) { return vk::arena() + vk::kBackbufferOffset; }
void* vk_framebuffer_ptr(void) { return vk::arena() + vk::kFramebufferOffset; }
uint32_t vk_framebuffer_offset(void) { return vk::kFramebufferOffset; }
uint32_t vk_backbuffer_offset(void) { return vk::kBackbufferOffset; }

int  vk_audio_play()        { return vk::audioPlay(); }
int  vk_audio_stop()        { return vk::audioStop(); }
void vk_audio_clear()       { }
void vk_audio_set_pattern(int pos) { (void)pos; }

// seeking: returns actual ModPos (rows) reached.
uint32_t vk_audio_seek_rows(uint32_t rows) { return vk::audioSeekRows(rows); }
uint32_t vk_audio_seek_ms(int ms)           { return vk::audioSeekMs(ms); }
uint32_t vk_audio_seek_order(int order)     { return vk::audioSeekOrder(order); }

// entry-part selector: 0 = run the full part1..part8 sequence (default),
// 1..8 = run only that part. Set by app.cpp before DemoStart32.
static int g_entry_part = 0;
void vk_set_entry_part(int part) { g_entry_part = part; }
int  vk_get_entry_part()         { return g_entry_part; }

// trace hook from NASM (simple %s/%x/%d formatting via platform logger)
void vk_log_printf(const char* fmt, ...) {
    char buf[512];
    va_list ap; va_start(ap, fmt);
    std::vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    vk::logPrint("%s", buf);
}

} // extern "C"
