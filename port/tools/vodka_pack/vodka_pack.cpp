// vodka_pack - reproduces the original Borland LINKER.PAS byte-for-byte.
//
// Original algorithm (CODE/LINKER/LINKER.PAS):
//   - reads vodka.txt: first line = file count N, then N relative paths
//   - opens vodka.dat for writing, seeks to 1000*4*2 = 8000
//   - for each file: records poz[l] = { currentfilepos, filesize }
//     then appends the file bytes (chunked at 65535 in the original;
//     result is byte-identical to a single append)
//   - seeks to 0 and writes the 1000-entry table (unused entries are
//     zero in TP global vars, so we write a zeroed 8000-byte table)
//
// Output layout: [ 8000-byte table of (offset:u32,size:u32) ][ data... ]
// Entry l (0-based by beer index) matches manifest file l+1.
//
// Usage: vodka_pack <manifest.txt> <daneDir> <out.dat>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <fstream>
#include <filesystem>

namespace fs = std::filesystem;

static std::vector<std::string> readManifest(const std::string& path, int& count) {
    std::vector<std::string> files;
    std::ifstream in(path);
    if (!in) { std::fprintf(stderr, "cannot open manifest %s\n", path.c_str()); return files; }
    std::string line;
    std::getline(in, line);
    count = std::atoi(line.c_str());
    while (std::getline(in, line)) {
        // trim CR and stray whitespace
        while (!line.empty() && (line.back() == '\r' || line.back() == '\n' || line.back() == ' '))
            line.pop_back();
        if (!line.empty())
            files.push_back(line);
    }
    return files;
}

static bool readFileBytes(const fs::path& path, std::vector<uint8_t>& out) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return false;
    in.seekg(0, std::ios::end);
    auto sz = (size_t)in.tellg();
    in.seekg(0, std::ios::beg);
    out.resize(sz);
    if (sz) in.read((char*)out.data(), (std::streamsize)sz);
    return true;
}

int main(int argc, char** argv) {
    if (argc != 4) {
        std::fprintf(stderr, "usage: vodka_pack <vodka.txt> <daneDir> <out.dat>\n");
        return 2;
    }
    const fs::path manifest(argv[1]);
    const fs::path daneDir(argv[2]);
    const fs::path outPath(argv[3]);

    int count = 0;
    auto files = readManifest(manifest.string(), count);
    if (files.empty()) return 1;
    if ((int)files.size() != count) {
        std::fprintf(stderr, "manifest count %d != entries %zu\n", count, files.size());
        return 1;
    }

    constexpr size_t TABLE_ENTRIES = 1000;
    constexpr size_t TABLE_BYTES = TABLE_ENTRIES * 8;   // 8000
    std::vector<uint8_t> table(TABLE_BYTES, 0);

    std::vector<uint8_t> data;
    data.reserve(8 * 1024 * 1024);
    uint32_t cursor = (uint32_t)TABLE_BYTES;

    for (int i = 0; i < count; i++) {
        // manifest entries are prefixed with "dane\" - daneDir already points
        // at the DANE directory, so strip any leading "dane[/\]" component.
        auto rel_f = files[i];
        auto strip = [](std::string s, const char* pfx) {
            size_t n = std::strlen(pfx);
            if (s.size() >= n && _stricmp(s.substr(0, n).c_str(), pfx) == 0)
                s = s.substr(n);
            return s;
        };
        rel_f = strip(rel_f, "dane\\");
        rel_f = strip(rel_f, "dane/");
        fs::path fname = daneDir / rel_f;
        std::vector<uint8_t> bytes;
        if (!readFileBytes(fname, bytes)) {
            std::fprintf(stderr, "missing file: %s\n", fname.string().c_str());
            return 1;
        }
        // entry l (0-based) at byte l*8 : offset, size (little endian)
        size_t e = (size_t)i * 8;
        uint32_t off = cursor;
        uint32_t sz = (uint32_t)bytes.size();
        table[e + 0] = (uint8_t)(off & 0xff);
        table[e + 1] = (uint8_t)((off >> 8) & 0xff);
        table[e + 2] = (uint8_t)((off >> 16) & 0xff);
        table[e + 3] = (uint8_t)((off >> 24) & 0xff);
        table[e + 4] = (uint8_t)(sz & 0xff);
        table[e + 5] = (uint8_t)((sz >> 8) & 0xff);
        table[e + 6] = (uint8_t)((sz >> 16) & 0xff);
        table[e + 7] = (uint8_t)((sz >> 24) & 0xff);
        data.insert(data.end(), bytes.begin(), bytes.end());
        cursor += sz;
        std::printf("packed %-24s off=%u size=%u\n", files[i].c_str(), off, sz);
    }

    std::ofstream out(outPath, std::ios::binary | std::ios::trunc);
    if (!out) { std::fprintf(stderr, "cannot write %s\n", outPath.string().c_str()); return 1; }
    out.write((const char*)table.data(), (std::streamsize)table.size());
    out.write((const char*)data.data(), (std::streamsize)data.size());
    out.close();

    std::printf("packed %d files -> %s (%zu table + %zu data)\n",
                count, outPath.string().c_str(), table.size(), data.size());
    return 0;
}
