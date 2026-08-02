// txtr_selftest.cpp - cross-checks the ported texture-mapped triangle
// rasterizer (txtr.asm tm_face) against a C++ transliteration of the exact
// original integer raster, including 16-bit fixed-point edges and the
// shld-based texel indexing. Output must match byte-for-byte.
//
// Exit code 0 = pass; nonzero = mismatch.

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <vector>

// ---- MS-x64 wrappers into the NASM txtr.asm --------------------------------
extern "C" void  ts_txtr_set_bases(uint64_t tex, uint64_t scr);
extern "C" void  ts_txtr_face(void);
extern "C" void  ts_txtr_set_face(int32_t x1,int32_t y1,uint32_t p1,
                                  int32_t x2,int32_t y2,uint32_t p2,
                                  int32_t x3,int32_t y3,uint32_t p3);

extern "C" {
    extern uint8_t asmScr[320*200];
}

static int fail = 0;
static void check(const char* name, bool ok) {
    std::printf("%-22s %s\n", name, ok ? "PASS" : "FAIL");
    if (!ok) fail++;
}

static uint8_t tex[256*256];

enum { x_min=0, y_min=0, x_max=320, y_max=200 };

// ---- reference: faithful transliteration of TXTR.ASM -----------------------
struct RefCtx {
    int32_t x_1,x_s,y_1,x_2,y_2,x_3,y_3;
    uint16_t p_1[2], p_2[2], p_3[2];
    int32_t dx_1,dy_1,dx_2,dy_2,dy_3;
    int16_t pd_1[2], pd_2[2];
    uint16_t pom, mem[2];
};
static uint8_t refScr[320*200];

