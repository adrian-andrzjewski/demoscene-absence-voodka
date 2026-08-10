// d3d11_asm_probe.cpp - host window and assertions for the NASM D3D11 probe.
//
// This is a validation utility, not production presentation code. It owns
// only the HWND/COM apartment and fixed-width report checks; the D3D11 device,
// COM calls, readback, Present, and Release sequence live in NASM.

#include <windows.h>
#include <objbase.h>

#include <cstdint>
#include <cstdio>
#include <cstddef>

struct D3DAsmProbeReport {
    uint32_t initHr;
    uint32_t getBufferHr;
    uint32_t rtvHr;
    uint32_t stagingHr;
    uint32_t mapHr;
    uint32_t presentHr;
    uint32_t rowPitch;
    uint32_t firstPixel;
    uint32_t featureLevel;
};

static_assert(sizeof(D3DAsmProbeReport) == 36, "NASM report layout changed");
static_assert(offsetof(D3DAsmProbeReport, firstPixel) == 28,
              "NASM report offset changed");

extern "C" uint32_t asm_d3d11_probe(HWND hwnd, uint32_t width, uint32_t height,
                                    D3DAsmProbeReport* report);

static LRESULT CALLBACK probeWindowProc(HWND hwnd, UINT message,
                                        WPARAM wParam, LPARAM lParam) {
    if (message == WM_DESTROY) {
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, message, wParam, lParam);
}

int main() {
    const wchar_t* className = L"VOODKA_D3D11_ASM_PROBE";
    HINSTANCE instance = GetModuleHandleW(nullptr);

    WNDCLASSW wc{};
    wc.lpfnWndProc = probeWindowProc;
    wc.hInstance = instance;
    wc.lpszClassName = className;
    if (!RegisterClassW(&wc)) {
        std::fprintf(stderr, "RegisterClassW failed: %lu\n", GetLastError());
        return 1;
    }

    HWND hwnd = CreateWindowExW(0, className, L"VOODKA D3D11 ASM probe",
                                WS_OVERLAPPEDWINDOW, 0, 0, 640, 480,
                                nullptr, nullptr, instance, nullptr);
    if (!hwnd) {
        std::fprintf(stderr, "CreateWindowExW failed: %lu\n", GetLastError());
        UnregisterClassW(className, instance);
        return 1;
    }

    HRESULT comHr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool comInitialized = SUCCEEDED(comHr);

    D3DAsmProbeReport report{};
    const uint32_t result = asm_d3d11_probe(hwnd, 640, 480, &report);

    std::printf("asm_d3d11_probe result=%u init=%08X getbuffer=%08X "
                "rtv=%08X staging=%08X map=%08X present=%08X "
                "feature=%08X row_pitch=%u first_pixel=%08X\n",
                result, report.initHr, report.getBufferHr, report.rtvHr,
                report.stagingHr, report.mapHr, report.presentHr,
                report.featureLevel, report.rowPitch, report.firstPixel);

    if (comInitialized)
        CoUninitialize();
    DestroyWindow(hwnd);
    UnregisterClassW(className, instance);

    // FF 40 7F FF in memory is 0xFF7F40FF as a little-endian uint32_t.
    // A hidden validation window may return DXGI_STATUS_OCCLUDED from
    // Present. That is a successful API execution for this probe; a visible
    // application window returns S_OK instead.
    const bool presentOk = report.presentHr == 0 || report.presentHr == 0x087A0001u;
    const bool reportOk =
        result == 0 && report.initHr == 0 && report.getBufferHr == 0 &&
        report.rtvHr == 0 && report.stagingHr == 0 && report.mapHr == 0 &&
        presentOk && report.featureLevel == 0xB000 &&
        report.rowPitch >= 640u * 4u && report.firstPixel == 0xFF7F40FFu;
    return reportOk ? 0 : 1;
}
