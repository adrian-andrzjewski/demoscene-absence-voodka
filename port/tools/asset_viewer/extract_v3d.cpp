// extract_v3d.cpp - extract the V3D/V3M 3D assets from vodka.dat.
//
// vodka.dat layout (byte-identical to the shipped release, reproduced by
// vodka_pack / LINKER.PAS semantics):
//   [0..7999]    1000 x (offset:u32le, size:u32le)  -- offsets are ABSOLUTE
//              within the archive (first payload starts at 8000)
//   [8000..]    concatenated files, in VODKA.TXT order
//
// This tool extracts the 9 V3D/V3M entries (archive indices 12-15, 31-35)
// to a flat directory as standalone files. It validates each entry's size
// against the known-good table so a corrupt/reshuffled archive is caught
// at build time instead of poisoning the viewer.
//
// Usage: extract_v3d <vodka.dat path> <output directory>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "v3d_entries.h"

namespace {

bool readAt(FILE* f, long offset, void* buf, size_t n) {
    if (fseek(f, offset, SEEK_SET) != 0) return false;
    return fread(buf, 1, n, f) == n;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 3) {
        std::fprintf(stderr,
                     "Usage: extract_v3d <vodka.dat path> <output directory>\n");
        return 2;
    }
    const char* archivePath = argv[1];
    const char* outDir = argv[2];

    FILE* f = std::fopen(archivePath, "rb");
    if (!f) {
        std::fprintf(stderr, "extract_v3d: cannot open %s\n", archivePath);
        return 1;
    }

    // ---- header: 1000 x {offset:u32, size:u32} ----------------------------
    std::uint8_t header[8000];
    if (!readAt(f, 0, header, sizeof header)) {
        std::fprintf(stderr, "extract_v3d: %s too small for 8000-byte header\n",
                     archivePath);
        std::fclose(f);
        return 1;
    }

    int failures = 0;
    for (const V3DEntry& e : kV3DEntries) {
        const std::uint8_t* ent = header + (size_t)e.index * 8;
        std::uint32_t off = (std::uint32_t)ent[0] | ((std::uint32_t)ent[1] << 8) |
                            ((std::uint32_t)ent[2] << 16) | ((std::uint32_t)ent[3] << 24);
        std::uint32_t sz = (std::uint32_t)ent[4] | ((std::uint32_t)ent[5] << 8) |
                           ((std::uint32_t)ent[6] << 16) | ((std::uint32_t)ent[7] << 24);

        if (sz != e.size) {
            std::fprintf(stderr,
                         "extract_v3d: %s archive size %u != expected %zu\n",
                         e.name, sz, e.size);
            failures++;
            continue;
        }

        std::string dst = std::string(outDir) + "\\" + e.name;
        FILE* w = std::fopen(dst.c_str(), "wb");
        if (!w) {
            std::fprintf(stderr, "extract_v3d: cannot write %s\n", dst.c_str());
            failures++;
            continue;
        }
        std::vector<uint8_t> blob(sz);
        bool ok = readAt(f, off, blob.data(), sz) &&
                  fwrite(blob.data(), 1, sz, w) == sz;
        std::fclose(w);
        if (!ok) {
            std::fprintf(stderr, "extract_v3d: failed to extract %s\n", e.name);
            failures++;
            continue;
        }
        std::printf("%2d %-13s %zu bytes\n", e.index, e.name, (size_t)sz);
    }

    std::fclose(f);
    if (failures) {
        std::fprintf(stderr, "extract_v3d: %d failure(s)\n", failures);
        return 1;
    }
    std::printf("extract_v3d: 9 files OK\n");
    return 0;
}