static void refFace(int32_t x1,int32_t y1,uint32_t p1,
                    int32_t x2,int32_t y2,uint32_t p2,
                    int32_t x3,int32_t y3,uint32_t p3) {
    RefCtx c;
    c.x_1=x1; c.y_1=y1; c.x_2=x2; c.y_2=y2; c.x_3=x3; c.y_3=y3;
    c.p_1[0]=(uint16_t)(p1&0xFFFF); c.p_1[1]=(uint16_t)((p1>>16)&0xFFFF);
    c.p_2[0]=(uint16_t)(p2&0xFFFF); c.p_2[1]=(uint16_t)((p2>>16)&0xFFFF);
    c.p_3[0]=(uint16_t)(p3&0xFFFF); c.p_3[1]=(uint16_t)((p3>>16)&0xFFFF);
    c.pom=0;

    // sort 3 by y with swaps (mirror asm)
    auto sw = [](int32_t&a,int32_t&b){ int32_t t=a; a=b; b=t; };
    if (c.y_1>c.y_2) { sw(c.x_1,c.x_2); sw(c.y_1,c.y_2); std::swap(c.p_1,c.p_2); }
    if (c.y_1>c.y_3) { sw(c.x_1,c.x_3); sw(c.y_1,c.y_3); std::swap(c.p_1,c.p_3); }
    if (c.y_2>c.y_3) { sw(c.x_2,c.x_3); sw(c.y_2,c.y_3); std::swap(c.p_2,c.p_3); }

    if ((int16_t)c.y_1 >= y_max-1) return;
    if ((int16_t)c.y_3 <  y_min)   return;

    c.dy_1 = c.y_2 - c.y_1; if (!c.dy_1){ c.dy_1=1; c.pom=1; }
    c.dy_2 = c.y_3 - c.y_2; if (!c.dy_2) c.dy_2=1;
    c.dy_3 = c.y_3 - c.y_1; if (!c.dy_3) c.dy_3=1;

    c.dx_2 = ((c.x_3 - c.x_1) << 16) / c.dy_3;
    c.pd_1[0] = (int16_t)(((int32_t)(uint16_t)c.p_3[0] - (int32_t)(uint16_t)c.p_1[0]) / c.dy_3);
    c.pd_2[0] = (int16_t)(((int32_t)(uint16_t)c.p_3[1] - (int32_t)(uint16_t)c.p_1[1]) / c.dy_3);

    if (c.pom == 1) {
        c.pom = (uint16_t)(int16_t)c.x_1;
        c.x_s = c.x_1 << 16;
        c.x_1 = c.x_2 << 16;
        c.mem[0] = c.p_1[0];
        c.mem[1] = c.p_1[1];
    } else {
        c.dx_1 = ((c.x_2 - c.x_1) << 16) / c.dy_1;
        // eax=dy_1; imul dx_2; shr eax,16; add eax,x_1; mov pom,ax
        int64_t t = (int32_t)((uint32_t)((int64_t)c.dy_1 * (int64_t)c.dx_2)); // low32
        c.pom = (uint16_t)(int16_t)((int32_t)((uint32_t)t >> 16) + c.x_1);
        // mem[0]= eax=dy_1; imul pd_1(dword, high word 0) ; add ax,p_1[0]; low16
        int32_t t1 = (int32_t)((uint32_t)((int64_t)c.dy_1 * (int64_t)(uint32_t)(uint16_t)c.pd_1[0]) & 0xFFFFFFFFu);
        c.mem[0] = (uint16_t)((uint16_t)t1 + c.p_1[0]);
        int32_t t2 = (int32_t)((uint32_t)((int64_t)c.dy_1 * (int64_t)(uint32_t)(uint16_t)c.pd_2[0]) & 0xFFFFFFFFu);
        c.mem[1] = (uint16_t)((uint16_t)t2 + c.p_1[1]);
        c.x_1 = c.x_1 << 16;
        c.x_s = c.x_1;
    }

    c.y_1 *= 320;
    c.y_2 *= 320;
    std::swap(c.p_1[0], c.p_1[1]);   // mov ax,p_1; xchg p_1+2,ax; mov p_1,ax

    if (c.y_3 >= y_max-1) { c.y_3 -= y_max-1; c.dy_3 -= c.y_3; }

    // bx = (uint16)x_2 - (uint16)pom  (16-bit sub, then signed 16-bit)
    int32_t bx = (int32_t)(int16_t)(uint16_t)((uint16_t)(uint32_t)(c.x_2 & 0xFFFF) - (uint16_t)c.pom);
    if (bx == 0) bx = 1;
    if (bx < 0) {
        bx = -bx;   // asm: neg bx
        // left side: esi = (dv<<16) | du from p_2 - mem
        int16_t s1 = (int16_t)(((int32_t)(uint16_t)c.p_2[0] - (int32_t)(uint16_t)c.mem[0]) / bx);
        int16_t s2 = (int16_t)(((int32_t)(uint16_t)c.p_2[1] - (int32_t)(uint16_t)c.mem[1]) / bx);
        // asm: mov si,ax (s1); shl esi,16; mov si,ax (s2)  -> esi = (s1<<16)|s2
        int32_t esi = (int32_t)(((uint32_t)(uint16_t)s1 << 16) | (uint32_t)(uint16_t)s2);

        for (;;) {
            int32_t ebx = c.y_1;
            if (c.y_2 == ebx)
                c.dx_1 = ((c.x_3 - c.x_2) << 16) / c.dy_2;
            if (ebx < y_min*320) goto go1;
            {   int32_t di = (int16_t)(uint16_t)((uint32_t)c.x_1 >> 16);
                int32_t cx = (int16_t)(uint16_t)((uint32_t)c.x_s >> 16);
                if (di >= x_max) goto go1;
                if (cx <  x_min) goto go1;
                int32_t edx = (int32_t)(uint32_t)((uint32_t)(uint16_t)c.p_1[0] | ((uint32_t)(uint16_t)c.p_1[1] << 16));
                if (cx >= x_max-1) { do { edx += esi; cx--; } while (cx > x_max-1); }
                if (di < x_min) di = x_min;
                cx -= di; if (cx < 0) goto go1;
                di += cx;
                di += (uint16_t)((uint32_t)c.y_1 & 0xFFFF);
                cx++;
                do {
                    // mov bl,dh; shld ebx,edx,8 -> bx = (edx[15:8]<<8) | edx[31:24]
                    uint32_t idx = ((uint32_t)edx & 0xFF00) | (((uint32_t)edx >> 24) & 0xFF);
                    refScr[di] = tex[idx];
                    di--;
                    edx += esi;
                    cx--;
                } while (cx);
            }
        go1:
            c.x_1 += c.dx_1; c.x_s += c.dx_2;
            c.p_1[0] = (uint16_t)(c.p_1[0] + c.pd_2[0]);
            c.p_1[1] = (uint16_t)(c.p_1[1] + c.pd_1[0]);
            c.y_1 += 320;
            if (--c.dy_3 == 0) break;
        }
    } else {
        // right side
        int16_t s1 = (int16_t)(((int32_t)(uint16_t)c.p_2[0] - (int32_t)(uint16_t)c.mem[0]) / bx);
        int16_t s2 = (int16_t)(((int32_t)(uint16_t)c.p_2[1] - (int32_t)(uint16_t)c.mem[1]) / bx);
        // asm: mov si,ax (s1); shl esi,16; mov si,ax (s2)  -> esi = (s1<<16)|s2
        int32_t esi = (int32_t)(((uint32_t)(uint16_t)s1 << 16) | (uint32_t)(uint16_t)s2);
        for (;;) {
            int32_t ebx = c.y_1;
            if (c.y_2 == ebx)
                c.dx_1 = ((c.x_3 - c.x_2) << 16) / c.dy_2;
            if (ebx < y_min*320) goto go2;
            {   int32_t di = (int16_t)(uint16_t)((uint32_t)c.x_s >> 16);
                int32_t cx = (int16_t)(uint16_t)((uint32_t)c.x_1 >> 16);
                if (di >= x_max) goto go2;
                if (cx <  x_min) goto go2;
                int32_t edx = (int32_t)(uint32_t)((uint32_t)(uint16_t)c.p_1[0] | ((uint32_t)(uint16_t)c.p_1[1] << 16));
                if (di < x_min) { do { edx += esi; di++; } while (di < x_min); }
                if (cx >= x_max-1) cx = x_max-1;
                cx -= di; if (cx < 0) goto go2;
                di += (uint16_t)((uint32_t)c.y_1 & 0xFFFF);
                cx++;
                do {
                    // mov bl,dh; shld ebx,edx,8 -> bx = (edx[15:8]<<8) | edx[31:24]
                    uint32_t idx = ((uint32_t)edx & 0xFF00) | (((uint32_t)edx >> 24) & 0xFF);
                    refScr[di] = tex[idx];
                    di++;
                    edx += esi;
                    cx--;
                } while (cx);
            }
        go2:
            c.x_1 += c.dx_1; c.x_s += c.dx_2;
            c.p_1[0] = (uint16_t)(c.p_1[0] + c.pd_2[0]);
            c.p_1[1] = (uint16_t)(c.p_1[1] + c.pd_1[0]);
            c.y_1 += 320;
            if (--c.dy_3 == 0) break;
        }
    }
}

