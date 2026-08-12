// normals_selftest.cpp - CTest comparing the NASM calcNormals (port of
// NORMALS.PM) against a C++ reference over random meshes.
//
// Validates per-face normal = (v2-v1)x(v3-v1), normalization (nor*250/len,
// zero if len==0), then per-vertex aggregation + division by face count.
// The sqrt length is rounded half-to-even (fistp), so per-vertex normals are
// compared with a small tolerance (FPU 80-bit vs double). Per-vertex counts
// are integer and compared exactly.
//
// Returns 0 on success, non-zero on any mismatch.

#include <cstdint>
#include <cmath>
#include <cstdio>
#include <cstdlib>

struct EvilObj {
    int32_t* vertexes; int nverts;
    int32_t* faces;    int nfaces;
    int32_t* normals;
    int32_t* wersory;
    int32_t* count;
};

extern "C" void vk_calc_normals(EvilObj* o);

static int failures = 0;

int main() {
    srand(13579);
    const int NVERTS = 24, NFACES = 40, NTRIALS = 800;

    for (int t = 0; t < NTRIALS && failures < 20; t++) {
        int32_t verts[NVERTS * 3], faces[NFACES * 3];
        for (int i = 0; i < NVERTS * 3; i++) verts[i] = (int32_t)((rand() % 2001) - 1000);
        for (int i = 0; i < NFACES * 3; i++) faces[i] = rand() % NVERTS;

        int32_t normals[NFACES * 3], wersory[NVERTS * 3], count[NVERTS];
        EvilObj o = { verts, NVERTS, faces, NFACES, normals, wersory, count };
        vk_calc_normals(&o);

        // reference
        int32_t rnorm[NFACES * 3], rwers[NVERTS * 3], rcnt[NVERTS];
        for (int f = 0; f < NFACES; f++) {
            int32_t v0 = faces[f*3], v1 = faces[f*3+1], v2 = faces[f*3+2];
            int32_t x1=verts[v0*3],y1=verts[v0*3+1],z1=verts[v0*3+2];
            int32_t x2=verts[v1*3],y2=verts[v1*3+1],z2=verts[v1*3+2];
            int32_t x3=verts[v2*3],y3=verts[v2*3+1],z3=verts[v2*3+2];
            int32_t v1x=x2-x1,v1y=y2-y1,v1z=z2-z1, v2x=x3-x1,v2y=y3-y1,v2z=z3-z1;
            int32_t norX=(int32_t)((int64_t)v1y*v2z - (int64_t)v1z*v2y);
            int32_t norY=(int32_t)((int64_t)v1z*v2x - (int64_t)v1x*v2z);
            int32_t norZ=(int32_t)((int64_t)v1x*v2y - (int64_t)v1y*v2x);
            double len = std::sqrt((double)norX*norX + (double)norY*norY + (double)norZ*norZ);
            int32_t lenint = (int32_t)std::nearbyint(len);
            if (lenint == 0) { rnorm[f*3]=rnorm[f*3+1]=rnorm[f*3+2]=0; }
            else {
                rnorm[f*3+0] = (int32_t)((int64_t)(int32_t)(norX*250) / lenint);
                rnorm[f*3+1] = (int32_t)((int64_t)(int32_t)(norY*250) / lenint);
                rnorm[f*3+2] = (int32_t)((int64_t)(int32_t)(norZ*250) / lenint);
            }
        }
        for (int i = 0; i < NVERTS; i++) { rcnt[i]=0; rwers[i*3]=rwers[i*3+1]=rwers[i*3+2]=0; }
        for (int f = 0; f < NFACES; f++) for (int k = 0; k < 3; k++) {
            int v = faces[f*3+k];
            rcnt[v]++;
            rwers[v*3+0]+=rnorm[f*3+0]; rwers[v*3+1]+=rnorm[f*3+1]; rwers[v*3+2]+=rnorm[f*3+2];
        }
        for (int v = 0; v < NVERTS; v++) {
            if (rcnt[v]==0) { rwers[v*3]=rwers[v*3+1]=rwers[v*3+2]=0; }
            else {
                rwers[v*3+0]=(int32_t)((int32_t)((int64_t)rwers[v*3+0]) / rcnt[v]);
                rwers[v*3+1]=(int32_t)((int32_t)((int64_t)rwers[v*3+1]) / rcnt[v]);
                rwers[v*3+2]=(int32_t)((int32_t)((int64_t)rwers[v*3+2]) / rcnt[v]);
            }
        }

        for (int v = 0; v < NVERTS; v++) {
            if (count[v] != rcnt[v]) { std::printf("FAIL t=%d count[%d]: nasm=%d ref=%d\n",t,v,count[v],rcnt[v]); if(++failures>=20) break; }
            for (int k = 0; k < 3; k++) {
                int32_t d = wersory[v*3+k] - rwers[v*3+k]; if (d<0)d=-d;
                if (d > 4) {
                    std::printf("FAIL t=%d wersory[%d][%d]: nasm=%d ref=%d\n",t,v,k,wersory[v*3+k],rwers[v*3+k]);
                    if (++failures>=20) break;
                }
            }
        }
    }

    if (failures == 0) { std::printf("normals.crosscheck: OK\n"); return 0; }
    std::printf("normals.crosscheck: %d failure(s)\n", failures);
    return 1;
}
