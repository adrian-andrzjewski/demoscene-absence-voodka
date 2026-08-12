// d3d11_dispatch.cpp - production-facing ABI for the assembly presenter.
//
// The shipped VOODKA target has no C++ D3D11 implementation.  All device,
// swap-chain, resource, upload, draw, readback, Present, and Release work is
// performed by d3d11_asm_present.asm.  This file keeps only the narrow ABI
// expected by the demo core plus host-side recording/diagnostic file I/O.
// The complete C++ presenter remains in d3d11_present.cpp, compiled only into
// VOODKA_REFERENCE for differential validation.

#include "platform_abi.h"

#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace vk {

namespace {

extern "C" uint32_t asm_present_init(void* hwnd, uint32_t width,
                                      uint32_t height);
extern "C" void asm_present_set_palette(const uint8_t* rgb6);
extern "C" uint32_t asm_present_draw(const uint8_t* arenaBase,
                                      uint32_t framebufferOffset);
extern "C" uint32_t asm_present_readback(uint8_t* out, uint32_t capacity);
extern "C" int32_t asm_present_present(void);
extern "C" void asm_present_shutdown(void);

uint8_t g_palette[kPaletteBytes] = {};
uint32_t g_width = 0;
uint32_t g_height = 0;
bool g_ready = false;
uint64_t g_presentCount = 0;

FILE* g_record = nullptr;

FILE* g_diagGpu = nullptr;
FILE* g_diagSource = nullptr;
FILE* g_diagPalette = nullptr;
bool g_diagEnabled = false;
uint32_t g_diagCaptured = 0;

void closeFile(FILE*& file) {
    if (file) {
        std::fclose(file);
        file = nullptr;
    }
}

void recordFrame(const uint8_t* frame) {
    if (!g_record) return;
    std::fwrite(frame, 1, kFramebufferBytes, g_record);
    std::fwrite(g_palette, 1, kPaletteBytes, g_record);
    std::fflush(g_record);
}

void closeDiagnosticFiles();

void captureDiagnostic(const uint8_t* frame) {
    if (!g_diagEnabled || g_diagCaptured >= 4) return;

    ++g_diagCaptured;
    std::fwrite(frame, 1, kFramebufferBytes, g_diagSource);
    std::fwrite(g_palette, 1, kPaletteBytes, g_diagPalette);
    std::fflush(g_diagSource);
    std::fflush(g_diagPalette);

    const uint64_t byteCount = static_cast<uint64_t>(g_width) * g_height * 4;
    if (byteCount > UINT32_MAX) {
        logPrint("[d3d] assembly readback diagnostic is too large\n");
        return;
    }

    std::vector<uint8_t> pixels(static_cast<size_t>(byteCount));
    if (asm_present_readback(pixels.data(), static_cast<uint32_t>(byteCount)) != 0) {
        logPrint("[d3d] assembly readback failed on diagnostic frame %u\n",
                 g_diagCaptured);
        return;
    }
    std::fwrite(pixels.data(), 1, pixels.size(), g_diagGpu);
    std::fflush(g_diagGpu);
}

} // namespace

void setAssemblyPresenter(bool enabled) {
    if (enabled) {
        logPrint("[d3d] presenter=native x64 assembly\n");
    } else {
        logPrint("[d3d] C++ presenter is unavailable in VOODKA.exe; "
                 "native x64 assembly remains active\n");
    }
}

bool initPresent(void* hwnd, int winW, int winH) {
    g_width = static_cast<uint32_t>(winW);
    g_height = static_cast<uint32_t>(winH);
    g_presentCount = 0;

    logPrint("[d3d] initPresent assembly(%p,%d,%d)\n", hwnd, winW, winH);
    const uint32_t result = asm_present_init(hwnd, g_width, g_height);
    if (result != 0) {
        logPrint("[d3d] assembly presenter init failed (%u)\n", result);
        g_ready = false;
        return false;
    }

    g_ready = true;
    logPrint("[d3d] assembly presenter ready\n");
    return true;
}

