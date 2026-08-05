// v3d_crosscheck.cpp - CTest decoding the real .V3D/.V3M assets from
// CODE/LINKER/DANE with the actual ported loader (loader.asm vk_load_object).
//
// Format (OBJECTS.PM Load_Object): +0 type(1=TEX,2=PHONG), +4 nov, +8 nof,
// +12..+32 adders, +36 vertexes(nov*3 dd), faces(nof*3 dd), then a PER-VERTEX
// UV block (nov*2 dd = nov*8 bytes; drawn via [uv + vidx*8], OBJECTS.PM:189-194;
// hex-proven by WALL.V3D: 140 = 36 + 4*12 + 2*12 + 4*8). The block is present
// in PHONG files too (filled with exporter leftovers) but only read for TEX.
// .V3M is the same blob minus the 36-byte header (P5 morph target).
//
// Checks: header sanity + minimum size, then the ASM load: struct fields,
// data offsets, and the in-place x16 vertex scale.
// Returns 0 on success.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

extern "C" void vk_load_object(uint8_t* base, uint32_t fileOff, uint16_t texSel);
extern "C" uint32_t lo_objects[10];
extern "C" uint32_t lo_number;
extern "C" uint32_t lo_bump;

#ifndef VOODKA_REPO_ROOT
#define VOODKA_REPO_ROOT "."
#endif

static int failures = 0;
static void ck(const char* what, long got, long want) {
    if (got != want) {
        std::printf("FAIL %s: %ld != %ld\n", what, got, want);
        if (++failures > 20) { std::printf("too many failures\n"); exit(1); }
    }
}

static std::vector<uint8_t> readFile(const std::string& path) {
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) { std::printf("FAIL cannot open %s\n", path.c_str()); failures++; return {}; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> d((size_t)sz);
    if (fread(d.data(), 1, (size_t)sz, f) != (size_t)sz) { fclose(f); std::printf("FAIL read %s\n", path.c_str()); failures++; return {}; }
    fclose(f);
    return d;
}

static void check_v3d(const char* dane, const char* name) {
    char tag[160];
    std::snprintf(tag, sizeof tag, "%s", name);
    std::string path = std::string(dane) + "\\" + name;
    std::vector<uint8_t> d = readFile(path);
    if (d.empty()) return;

    const int32_t* h = (const int32_t*)d.data();
    int32_t type = h[0], nov = h[1], nof = h[2];
    ck("v3d type in {1,2}", type == 1 || type == 2, 1);
    ck("v3d nov sane", nov > 0 && nov < 4096, 1);
    ck("v3d nof sane", nof > 0 && nof < 8192, 1);
    long need = 36 + (long)nov * 12 + (long)nof * 12 + (type == 1 ? (long)nof * 12 : 0);
    if ((long)d.size() < need) {
        std::printf("FAIL %s size %zu < expected %ld\n", name, d.size(), need);
        failures++;
        return;
    }

    // ---- run the real loader over the file bytes ----
    const uint32_t FILEOFF = 0x1000;
    uint8_t* base = (uint8_t*)calloc(1, 1 << 22);
    memcpy(base + FILEOFF, d.data(), d.size());
    int32_t firstVert[3] = { h[9], h[10], h[11] };

    lo_number = 0;
    lo_bump = 0x100000;
    vk_load_object(base, FILEOFF, 0x42);

    uint32_t obj = lo_objects[0];
    ck("v3d obj type", *(int32_t*)(base + obj + 0), type);
    ck("v3d obj nov", *(int32_t*)(base + obj + 4), nov);
    ck("v3d obj nof", *(int32_t*)(base + obj + 8), nof);
    ck("v3d obj vertexes ofs", *(int32_t*)(base + obj + 36), (int32_t)FILEOFF + 36);
    ck("v3d obj faces ofs", *(int32_t*)(base + obj + 40), (int32_t)FILEOFF + 36 + nov * 12);
    if (type == 1)
        ck("v3d obj textures ofs", *(int32_t*)(base + obj + 44), (int32_t)FILEOFF + 36 + nov * 12 + nof * 12);
    // x16 in-place vertex scale
    ck("v3d vert0.x*16", *(int32_t*)(base + FILEOFF + 36), firstVert[0] * 16);
    ck("v3d vert0.y*16", *(int32_t*)(base + FILEOFF + 40), firstVert[1] * 16);
    ck("v3d vert0.z*16", *(int32_t*)(base + FILEOFF + 44), firstVert[2] * 16);
    // PHONG: normals generated
    if (type == 2) {
        int32_t* normals = (int32_t*)(base + *(int32_t*)(base + obj + 48));
        int nz = 0;
        for (int i = 0; i < nof * 3; i++) if (normals[i]) nz++;
        ck("v3d phong normals nonzero", nz > 0, 1);
    }
    free(base);
    std::printf("  %s: type=%d nov=%d nof=%d  OK\n", name, type, nov, nof);
}

int main() {
    std::string dane = std::string(VOODKA_REPO_ROOT) +
        "/reference/source/demoscene-absence-voodka-master/CODE/LINKER/DANE";
    const char* v3ds[] = { "wall.v3d", "wall2.v3d", "wall3.v3d", "torus.v3d",
                           "2wall.v3d", "2wall2.v3d", "2wall3.v3d", "2torus.v3d" };
    for (const char* n : v3ds) check_v3d(dane.c_str(), n);

    // .V3M = same blob minus the 36-byte header (P5 morph target): identical
    // face/tail structure, DIFFERENT vertex positions (128 verts x 12 bytes).
    std::vector<uint8_t> v3d = readFile(dane + "\\2torus.v3d");
    std::vector<uint8_t> v3m = readFile(dane + "\\2torus.v3m");
    ck("v3m size = v3d-36", (long)v3m.size(), (long)v3d.size() - 36);
    const size_t VERTS = 128 * 12;
    ck("v3m tail = v3d+36 tail",
       memcmp(v3m.data() + VERTS, v3d.data() + 36 + VERTS, v3m.size() - VERTS), 0);
    ck("v3m head differs (morph target)",
       memcmp(v3m.data(), v3d.data() + 36, VERTS) != 0, 1);

    if (failures == 0) { std::printf("v3d.crosscheck: OK\n"); return 0; }
    std::printf("v3d.crosscheck: %d failure(s)\n", failures);
    return 1;
}
