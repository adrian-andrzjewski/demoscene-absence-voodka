// win32_d3d_dispatch_probe.cpp - production NASM D3D11 service witness.

#include "platform_abi.h"
#include <windows.h>

#include <array>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

namespace {

constexpr size_t kArenaBytes = 0x20000u + 320u * 200u;
constexpr size_t kFrameBytes = 320u * 200u;
constexpr size_t kPaletteBytes = 768u;
constexpr size_t kGpuBytes = 128u * 64u * 4u;

std::array<uint8_t, kArenaBytes> g_arena{};
std::array<uint8_t, kPaletteBytes> g_uploadedPalette{};
int g_initCalls = 0;
int g_setPaletteCalls = 0;
int g_drawCalls = 0;
int g_readbackCalls = 0;
int g_presentCalls = 0;
int g_shutdownCalls = 0;
int g_updateInputCalls = 0;
int g_shutdownExitCalls = 0;
uint32_t g_lastDrawOffset = 0;
uint32_t g_lastReadbackCapacity = 0;
std::string g_log;

std::vector<uint8_t> readFile(const std::string& path) {
    std::ifstream input(path, std::ios::binary);
    if (!input) return {};
    input.seekg(0, std::ios::end);
    const std::streamoff size = input.tellg();
    input.seekg(0, std::ios::beg);
    if (size < 0) return {};
    std::vector<uint8_t> bytes(static_cast<size_t>(size));
    input.read(reinterpret_cast<char*>(bytes.data()), size);
    return bytes;
}

bool checkFile(const std::string& path, const uint8_t* expected, size_t count) {
    const auto bytes = readFile(path);
    return bytes.size() == count && std::memcmp(bytes.data(), expected, count) == 0;
}

bool checkFrameFile(const std::string& path, const uint8_t* frame,
                    const uint8_t* palette) {
    const auto bytes = readFile(path);
    return bytes.size() == kFrameBytes + kPaletteBytes &&
           std::memcmp(bytes.data(), frame, kFrameBytes) == 0 &&
           std::memcmp(bytes.data() + kFrameBytes, palette, kPaletteBytes) == 0;
}

bool checkGpuFile(const std::string& path) {
    const auto bytes = readFile(path);
    if (bytes.size() != kGpuBytes) return false;
    for (uint8_t value : bytes) if (value != 0x5a) return false;
    return true;
}

void cleanup(const std::string& dir) {
    const char* names[] = {
        "frames.raw", "frame_gpu.raw", "frame_src.raw", "frame_pal.raw"
    };
    for (const char* name : names)
        DeleteFileA((dir + "\\" + name).c_str());
    RemoveDirectoryA(dir.c_str());
}

} // namespace

extern "C" uint64_t vk_arena_get() {
    return reinterpret_cast<uint64_t>(g_arena.data());
}
extern "C" void* vk_framebuffer_ptr() {
    return g_arena.data() + 0x20000;
}
extern "C" void vk_platform_update_input() { ++g_updateInputCalls; }
extern "C" int vk_platform_quit_requested() { return 0; }
extern "C" void vk_app_shutdown_and_exit() { ++g_shutdownExitCalls; }

extern "C" void vk_log_printf(const char* format, ...) {
    char line[512]{};
    va_list ap;
    va_start(ap, format);
    std::vsnprintf(line, sizeof(line), format, ap);
    va_end(ap);
    g_log += line;
}

extern "C" uint32_t asm_present_init(void*, uint32_t width, uint32_t height) {
    ++g_initCalls;
    return width == 128 && height == 64 ? 0u : 1u;
}
extern "C" void asm_present_set_palette(const uint8_t* palette) {
    ++g_setPaletteCalls;
    std::memcpy(g_uploadedPalette.data(), palette, kPaletteBytes);
}
extern "C" uint32_t asm_present_draw(const uint8_t* arena, uint32_t offset) {
    ++g_drawCalls;
    g_lastDrawOffset = offset;
    return arena == g_arena.data() && offset == 0x20000 ? 0u : 1u;
}
extern "C" uint32_t asm_present_readback(uint8_t* out, uint32_t capacity) {
    ++g_readbackCalls;
    g_lastReadbackCapacity = capacity;
    if (capacity != kGpuBytes) return 1;
    std::memset(out, 0x5a, capacity);
    return 0;
}
extern "C" int32_t asm_present_present() {
    ++g_presentCalls;
    return 0;
}
extern "C" void asm_present_shutdown() { ++g_shutdownCalls; }

int main() {
    const std::string dir = "win32_d3d_dispatch_probe_artifacts";
    cleanup(dir);
    CreateDirectoryA(dir.c_str(), nullptr);

    if (!vk::initPresent(nullptr, 128, 64)) return 1;
    vk::selfTestPattern();
    const uint8_t* selfFrame = g_arena.data() + 0x20000;
    if (selfFrame[0] != 0 || selfFrame[79] != 0 || selfFrame[80] != 1 ||
        selfFrame[50 * 320] != 2) return 2;

    std::array<uint8_t, 256> r{}, g{}, b{};
    for (int i = 0; i < 256; ++i) {
        r[i] = static_cast<uint8_t>(i);
        g[i] = static_cast<uint8_t>(i + 1);
        b[i] = static_cast<uint8_t>(i + 2);
    }
    vk::setPalette(r.data(), g.data(), b.data());
    std::array<uint8_t, kPaletteBytes> palette{};
    vk::currentPalette(palette.data());
    for (int i = 0; i < 256; ++i) {
        if (palette[i * 3 + 0] != (r[i] & 63) ||
            palette[i * 3 + 1] != (g[i] & 63) ||
            palette[i * 3 + 2] != (b[i] & 63)) return 3;
    }

    auto* frame = g_arena.data() + 0x20000;
    for (size_t i = 0; i < kFrameBytes; ++i)
        frame[i] = static_cast<uint8_t>((i * 13u + 7u) & 0xff);
    vk::recInit(dir.c_str());
    vk::diagReadbackInit(dir.c_str());
    if (!vk::diagReadbackEnabled()) {
        std::fprintf(stderr, "diagnostic init failed: %s\n", g_log.c_str());
        cleanup(dir);
        return 4;
    }
    vk::presentFrame();

    const std::string frames = dir + "\\frames.raw";
    const std::string source = dir + "\\frame_src.raw";
    const std::string palettePath = dir + "\\frame_pal.raw";
    const std::string gpu = dir + "\\frame_gpu.raw";
    if (!checkFrameFile(frames, frame, palette.data()) ||
        !checkFile(source, frame, kFrameBytes) ||
        !checkFile(palettePath, palette.data(), kPaletteBytes) ||
        !checkGpuFile(gpu)) return 5;

    vk::diagReadbackShutdown();
    vk::recClose();
    vk::shutdownPresent();
    const bool ok =
        g_initCalls == 1 && g_setPaletteCalls == 1 && g_drawCalls == 1 &&
        g_readbackCalls == 1 && g_lastReadbackCapacity == kGpuBytes &&
        g_presentCalls == 1 && g_shutdownCalls == 1 &&
        g_updateInputCalls == 1 && g_shutdownExitCalls == 0 &&
        g_lastDrawOffset == 0x20000 &&
        g_log.find("assembly readback diagnostics on ->") != std::string::npos;
    cleanup(dir);
    return ok ? 0 : 6;
}
