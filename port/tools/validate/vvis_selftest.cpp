// vvis_selftest.cpp - CTest for visibility + painter sort (vvis.asm).
//
//   vk_calc_visibility: camera-space z via (p-cam) . matrix 3rd column (shrd15)
//                       -> exact byte-for-byte vs reference; visibility flag.
//   vk_virsort:         orderOut must equal a stable DESCENDING sort by
//                       key=(uint16)((int16)low16(zet)>>virsort_shift)
//                       (painter far->near, like VirSort's 15->0 bucket
//                       gather in INC/VIRSORT.PM and P5/VIRSORT.PM).
//
// Returns 0 on success, non-zero on any mismatch.

#include <cstdint>
#include <cstring>
#include <cstdio>
#include <cstdlib>

extern "C" void vk_make_camera_matrix(int ax, int ay, int az);
extern "C" int32_t cam_matrix[16];
extern "C" int32_t cam_cameraX, cam_cameraY, cam_cameraZ;
extern "C" void vk_calc_visibility(const int32_t* w, int c, int32_t* zet, uint8_t* vis);
extern "C" void vk_virsort(const int32_t* zet, int c, int32_t* order);
extern "C" int32_t virsort_shift;

static int failures = 0;
static inline int32_t shrd15(int32_t a, int32_t b) {
    return (int32_t)(((uint64_t)((int64_t)a * b)) >> 15);
}

int main() {
    srand(2024);
    const int NTRIALS = 4000, N = 64;

    for (int t = 0; t < NTRIALS && failures < 20; t++) {
        int ax = rand() & 1023, ay = rand() & 1023, az = rand() & 1023;
        vk_make_camera_matrix(ax, ay, az);
        int32_t cx = (int32_t)((rand()%20001)-10000), cy = (int32_t)((rand()%20001)-10000), cz = (int32_t)((rand()%20001)-10000);
        cam_cameraX = cx; cam_cameraY = cy; cam_cameraZ = cz;

        int32_t w[N*3], zet[N]; uint8_t vis[N];
        for (int i = 0; i < N*3; i++) w[i] = (int32_t)((rand()%40001)-20000);
        vk_calc_visibility(w, N, zet, vis);
            int32_t m13=cam_matrix[2], m23=cam_matrix[6], m33=cam_matrix[10];
            for (int i = 0; i < N; i++) {
            int32_t z = shrd15(w[i*3]-cx, m13) + shrd15(w[i*3+1]-cy, m23) + shrd15(w[i*3+2]-cz, m33);
            uint8_t v = z >= 1 ? 1 : 0;
            if (zet[i] != z) { std::printf("FAIL vis t=%d zet[%d]: nasm=%d ref=%d\n",t,i,zet[i],z); if(++failures>=20)break; }
            if (vis[i] != v) { std::printf("FAIL vis t=%d flag[%d]: nasm=%d ref=%d\n",t,i,vis[i],v); if(++failures>=20)break; }
        }

        // virsort on a shuffled zet array, in both key-shift modes (swiatynia city (P2)=0, torus ustep village (P5)=4)
        int32_t keys[N]; for (int i=0;i<N;i++) keys[i]=(int32_t)((rand()%70000)-1000);
        for (int shift = 0; shift <= 4 && failures < 20; shift += 4) {
            virsort_shift = shift;
            int32_t order[N];
            vk_virsort(keys, N, order);
            bool seen[256]={}; bool okperm=true;
            for (int i=0;i<N;i++){ if(order[i]<0||order[i]>=N||seen[order[i]]){okperm=false;break;} seen[order[i]]=true; }
            if(!okperm){ std::printf("FAIL virsort t=%d shift=%d not a permutation\n",t,shift); if(++failures>=20)break; }
            // reference: stable DESCENDING by key (far->near)
            int ref[N]; for (int i=0;i<N;i++) ref[i]=i;
            for (int i=1;i<N;i++){
                int k=ref[i];
                uint16_t kz=(uint16_t)((int16_t)(keys[k]&0xffff)>>shift); int j=i-1;
                while(j>=0 && (uint16_t)((int16_t)(keys[ref[j]]&0xffff)>>shift) < kz){ ref[j+1]=ref[j]; j--; }
                ref[j+1]=k;
            }
            for (int i=0;i<N;i++){ if(order[i]!=ref[i]){
                std::printf("FAIL virsort t=%d shift=%d order[%d]: nasm=%d ref=%d\n",t,shift,i,order[i],ref[i]); if(++failures>=20)break; } }
        }
        virsort_shift = 0;
    }

    if (failures == 0) { std::printf("vvis.crosscheck: OK\n"); return 0; }
    std::printf("vvis.crosscheck: %d failure(s)\n", failures);
    return 1;
}
