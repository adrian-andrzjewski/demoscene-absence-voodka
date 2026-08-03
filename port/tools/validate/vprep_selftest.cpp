// vprep_selftest.cpp - CTest for the VR object-prepare pipeline (vprep.asm
// PrepareObjectVirtual). Verifies copy, angle setup, rotation, world+camera
// offset, and transform by comparing the object's working vertexes against a
// reference built from the ALREADY-verified rotate/transform primitives
// (vk_prep_rot_matrix, vk_mrotate, vk_transform) - so this isolates vprep's
// own sequencing/copy/offset logic.
//
// Returns 0 on success, non-zero on any mismatch.

#include <cstdint>
#include <cstring>
#include <cstdio>
#include <cstdlib>

extern "C" void vk_make_camera_matrix(int ax, int ay, int az);
extern "C" int32_t cam_cameraX, cam_cameraY, cam_cameraZ;
extern "C" void vk_prepare_object(uint8_t* base, uint32_t objOff,
                                  const int32_t* worldXYZ, const int32_t* worldAngles);
extern "C" void vk_prep_rot_matrix(int ax, int ay, int az);
extern "C" void vk_mrotate(int32_t* v, int n);
extern "C" void vk_mrotate_normals(int32_t* v, int n);
extern "C" void vk_transform(int32_t* v, int n);

static int failures = 0;
static void ck(const char* what, int32_t got, int32_t want){
    if (got != want){ std::printf("FAIL %s: %d != %d\n", what, got, want); if(++failures>25) exit(1); }
}

int main(){
    srand(555);
    const int NV = 12, NTRIALS = 3000;
    // array offsets in the test base
    const uint32_t OBJ = 0x100, SRC = 0x200, WORK = 0x400, WER = 0x600, CW = 0x800;

    for (int t = 0; t < NTRIALS && failures < 20; t++){
        int ax = rand()&1023, ay = rand()&1023, az = rand()&1023;
        int type = (t & 1) ? 2 : 0;                 // alternate PHONG
        vk_make_camera_matrix(ax, ay, az);
        int32_t cxx=(int32_t)((rand()%4001)-2000), cyy=(int32_t)((rand()%4001)-2000), czz=(int32_t)((rand()%4001)-2000);
        cam_cameraX=cxx; cam_cameraY=cyy; cam_cameraZ=czz;
        int32_t wx=(int32_t)((rand()%2001)-1000), wy=(int32_t)((rand()%2001)-1000), wz=(int32_t)((rand()%2001)-1000);
        int32_t worldXYZ[3]={wx,wy,wz};
        int32_t ang[3]={(int32_t)(rand()&1023),(int32_t)(rand()&1023),(int32_t)(rand()&1023)};

        uint8_t* base=(uint8_t*)malloc(1<<21); memset(base,0,1<<21);
        // place arrays
        int32_t* src  =(int32_t*)(base+SRC); int32_t* work=(int32_t*)(base+WORK);
        int32_t* wer  =(int32_t*)(base+WER); int32_t* cw   =(int32_t*)(base+CW);
        int32_t* obj  =(int32_t*)(base+OBJ);
        obj[0]=type; obj[1]=NV; obj[9]=SRC; obj[13]=WORK; obj[15]=WER; obj[16]=CW;
        // note struct offsets (dwords): +0 type +4 nov +36 vertexes +52 wersory +60 copy +64 cw
        // -> dword indices: 0,1, 9(SRC),13(WER),15(WORK),16(CW)
        obj[9]=SRC; obj[13]=WER; obj[15]=WORK; obj[16]=CW;
        for (int i=0;i<NV*3;i++) src[i]=(int32_t)((rand()%4001)-2000);
        for (int i=0;i<NV*3;i++) wer[i]=(int32_t)((rand()%2001)-1000);

        // reference: rotate(src) -> ref, world/camera, transform
        int32_t ref[NV*3]; memcpy(ref, src, sizeof ref);
        vk_prep_rot_matrix(ang[0],ang[1],ang[2]);
        vk_mrotate(ref, NV);
        for (int i=0;i<NV*3;i++){
            int32_t off = (i%3)==0?cxx:((i%3)==1?cyy:czz);
            int32_t w0  = (i%3)==0?wx:((i%3)==1?wy:wz);
            ref[i] = ref[i] + w0 - off;
        }
        vk_transform(ref, NV);

        vk_prepare_object(base, OBJ, worldXYZ, ang);

        for (int i=0;i<NV*3;i++) ck("work", work[i], ref[i]);

        if (type==2){
            // normals are rotated x,y only (mrotate_normals), like vk_rotate_object
            int32_t cr[NV*3]; memcpy(cr, wer, sizeof cr);
            vk_prep_rot_matrix(ang[0],ang[1],ang[2]);
            vk_mrotate_normals(cr, NV);
            for (int i=0;i<NV*3;i++) ck("cw", cw[i], cr[i]);
        }
        free(base);
    }
    if (failures==0){ std::printf("vprep.crosscheck: OK\n"); return 0; }
    std::printf("vprep.crosscheck: %d failure(s)\n", failures);
    return 1;
}
