// toonel_selftest.cpp - CTest for vk_make_toonel (shared tunnel table).
//
// vk_make_toonel fills a 128000-byte buffer with the tunnel u/v table that
// boot's Start32 builds once and the tunnel parts (tunel + wygibasy (P3) tooneling) read. This
// test validates the REAL NASM routine:
//   - determinism: two fills hash identically;
//   - non-triviality: the buffer is not zero/uniform;
//   - spot coordinates: u = int(atan2(x,y)*128/pi) and v = int(3000/r)
//     for a spread of cells, within a small tolerance (x87 80-bit vs double).
//
// Cell layout after packing (see toonel.asm):
//   cell index edi = (y+100)*320 + (x+160)
//   edi even (2k):  u = buf[2k],     v = buf[2k+1]
//   edi odd  (2k+1):u = buf[64000+2k], v = buf[64000+2k+1]
//
// Returns 0 on success, non-zero on any mismatch.

#include <cstdint>
#include <cmath>
#include <cstdio>
#include <cstring>

extern "C" void vk_make_toonel(uint8_t* dest);

static int failures = 0;

static uint64_t fnv1a(const uint8_t* p, size_t n) {
    uint64_t h = 1469598103934665603ull;
    for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 1099511628211ull; }
    return h;
}

static void check(const char* what, int32_t got, int32_t want, int32_t tol) {
    int32_t d = got - want;
    if (d < 0) d = -d;
    if (d > tol) {
        std::printf("FAIL %s: got %d want %d (tol %d)\n", what, got, want, tol);
        failures++;
    }
}

int main() {
    uint8_t a[128000], b[128000];
    vk_make_toonel(a);
    vk_make_toonel(b);

    // determinism + non-triviality
    uint64_t ha = fnv1a(a, sizeof a), hb = fnv1a(b, sizeof b);
    std::printf("hash=%016llx\n", (unsigned long long)ha);
    if (ha != hb) { std::printf("FAIL determinism: %016llx != %016llx\n",
                                (unsigned long long)ha, (unsigned long long)hb); failures++; }
    if (ha == 0) { std::printf("FAIL zero hash (degenerate table)\n"); failures++; }

    // byte diversity
    bool seen[256] = {};
    int distinct = 0;
    for (size_t i = 0; i < sizeof a; i++) if (!seen[a[i]]) { seen[a[i]] = true; distinct++; }
    if (distinct < 16) { std::printf("FAIL low diversity: %d distinct bytes\n", distinct); failures++; }

    // spot cells (x,y). Skip (0,0) (divide-by-zero) and x==0 (fpatan signed-zero
    // quadrant edge). v checked everywhere else.
    struct Cell { int x, y; } cells[] = {
        {-160, -100}, {-160, -1}, {159, -1}, {100, -50}, {-100, 50}, {159, 99},
    };
    const double kPi = 3.14159265358979323846;
    for (auto c : cells) {
        int x = c.x, y = c.y;
        int edi = (y + 100) * 320 + (x + 160);
        int u_act, v_act;
        if (edi & 1) { u_act = a[64000 + edi - 1]; v_act = a[64000 + edi]; }
        else         { u_act = a[edi];            v_act = a[edi + 1]; }
        double r = std::sqrt((double)(x * x) + (double)(y * y));
        int v_want = (int)(3000.0 / r) & 0xFF;
        check("v", v_act, v_want, 3);
        if (x != 0) {
            double ang = std::atan2((double)x, (double)y);
            int u_want = (int)(ang * 128.0 / kPi) & 0xFF;
            check("u", u_act, u_want, 3);
        }
    }

    if (failures == 0) { std::printf("toonel.crosscheck: OK\n"); return 0; }
    std::printf("toonel.crosscheck: %d failure(s)\n", failures);
    return 1;
}
