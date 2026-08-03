// persp_selftest.cpp - CTest comparing the NASM persp (port of PERSP.PM)
// against a C++ reference over random 3D vertices.
//
// x' = (x*185)/(z+2960)+160 ; y' = (y*185)/(z+2960)+100 ; s==0 -> s=1.
// Signed 64-bit division (idiv) truncates toward zero, matching C++.
//
// Returns 0 on success, non-zero on any mismatch.

#include <cstdint>
#include <cstdio>
#include <cstdlib>

extern "C" void vk_persp(const int32_t* src, int32_t* dst, int count);

static int failures = 0;

int main() {
    srand(4242);
    const int N = 256;
    const int NTRIALS = 4000;
    for (int t = 0; t < NTRIALS && failures < 20; t++) {
        int32_t src[N * 3], nasm[N * 2];
        for (int i = 0; i < N * 3; i++) src[i] = (int32_t)((rand() % 40001) - 20000);

        vk_persp(src, nasm, N);
        for (int i = 0; i < N; i++) {
            int32_t x = src[i*3], y = src[i*3+1], z = src[i*3+2];
            int64_t s = (int64_t)z + 2960;
            if (s == 0) s = 1;
            int32_t xo = (int32_t)(((int64_t)x * 185) / s) + 160;
            int32_t yo = (int32_t)(((int64_t)y * 185) / s) + 100;
            if (nasm[i*2] != xo || nasm[i*2+1] != yo) {
                std::printf("FAIL trial %d vert %d: nasm=(%d,%d) ref=(%d,%d)\n",
                            t, i, nasm[i*2], nasm[i*2+1], xo, yo);
                if (++failures >= 20) break;
            }
        }
    }
    if (failures == 0) { std::printf("persp.crosscheck: OK\n"); return 0; }
    std::printf("persp.crosscheck: %d failure(s)\n", failures);
    return 1;
}
