// tablica3_crosscheck.cpp - CTest verifying the generated NASM water tables
// (core/parts/p{2,6,7}_tablica3.asm, p2_watertab.asm, p5_tablica3.asm,
// produced by tools/vodka_pack/tabl2nasm) match the original TASM text tables
// value-for-value.
//
// Both sides are parsed as integer sequences ('dd'/'dw' rows); the original
// 'tablica3 label dword' header line maps to the generated 'tablica3:' label
// (p2_watertab.asm renames it to 'watertab:' - the label line carries no
// values, so the comparison is unaffected).
// Returns 0 on success.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#ifndef VOODKA_REPO_ROOT
#define VOODKA_REPO_ROOT "."
#endif

static int failures = 0;

// extract all integers from dd/dw/db rows, in order
static std::vector<long> parseNums(const std::string& path) {
    std::vector<long> out;
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) { std::printf("FAIL cannot open %s\n", path.c_str()); failures++; return out; }
    char buf[4096];
    while (fgets(buf, sizeof buf, f)) {
        char* p = buf;
        while (*p == ' ' || *p == '\t') p++;
        if (strncmp(p, "dd", 2) && strncmp(p, "dw", 2) && strncmp(p, "db", 2)) continue;
        p += 2;
        while (*p) {
            while (*p == ' ' || *p == '\t' || *p == ',') p++;
            if (*p == ';' || *p == '\r' || *p == '\n' || !*p) break;
            char* end = nullptr;
            long v = strtol(p, &end, 10);
            if (end == p) break;
            out.push_back(v);
            p = end;
        }
    }
    fclose(f);
    return out;
}

static void check(const std::string& orig, const std::string& gen, const char* tag) {
    std::vector<long> a = parseNums(orig), b = parseNums(gen);
    if (a.size() != b.size()) {
        std::printf("FAIL %s count: orig %zu != generated %zu\n", tag, a.size(), b.size());
        failures++;
        return;
    }
    long bad = -1;
    for (size_t i = 0; i < a.size(); i++) if (a[i] != b[i]) { bad = (long)i; break; }
    if (bad >= 0) {
        std::printf("FAIL %s value #%ld: %ld != %ld\n", tag, bad, a[(size_t)bad], b[(size_t)bad]);
        failures++;
        return;
    }
    std::printf("  %s: %zu values identical\n", tag, a.size());
}

int main() {
    std::string ref = std::string(VOODKA_REPO_ROOT) + "/reference/source/demoscene-absence-voodka-master/CODE";
    std::string gen = std::string(VOODKA_REPO_ROOT) + "/port/core/parts";
    check(ref + "/P2/TABLICA3", gen + "/p2_tablica3.asm", "P2/TABLICA3");
    check(ref + "/P6/TABLICA3", gen + "/p6_tablica3.asm", "P6/TABLICA3");
    check(ref + "/P7/TABLICA3", gen + "/p7_tablica3.asm", "P7/TABLICA3");
    // the table P2's production water actually used (WATER.PM:106 `include
    // water\tab`) and the P5 RIP drop path (P5/WATER.PM:6 -> P5/RIP -> TABLICA3)
    check(ref + "/P2/WATER/TAB", gen + "/p2_watertab.asm", "P2/WATER/TAB");
    check(ref + "/P5/TABLICA3", gen + "/p5_tablica3.asm", "P5/TABLICA3");
    if (failures == 0) { std::printf("tablica3.crosscheck: OK\n"); return 0; }
    std::printf("tablica3.crosscheck: %d failure(s)\n", failures);
    return 1;
}
