// audio_lookup_probe.cpp - NASM lower_bound vs the C++ seek oracle.

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <vector>

extern "C" uint32_t asm_audio_lower_bound_u32(const uint32_t* values,
                                                uint32_t count,
                                                uint32_t key);

static uint32_t oracle(const std::vector<uint32_t>& values, uint32_t key) {
    const auto it = std::lower_bound(values.begin(), values.end(), key);
    if (it == values.end()) return static_cast<uint32_t>(values.size() - 1);
    return static_cast<uint32_t>(it - values.begin());
}

static bool check(const std::vector<uint32_t>& values, uint32_t key) {
    const uint32_t* data = values.empty() ? nullptr : values.data();
    const uint32_t got = asm_audio_lower_bound_u32(
        data, static_cast<uint32_t>(values.size()), key);
    const uint32_t want = oracle(values, key);
    if (got == want) return true;
    std::fprintf(stderr, "lookup mismatch count=%zu key=%u got=%u want=%u\n",
                 values.size(), key, got, want);
    return false;
}

int main() {
    bool ok = true;
    ok &= check({}, 0);
    ok &= check({0}, 0);
    ok &= check({0}, 1);
    ok &= check({3, 3, 3, 9}, 3);
    ok &= check({3, 3, 3, 9}, 4);
    ok &= check({3, 3, 3, 9}, 99);

    uint32_t state = 0x13579bdfu;
    for (uint32_t count = 1; count <= 257; ++count) {
        std::vector<uint32_t> values(count);
        for (uint32_t i = 0; i < count; ++i) {
            state = state * 1664525u + 1013904223u;
            values[i] = (state >> 7) & 0x3fu; // deliberate duplicates
        }
        std::sort(values.begin(), values.end());
        for (uint32_t key = 0; key < 128; ++key) {
            if (!check(values, key)) ok = false;
        }
    }
    return ok ? 0 : 1;
}