int main() {
    std::printf("txtr_selftest: cross-checking ported NASM tm_face\n");
    std::memset(refScr, 0, sizeof refScr);

    for (int ty = 0; ty < 256; ty++)
        for (int tx = 0; tx < 256; tx++)
            tex[ty*256 + tx] = (uint8_t)(((ty>>3) + (tx>>3)) & 1) ? 10 : 200;

    ts_txtr_set_bases((uint64_t)(uintptr_t)tex, (uint64_t)(uintptr_t)asmScr);

    struct Tri { int32_t x1,y1,x2,y2,x3,y3; uint32_t p1,p2,p3; };
    std::vector<Tri> tris = {
        { 10, 10, 100, 10, 50, 80, 0x00100000, 0x00400080, 0x00800100 },
        { 300, 190, 320, 190, 310, 150, 0x00000010, 0x00000080, 0x00008000 },
        { -20, 50, 300, 50, 140, 190, 0x01000200, 0x02000300, 0x04000500 },
        { 100, 5, 200, 120, 50, 150, 0x00110011, 0x00220022, 0x00330033 },
        { 50, 100, 150, 40, 250, 150, 0x0F0F0000, 0x0F0F0080, 0x0F0F00FF },
        { 30, 30, 31, 130, 29, 90, 0x00000000, 0x000000FF, 0x0000FF00 },
    };

    // geometry-only coverage check first: solid texture -> any diff is coverage
    {
        uint8_t solidTex[256*256];
        std::memset(solidTex, 123, sizeof solidTex);
        ts_txtr_set_bases((uint64_t)(uintptr_t)solidTex, (uint64_t)(uintptr_t)asmScr);
        bool covOk = true;
        for (size_t t = 0; t < tris.size(); t++) {
            std::memset(asmScr, 0, sizeof asmScr);
            std::memset(refScr, 0, sizeof refScr);
            Tri tr = tris[t];
            ts_txtr_set_face(tr.x1,tr.y1,tr.p1,tr.x2,tr.y2,tr.p2,tr.x3,tr.y3,tr.p3);
            ts_txtr_face();
            refFace(tr.x1,tr.y1,tr.p1,tr.x2,tr.y2,tr.p2,tr.x3,tr.y3,tr.p3);
            for (int y = 0; y < 200; y++) for (int x = 0; x < 320; x++)
                if ((asmScr[y*320+x]!=0) != (refScr[y*320+x]!=0)) covOk = false;
        }
        check("tm_face coverage", covOk);
    }
    ts_txtr_set_bases((uint64_t)(uintptr_t)tex, (uint64_t)(uintptr_t)asmScr);

    for (size_t t = 0; t < tris.size(); t++) {
        std::memset(asmScr, 0, sizeof asmScr);
        std::memset(refScr, 0, sizeof refScr);

        ts_txtr_set_face(tris[t].x1, tris[t].y1, tris[t].p1,
                         tris[t].x2, tris[t].y2, tris[t].p2,
                         tris[t].x3, tris[t].y3, tris[t].p3);
        ts_txtr_face();
        refFace(tris[t].x1, tris[t].y1, tris[t].p1,
                tris[t].x2, tris[t].y2, tris[t].p2,
                tris[t].x3, tris[t].y3, tris[t].p3);

        long diff = 0;
        for (int y = 0; y < 200; y++)
            for (int x = 0; x < 320; x++)
                if (asmScr[y*320+x] != refScr[y*320+x]) diff++;
        if (diff) {
            fail++;
            std::printf("  tri%zu: %ld differing pixels (of %d)\n", t, diff, 320*200);
            std::printf("    first mismatches:\n");
            int shown = 0;
            for (int y = 0; y < 200 && shown < 8; y++)
                for (int x = 0; x < 320 && shown < 8; x++)
                    if (asmScr[y*320+x] != refScr[y*320+x]) {
                        std::printf("      y=%d x=%d asm=%u ref=%u\n", y, x, asmScr[y*320+x], refScr[y*320+x]);
                        shown++;
                    }
        }
        char name[32];
        std::snprintf(name, sizeof name, "tm_face tri%zu", t);
        check(name, diff == 0);
    }

    std::printf(fail ? "txtr_selftest: FAILED\n" : "txtr_selftest: PASS\n");
    return fail ? 1 : 0;
}
