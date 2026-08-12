// tabl2nasm - converts TASM data-table include files (used by the demo) into
// NASM-compatible data. The original files look like:
//
//   tablica3 label dword
//   dd  -160,  -120
//   ...
//
// or (word tables):
//
//   MUL160 LABEL WORD
//   uuu=0
//   REPT 100
//     dw uuu
//     uuu=uuu+160
//   ENDM
//
// This tool handles the common straight-line forms:
//   - 'label ...' line -> NASM label
//   - 'dd a, b, c' / 'dw a, b, c' / 'db a, b, c' value lines (kept verbatim)
//   - simple REPT-style tables are expanded by a second, special-cased tool
//     when needed (none in P6/P7 paths use them at runtime).
//
// Usage: tabl2nasm <in.inc> <out.asm> [label_plain=0]
// Output format is NASM:  label:  dd  ..., ...

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static std::vector<std::string> readLines(const char* path) {
    std::vector<std::string> out;
    FILE* f = fopen(path, "rb");
    if (!f) return out;
    char buf[4096];
    while (fgets(buf, sizeof buf, f)) {
        std::string s(buf);
        while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) s.pop_back();
        out.push_back(s);
    }
    fclose(f);
    return out;
}

int main(int argc, char** argv) {
    if (argc < 3) { std::fprintf(stderr, "usage: tabl2nasm <in> <out>\n"); return 2; }
    auto lines = readLines(argv[1]);
    if (lines.empty()) { std::fprintf(stderr, "cannot read %s\n", argv[1]); return 1; }

    FILE* out = fopen(argv[2], "wb");
    if (!out) return 1;
    std::fprintf(out, "; auto-converted by tabl2nasm from %s\n", argv[1]);
    for (auto& l : lines) {
        // strip ; comments? keep them
        std::string c = l;
        // leading whitespace
        size_t st = c.find_first_not_of(" \t");
        if (st == std::string::npos) { std::fprintf(out, "%s\n", c.c_str()); continue; }
        c = c.substr(st);
        // detect label line: ends with 'label WORD/DWORD/BYTE' (case-insensitive)
        std::string lc = c;
        for (auto& ch : lc) ch = (char)toupper((unsigned char)ch);
        bool isLabel = (lc.find("LABEL WORD") != std::string::npos ||
                        lc.find("LABEL DWORD") != std::string::npos ||
                        lc.find("LABEL BYTE") != std::string::npos);
        if (isLabel) {
            // extract symbol name; emit "name:"
            std::string name;
            size_t sp = c.find_first_of(" \t");
            if (sp != std::string::npos) name = c.substr(0, sp);
            std::fprintf(out, "%s:\n", name.c_str());
            continue;
        }
        // data line: dd/dw/db -> NASM is identical
        if (c.rfind("dd", 0) == 0 || c.rfind("dw", 0) == 0 ||
            c.rfind("db", 0) == 0 || c.rfind("dd ", 0) == 0 ||
            c.rfind("dw ", 0) == 0 || c.rfind("db ", 0) == 0) {
            std::fprintf(out, "%s\n", c.c_str());
            continue;
        }
        // anything else: pass through (usually blank or comment)
        if (c[0] == ';' || c.empty()) { std::fprintf(out, "%s\n", c.c_str()); continue; }
        // unknown directive - drop with a note (REPT etc handled elsewhere)
        std::fprintf(out, "; (dropped) %s\n", c.c_str());
    }
    fclose(out);
    std::printf("tabl2nasm: %s -> %s (%zu lines)\n", argv[1], argv[2], lines.size());
    return 0;
}
