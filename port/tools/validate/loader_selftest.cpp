// loader_selftest.cpp - CTest for Load_Object (OBJECTS.PM -> loader.asm).
//
// Packs a small object file into a test arena, then vk_load_object parses it:
// struct fields, vertex/face/texture offsets, working-buffer layout, vertex
// x16 scaling, and (for PHONG) per-face normals via unit 5. All object
// offsets are base-relative; the test derefs through the base pointer.
//
// Returns 0 on success, non-zero on any mismatch.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

extern "C" void vk_load_object(uint8_t* base, uint32_t fileOff, uint16_t texSel);
extern "C" uint32_t lo_objects[10];
extern "C" uint32_t lo_number;
extern "C" uint32_t lo_bump;

static int failures = 0;
#define I32(o) (*(int32_t*)(base + (uint32_t)(o)))

int main() {
    const int NV = 8, NF = 12;
    const int FIELD[11] = {48,52,56,60,64,68,76,80, 36,40,44}; // int fields to sanity-check
    for (int kind = 0; kind < 3; kind++) {   // 0=PIX 1=TEX 2=PHONG
        srand(0x1000 + kind);
        const uint32_t FILEOFF = 0x1000;
        uint8_t* base = (uint8_t*)malloc(1 << 22);
        memset(base, 0, 1 << 22);

        // ---- build the object file blob at FILEOFF ----
        int32_t* hdr = (int32_t*)(base + FILEOFF);
        hdr[0] = kind; hdr[1] = NV; hdr[2] = NF;
        hdr[3] = 111; hdr[4] = -222; hdr[5] = 333;   // adders
        hdr[6] = 0; hdr[7] = 0; hdr[8] = 0;          // padding
        int32_t* verts = hdr + 9;
        for (int i = 0; i < NV * 3; i++) verts[i] = (int32_t)((rand() % 2001) - 1000);
        int32_t verts_orig[NV * 3];
        for (int i = 0; i < NV * 3; i++) verts_orig[i] = verts[i];
        int32_t* faces = verts + NV * 3;
        for (int i = 0; i < NF; i++) {            // distinct, non-degenerate indices
            faces[i*3+0] = (i * 3 + 0) % NV;
            faces[i*3+1] = (i * 3 + 1) % NV;
            faces[i*3+2] = (i * 3 + 2) % NV;
        }

        // ---- seed bump + load ----
        lo_number = 0;
        lo_bump = 0x10000;
        vk_load_object(base, FILEOFF, (uint16_t)(0x50 + kind));

        if (lo_number != 1) { std::printf("FAIL kind %d lo_number=%d\n", kind, lo_number); failures++; }
        uint32_t obj = lo_objects[0];
        if (I32(obj + 0) != kind) { std::printf("FAIL kind %d type\n", kind); failures++; }
        if (I32(obj + 4) != NV)    { std::printf("FAIL kind %d nov\n", kind); failures++; }
        if (I32(obj + 8) != NF)    { std::printf("FAIL kind %d nof\n", kind); failures++; }
        if (I32(obj + 24) != 111 || I32(obj + 28) != -222 || I32(obj + 32) != 333)
            { std::printf("FAIL kind %d adders\n", kind); failures++; }
        if ((*(uint16_t*)(base + obj + 72)) != (uint16_t)(0x50 + kind))
            { std::printf("FAIL kind %d texsel\n", kind); failures++; }

        // addresses
        if (I32(obj + 36) != FILEOFF + 36) { std::printf("FAIL kind %d vertexes\n", kind); failures++; }
        if (I32(obj + 40) != FILEOFF + 36 + NV * 12) { std::printf("FAIL kind %d faces\n", kind); failures++; }
        if (kind == 1 && I32(obj + 44) != FILEOFF + 36 + NV * 12 + NF * 12)
            { std::printf("FAIL kind %d textures\n", kind); failures++; }

        // all int fields (normals..order) nonzero, distinct-ish, and >= file region
        for (int idx = 0; idx < 8; idx++) {
            uint32_t f = (uint32_t)I32(obj + FIELD[idx]);
            if (f <= FILEOFF + 36 + NV * 12 + (kind==1 ? NF*12 : 0) || f > lo_bump) {
                std::printf("FAIL kind %d field off %d = %u (bump %u)\n", kind, FIELD[idx], f, lo_bump);
                failures++;
            }
        }
        // vertex scaled x16
        for (int i = 0; i < NV * 3; i++) {
            if (verts[i] != verts_orig[i] * 16) {
                std::printf("FAIL kind %d vert[%d]: %d != %d\n", kind, i, verts[i], verts_orig[i] * 16);
                if (++failures > 25) break;
            }
        }
        // PHONG normals populated by unit 5
        if (kind == 2) {
            int32_t* normals = (int32_t*)(base + I32(obj + 48));
            int nz = 0;
            for (int i = 0; i < NF * 3; i++) if (normals[i]) nz++;
            if (nz == 0) { std::printf("FAIL kind 2 normals all zero\n"); failures++; }
        }

        free(base);
        if (failures > 25) break;
    }
    if (failures == 0) { std::printf("loader.crosscheck: OK\n"); return 0; }
    std::printf("loader.crosscheck: %d failure(s)\n", failures);
    return 1;
}
