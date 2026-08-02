// engine_selftest.cpp - cross-checks the ported NASM engine (engine.asm)
// against a C++ reference of the same algorithms, using exact 32-bit integer
// arithmetic. Exercises sqrt, rotate_shape (matrix + apply), n_calc, and the
// radix sort through the MS-x64 shim (engine_selftest.asm).
//
// Exit code 0 = pass; nonzero = mismatch.

#include <cstdint>
#include <cstdio>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <algorithm>

// ---- MS-x64 wrappers into the NASM engine -----------------------------------
extern "C" void ts_set_code32(uint64_t base);
extern "C" int  ts_sqrt(int x);
extern "C" void ts_n_calc(void);
extern "C" void ts_rotate_shape(void);
extern "C" void ts_set_globals(uint32_t shape, uint32_t srot, uint32_t n, uint32_t nrot,
                               uint32_t inc, uint32_t con, uint32_t sort,
                               uint32_t points, uint32_t faces);
extern "C" void ts_set_angles(uint16_t x, uint16_t y, uint16_t z);
extern "C" void ts_set_len(uint32_t v);
extern "C" void ts_sort(void);
extern "C" void ts_set_sortmem(uint32_t mem);

extern "C" uint64_t eng_get_code32();

// ---- helpers ----------------------------------------------------------------
static int fail = 0;
static void check(const char* name, bool ok) {
    std::printf("%-18s %s\n", name, ok ? "PASS" : "FAIL");
    if (!ok) fail++;
}

static uint8_t* arena;
static size_t   arenaUsed = 0;
static uint32_t aalloc(size_t n) {
    uint32_t off = (uint32_t)arenaUsed;
    arenaUsed += (n + 15) & ~15u;
    return off;
}

// ---- reference sqrt (mirror engine.asm) --------------------------------------
static uint32_t refSqrt(uint32_t x) {
    uint32_t e = x;
    uint32_t c = 31;
    while (c && !(x >> c)) c--;          // c = floor(log2(x))  (bsr)
    c >>= 1;
    uint32_t v = x >> c;
    c = v;
    c = (c + e / c) >> 1;
    c = (c + e / c) >> 1;
    c = (c + e / c) >> 1;
    return c;
}

// ---- reference rotation (mirror build_matrix + rotate_shape) ----------------
static int16_t refSinus[1024];
static void buildSinus() {
    for (int i = 0; i < 1024; i++)
        refSinus[i] = (int16_t)std::lround(std::sin(2.0 * 3.14159265358979323846 * i / 1024.0) * 32767.0);
}
struct M3 { int32_t a[9]; };

// exact matrix from the word sine table, mirroring the original 386 arithmetic
// step-by-step (32-bit truncated imul + interleaved sar, NOT an algebraic form)
static M3 refMatrix2(int16_t rx, int16_t ry, int16_t rz) {
    int32_t sx = refSinus[(rx & 1023)], cx = refSinus[((rx + 256) & 1023)];
    int32_t sy = refSinus[(ry & 1023)], cy = refSinus[((ry + 256) & 1023)];
    int32_t sz = refSinus[(rz & 1023)], cz = refSinus[((rz + 256) & 1023)];
    auto mul = [](int32_t a, int32_t b) -> int32_t { return (int32_t)((int64_t)a * (int64_t)b); };
    auto sar = [](int32_t v, int n) -> int32_t { return v >> n; };
    int32_t eax, ebx;
    M3 m;
    eax = mul(cy, cz);                 m.a[0] = sar(eax, 15);              // ob1
    eax = mul(cx, sz);                 ebx = mul(sx, sy);  ebx = sar(ebx, 15);
    ebx = mul(ebx, cz);                ebx = ebx - eax;    m.a[1] = sar(ebx, 15);  // ob2
    eax = mul(sx, sz);                 ebx = mul(cx, sy);  ebx = sar(ebx, 15);
    ebx = mul(ebx, cz);                ebx = ebx + eax;    m.a[2] = sar(ebx, 15);  // ob3
    eax = mul(cy, sz);                 m.a[3] = sar(eax, 15);              // ob4
    eax = mul(cx, cz);                 ebx = mul(sx, sy);  ebx = sar(ebx, 15);
    ebx = mul(ebx, sz);                ebx = ebx + eax;    m.a[4] = sar(ebx, 15);  // ob5
    eax = mul(sx, cz);                 ebx = mul(cx, sy);  ebx = sar(ebx, 15);
    ebx = mul(ebx, sz);                ebx = ebx - eax;    m.a[5] = sar(ebx, 15);  // ob6
    m.a[6] = -sy;                                              // ob7
    m.a[7] = sar(mul(sx, cy), 15);                             // ob8
    m.a[8] = sar(mul(cx, cy), 15);                             // ob9
    return m;
}

