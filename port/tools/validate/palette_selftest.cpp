// palette_selftest.cpp - CTest for the palette-range model.
//
// Validates applyPaletteRange (the exact logic behind the bridge
// vk_set_palette_range, which backs the port's `set_pal` macro) against a
// hand-built 768-byte interleaved-RGB palette.
//
// Returns 0 on success, non-zero on any mismatch.

#include "pal_range.h"
#include <cstdint>
#include <cstdio>
#include <cstring>

static int failures = 0;

static void checkEq(const char* what, uint32_t got, uint32_t want) {
    if (got != want) {
        std::printf("FAIL %s: got %u want %u\n", what, got, want);
        failures++;
    }
}

int main() {
    uint8_t pal[768];
    for (int i = 0; i < 256; i++) {
        pal[i * 3 + 0] = (uint8_t)i;       // R = index
        pal[i * 3 + 1] = (uint8_t)(255 - i); // G = 255-index
        pal[i * 3 + 2] = (uint8_t)(i * 2);   // B = 2*index
    }

    // Set range [10, 20) from a source (10 entries).
    uint8_t src[30];
    for (int i = 0; i < 10; i++) {
        src[i * 3 + 0] = 200 + (uint8_t)i;
        src[i * 3 + 1] = 1;
        src[i * 3 + 2] = (uint8_t)(i + 50);
    }
    applyPaletteRange(pal, src, 10, 10);

    // entries inside [10,20) updated
    for (int i = 0; i < 10; i++) {
        checkEq("inside.R", pal[(10 + i) * 3 + 0], 200 + (uint8_t)i);
        checkEq("inside.G", pal[(10 + i) * 3 + 1], 1);
        checkEq("inside.B", pal[(10 + i) * 3 + 2], (uint8_t)(i + 50));
    }
    // entries outside untouched
    for (int i = 0; i < 10; i++) {
        checkEq("outside0.R", pal[i * 3 + 0], (uint8_t)i);
        checkEq("outside0.G", pal[i * 3 + 1], (uint8_t)(255 - i));
        checkEq("outside20.R", pal[(20 + i) * 3 + 0], (uint8_t)(20 + i));
        checkEq("outside20.G", pal[(20 + i) * 3 + 1], (uint8_t)(235 - i));
    }

    // clamping: start+count beyond 256 must clamp (not overrun buffer)
    uint8_t cur[768];
    for (int i = 0; i < 256; i++) { cur[i * 3 + 0] = 0xAA; cur[i * 3 + 1] = 0xBB; cur[i * 3 + 2] = 0xCC; }
    uint8_t big[999];               // would read OOB if clamp failed
    memset(big, 0x5A, sizeof big);
    applyPaletteRange(cur, big, 250, 100); // -> clamped to entries [250,256)
    for (int i = 250; i < 256; i++) {      // all 6 fully rewritten
        checkEq("clamp.R", cur[i * 3 + 0], 0x5A);
        checkEq("clamp.G", cur[i * 3 + 1], 0x5A);
        checkEq("clamp.B", cur[i * 3 + 2], 0x5A);
    }
    checkEq("clamp.keepL", cur[249 * 3 + 0], 0xAA); // index 249 untouched

    if (failures == 0) {
        std::printf("palette.crosscheck: OK\n");
        return 0;
    }
    std::printf("palette.crosscheck: %d failure(s)\n", failures);
    return 1;
}
