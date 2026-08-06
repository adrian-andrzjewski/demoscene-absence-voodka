// v3d_parser.cpp - V3D/V3M geometry loader (see v3d_parser.h).

#include "v3d_parser.h"

#include <cmath>
#include <cstdio>
#include <cstring>

namespace {

// Little-endian read of a 32-bit word.
inline int32_t le32(const uint8_t* p) {
    return (int32_t)((uint32_t)p[0] | ((uint32_t)p[1] << 8) |
                     ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24));
}

bool readFile(const std::string& path, std::vector<uint8_t>& out) {
    FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) {
        std::fprintf(stderr, "v3d: cannot open %s\n", path.c_str());
        return false;
    }
    std::fseek(f, 0, SEEK_END);
    long n = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    if (n < 0) {
        std::fclose(f);
        return false;
    }
    out.resize((size_t)n);
    size_t rd = std::fread(out.data(), 1, (size_t)n, f);
    std::fclose(f);
    return rd == (size_t)n;
}

// Fill faceNormals (per face) from the scaled vertex list via cross product.
// Degenerate faces (zero-length normal) fall back to (0,1,0) with a warning.
void buildFaceNormals(V3DAsset& a) {
    a.faceNormals.assign((size_t)a.faceCount * 3, 0.0f);
    for (int f = 0; f < a.faceCount; ++f) {
        const uint32_t* tri = &a.faces[(size_t)f * 3];
        const float* v0 = &a.vertices[(size_t)tri[0] * 3];
        const float* v1 = &a.vertices[(size_t)tri[1] * 3];
        const float* v2 = &a.vertices[(size_t)tri[2] * 3];
        float e1x = v1[0] - v0[0], e1y = v1[1] - v0[1], e1z = v1[2] - v0[2];
        float e2x = v2[0] - v0[0], e2y = v2[1] - v0[1], e2z = v2[2] - v0[2];
        float nx = e1y * e2z - e1z * e2y;
        float ny = e1z * e2x - e1x * e2z;
        float nz = e1x * e2y - e1y * e2x;
        float len = std::sqrt(nx * nx + ny * ny + nz * nz);
        if (len == 0.0f) {
            std::fprintf(stderr, "v3d: face %d degenerate (zero normal)\n", f);
            nx = 0.0f; ny = 1.0f; nz = 0.0f;
        } else {
            nx /= len; ny /= len; nz /= len;
        }
        float* n = &a.faceNormals[(size_t)f * 3];
        n[0] = nx; n[1] = ny; n[2] = nz;
    }
}

// Common tail: parse the payload (vertices + faces + optional UV block)
// given a base pointer and a payload byte length, then build normals.
// Returns false on error (message printed by caller for context).
bool parsePayload(V3DAsset& a, const uint8_t* payload, size_t payloadLen) {
    const size_t ovb = (size_t)a.vertexCount * 12;   // vertex block
    const size_t fvb = (size_t)a.faceCount * 12;     // face block
    const size_t minLen = ovb + fvb;
    if (payloadLen < minLen) {
        std::fprintf(stderr, "v3d: file truncated (need %zu payload bytes, have %zu)\n",
                     minLen, payloadLen);
        return false;
    }

    // Vertices, scaled x16 (as the original loader does in place).
    a.vertices.resize((size_t)a.vertexCount * 3);
    for (int i = 0; i < a.vertexCount; ++i) {
        const uint8_t* vp = payload + (size_t)i * 12;
        a.vertices[(size_t)i * 3 + 0] = (float)(le32(vp) * 16);
        a.vertices[(size_t)i * 3 + 1] = (float)(le32(vp + 4) * 16);
        a.vertices[(size_t)i * 3 + 2] = (float)(le32(vp + 8) * 16);
    }

    // Faces: validate every index before use.
    a.faces.resize((size_t)a.faceCount * 3);
    for (int f = 0; f < a.faceCount; ++f) {
        const uint8_t* fp = payload + ovb + (size_t)f * 12;
        for (int k = 0; k < 3; ++k) {
            int32_t idx = le32(fp + k * 4);
            if (idx < 0 || idx >= a.vertexCount) {
                std::fprintf(stderr,
                             "v3d: face %d index %d out of range (nov=%d)\n",
                             f, idx, a.vertexCount);
                return false;
            }
            a.faces[(size_t)f * 3 + (size_t)k] = (uint32_t)idx;
        }
    }

    // UV block (optional; exporter leftover, not needed for geometry).
    // Present in every shipped file: 36 + nov*12 + nof*12 + nov*8.
    const size_t uvSize = (size_t)a.vertexCount * 8;
    if (payloadLen < minLen + uvSize) {
        std::fprintf(stderr,
                     "v3d: %s: UV block missing/truncated (no geometry impact)\n",
                     a.name.c_str());
    }

    buildFaceNormals(a);
    return true;
}

}  // namespace