void setPalette(const uint8_t r[256], const uint8_t g[256],
                const uint8_t b[256]) {
    for (int i = 0; i < 256; ++i) {
        g_palette[i * 3 + 0] = r[i] & 63;
        g_palette[i * 3 + 1] = g[i] & 63;
        g_palette[i * 3 + 2] = b[i] & 63;
    }
}

void currentPalette(uint8_t out[kPaletteBytes]) {
    std::memcpy(out, g_palette, kPaletteBytes);
}

void selfTestPattern() {
    uint8_t* frame = arena() + kFramebufferOffset;
    static const uint8_t palette[8][3] = {
        {63, 0, 0}, {0, 63, 0}, {0, 0, 63}, {63, 63, 0},
        {0, 63, 63}, {63, 0, 63}, {63, 63, 63}, {31, 31, 31}
    };

    for (int i = 0; i < 256; ++i) {
        g_palette[i * 3 + 0] = palette[i & 7][0];
        g_palette[i * 3 + 1] = palette[i & 7][1];
        g_palette[i * 3 + 2] = palette[i & 7][2];
    }
    for (int y = 0; y < kScreenH; ++y) {
        for (int x = 0; x < kScreenW; ++x) {
            frame[y * kScreenW + x] =
                static_cast<uint8_t>(((x / 80) + (y / 50) * 2) & 7);
        }
    }
    logPrint("[d3d] selfTestPattern: wrote 4x4 8-color grid to framebuffer\n");
}

void recInit(const char* dir) {
    if (!dir) return;
    const std::string path = std::string(dir) + "\\frames.raw";
    closeFile(g_record);
    (void)fopen_s(&g_record, path.c_str(), "wb");
    if (g_record) logPrint("[rec] recording frames to %s\n", path.c_str());
}

void recClose() {
    closeFile(g_record);
}

void diagReadbackInit(const char* dir) {
    closeDiagnosticFiles();
    if (!dir) return;

    const std::string base = dir;
    (void)fopen_s(&g_diagGpu, (base + "\\frame_gpu.raw").c_str(), "wb");
    (void)fopen_s(&g_diagSource, (base + "\\frame_src.raw").c_str(), "wb");
    (void)fopen_s(&g_diagPalette, (base + "\\frame_pal.raw").c_str(), "wb");
    if (!g_diagGpu || !g_diagSource || !g_diagPalette) {
        logPrint("[d3d] assembly readback diagnostics could not open %s\n", dir);
        diagReadbackShutdown();
        return;
    }

    g_diagEnabled = true;
    g_diagCaptured = 0;
    logPrint("[d3d] assembly readback diagnostics on -> %s\n", dir);
}

void diagReadbackShutdown() {
    closeDiagnosticFiles();
}

namespace {
void closeDiagnosticFiles() {
    closeFile(g_diagGpu);
    closeFile(g_diagSource);
    closeFile(g_diagPalette);
    g_diagEnabled = false;
    g_diagCaptured = 0;
}
} // namespace

bool diagReadbackEnabled() {
    return g_diagEnabled;
}

void presentFrame() {
    updateInput();
    if (quitRequested()) shutdownAndExit();
    if (!g_ready) return;

    if ((g_presentCount++ & 0x3fff) == 0)
        logPrint("[d3d] assembly presentFrame #%llu\n",
                 static_cast<unsigned long long>(g_presentCount - 1));

    const uint8_t* frame = arena() + kFramebufferOffset;
    recordFrame(frame);
    asm_present_set_palette(g_palette);

    const uint32_t drawResult = asm_present_draw(arena(), kFramebufferOffset);
    if (drawResult != 0) {
        logPrint("[d3d] assembly presenter draw failed (%u)\n", drawResult);
        return;
    }
    captureDiagnostic(frame);

    const int32_t presentResult = asm_present_present();
    if (presentResult != 0 && presentResult != static_cast<int32_t>(0x087A0001)) {
        logPrint("[d3d] assembly Present failed (%08x)\n",
                 static_cast<unsigned>(presentResult));
    }
}

void shutdownPresent() {
    asm_present_shutdown();
    g_ready = false;
    g_width = 0;
    g_height = 0;
    g_presentCount = 0;
    std::memset(g_palette, 0, sizeof g_palette);
}

} // namespace vk
