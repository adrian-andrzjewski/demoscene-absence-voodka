// d3d11_asm_present_probe.cpp - host-side differential test for the complete
// assembly presenter. HWND creation and COM apartment setup are the only
// platform operations owned by this validation host.

#include <windows.h>
#include <objbase.h>

#include <cstdint>
#include <cstdio>
#include <vector>

extern "C" uint32_t asm_present_init(HWND hwnd, uint32_t width, uint32_t height);
extern "C" void asm_present_set_palette(const uint8_t* interleavedRgb6);
extern "C" uint32_t asm_present_draw(const uint8_t* arenaBase,
                                      uint32_t framebufferOffset);
extern "C" uint32_t asm_present_readback(uint8_t* out, uint32_t capacity);
extern "C" int32_t asm_present_present(void);
extern "C" void asm_present_shutdown(void);

static LRESULT CALLBACK probeWindowProc(HWND hwnd, UINT message,
                                        WPARAM wParam, LPARAM lParam) {
    if (message == WM_DESTROY) {
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, message, wParam, lParam);
}

static uint8_t vgaTo8(uint8_t value) {
    return static_cast<uint8_t>(
        (static_cast<unsigned>(value & 63u) * 255u + 31u) / 63u);
}

int main() {
    constexpr uint32_t kLogicWidth = 320;
    constexpr uint32_t kLogicHeight = 200;
    constexpr uint32_t kFramebufferOffset = 0x20000;
    constexpr uint32_t kDxgiStatusOccluded = 0x087A0001u;

    const wchar_t* className = L"VOODKA_D3D11_ASM_PRESENTER_PROBE";
    HINSTANCE instance = GetModuleHandleW(nullptr);
    WNDCLASSW wc{};
    wc.lpfnWndProc = probeWindowProc;
    wc.hInstance = instance;
    wc.lpszClassName = className;
    if (!RegisterClassW(&wc)) {
        std::fprintf(stderr, "RegisterClassW failed: %lu\n", GetLastError());
        return 1;
    }

    const HRESULT comHr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool comInitialized = SUCCEEDED(comHr);

    std::vector<uint8_t> arena(kFramebufferOffset + kLogicWidth * kLogicHeight);
    std::vector<uint8_t> palette(768);
    for (uint32_t i = 0; i < 256; ++i) {
        palette[i * 3 + 0] = static_cast<uint8_t>(i & 63u);
        palette[i * 3 + 1] = static_cast<uint8_t>((i * 3u) & 63u);
        palette[i * 3 + 2] = static_cast<uint8_t>((63u - i) & 63u);
    }
    for (uint32_t y = 0; y < kLogicHeight; ++y) {
        for (uint32_t x = 0; x < kLogicWidth; ++x) {
            arena[kFramebufferOffset + y * kLogicWidth + x] =
                static_cast<uint8_t>(((x / 80u) + (y / 50u) * 2u) & 7u);
        }
    }

    struct Case { uint32_t width; uint32_t height; };
    const Case cases[] = {{640, 400}, {1920, 1080}};
    size_t totalMismatches = 0;
    bool allPassed = true;
    uint32_t lastInit = 1;
    uint32_t lastDraw = 1;
    uint32_t lastReadback = 1;
    uint32_t lastPresent = 0xffffffffu;

    for (const Case test : cases) {
        HWND hwnd = CreateWindowExW(0, className,
                                    L"VOODKA assembly presenter probe",
                                    WS_POPUP, 0, 0,
                                    static_cast<int>(test.width),
                                    static_cast<int>(test.height),
                                    nullptr, nullptr, instance, nullptr);
        if (!hwnd) {
            std::fprintf(stderr, "CreateWindowExW failed: %lu\n", GetLastError());
            allPassed = false;
            continue;
        }

        const uint32_t init = asm_present_init(hwnd, test.width, test.height);
        uint32_t draw = 1;
        uint32_t readback = 1;
        int32_t present = -1;
        size_t mismatches = 0;
        std::vector<uint8_t> gpu(static_cast<size_t>(test.width) *
                                 test.height * 4u);

        if (init == 0) {
            asm_present_set_palette(palette.data());
            draw = asm_present_draw(arena.data(), kFramebufferOffset);
            if (draw == 0)
                readback = asm_present_readback(
                    gpu.data(), static_cast<uint32_t>(gpu.size()));

            const uint32_t scaleX = test.width / kLogicWidth;
            const uint32_t scaleY = test.height / kLogicHeight;
            const uint32_t scale = scaleX < scaleY ? scaleX : scaleY;
            const uint32_t contentWidth = kLogicWidth * scale;
            const uint32_t contentHeight = kLogicHeight * scale;
            const uint32_t offsetX = (test.width - contentWidth) / 2u;
            const uint32_t offsetY = (test.height - contentHeight) / 2u;

            if (readback == 0) {
                for (uint32_t y = 0; y < test.height; ++y) {
                    for (uint32_t x = 0; x < test.width; ++x) {
                        const bool inContent =
                            x >= offsetX && x < offsetX + contentWidth &&
                            y >= offsetY && y < offsetY + contentHeight;
                        uint8_t expected[4] = {0, 0, 0, 255};
                        if (inContent) {
                            const uint32_t sx = (x - offsetX) / scale;
                            const uint32_t sy = (y - offsetY) / scale;
                            const uint8_t index = static_cast<uint8_t>(
                                ((sx / 80u) + (sy / 50u) * 2u) & 7u);
                            const uint8_t* rgb = &palette[index * 3u];
                            expected[0] = vgaTo8(rgb[0]);
                            expected[1] = vgaTo8(rgb[1]);
                            expected[2] = vgaTo8(rgb[2]);
                        }
                        const size_t pixel =
                            (static_cast<size_t>(y) * test.width + x) * 4u;
                        for (uint32_t c = 0; c < 4; ++c)
                            mismatches += gpu[pixel + c] != expected[c];
                    }
                }
            }
            present = asm_present_present();
        }

        asm_present_shutdown();
        DestroyWindow(hwnd);

        const uint32_t presentBits = static_cast<uint32_t>(present);
        const bool presentOk = presentBits == 0 ||
                               presentBits == kDxgiStatusOccluded;
        allPassed &= init == 0 && draw == 0 && readback == 0 && presentOk &&
                     mismatches == 0;
        totalMismatches += mismatches;
        lastInit = init;
        lastDraw = draw;
        lastReadback = readback;
        lastPresent = presentBits;
        std::printf("asm_present_case %ux%u init=%u draw=%u readback=%u "
                    "present=%08X mismatches=%zu\n",
                    test.width, test.height, init, draw, readback,
                    presentBits, mismatches);
    }

    if (comInitialized)
        CoUninitialize();
    UnregisterClassW(className, instance);
    std::printf("asm_present_probe total_mismatches=%zu last=%u/%u/%u/%08X\n",
                totalMismatches, lastInit, lastDraw, lastReadback, lastPresent);
    return allPassed ? 0 : 1;
}