std::optional<V3DAsset> loadV3D(const std::string& path) {
    std::vector<uint8_t> d;
    if (!readFile(path, d)) return std::nullopt;
    std::string name = path.substr(path.find_last_of("\\/") + 1);
    return loadV3DFromMemory(d.data(), d.size(), name);
}

std::optional<V3DAsset> loadV3DFromMemory(const uint8_t* data, size_t size,
                                          const std::string& name) {
    if (size < 36) {
        std::fprintf(stderr, "v3d: %s: file too small (%zu bytes) for header\n",
                     name.c_str(), size);
        return std::nullopt;
    }

    V3DAsset a;
    a.name = name;
    a.type = le32(data);
    a.vertexCount = (int)le32(data + 4);
    a.faceCount = (int)le32(data + 8);
    a.spinAdderX = (int)le32(data + 12);
    a.spinAdderY = (int)le32(data + 16);
    a.spinAdderZ = (int)le32(data + 20);

    if (a.type < 0 || a.type > 2) {
        std::fprintf(stderr, "v3d: %s: invalid type %d\n", name.c_str(), a.type);
        return std::nullopt;
    }
    if (a.vertexCount <= 0 || a.faceCount <= 0) {
        std::fprintf(stderr, "v3d: %s: nov=%d nof=%d must be > 0\n",
                     name.c_str(), a.vertexCount, a.faceCount);
        return std::nullopt;
    }

    if (!parsePayload(a, data + 36, size - 36)) return std::nullopt;
    return a;
}

std::optional<V3DAsset> loadV3M(const std::string& path,
                                int expectedNov, int expectedNof,
                                const std::string& name) {
    std::vector<uint8_t> d;
    if (!readFile(path, d)) return std::nullopt;
    return loadV3MFromMemory(d.data(), d.size(), expectedNov, expectedNof, name);
}

std::optional<V3DAsset> loadV3MFromMemory(const uint8_t* data, size_t size,
                                          int expectedNov, int expectedNof,
                                          const std::string& name) {
    if (expectedNov <= 0 || expectedNof <= 0) {
        std::fprintf(stderr, "v3m: %s: invalid expected nov/nof (%d/%d)\n",
                     name.c_str(), expectedNov, expectedNof);
        return std::nullopt;
    }

    size_t want = (size_t)expectedNov * 12 + (size_t)expectedNof * 12 +
                  (size_t)expectedNov * 8;  // verts + faces + UVs
    if (size < want) {
        std::fprintf(stderr,
                     "v3m: %s: size %zu < expected %zu (nov=%d nof=%d); parsing "
                     "partial payload\n",
                     name.c_str(), size, want, expectedNov, expectedNof);
    }

    V3DAsset a;
    a.name = name;
    a.type = 0;  // V3M is a bare morph target, not a typed object
    a.vertexCount = expectedNov;
    a.faceCount = expectedNof;

    if (!parsePayload(a, data, size)) return std::nullopt;
    return a;
}