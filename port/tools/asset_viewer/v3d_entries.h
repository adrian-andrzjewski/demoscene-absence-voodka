// v3d_entries.h - the 9 V3D/V3M assets packed in vodka.dat.
//
// Single source of truth for the archive positions and known-good sizes
// shared by extract_v3d.cpp, the viewer, and the parse selftest. Sizes
// verified against CODE/LINKER/DANE/*.V3*:
//   WALL*.V3D 140, TORUS.V3D 15212, 2WALL*.V3D 140, 2TORUS.V3D 5668,
//   2TORUS.V3M 5632 (2TORUS.V3M = 2TORUS.V3D minus the 36-byte header).

#pragma once

#include <cstddef>

struct V3DEntry {
    unsigned     index;   // vodka.dat entry index (VODKA.TXT order)
    const char*  name;    // runtime filename (archive casing)
    std::size_t  size;    // known-good payload size in bytes
};

inline constexpr V3DEntry kV3DEntries[] = {
    {12, "wall.v3d",    140},
    {13, "wall2.v3d",   140},
    {14, "wall3.v3d",   140},
    {15, "torus.v3d",   15212},
    {31, "2wall.v3d",   140},
    {32, "2wall2.v3d",  140},
    {33, "2wall3.v3d",  140},
    {34, "2torus.v3d",  5668},
    {35, "2torus.v3m",  5632},
};

inline constexpr int kV3DEntryCount =
    (int)(sizeof(kV3DEntries) / sizeof(kV3DEntries[0]));