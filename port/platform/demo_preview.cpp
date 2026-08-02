// demo_preview.cpp - TEMPORARY software fallback for DemoStart32 so the
// C++ platform layer can be built, run and validated before the assembly
// core (Phases 3-4) lands. Renders a rotating palette test frame with the
// same present/timing path the real demo will use.
//
// This file is replaced by the NASM core objects once those are linked.

#include "platform_abi.h"
#include "demo_entry.h"
#include <windows.h>

extern "C" int DemoStart32(uint8_t*, uint64_t) {
    // build a simple 16-colour palette
    uint8_t r[256] = {}, g[256] = {}, b[256] = {};
    for (int i = 0; i < 256; i++) {
        // fold 8 bits to rgb565-ish so fades are visible
        r[i] = (uint8_t)((i & 0x07) ? 0 : 0);
        g[i] = (uint8_t)((i & 0x38) ? 255 : 0);
        b[i] = (uint8_t)((i & 0xC0) ? 255 : 0);
    }
    vk::setPalette(r, g, b);

    uint64_t f = 0;
    while (true) {
        vk::waitVbl();
        uint8_t* fb = vk::arena() + vk::kFramebufferOffset;
        uint8_t* bb = vk::arena() + vk::kBackbufferOffset;
        uint32_t t = (uint32_t)(f * 37);
        for (int y = 0; y < vk::kScreenH; y++) {
            for (int x = 0; x < vk::kScreenW; x++) {
                bb[y * vk::kScreenW + x] =
                    (uint8_t)(((x / 32) & 7) + (((y + (t >> 8)) / 32 & 7) << 3));
            }
        }
        ::memcpy(fb, bb, vk::kFramebufferBytes);
        vk::presentFrame();
        f++;
        vk::updateInput();
        if (vk::escapeQueued()) break;
    }
    return 0;
}

extern "C" void DemoSetProgressHook(DemoProgressFn) {}
