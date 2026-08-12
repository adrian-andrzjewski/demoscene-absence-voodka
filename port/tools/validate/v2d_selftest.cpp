// v2d_selftest.cpp - CTest for the 2D primitives (VISIBLE.PM isVisible,
// PIXEL2D.PM Pixel2d) against C++ references.
//
//   isVisible: 16-bit corner cross-product (visible = -(p1-p2) >= 0)
//   Pixel2d:   clipped colored-point plot into a 320x200 buffer
//
// Returns 0 on success, non-zero on any mismatch.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

extern "C" int  vk_is_visible(int x1, int y1, int x2, int y2, int x3, int y3);
extern "C" void vk_pixel2d(uint8_t* screen, const int32_t* pts, int count, uint8_t color);

static int failures = 0;

int main() {
    // ---- isVisible over random 16-bit triangles ----
    srand(99);
    const int NTRIALS = 200000;
    for (int t = 0; t < NTRIALS && failures < 20; t++) {
        int16_t x1 = (int16_t)(rand() & 0xFFFF), y1 = (int16_t)(rand() & 0xFFFF);
        int16_t x2 = (int16_t)(rand() & 0xFFFF), y2 = (int16_t)(rand() & 0xFFFF);
        int16_t x3 = (int16_t)(rand() & 0xFFFF), y3 = (int16_t)(rand() & 0xFFFF);
        int got = vk_is_visible(x1, y1, x2, y2, x3, y3);

        int16_t p1 = (int16_t)((int16_t)(y2 - y1) * (int16_t)(x3 - x1));
        int16_t c  = p1;
        int16_t p2 = (int16_t)((int16_t)(y3 - y1) * (int16_t)(x2 - x1));
        c = (int16_t)(c - p2);
        int16_t neg = (int16_t)(-c);
        int want = (neg < 0) ? 0 : 1;
        if (got != want) {
            std::printf("FAIL isVisible t=%d (x1=%d y1=%d x2=%d y2=%d x3=%d y3=%d): got=%d want=%d\n",
                        t, x1, y1, x2, y2, x3, y3, got, want);
            if (++failures >= 20) break;
        }
    }

    // ---- Pixel2d over random points ----
    const int N = 300;
    const int SCRN = 64000;
    for (int t = 0; t < 4000 && failures < 20; t++) {
        int32_t pts[N * 2];
        for (int i = 0; i < N * 2; i++) pts[i] = (int32_t)((rand() % 500) - 100); // mostly OOB/in-range

        uint8_t scr[SCRN], ref[SCRN];
        memset(scr, 0, SCRN); memset(ref, 0, SCRN);
        uint8_t color = (uint8_t)(rand() & 0xFF);

        vk_pixel2d(scr, pts, N, color);
        for (int i = 0; i < N; i++) {
            int32_t x = pts[i*2], y = pts[i*2+1];
            if (x >= 0 && x <= 319 && y >= 0 && y <= 199) ref[y * 320 + x] = color;
        }
        if (memcmp(scr, ref, SCRN) != 0) {
            std::printf("FAIL pixel2d t=%d\n", t);
            if (++failures >= 20) break;
        }
    }

    if (failures == 0) { std::printf("v2d.crosscheck: OK\n"); return 0; }
    std::printf("v2d.crosscheck: %d failure(s)\n", failures);
    return 1;
}
