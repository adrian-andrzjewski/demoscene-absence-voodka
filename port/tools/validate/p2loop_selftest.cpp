// p2loop_selftest.cpp - CTest for the swiatynia city (P2) per-frame render loop (p2loop.asm
// vk_vr_world_render_frame = CalculateVisiblating -> VirSort -> WorldKol walk ->
// prepare/draw dispatch).
//
// Builds a synthetic World record table (48B records: +0 visible, +4 X, +8 Y,
// +12 Z, +16 obj#, +44 type), an object-offset table, a type->texture
// selector table, sets the camera (vk_make_camera_matrix + cam_cameraX/Y/Z),
// then runs vk_vr_world_render_frame in TRACE mode and compares the emitted
// { drawn, recordIndex, objNumber } stream against a C++ reference that
// re-derives the same visibility gate and painter order.
//
// The visibility z and the painter sort are computed identically to
// vk_calc_visibility/vk_virsort (camera-space z via cam_matrix, stable low16
// key sort DESCENDING far->near, like VirSort's 15->0 bucket gather).
//
// Returns 0 on success, non-zero on any mismatch.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

extern "C" void vk_make_camera_matrix(int ax,int ay,int az);
extern "C" int32_t cam_matrix[16];
extern "C" int32_t cam_cameraX, cam_cameraY, cam_cameraZ;
extern "C" void vk_vr_world_render_frame(uint8_t* base, const int32_t* world, int count,
                                   int32_t* worldZet, int32_t* worldKol,
                                   const uint32_t* objects, const uint16_t* textury,
                                   int32_t* trace);
extern "C" int32_t virsort_shift;

static int failures = 0;
static void ck(const char* w, int32_t got, int32_t want){
    if (got != want){ std::printf("FAIL %s: %d != %d\n", w, got, want); if(++failures>25) exit(1); }
}
static inline int32_t shrd15(int32_t a, int32_t b){ return (int32_t)(((uint64_t)((int64_t)a*b))>>15); }

// reference: camera-space z of a World record (X=+4,Y=+8,Z=+12)
static int32_t ref_z(const int32_t* rec){
    int32_t z = shrd15(rec[1]-cam_cameraX, cam_matrix[2]/*m13*/);
    z += shrd15(rec[2]-cam_cameraY, cam_matrix[6]/*m23*/);
    z += shrd15(rec[3]-cam_cameraZ, cam_matrix[10]/*m33*/);
    return z;
}

static void run_case(){
    srand(9981);
    for (int trial=0; trial<300 && failures<25; trial++){
        int n = 4 + (rand()%40);
        int NV = 8 + (rand()%20);
        const uint32_t REC = 0x300;
        const uint32_t OBJ = 0x4000;

        vk_make_camera_matrix(rand()&1023, rand()&1023, rand()&1023);
        cam_cameraX=(int32_t)((rand()%8001)-4000);
        cam_cameraY=(int32_t)((rand()%8001)-4000);
        cam_cameraZ=(int32_t)((rand()%8001)-4000);

        uint8_t* base=(uint8_t*)malloc(1<<21); memset(base,0,1<<21);
        int32_t* world =(int32_t*)(base+REC);
        int32_t* worldZet = (int32_t*)(base+0x2000);
        int32_t* worldKol = (int32_t*)(base+0x3000);
        // object offset table (1 per loaded obj; obj# indexes it)
        uint32_t* objects = (uint32_t*)(base+OBJ);
        uint16_t* textury = (uint16_t*)(base+OBJ+0x400);
        uint32_t* zet      = (uint32_t*)(base+REC + n*12);

        // build world records (visible field initially arbitrary; we compute
        // the real gate in the reference)
        for (int i=0;i<n;i++){
            int32_t* rec = world + i*12;
            rec[0]= (rand()&1);      // "visible" (overwritten by the loop)
            rec[1]=(int32_t)((rand()%20001)-10000);  // X
            rec[2]=(int32_t)((rand()%20001)-10000);  // Y
            rec[3]=(int32_t)((rand()%20001)-10000);  // Z
            rec[4]= i % NV;          // obj#
            rec[11]=(int32_t)(rand()%8) - 0;         // type >=0
        }
        // textury: type -> selector (word)
        for (int i=0;i<16;i++) textury[i]=(uint16_t)(1+i);
        // objects table: distinct offsets
        for (int i=0;i<NV;i++) objects[i]=0x8000 + (uint32_t)(i*200);

        // ---- reference: compute z, gate, painter order ----
        std::vector<int32_t> zr(n);
        std::vector<int8_t> visr(n);
        for (int i=0;i<n;i++){
            zr[i]=ref_z(world+i*12);
            visr[i]=(zr[i]>=1)?1:0;
        }
        // write visible gate back into world records (matches loop)
        for (int i=0;i<n;i++) world[i*12+0]=visr[i];
        // stable insertion sort of indices by low16 key, DESCENDING (far->near);
        // key=(uint16)((int16)low16(z)>>virsort_shift), matching VirSort
        std::vector<int> order(n); for(int i=0;i<n;i++) order[i]=i;
        for (int i=1;i<n;i++){
            int key=order[i];
            uint16_t kz=(uint16_t)((int16_t)(zr[key]&0xffff)>>virsort_shift); int j=i-1;
            while(j>=0 && (uint16_t)((int16_t)(zr[order[j]]&0xffff)>>virsort_shift) < kz){ order[j+1]=order[j]; j--; }
            order[j+1]=key;
        }
        // ---- expected trace stream ----
        std::vector<int32_t> eref;
        for (int k=0;k<n;k++){
            int idx=order[k];
            bool vis = world[idx*12+0]!=0;
            eref.push_back(vis?1:0);
            eref.push_back(idx);
            eref.push_back(vis? world[idx*12+4] : 0);
        }

        // ---- run port ----
        std::vector<int32_t> got(n*3);
        vk_vr_world_render_frame(base, world, n, worldZet, worldKol, objects, textury, got.data());

        for (int i=0;i<n*3;i++) ck("loop", got[i], eref[i]);
        free(base);
    }
}

int main(){
    virsort_shift = 0;   // swiatynia city (P2) mode (torus ustep village (P5) would be 4)
    // also exercise the zero-count / all-invisible edge: n=1 behind camera
    {
        srand(7);
        const uint32_t REC=0x300;
        uint8_t* base=(uint8_t*)malloc(1<<21); memset(base,0,1<<21);
        int32_t* world=(int32_t*)(base+REC);
        int32_t* zet=(int32_t*)(base+0x2000);
        int32_t* kol=(int32_t*)(base+0x3000);
        uint32_t objects[2]={0x8000,0x8200};
        uint16_t textury[4]={1,2,3,4};
        int32_t got[3]={-1,-1,-1};
        world[0]=0; world[1]=0;world[2]=0;world[3]=-100;world[4]=1; world[11]=3;
        vk_vr_world_render_frame(base, world, 1, zet, kol, objects, textury, got);
        ck("edge.drawn", got[0], 0);
        ck("edge.idx", got[1], 0);
        ck("edge.obj", got[2], 0);
        free(base);
    }
    run_case();
    if (failures==0){ std::printf("vr_world_loop.crosscheck: OK\n"); return 0; }
    std::printf("vr_world_loop.crosscheck: %d failure(s)\n", failures);
    return 1;
}
