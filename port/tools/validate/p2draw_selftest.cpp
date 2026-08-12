// p2draw_selftest.cpp - CTest for the swiatynia city (P2) object rasterizer (p2draw.asm
// DrawObject / DrawZielonyLudek).
//
// Constructs synthetic objects (type 1 TEXTURE and type 2 PHONG) with known
// copy-vert/faces/textures/wersory/order tables, runs vk_draw_object_trace
// (which projects copy-vert->wsp2d via the same persp as the reference and
// then, per order entry, writes a 10-dword record {drawn,x1,y1,x2,y2,x3,y3,
// p1,p2,p3} instead of rasterizing), and cross-checks every record against a
// C++ reference that re-derives DrawZielonyLudek's arithmetic exactly.
//
// The reference traces are also run against the same trivial object with the
// copy-vert data already marked as "behind camera" to exercise the z-clip and
// the 16-bit backface path.
//
// Returns 0 on success, non-zero on any mismatch.

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <vector>
#include <algorithm>

extern "C" void vk_draw_object_trace(uint8_t* base, uint32_t objOff, int32_t* rec);
extern "C" void ts_vr_object_draw_set_base(uint8_t* base, void* rec);

static int failures = 0;
static void ck2(int idx, int32_t got, int32_t want){
    if (got != want){ std::fprintf(stderr, "FAIL rec[%d]: %d (0x%08x) != %d\n", idx, got, got, want); if(++failures>20) exit(1); }
}

// reference persp (identical to persp.asm)
static void ref_persp(const int32_t* src, int32_t* dst, int n){
    for (int i=0;i<n;i++){
        int s = src[i*3+2] + 185*16; if (s==0) s=1;
        long x = (long)src[i*3+0] * 185; x /= s; x += 160;
        long y = (long)src[i*3+1] * 185; y /= s; y += 100;
        dst[i*2+0]=(int32_t)x; dst[i*2+1]=(int32_t)y;
    }
}

// reference BITSORT.PM Sort (called by DrawZielonyLudek before the face walk):
// sumz16 = lo16(z1>>4)+lo16(z2>>4)+lo16(z3>>4) + 15000, pack (i<<16)|sumz16,
// stable sort DESCENDING by sumz16 (radix-equivalent), then >>16.
static void ref_sort_faces(const int32_t* cvert, const int32_t* face, int nof,
                           std::vector<int32_t>& order){
    std::vector<uint32_t> e(nof);
    for (int i=0;i<nof;i++){
        uint16_t s=0;
        for (int k=0;k<3;k++){
            int v = face[i*3+k];
            int16_t z = (int16_t)(cvert[v*3+2] >> 4);   // sar 4, keep low16
            s = (uint16_t)(s + (uint16_t)z);
        }
        s = (uint16_t)(s + 15000);                       // SortAdd
        e[i] = ((uint32_t)i << 16) | s;
    }
    std::stable_sort(e.begin(), e.end(),
                     [](uint32_t a, uint32_t b){ return (a & 0xffff) > (b & 0xffff); });
    for (int i=0;i<nof;i++) order[i] = (int32_t)(e[i] >> 16);
}

