// cammat_selftest.cpp - CTest comparing the NASM MakeCameraMatrix (port of
// VIRTUAL.INC) against a C++ reference over random eye angles.
//
// Builds the 16-dword camera matrix from eyeAX/eyeAY/eyeAZ using the same
// `sar` (arithmetic) shifts on the low 32 bits of each product. Missing
// (unused) matrix entries must be zero. Byte-for-byte comparison.
//
// Returns 0 on success, non-zero on any mismatch.

#include <cstdint>
#include <cmath>
#include <cstdio>
#include <cstdlib>

extern "C" void vk_make_camera_matrix(int eyeAX, int eyeAY, int eyeAZ);
extern "C" int32_t cam_matrix[16];

static int failures = 0;

static inline int32_t low32(int32_t a, int32_t b) { return (int32_t)((int64_t)a * b); }
static inline int32_t s15(int32_t v)              { return v >> 15; }   // arithmetic

static int32_t sintab(int i) {
    double a = (2.0 * 3.14159265358979323846 * i) / 1024.0;
    return (int32_t)std::lround(std::sin(a) * 32767.0);
}

int main() {
    int32_t sin[1024];
    for (int i = 0; i < 1024; i++) sin[i] = sintab(i);

    srand(777);
    const int NTRIALS = 4000;
    for (int t = 0; t < NTRIALS && failures < 20; t++) {
        int ax = rand() & 1023, ay = rand() & 1023, az = rand() & 1023;
        vk_make_camera_matrix(ax, ay, az);

        int32_t s1 = sin[(uint32_t)ax & 1023], c1 = sin[((uint32_t)ax + 256) & 1023];
        int32_t s2 = sin[(uint32_t)ay & 1023], c2 = sin[((uint32_t)ay + 256) & 1023];
        int32_t s3 = sin[(uint32_t)az & 1023], c3 = sin[((uint32_t)az + 256) & 1023];

        int32_t mx[16] = {0};
        mx[0]  = s15(low32(c2, c3));                                   // mx11
        int32_t s3c1 = low32(s3, c1), c3s1 = low32(c3, s1);
        mx[4]  = s15(-s3c1 - low32(s15(c3s1), s2));                    // mx21
        int32_t s3s1 = low32(s3, s1), c3c1 = low32(c3, c1);
        mx[8]  = s15(-s3s1 + low32(s15(c3c1), s2));                    // mx31
        mx[1]  = s15(low32(s3, c2));                                   // mx12
        mx[5]  = s15(c3c1 - low32(s15(s3s1), s2));                     // mx22
        mx[9]  = s15(c3s1 + low32(s15(s3c1), s2));                     // mx32
        mx[2]  = -s2;                                                  // mx13
        mx[6]  = -s15(low32(c2, s1));                                  // mx23
        mx[10] = s15(low32(c2, c1));                                   // mx33

        for (int i = 0; i < 16; i++) {
            if (cam_matrix[i] != mx[i]) {
                std::printf("FAIL row/col trial %d index %d (off %d): nasm=%d ref=%d (ax=%d ay=%d az=%d)\n",
                            t, i, i*4, cam_matrix[i], mx[i], ax, ay, az);
                if (++failures >= 20) break;
            }
        }
    }

    if (failures == 0) { std::printf("cammat.crosscheck: OK\n"); return 0; }
    std::printf("cammat.crosscheck: %d failure(s)\n", failures);
    return 1;
}
