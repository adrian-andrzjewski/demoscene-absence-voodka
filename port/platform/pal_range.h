// pal_range.h - pure, testable helper for setting a sub-range of the 768-byte
// interleaved-RGB VGA palette, preserving all other entries.
//
// Shared by the bridge (vk_set_palette_range) and the unit test
// (tools/validate/palette_selftest.cpp) so the test exercises the exact logic
// that runs in the demo.

#ifndef VOODKA_PAL_RANGE_H
#define VOODKA_PAL_RANGE_H

#include <cstdint>

// Overwrite palette entries [start, start+count) in the 768-byte interleaved
// cur[] buffer (cur[i*3+0..2] = R,G,B of index i) with 3-byte entries taken
// from src[].  Entries outside the range are left untouched.  start+count is
// clamped at 256.  Mirrors the original VGA `set_pal src,start,count`
// (writing DAC registers for indices start..start+count-1 only).
inline void applyPaletteRange(uint8_t* cur,                       // in/out 768
                              const uint8_t* src,                 // 3*count bytes
                              uint32_t start, uint32_t count) {
    if (count > 256 - start) count = 256 - start;
    for (uint32_t i = 0; i < count; i++) {
        cur[(start + i) * 3 + 0] = src[i * 3 + 0];
        cur[(start + i) * 3 + 1] = src[i * 3 + 1];
        cur[(start + i) * 3 + 2] = src[i * 3 + 2];
    }
}

#endif // VOODKA_PAL_RANGE_H
