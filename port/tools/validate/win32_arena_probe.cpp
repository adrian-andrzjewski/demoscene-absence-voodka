// win32_arena_probe.cpp - production NASM arena/archive service witness.

#include "platform_abi.h"

#include <cstddef>
#include <cstdint>

extern "C" void vk_log_printf(const char*, ...) {}

int main() {
    if (!vk::platformInit()) return 1;

    uint8_t* base = vk::arena();
    if (!base) return 2;

    const uint32_t first = vk::arenaAlloc(1);
    if (first != 0x00040000) return 3;
    for (uint32_t i = 0; i < 16; ++i) {
        if (base[first + i] != 0) return 4;
    }

    const uint32_t second = vk::arenaAlloc(17);
    if (second != 0x00040010) return 5;
    for (uint32_t i = 0; i < 32; ++i) {
        if (base[second + i] != 0) return 6;
    }
    const uint32_t archive = vk::loadInternalFile("VoOdKa.DaT");
    if (!archive || !vk::archiveBytes() || vk::archiveSize() == 0) return 7;
    if (archive == first || archive == second) return 8;
    if (vk::loadInternalFile("vodka.dat") != archive) return 9;
    const auto* source = static_cast<const uint8_t*>(vk::archiveBytes());
    const auto* copy = base + archive;
    for (size_t i = 0; i < vk::archiveSize(); ++i) {
        if (source[i] != copy[i]) return 10;
    }
    const uint32_t archiveHeader =
        *reinterpret_cast<const uint32_t*>(base + archive);
    if (archiveHeader != 8000) return 11;

    vk::platformShutdown();
    if (vk::arena() != nullptr || vk::archiveBytes() != nullptr ||
        vk::archiveSize() != 0) return 12;
    return 0;
}
