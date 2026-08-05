// world_pack.cpp - C++ port of VIRTUAL/OBJECTS/WORLD.PAS (Borland Pascal):
// packs the VR viewer's object archive.
//
// Manifest (WORLD.TXT):
//   line 1: count
//   line 2: output name (ignored here; the output path comes from argv)
//   next `count` lines: input .V3D files (relative to the manifest's dir)
//
// Archive layout (exactly WORLD.PAS):
//   [count:u32] [ofs[0]:u32 ... ofs[count-1]:u32] [raw blobs...]
//   ofs[0] = 4 + count*4; ofs[i] = ofs[i-1] + size[i-1]
//
// Usage: world_pack <manifest> <out>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static std::string trim(const std::string& s) {
    size_t a = s.find_first_not_of(" \t\r\n");
    size_t b = s.find_last_not_of(" \t\r\n");
    return a == std::string::npos ? "" : s.substr(a, b - a + 1);
}

int main(int argc, char** argv) {
    if (argc < 3) { std::fprintf(stderr, "usage: world_pack <manifest> <out>\n"); return 2; }
    std::string manifest = argv[1];
    std::string dir = manifest.substr(0, manifest.find_last_of("\\/") + 1);

    FILE* f = fopen(manifest.c_str(), "rb");
    if (!f) { std::fprintf(stderr, "cannot open %s\n", manifest.c_str()); return 1; }
    char buf[512];
    std::vector<std::string> lines;
    while (fgets(buf, sizeof buf, f)) { std::string s = trim(buf); if (!s.empty()) lines.push_back(s); }
    fclose(f);
    if (lines.size() < 2) { std::fprintf(stderr, "manifest too short\n"); return 1; }
    long count = strtol(lines[0].c_str(), nullptr, 10);
    if (count <= 0 || (size_t)count > lines.size() - 2) { std::fprintf(stderr, "bad count %ld\n", count); return 1; }

    // read inputs (manifest lines 2..2+count-1; line 1 is the output name)
    std::vector<std::vector<uint8_t>> blobs((size_t)count);
    std::vector<uint32_t> ofs((size_t)count);
    uint32_t cursor = 4 + (uint32_t)count * 4;
    for (long i = 0; i < count; i++) {
        std::string p = dir + lines[2 + i];
        FILE* fi = fopen(p.c_str(), "rb");
        if (!fi) { std::fprintf(stderr, "missing input %s\n", p.c_str()); return 1; }
        fseek(fi, 0, SEEK_END); long sz = ftell(fi); fseek(fi, 0, SEEK_SET);
        blobs[(size_t)i].resize((size_t)sz);
        if (fread(blobs[(size_t)i].data(), 1, (size_t)sz, fi) != (size_t)sz) { fclose(fi); return 1; }
        fclose(fi);
        ofs[(size_t)i] = cursor;
        cursor += (uint32_t)sz;
    }

    FILE* out = fopen(argv[2], "wb");
    if (!out) { std::fprintf(stderr, "cannot write %s\n", argv[2]); return 1; }
    fwrite(&count, 4, 1, out);
    fwrite(ofs.data(), 4, (size_t)count, out);
    for (long i = 0; i < count; i++) fwrite(blobs[(size_t)i].data(), 1, blobs[(size_t)i].size(), out);
    fclose(out);
    std::printf("world_pack: %ld objects -> %s (%u bytes)\n", count, argv[2], cursor);
    return 0;
}
