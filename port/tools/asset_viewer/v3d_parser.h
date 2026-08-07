// v3d_parser.h - V3D/V3M geometry loader for the asset viewer.
//
// Implements the format reverse-engineered from the ported loader
// (core/engine/loader.asm) and documented in docs/ASSET_FORMATS.md §4.1-4.2:
//
//   V3D:  36-byte header { type:i32(0=PIX,1=TEX,2=PHONG), nov:i32, nof:i32,
//          addX:i32, addY:i32, addZ:i32, 12B unused }
//         then nov*12B vertices (x,y,z i32), nof*12B faces (i0,i1,i2 i32
//         vertex indices), then an optional nov*8B per-vertex UV block
//         (exporter leftover; present in every shipped file).
//   V3M:  the same vertex/face/UV block WITHOUT the 36-byte header (P5 morph
//         target). Detected by the .v3m extension / invalid type prefix and
//         parsed with externally-supplied nov/nof counts.
//
// Vertices are scaled x16 in place by the original loader; this parser
// applies the same scale. Face normals are computed per-face (cross product
// of edge vectors, normalized) for flat shading.

#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

struct V3DAsset {
    std::string name;
    int         type = 0;          // 0=PIXELS, 1=TEXTURES, 2=PHONG
    int         vertexCount = 0;
    int         faceCount = 0;
    int         spinAdderX = 0;
    int         spinAdderY = 0;
    int         spinAdderZ = 0;

    std::vector<float>      vertices;    // x,y,z triplets, SCALED x16
    std::vector<uint32_t>   faces;       // i0,i1,i2 triplets (flat index list)
    std::vector<float>      faceNormals; // per-face nx,ny,nz; filled for all types
};

// Load a .v3d file. Returns std::nullopt on parse error (prints the reason
// to stderr).
std::optional<V3DAsset> loadV3D(const std::string& path);

// Fill faceNormals (per face) for any already-populated asset (vertices +
// faces). Degenerate faces fall back to (0,1,0). Reused by the DATAS mesh
// parser.
void computeFaceNormals(V3DAsset& a);

// Same parse, from an in-memory blob (the viewer extracts directly from
// vodka.dat without touching disk).
std::optional<V3DAsset> loadV3DFromMemory(const uint8_t* data, size_t size,
                                          const std::string& name);

// Load a headerless .v3m file given the companion .v3d's nov/nof counts.
// Returns std::nullopt on parse error (prints the reason to stderr).
std::optional<V3DAsset> loadV3M(const std::string& path,
                                int expectedNov, int expectedNof,
                                const std::string& name);

// Same parse, from an in-memory blob.
std::optional<V3DAsset> loadV3MFromMemory(const uint8_t* data, size_t size,
                                          int expectedNov, int expectedNof,
                                          const std::string& name);