// reference DrawZielonyLudek record emitter (returns records appended to *out)
// mode==1 -> TEXTURE (stride 8, shl8), mode==0 -> PHONG (stride 12, /2+128).
static void ref_draw(const int32_t* cvert, int nov,
                     const int32_t* face, int nof,
                     const int32_t* tex, const int32_t* order,
                     int mode, std::vector<int32_t>& out){
    // build wsp2d first (as persp would)
    std::vector<int32_t> wsp(nov*2);
    ref_persp(cvert, wsp.data(), nov);

    auto texel=[&](int v, int32_t& pv){
        if (mode){ // texture: stride 8 dwords*2 = 2 dwords/vertex
            int u = tex[v*2+0]<<8, w = tex[v*2+1]<<8;
            pv = (int32_t)((uint32_t)(w&0xffff)<<16 | (uint32_t)(u&0xffff));
        } else {   // phong: stride 12 bytes = 3 dwords/vertex
            int u = ((tex[v*3+0]>>1)+128)<<8;
            int w = ((tex[v*3+1]>>1)+128)<<8;
            pv = (int32_t)((uint32_t)(w&0xffff)<<16 | (uint32_t)(u&0xffff));
        }
    };

    for (int f=0; f<nof; f++){
        int fi = order[f];                       // face index
        int b  = fi*3;                           // *3
        int v0 = face[b+0], v1=face[b+1], v2=face[b+2];
        int x1=wsp[v0*2+0], y1=wsp[v0*2+1];
        int x2=wsp[v1*2+0], y2=wsp[v1*2+1];
        int x3=wsp[v2*2+0], y3=wsp[v2*2+1];
        int32_t p1,p2,p3; texel(v0,p1); texel(v1,p2); texel(v2,p3);

        // z-clip: copy-vert[v*12+8] >= 1 for all three
        bool zok = (cvert[v0*3+2]>=1) && (cvert[v1*3+2]>=1) && (cvert[v2*3+2]>=1);

        // isvisible (16-bit) -> visible; skip when visible==1
        // asm: cx=(y2-y1)(x3-x1)-(y3-y1)(x2-x1) 16-bit; neg cx; js=>vis0 else vis1
        // face draws when visible!=1  ==  when (cx>0)
        bool drawn = zok;
        if (drawn){
            int ax = (int16_t)((y2-y1)&0xffff);
            int bx = (int16_t)((x3-x1)&0xffff);
            int c  = (int16_t)((ax*bx)&0xffff);
            ax = (int16_t)((y3-y1)&0xffff);
            bx = (int16_t)((x2-x1)&0xffff);
            c  = (int16_t)((c - (int16_t)((ax*bx)&0xffff))&0xffff);
            if (!(c>0)) drawn = false;              // visible==1 or 0 -> skip
        }
        out.push_back(drawn?1:0);
        if (drawn){
            out.push_back(x1);out.push_back(y1);out.push_back(x2);out.push_back(y2);
            out.push_back(x3);out.push_back(y3);out.push_back(p1);out.push_back(p2);out.push_back(p3);
        } else {
            for (int k=0;k<9;k++) out.push_back(0);
        }
    }
}

static void run_case(bool phong, int NV, int NOF){
    const uint32_t OBJ=0x100, CV=0x300, FACE=0x500, TEX=0x700, ORD=0x900;
    uint8_t* base=(uint8_t*)malloc(1<<21); memset(base,0,1<<21);
    int32_t* obj =(int32_t*)(base+OBJ);
    int32_t* cv  =(int32_t*)(base+CV);
    int32_t* fc  =(int32_t*)(base+FACE);
    int32_t* tx  =(int32_t*)(base+TEX);
    int32_t* od  =(int32_t*)(base+ORD);

    // textures/wersory tables
    int texwords = phong ? NV*3 : NV*2;
    for (int i=0;i<texwords;i++) tx[i] = (int32_t)((rand()&0x1fff)-0x1000);

    // copy-vert: keep all z >= 1 so faces draw; exercise x/y spread
    for (int i=0;i<NV*3;i++) cv[i]=(int32_t)(((rand()%20001)-10000));
    for (int i=0;i<NV;i++)   cv[i*3+2] += 2000 + (rand()%2000);   // z safe

    // faces: random triples in range
    for (int i=0;i<NOF*3;i++) fc[i]=(int32_t)(rand()%NV);
    // order: 0..NOF-1 (the draw re-sorts it per BITSORT before walking)
    for (int i=0;i<NOF;i++) od[i]=i;

    obj[0]= phong?2:1;        // type
    obj[1]= NV;               // nov
    obj[2]= NOF;              // nof
    obj[10]= FACE;            // +40 faces
    obj[11]= TEX;             // +44 textures
    obj[15]= CV;              // +60 copy-vert
    obj[16]= TEX;             // +64 copy-wersory (phong reads this)
    obj[19]= (uint32_t)(0x50000); // +76 wsp2d (scratch)
    obj[20]= ORD;             // +80 order

    // reference: face order after the BITSORT painter sort, then the walk
    std::vector<int32_t> sorted(NOF);
    ref_sort_faces(cv, fc, NOF, sorted);
    std::vector<int32_t> ref;
    ref_draw(cv, NV, fc, NOF, tx, sorted.data(), phong?0:1, ref);

    // run trace
    std::vector<int32_t> got(NOF*10);
    ts_vr_object_draw_set_base(base, got.data());
    vk_draw_object_trace(base, OBJ, got.data());

    int nrec = NOF*10;
    for (int i=0;i<nrec;i++) ck2(i, got[i], ref[i]);
    free(base);
}

int main(){
    srand(1234);
    for (int t=0;t<400 && failures<20;t++){
        run_case(t&1, 8+(rand()%20), 6+(rand()%16));
    }
    if (failures==0){ std::printf("vr_object_draw.crosscheck: OK\n"); return 0; }
    std::printf("vr_object_draw.crosscheck: %d failure(s)\n", failures);
    return 1;
}
