// p4_raster_probe.cpp - deterministic NASM-vs-C++ processorek Nevosolek
// rasterizer witness.

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>

struct ProcessorekNevosolekDrawArgs {
    int32_t xy[6];
    uint32_t uv[3];
    const uint8_t* texture;
    uint8_t* screen;
    uint32_t color;
};

static_assert(offsetof(ProcessorekNevosolekDrawArgs, texture) == 40);
static_assert(offsetof(ProcessorekNevosolekDrawArgs, screen) == 48);
static_assert(offsetof(ProcessorekNevosolekDrawArgs, color) == 56);

extern "C" void vk_processorek_nevosolek_draw_triangle_asm(const ProcessorekNevosolekDrawArgs* args);

namespace {

constexpr int kWidth = 320;
constexpr int kHeight = 200;
constexpr size_t kPixels = static_cast<size_t>(kWidth) * kHeight;

void referenceTriangle(const ProcessorekNevosolekDrawArgs* a) {
    struct V { double x, y, u, v; } v[3] = {
        {double(a->xy[0]), double(a->xy[1]),
         double((a->uv[0] >> 8) & 0xff), double((a->uv[0] >> 24) & 0xff)},
        {double(a->xy[2]), double(a->xy[3]),
         double((a->uv[1] >> 8) & 0xff), double((a->uv[1] >> 24) & 0xff)},
        {double(a->xy[4]), double(a->xy[5]),
         double((a->uv[2] >> 8) & 0xff), double((a->uv[2] >> 24) & 0xff)}
    };
    if (v[1].y < v[0].y) std::swap(v[0], v[1]);
    if (v[2].y < v[0].y) std::swap(v[0], v[2]);
    if (v[2].y < v[1].y) std::swap(v[1], v[2]);
    const int y0 = (std::max)(0, (int)std::ceil(v[0].y));
    const int y1 = (std::min)(199, (int)std::floor(v[2].y));
    if (y0 > y1) return;
    const double area = (v[2].x - v[0].x) * (v[1].y - v[0].y) -
                        (v[2].y - v[0].y) * (v[1].x - v[0].x);
    if (area == 0.0) return;
    auto edge = [](const V& a, const V& b, double y) {
        const double t = (b.y == a.y) ? 0.0 : (y - a.y) / (b.y - a.y);
        return V{a.x + (b.x - a.x) * t, y,
                 a.u + (b.u - a.u) * t, a.v + (b.v - a.v) * t};
    };
    for (int y = y0; y <= y1; ++y) {
        const double yy = double(y);
        const V longEdge = edge(v[0], v[2], yy);
        const V shortEdge = (yy < v[1].y) ? edge(v[0], v[1], yy)
                                          : edge(v[1], v[2], yy);
        V left = longEdge, right = shortEdge;
        if (left.x > right.x) std::swap(left, right);
        const int xa = (std::max)(0, (int)std::ceil(left.x));
        const int xb = (std::min)(319, (int)std::floor(right.x));
        if (xa > xb) continue;
        const double width = right.x - left.x;
        for (int x = xa; x <= xb; ++x) {
            const double t = width == 0.0 ? 0.0 :
                (double(x) - left.x) / width;
            const int u = (int)(left.u + (right.u - left.u) * t);
            const int vv = (int)(left.v + (right.v - left.v) * t);
            const uint8_t texel = a->texture[((vv & 0xff) << 8) | (u & 0xff)];
            a->screen[y * kWidth + x] = uint8_t(texel + a->color);
        }
    }
}

uint32_t packedUv(uint8_t u, uint8_t v) {
    return (static_cast<uint32_t>(u) << 8) |
           (static_cast<uint32_t>(v) << 24);
}

} // namespace

int main() {
    std::array<uint8_t, 65536> texture{};
    for (size_t i = 0; i < texture.size(); ++i)
        texture[i] = static_cast<uint8_t>((i * 37u + (i >> 8) * 11u) & 0xff);

    const ProcessorekNevosolekDrawArgs cases[] = {
        {{10, 20, 200, 35, 70, 180},
         {packedUv(3, 7), packedUv(211, 19), packedUv(127, 250)}, nullptr, nullptr, 5},
        {{70, 180, 10, 20, 200, 35},
         {packedUv(127, 250), packedUv(3, 7), packedUv(211, 19)}, nullptr, nullptr, 0},
        {{-80, -30, 410, 40, 120, 260},
         {packedUv(255, 0), packedUv(1, 254), packedUv(200, 128)}, nullptr, nullptr, 63},
        {{0, 100, 319, 100, 160, 0},
         {packedUv(15, 15), packedUv(31, 31), packedUv(63, 63)}, nullptr, nullptr, 129},
        {{0, 0, 160, 100, 319, 199},
         {packedUv(0, 0), packedUv(128, 128), packedUv(255, 255)}, nullptr, nullptr, 255},
        {{-300, 20, -100, 40, -200, 180},
         {packedUv(1, 1), packedUv(2, 2), packedUv(3, 3)}, nullptr, nullptr, 17},
        {{50, 50, 150, 50, 250, 50},
         {packedUv(8, 240), packedUv(80, 160), packedUv(240, 8)}, nullptr, nullptr, 33},
        {{319, 0, 500, 200, 0, 199},
         {packedUv(240, 240), packedUv(120, 120), packedUv(8, 8)}, nullptr, nullptr, 201},
    };

    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
        std::array<uint8_t, kPixels> reference{};
        std::array<uint8_t, kPixels> assembly{};
        reference.fill(0xa5);
        assembly.fill(0xa5);

        ProcessorekNevosolekDrawArgs ref = cases[i];
        ref.texture = texture.data();
        ref.screen = reference.data();
        ProcessorekNevosolekDrawArgs asmArgs = ref;
        asmArgs.screen = assembly.data();
        referenceTriangle(&ref);
        vk_processorek_nevosolek_draw_triangle_asm(&asmArgs);
        if (std::memcmp(reference.data(), assembly.data(), kPixels) != 0) {
            size_t mismatch = 0;
            while (mismatch < kPixels && reference[mismatch] == assembly[mismatch])
                ++mismatch;
            std::fprintf(stderr,
                         "processorek Nevosolek (P4) raster mismatch case=%zu pixel=%zu ref=%u asm=%u\n",
                         i, mismatch,
                         static_cast<unsigned>(reference[mismatch]),
                         static_cast<unsigned>(assembly[mismatch]));
            return 1;
        }
    }
    return 0;
}
