// pal_integrity.cpp - CTest guarding the OBJ-recovered compile-time palettes:
//   - port/core/parts/*.pal (incbin'd by the parts) and the reference copies
//     in port/data/pal/ must be identical
//   - every byte must be a legal 6-bit VGA DAC value (0..63)
//   - sizes must be multiples of 3
// Returns 0 on success.

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#ifndef VOODKA_REPO_ROOT
#define VOODKA_REPO_ROOT "."
#endif

static int failures = 0;

static std::vector<unsigned char> readAll(const std::string& path) {
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) { std::printf("FAIL cannot open %s\n", path.c_str()); failures++; return {}; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    std::vector<unsigned char> d((size_t)sz);
    if (fread(d.data(), 1, (size_t)sz, f) != (size_t)sz) { fclose(f); failures++; return {}; }
    fclose(f);
    return d;
}

int main() {
    const char* pals[] = { "jup.pal", "tn.pal", "sw.pal", "p8_sw.pal", "metal.pal" };
    std::string a = std::string(VOODKA_REPO_ROOT) + "/port/core/parts/";
    std::string b = std::string(VOODKA_REPO_ROOT) + "/port/data/pal/";
    for (const char* p : pals) {
        std::vector<unsigned char> pa = readAll(a + p), pb = readAll(b + p);
        if (pa.empty() || pb.empty()) continue;
        if (pa.size() % 3) { std::printf("FAIL %s size %zu not multiple of 3\n", p, pa.size()); failures++; }
        for (size_t i = 0; i < pa.size(); i++)
            if (pa[i] > 63) { std::printf("FAIL %s byte %zu = %u (>63, not 6-bit)\n", p, i, pa[i]); failures++; break; }
        if (pa != pb) { std::printf("FAIL %s: parts/ and data/pal/ copies differ\n", p); failures++; }
        if (!failures) std::printf("  %s: %zu colors, identical copies, 6-bit clean\n", p, pa.size() / 3);
    }
    if (failures == 0) { std::printf("pal.integrity: OK\n"); return 0; }
    std::printf("pal.integrity: %d failure(s)\n", failures);
    return 1;
}
