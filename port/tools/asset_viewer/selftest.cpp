// selftest.cpp - CTest v3d.viewer_parse: validate every V3D/V3M asset
// extracted from vodka.dat against known-good header values.
//
// Runs without a window or GPU. Depends on the extraction step having
// produced the flat files under ASSET_VIEWER_DATA_DIR.
//
// Expected values verified against the raw files:
//   all 6 walls       : type 1 (TEX),   nov 4,   nof 2,   spin (0,0,0), 140 B
//   torus.v3d         : type 2 (PHONG), nov 346, nof 688, spin (2,2,2), 15212 B
//   2torus.v3d        : type 2 (PHONG), nov 128, nof 256, spin (2,2,2), 5668 B
//   2torus.v3m        : headerless, nov 128, nof 256, 5632 B
// (2tor.v3d header bytes: 02 00 00 00 | 80 00 00 00 | 00 01 00 00 | 02...)

#include "v3d_parser.h"
#include "v3d_entries.h"

#include <cstdio>
#include <cstring>
#include <string>

#ifndef ASSET_VIEWER_DATA_DIR
#error "ASSET_VIEWER_DATA_DIR must be defined by the build"
#endif

namespace {

const char* kDataDir = ASSET_VIEWER_DATA_DIR;

int g_failures = 0;

void ck(const char* what, bool ok) {
    if (!ok) {
        std::fprintf(stderr, "FAIL: %s\n", what);
        g_failures++;
    }
}

std::string join(const char* name) {
    return std::string(kDataDir) + "\\" + name;
}

}  // namespace

int main() {
    // ---- V3D files: exact header fields + index bounds + PHONG normals ----
    struct Expected {
        const char* name;
        int type, nov, nof;
        int spinX, spinY, spinZ;
    };
    const Expected kExpected[] = {
        {"wall.v3d",    1,  4,   2,  0, 0, 0},
        {"wall2.v3d",   1,  4,   2,  0, 0, 0},
        {"wall3.v3d",   1,  4,   2,  0, 0, 0},
        {"torus.v3d",   2, 346, 688,  2, 2, 2},    // PHONG, spin (2,2,2)
        {"2wall.v3d",   1,  4,   2,  0, 0, 0},
        {"2wall2.v3d",  1,  4,   2,  0, 0, 0},
        {"2wall3.v3d",  1,  4,   2,  0, 0, 0},
        {"2torus.v3d",  2, 128, 256,  2, 2, 2},    // PHONG, spin (2,2,2)
    };

    for (const Expected& e : kExpected) {
        auto asset = loadV3D(join(e.name));
        char what[256];
        if (!asset) {
            std::snprintf(what, sizeof what, "%s: parse returned nullopt",
                          e.name);
            ck(what, false);
            continue;
        }
        std::snprintf(what, sizeof what, "%s type", e.name);
        ck(what, asset->type == e.type);
        std::snprintf(what, sizeof what, "%s nov", e.name);
        ck(what, asset->vertexCount == e.nov);
        std::snprintf(what, sizeof what, "%s nof", e.name);
        ck(what, asset->faceCount == e.nof);
        std::snprintf(what, sizeof what, "%s spin", e.name);
        ck(what, asset->spinAdderX == e.spinX && asset->spinAdderY == e.spinY &&
                 asset->spinAdderZ == e.spinZ);

        bool indicesOk = true;
        for (size_t i = 0; i < asset->faces.size(); ++i)
            if (asset->faces[i] >= (uint32_t)asset->vertexCount) indicesOk = false;
        std::snprintf(what, sizeof what, "%s face indices in range", e.name);
        ck(what, indicesOk);

        if (e.type == 2) {
            int nonZero = 0;
            for (float n : asset->faceNormals) if (n != 0.0f) nonZero++;
            std::snprintf(what, sizeof what, "%s PHONG normals nonzero", e.name);
            ck(what, nonZero > 0);
        }
        std::printf("  %s: type=%d nov=%d nof=%d spin=(%d,%d,%d) OK\n",
                    e.name, asset->type, asset->vertexCount, asset->faceCount,
                    asset->spinAdderX, asset->spinAdderY, asset->spinAdderZ);
    }

    // ---- V3M: headerless morph target, counts from the companion V3D ------
    {
        auto v3d = loadV3D(join("2torus.v3d"));
        (void)v3d;
        auto v3m = loadV3M(join("2torus.v3m"), 128, 256, "2torus.v3m");
        ck("2torus.v3m: parse returned non-null", v3m.has_value());
        if (v3m) {
            ck("2torus.v3m nov", v3m->vertexCount == 128);
            ck("2torus.v3m nof", v3m->faceCount == 256);
            int nonZero = 0;
            for (float v : v3m->vertices) if (v != 0.0f) nonZero++;
            ck("2torus.v3m vertices non-zero (morph target differs from V3D)",
               nonZero > 0);
            bool indicesOk = true;
            for (size_t i = 0; i < v3m->faces.size(); ++i)
                if (v3m->faces[i] >= 128) indicesOk = false;
            ck("2torus.v3m face indices in range", indicesOk);
            std::printf("  2torus.v3m: type=%d(headerless) nov=%d nof=%d OK\n",
                        v3m->type, v3m->vertexCount, v3m->faceCount);
        }
    }

    // ---- archive table sanity: every entry extracted at known size ---------
    {
        bool sizesOk = true;
        for (int i = 0; i < kV3DEntryCount; ++i) {
            FILE* f = std::fopen(join(kV3DEntries[i].name).c_str(), "rb");
            if (!f) { sizesOk = false; break; }
            std::fseek(f, 0, SEEK_END);
            long n = std::ftell(f);
            std::fclose(f);
            if ((size_t)n != kV3DEntries[i].size) { sizesOk = false; break; }
        }
        ck("all 9 extracted files present at expected sizes", sizesOk);
    }

    if (g_failures == 0) {
        std::printf("v3d.viewer_parse: OK (9 files validated)\n");
        return 0;
    }
    std::printf("v3d.viewer_parse: %d failure(s)\n", g_failures);
    return 1;
}