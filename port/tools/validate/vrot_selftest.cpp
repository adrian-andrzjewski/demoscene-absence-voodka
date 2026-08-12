// vrot_selftest.cpp - CTest for the rotation/transform glue (vrot.asm).
//
//   vk_transform:  camera-space matrix-vector multiply -> verified byte-exact
//                  against a C++ reference using cam_matrix (unit 2).
//   vk_rotate_object: rotates working vertices (+normals) via unit 1 ->
//                  verified identical to calling vk_prep_rot_matrix+vk_mrotate
//                  directly (which unit-1 already cross-checks).
//
// Returns 0 on success, non-zero on any mismatch.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

extern "C" void vk_make_camera_matrix(int ax, int ay, int az);
extern "C" int32_t cam_matrix[16];
extern "C" void vk_transform(int32_t* vecs, int count);
extern "C" void vk_rotate_object(int32_t* vertices, int nverts, int32_t* normals,
                                 int ax, int ay, int az);
extern "C" void vk_mrotate(int32_t* vecs, int count);
extern "C" void vk_prep_rot_matrix(int ax, int ay, int az);

static int failures = 0;
static inline int32_t s15(int32_t v) { return v >> 15; }

int main() {
    srand(31415);
    const int N = 64, NTRIALS = 4000;

    for (int t = 0; t < NTRIALS && failures < 20; t++) {
        int ax = rand() & 1023, ay = rand() & 1023, az = rand() & 1023;

        // ---- vk_transform vs reference ----
        vk_make_camera_matrix(ax, ay, az);
        int32_t vec[N * 3], got[N * 3], ref[N * 3];
        for (int i = 0; i < N * 3; i++) vec[i] = (int32_t)((rand() % 40001) - 20000);
        memcpy(got, vec, sizeof vec);
        vk_transform(got, N);

        for (int i = 0; i < N; i++) {
            int32_t x = vec[i*3], y = vec[i*3+1], z = vec[i*3+2];
            // cam_matrix is row-major; `mx<row><col>` at offset 16*(row-1)+4*(col-1).
            // Transform x' uses m11,m21,m31; y' uses m12,m22,m32; z' uses m13,m23,m33.
            int32_t m11=cam_matrix[0], m21=cam_matrix[4], m31=cam_matrix[8];
            int32_t m12=cam_matrix[1], m22=cam_matrix[5], m32=cam_matrix[9];
            int32_t m13=cam_matrix[2], m23=cam_matrix[6], m33=cam_matrix[10];
            auto low32 = [](int64_t a, int32_t b){ return (int32_t)((int64_t)a * b); };
            ref[i*3+0] = s15(low32(x,m11)) + s15(low32(y,m21)) + s15(low32(z,m31));
            ref[i*3+1] = s15(low32(x,m12)) + s15(low32(y,m22)) + s15(low32(z,m32));
            ref[i*3+2] = s15(low32(x,m13)) + s15(low32(y,m23)) + s15(low32(z,m33));
        }
        for (int i = 0; i < N * 3; i++) {
            if (got[i] != ref[i]) {
                std::printf("FAIL transform t=%d vec[%d]: nasm=%d ref=%d\n", t, i, got[i], ref[i]);
                if (++failures >= 20) break;
            }
        }

        // ---- vk_rotate_object smoke vs unit-1 directly ----
        int32_t A[N * 3], B[N * 3];
        int32_t normals_src[N * 3], normalsA[N * 3];
        for (int i = 0; i < N * 3; i++) { A[i] = vec[i]; B[i] = vec[i]; normals_src[i] = (int32_t)((rand()%2001)-1000); }
        memcpy(normalsA, normals_src, sizeof normals_src);
        vk_rotate_object(A, N, normalsA, ax, ay, az);
        vk_prep_rot_matrix(ax, ay, az);
        vk_mrotate(B, N);
        for (int i = 0; i < N * 3; i++) {
            if (A[i] != B[i]) { std::printf("FAIL rotate t=%d [%d]: %d vs %d\n", t, i, A[i], B[i]); if(++failures>=20) break; }
        }
    }

    if (failures == 0) { std::printf("vrot.crosscheck: OK\n"); return 0; }
    std::printf("vrot.crosscheck: %d failure(s)\n", failures);
    return 1;
}
