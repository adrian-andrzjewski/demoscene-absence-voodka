// mrotate_selftest.cpp - CTest comparing the NASM mrotate (port of
// MROTATE.PM) against a C++ reference over random angles + random vertices.
//
// The assembly uses 15-bit-fraction fixed point with x87-free integer math:
//   1-operand imul -> 64-bit edx:eax product, then
//     PrepareRotationMatrix : shrd eax,edx,15  (logical shift of the product)
//     mrotate z-m terms     : sar  eax,15      (arithmetic shift of low 32)
// The reference replicates both exactly so the outputs must match byte-for-byte.
//
// Returns 0 on success, non-zero on any mismatch.

#include <cstdint>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

extern "C" void vk_prep_rot_matrix(int ax, int ay, int az);
extern "C" void vk_mrotate(int32_t* vecs, int count);
extern "C" void vk_mrotate_normals(int32_t* vecs, int count);
extern "C" int32_t mrot_matrix[9];

static int failures = 0;

// shrd eax,edx,15 of a 64-bit product: (uint64 product) >> 15, low 32 kept.
static inline int32_t shrd15(int32_t a, int32_t b) {
    return (int32_t)(((uint64_t)((int64_t)a * (int64_t)b)) >> 15);
}
// sar eax,15 of the low 32 bits of a 64-bit product.
static inline int32_t sar15(int32_t a, int32_t b) {
    return ((int32_t)((uint64_t)((int64_t)a * (int64_t)b)) ) >> 15;
}

struct Ref {
    int32_t m[9], ab1, ab2, ab3;
};

static Ref buildMatrix(int ax, int ay, int az, const int32_t* sintab) {
    int32_t s1 = sintab[(uint32_t)ax & 1023];
    int32_t c1 = sintab[((uint32_t)ax + 256) & 1023];
    int32_t s2 = sintab[(uint32_t)ay & 1023];
    int32_t c2 = sintab[((uint32_t)ay + 256) & 1023];
    int32_t s3 = sintab[(uint32_t)az & 1023];
    int32_t c3 = sintab[((uint32_t)az + 256) & 1023];
    Ref R;
    R.m[0] = shrd15(c3, c2);
    R.m[6] = -s2;
    R.m[3] = shrd15(s3, c2);
    int32_t s3c1 = shrd15(s3, c1);
    int32_t s3s1 = shrd15(s3, s1);
    int32_t c3s2 = shrd15(c3, s2);
    R.m[1] = -shrd15(c3s2, s1) - s3c1;
    R.m[2] = shrd15(c3s2, c1) - s3s1;
    R.m[4] = shrd15(c3, c1) - shrd15(s3s1, s2);
    R.m[7] = -shrd15(c2, s1);
    R.m[8] = shrd15(c2, c1);
    R.m[5] = shrd15(s3c1, s2) + shrd15(c3, s1);
    R.ab1 = (int32_t)((int64_t)R.m[0] * R.m[1]);
    R.ab2 = (int32_t)((int64_t)R.m[3] * R.m[4]);
    R.ab3 = (int32_t)((int64_t)R.m[6] * R.m[7]);
    return R;
}

static void refRotate(const Ref& R, const int32_t* in, int nverts, int32_t* out) {
    for (int i = 0; i < nverts; i++) {
        int32_t x = in[i * 3 + 0], y = in[i * 3 + 1], z = in[i * 3 + 2];
        int32_t xy = (int32_t)((int64_t)x * y);
        int32_t p1 = (int32_t)((int64_t)(x + R.m[1]) * (y + R.m[0]));
        int32_t xr = (int32_t)((uint32_t)((uint32_t)p1 - (uint32_t)xy - (uint32_t)R.ab1)) >> 15;
        xr += sar15(z, R.m[2]);
        int32_t p2 = (int32_t)((int64_t)(x + R.m[4]) * (y + R.m[3]));
        int32_t yr = (int32_t)((uint32_t)((uint32_t)p2 - (uint32_t)xy - (uint32_t)R.ab2)) >> 15;
        yr += sar15(z, R.m[5]);
        int32_t p3 = (int32_t)((int64_t)(x + R.m[7]) * (y + R.m[6]));
        int32_t zr = (int32_t)((uint32_t)((uint32_t)p3 - (uint32_t)xy - (uint32_t)R.ab3)) >> 15;
        zr += sar15(z, R.m[8]);
        out[i * 3 + 0] = xr;
        out[i * 3 + 1] = yr;
        out[i * 3 + 2] = zr;
    }
}

int main() {
    // sine table, generated exactly like sin_tables.cpp
    int32_t sintab[1024];
    for (int i = 0; i < 1024; i++) {
        double a = (2.0 * 3.14159265358979323846 * i) / 1024.0;
        sintab[i] = (int32_t)std::lround(std::sin(a) * 32767.0);
    }

    srand(12345);
    const int NVERTS = 32;
    const int NTRIALS = 4000;
    for (int t = 0; t < NTRIALS && failures < 20; t++) {
        int ax = rand() & 1023, ay = rand() & 1023, az = rand() & 1023;
        int32_t verts[NVERTS * 3], asmout[NVERTS * 3];
        for (int i = 0; i < NVERTS * 3; i++)
            verts[i] = (int32_t)((rand() & 0xFFFF) - 0x8000);

        vk_prep_rot_matrix(ax, ay, az);
        Ref R = buildMatrix(ax, ay, az, sintab);
        int32_t ref[9], cur[9];
        for (int i = 0; i < 9; i++) ref[i] = R.m[i], cur[i] = 0;
        // matrix comparison
        for (int i = 0; i < 9; i++) {
            if (mrot_matrix[i] != ref[i]) {
                std::printf("FAIL matrix[%d] trial %d: nasm=%d ref=%d\n",
                            i, t, mrot_matrix[i], ref[i]);
                if (++failures >= 20) break;
            }
        }

        memcpy(asmout, verts, sizeof verts);
        vk_mrotate(asmout, NVERTS);
        int32_t outref[NVERTS * 3];
        refRotate(R, verts, NVERTS, outref);

        for (int i = 0; i < NVERTS * 3; i++) {
            if (asmout[i] != outref[i]) {
                std::printf("FAIL rotate trial %d vert[%d]: nasm=%d ref=%d (ax=%d ay=%d az=%d)\n",
                            t, i, asmout[i], outref[i], ax, ay, az);
                if (++failures >= 20) break;
            }
        }

        // mrotate_normals (2-component x,y; z term still used in x,y)
        memcpy(asmout, verts, sizeof verts);
        vk_mrotate_normals(asmout, NVERTS);
        for (int i = 0; i < NVERTS; i++) {
            int32_t x = verts[i*3], y = verts[i*3+1], z = verts[i*3+2];
            (void)z;
            // reuse refRotate output's x,y
            if (asmout[i*3] != outref[i*3] || asmout[i*3+1] != outref[i*3+1]) {
                std::printf("FAIL rotnormals trial %d vert[%d]\n", t, i);
                if (++failures >= 20) break;
            }
        }
    }

    if (failures == 0) { std::printf("mrotate.crosscheck: OK\n"); return 0; }
    std::printf("mrotate.crosscheck: %d failure(s)\n", failures);
    return 1;
}
