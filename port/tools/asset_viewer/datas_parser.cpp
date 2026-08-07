// datas_parser.cpp - CODE/DATAS compile-time mesh loader (see datas_parser.h).

#include "datas_parser.h"

#include <array>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

namespace {

std::string toLower(std::string s) {
    for (char& c : s)
        if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
    return s;
}

bool readLines(const std::string& path, std::vector<std::string>& out) {
    FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) {
        std::fprintf(stderr, "datas: cannot open %s\n", path.c_str());
        return false;
    }
    std::string line;
    int ch;
    while ((ch = std::fgetc(f)) != EOF) {
        if (ch == '\n') { out.push_back(line); line.clear(); }
        else if (ch != '\r') line += (char)ch;
    }
    if (!line.empty()) out.push_back(line);
    std::fclose(f);
    return true;
}

// Parse "dw a,b,c" rows from a DATAS file. `expectVertices` selects which
// header keyword is required. On success fills `count` (from the header) and
// `rows` (one triple per data line); returns false + a stderr message on any
// structural problem.
bool parseDwRows(const std::vector<std::string>& lines, const char* file,
                 bool expectVertices, int& count,
                 std::vector<std::array<int, 3>>& rows) {
    rows.clear();
    int headerLen = -1;
    const char* key = expectVertices ? "vertices:" : "faces:";
    size_t keyLen = std::strlen(key);    for (const std::string& raw : lines) {
        size_t b = raw.find_first_not_of(" \t");
        if (b == std::string::npos) continue;

        if (raw[b] == ';') {
            // ";Vertices: N" / ";Faces: M" header comment
            std::string low = toLower(raw);
            size_t p = low.find(key);
            if (p != std::string::npos) {
                headerLen = std::atoi(raw.c_str() + p + keyLen);
                continue;
            }
            continue;  // other comment - ignore
        }

        // data row: find the "dw" keyword, then three comma-separated ints
        std::string low = toLower(raw);
        size_t dw = low.find("dw");
        if (dw == std::string::npos) continue;   // label/other directive
        size_t v = dw + 2;
        std::array<int, 3> row{0, 0, 0};
        for (int k = 0; k < 3; ++k) {
            while (v < raw.size() &&
                   (raw[v] == ' ' || raw[v] == '\t' || raw[v] == ',' ||
                    raw[v] == '\r'))
                v++;
            if (v >= raw.size()) {
                std::fprintf(stderr, "datas: %s: row %zu has <3 values\n",
                             file, rows.size() + 1);
                return false;
            }
            char* end = nullptr;
            long val = std::strtol(raw.c_str() + v, &end, 10);
            row[k] = (int)val;
            v = (size_t)(end - raw.c_str());
        }
        rows.push_back(row);
    }

    if (headerLen < 0) {
        std::fprintf(stderr, "datas: %s: missing ';%s' header\n", file,
                     expectVertices ? "Vertices" : "Faces");
        return false;
    }
    if ((int)rows.size() != headerLen) {
        std::fprintf(stderr,
                     "datas: %s: header says %d but found %zu rows\n",
                     file, headerLen, rows.size());
        return false;
    }
    count = headerLen;
    return true;
}

}  // namespace

std::optional<V3DAsset> loadDatasMesh(const std::string& vertInc,
                                      const std::string& faceInc,
                                      const std::string& name) {
    std::vector<std::string> vl, fl;
    if (!readLines(vertInc, vl)) return std::nullopt;
    if (!readLines(faceInc, fl)) return std::nullopt;

    int nov = 0, nof = 0;
    std::vector<std::array<int, 3>> vrows, frows;
    if (!parseDwRows(vl, vertInc.c_str(), true, nov, vrows))
        return std::nullopt;
    if (!parseDwRows(fl, faceInc.c_str(), false, nof, frows))
        return std::nullopt;

    V3DAsset a;
    a.name = name;
    a.type = 3;  // DATAS compile-time mesh marker (not a V3D type)
    a.vertexCount = nov;
    a.faceCount = nof;
    a.spinAdderX = a.spinAdderY = a.spinAdderZ = 0;

    a.vertices.resize((size_t)nov * 3);
    for (int i = 0; i < nov; ++i) {
        a.vertices[(size_t)i * 3 + 0] = (float)vrows[(size_t)i][0];
        a.vertices[(size_t)i * 3 + 1] = (float)vrows[(size_t)i][1];
        a.vertices[(size_t)i * 3 + 2] = (float)vrows[(size_t)i][2];
    }

    a.faces.resize((size_t)nof * 3);
    for (int f = 0; f < nof; ++f) {
        for (int k = 0; k < 3; ++k) {
            int idx = frows[(size_t)f][k];
            if (idx < 0 || idx >= nov) {
                std::fprintf(stderr,
                             "datas: %s: face %d index %d out of range (nov=%d)\n",
                             name.c_str(), f, idx, nov);
                return std::nullopt;
            }
            a.faces[(size_t)f * 3 + (size_t)k] = (uint32_t)idx;
        }
    }

    computeFaceNormals(a);
    return a;
}