static int16_t refRotateX(const M3& m, int16_t x, int16_t y, int16_t z) {
    return (int16_t)(((((int32_t)x * m.a[0]) >> 15) + (((int32_t)y * m.a[1]) >> 15) + (((int32_t)z * m.a[2]) >> 15)) & 0xFFFF);
}
static int16_t refRotateY(const M3& m, int16_t x, int16_t y, int16_t z) {
    return (int16_t)(((((int32_t)x * m.a[3]) >> 15) + (((int32_t)y * m.a[4]) >> 15) + (((int32_t)z * m.a[5]) >> 15)) & 0xFFFF);
}
static int16_t refRotateZ(const M3& m, int16_t x, int16_t y, int16_t z) {
    return (int16_t)(((((int32_t)x * m.a[6]) >> 15) + (((int32_t)y * m.a[7]) >> 15) + (((int32_t)z * m.a[8]) >> 15)) & 0xFFFF);
}

int main() {
    std::printf("engine_selftest: cross-checking ported NASM engine\n");
    buildSinus();

    arena = (uint8_t*)malloc(4 * 1024 * 1024);
    if (!arena) { std::printf("alloc fail\n"); return 2; }
    std::memset(arena, 0, 4 * 1024 * 1024);
    ts_set_code32((uint64_t)(uintptr_t)arena);

    // ---- sqrt ----
    bool okSqrt = true;
    for (uint32_t v = 1; v < 200000; v += 37) {
        int got = ts_sqrt((int)v);
        if ((uint32_t)got != refSqrt(v)) { okSqrt = false; if (v < 200) std::printf("  sqrt(%u): asm %d ref %u\n", v, got, refSqrt(v)); }
    }
    check("sqrt (200k samples)", okSqrt);

    // ---- rotate_shape ----
    // Build a small 5-vertex cube face: verts (3 words each) at shape.
    std::vector<int16_t> verts = {
        -100, -100, -100,
         100, -100, -100,
         100,  100, -100,
        -100,  100, -100,
           0,    0,  200,
    };
    uint32_t shape = aalloc(verts.size() * 2);
    std::memcpy(arena + shape, verts.data(), verts.size() * 2);
    uint32_t srot = aalloc(verts.size() * 2);
    ts_set_globals(shape, srot, 0, 0, 0, 0, 0, (uint32_t)verts.size()/3, 0);
    int16_t rx = 45, ry = 120, rz = 300;
    ts_set_angles((uint16_t)rx, (uint16_t)ry, (uint16_t)rz);
    ts_rotate_shape();

    M3 m = refMatrix2(rx, ry, rz);
    bool okRot = true;
    for (size_t i = 0; i < verts.size() / 3; i++) {
        int16_t* in = verts.data() + i * 3;
        int16_t* out = (int16_t*)(arena + srot + i * 6);
        int16_t ex = refRotateX(m, in[0], in[1], in[2]);
        int16_t ey = refRotateY(m, in[0], in[1], in[2]);
        int16_t ez = refRotateZ(m, in[0], in[1], in[2]);
        if (out[0] != ex || out[1] != ey || out[2] != ez) {
            okRot = false;
            std::printf("  rot v%zu: asm(%d,%d,%d) ref(%d,%d,%d)\n", i, out[0],out[1],out[2], ex,ey,ez);
        }
    }
    check("rotate_shape", okRot);

    // ---- n_calc (on a tetrahedron) ----
    // shape: 4 verts; con: 4 faces (each 3 vert indices)
    std::vector<int16_t> tverts = {
           0,    0,  100,
         100,    0, -100,
        -100,    0, -100,
           0,  150,  200,
    };
    uint16_t tf[4][3] = {
        {0,1,2},
        {0,1,3},
        {0,2,3},
        {1,2,3},
    };
    uint32_t sh2 = aalloc(tverts.size()*2);
    std::memcpy(arena+sh2, tverts.data(), tverts.size()*2);
    uint32_t con2 = aalloc(4*6);
    std::memcpy(arena+con2, tf, sizeof tf);
    uint32_t n2  = aalloc(4*6);
    uint32_t inc2 = aalloc(4*2);
    std::memset(arena+n2, 0, 4*6);
    std::memset(arena+inc2, 0, 4*2);
    ts_set_len(80);       // normal-scale constant (per-part value)
    ts_set_globals(sh2, 0, n2, 0, inc2, con2, 0, 4, 4);
    ts_n_calc();

    // exact C++ reference mirroring the original n_calc step-by-step using its
    // quirky addressing: shape read at byte v*3 (overlaps!), inc write at byte v,
    // then finalize reads inc word at byte v*2, n writes at byte v*3 and
    // finalize reads n words at byte v*6. Raw byte arrays reproduce the overlap.
    {
        std::vector<uint8_t> shb(tverts.size()*2, 0);
        std::memcpy(shb.data(), tverts.data(), tverts.size()*2);
        std::vector<uint8_t> incb(16, 0);       // mirrors inc_addr arena
        std::vector<uint8_t> nab(64, 0);        // mirrors n_addr arena
        auto rdw = [](const std::vector<uint8_t>& p, size_t b) -> int16_t {
            return (int16_t)(uint16_t)(p[b] | (p[b+1] << 8));
        };
        auto wrw = [](std::vector<uint8_t>& p, size_t b, int16_t v) {
            p[b] = (uint8_t)(v & 0xFF); p[b+1] = (uint8_t)((v >> 8) & 0xFF);
        };
        auto mul = [](int32_t a, int32_t b) -> int32_t { return (int32_t)((int64_t)a * (int64_t)b); };
        for (int f = 0; f < 4; f++) {
            int64_t sx[3], sy[3], sz[3];
            for (int k = 0; k < 3; k++) {
                int v = tf[f][k];
                size_t vb = (size_t)v * 3;               // byte v*3 (overlapping!)
                sx[k] = rdw(shb, vb);     sy[k] = rdw(shb, vb+2);   sz[k] = rdw(shb, vb+4);
                sx[k] = (int16_t)sx[k] >> 4;
                sy[k] = (int16_t)sy[k] >> 4;
                sz[k] = (int16_t)sz[k] >> 4;
            }
            int32_t eax, ebx, ebp, n_x, n_y, n_z;
            eax = (int32_t)sy[1] - (int32_t)sy[0]; ebp = (int32_t)sz[2] - (int32_t)sz[0];
            ebx = mul(eax, ebp);
            eax = (int32_t)sy[2] - (int32_t)sy[0]; ebp = (int32_t)sz[1] - (int32_t)sz[0];
            ebx = ebx - mul(eax, ebp); n_x = -ebx;
            eax = (int32_t)sx[1] - (int32_t)sx[0]; ebp = (int32_t)sz[2] - (int32_t)sz[0];
            ebx = mul(eax, ebp);
            eax = (int32_t)sx[2] - (int32_t)sx[0]; ebp = (int32_t)sz[1] - (int32_t)sz[0];
            ebx = ebx - mul(eax, ebp); n_y = ebx;
            eax = (int32_t)sy[1] - (int32_t)sy[0]; ebp = (int32_t)sx[2] - (int32_t)sx[0];
            ebx = mul(eax, ebp);
            eax = (int32_t)sy[2] - (int32_t)sy[0]; ebp = (int32_t)sx[1] - (int32_t)sx[0];
            ebx = ebx - mul(eax, ebp); n_z = -ebx;
            int64_t ss = (int64_t)n_x*n_x + (int64_t)n_y*n_y + (int64_t)n_z*n_z;
            int32_t ecx = (ss != 0) ? (int32_t)refSqrt((uint32_t)ss) : 80;
            int32_t nx = (int32_t)(((int64_t)n_x * 80) / ecx) & 0xFFFF;
            int32_t ny = (int32_t)(((int64_t)n_y * 80) / ecx) & 0xFFFF;
            int32_t nz = (int32_t)(((int64_t)n_z * 80) / ecx) & 0xFFFF;
            for (int k = 0; k < 3; k++) {
                int v = tf[f][k];
                // inc: byte-offset write; n: write at byte v*3, words +0,+2,+4
                wrw(incb, v, (int16_t)(rdw(incb, v) + 1));
                size_t nb = (size_t)v * 3;
                wrw(nab, nb,   (int16_t)(rdw(nab, nb)   + (int16_t)nx));
                wrw(nab, nb+2, (int16_t)(rdw(nab, nb+2) + (int16_t)ny));
                wrw(nab, nb+4, (int16_t)(rdw(nab, nb+4) + (int16_t)nz));
            }
        }
        // finalize: read inc word at byte v*2, divide n words at byte v*6
        for (int v = 0; v < 4; v++) {
            int16_t c = rdw(incb, (size_t)v * 2);
            if (c) {
                size_t nb = (size_t)v * 6;
                wrw(nab, nb,   (int16_t)(rdw(nab, nb)   / c));
                wrw(nab, nb+2, (int16_t)(rdw(nab, nb+2) / c));
                wrw(nab, nb+4, (int16_t)(rdw(nab, nb+4) / c));
            }
        }
        bool okNorm = true;
        for (int i = 0; i < 4; i++) {
            int16_t* n = (int16_t*)(arena + n2);
            if (n[i*3] != rdw(nab, (size_t)i*6) || n[i*3+1] != rdw(nab, (size_t)i*6+2) || n[i*3+2] != rdw(nab, (size_t)i*6+4)) {
                okNorm = false;
                std::printf("  n_calc v%d: asm(%d,%d,%d) ref(%d,%d,%d)\n", i,
                    n[i*3], n[i*3+1], n[i*3+2],
                    rdw(nab, (size_t)i*6), rdw(nab, (size_t)i*6+2), rdw(nab, (size_t)i*6+4));
            }
        }
        check("n_calc", okNorm);
    }

    // ---- sort ----
    static const uint32_t SORTDATA[18] = { 5, 1, 4, 7, 2, 9, 0, 8, 3, 6, 65535, 256, 5, 5, 5, 2, 2, 1 };
    const size_t N = 18;
    uint32_t srt = aalloc(N*4);
    std::memcpy(arena+srt, SORTDATA, N*4);
    // sort_addr points at the array; sort_mem (radix scratch) is in engine;
    // prep_sort isn't wired into the shim, so provide scratch manually:
    // addr_tab lives inside engine.asm globals -> handled via prep_sort normally.
    // For the test we set engine.sort_mem + addr_tab via ts_set_sortmem.
    uint32_t sm = aalloc(1200*16*4);
    ts_set_sortmem(sm);
    // re-do globals with sort addr/faces
    ts_set_globals(0,0,0,0,0,0, srt, 0, (uint32_t)N);
    ts_sort();
    bool okSort = true;
    uint32_t expect[18];
    std::memcpy(expect, SORTDATA, N*4);
    std::sort(&expect[0], &expect[N]);
    uint32_t* out = (uint32_t*)(arena + srt);
    for (size_t i = 0; i < N; i++)
        if (out[i] != expect[i]) { okSort = false; std::printf("  sort[%zu]: asm %u ref %u\n", i, out[i], expect[i]); }
    check("radix sort", okSort);

    std::free(arena);
    std::printf(fail ? "engine_selftest: FAILED\n" : "engine_selftest: PASS\n");
    return fail ? 1 : 0;
}
