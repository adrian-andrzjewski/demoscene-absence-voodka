// virtual_main.cpp - port of VIRTUAL/VIRTUAL.AS^, the standalone VR-engine
// test viewer (not part of the shipped demo link).
//
// Original flow: Allocate_System, Set13h, LoadVirtualObjects 'objects\world',
// wait for Escape, exit. The port: platform init (arena, window, input),
// loads the packed object archive (built by world_pack, WORLD.PAS semantics),
// registers every object with the real ported loader (vk_load_object) and
// reports what decoded, then idles until Escape / window close.
//
//   VIRTUAL.exe           load + report + idle until Escape
//   VIRTUAL.exe --check   load + report + exit (for CTest)

#include "platform_abi.h"
#include <windows.h>
#include <cstdio>
#include <cstring>
#include <vector>
#include <string>

extern "C" void vk_load_object(uint8_t* base, uint32_t fileOff, uint16_t texSel);
extern "C" uint32_t lo_objects[10];
extern "C" uint32_t lo_number;
extern "C" uint32_t lo_bump;

namespace {
constexpr const wchar_t* kWinClass = L"VOODKA_VIRTUAL";
volatile bool g_quit = false;
}

static LRESULT CALLBACK VWndProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_KEYDOWN) {
        UINT sc = (UINT)((l >> 16) & 0xFF);      // PC scancode
        if (sc == 0x01) g_quit = true;           // Escape
        return 0;
    }
    if (m == WM_DESTROY) { PostQuitMessage(0); g_quit = true; return 0; }
    return DefWindowProcW(h, m, w, l);
}

static std::wstring exeDir() {
    wchar_t p[MAX_PATH] = {};
    GetModuleFileNameW(nullptr, p, MAX_PATH);
    std::wstring d(p);
    auto s = d.find_last_of(L"\\/");
    return s == std::wstring::npos ? L"." : d.substr(0, s + 1);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE, LPSTR lpCmd, int) {
    vk::logInit();
    vk::logPrint("[virtual] VIRTUAL viewer port starting\n");

    bool checkOnly = lpCmd && std::strstr(lpCmd, "--check");

    // arena + archive search paths (exe dir data\world, then dev tree)
    if (!vk::platformInit()) { vk::logPrint("[virtual] arena init failed\n"); return 1; }

    std::vector<std::wstring> cands = { exeDir() + L"data\\world", exeDir() + L"world" };
    std::wstring dev(VOODKA_REPO_ROOT, VOODKA_REPO_ROOT + strlen(VOODKA_REPO_ROOT));
    cands.push_back(dev + L"/port/data/world");
    cands.push_back(dev + L"/demoscene-absence-voodka-master/VIRTUAL/OBJECTS/WORLD");

    std::vector<uint8_t> world;
    std::wstring used;
    for (auto& c : cands) {
        HANDLE h = CreateFileW(c.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
        if (h == INVALID_HANDLE_VALUE) continue;
        LARGE_INTEGER sz{}; GetFileSizeEx(h, &sz);
        world.resize((size_t)sz.QuadPart);
        DWORD rd = 0; ReadFile(h, world.data(), (DWORD)sz.QuadPart, &rd, nullptr);
        CloseHandle(h);
        used = c;
        break;
    }
    if (world.empty()) { vk::logPrint("[virtual] objects/world not found\n"); return 1; }
    vk::logPrint("[virtual] loaded %S (%zu bytes)\n", used.c_str(), world.size());

    // register objects with the real loader (the original merely walks the
    // offset table; we additionally parse each object so the load is proven)
    uint8_t* base = world.data();
    uint32_t count = *(uint32_t*)base;
    lo_number = 0;
    lo_bump = 0x02000000;   // same scratch region convention as the parts
    uint8_t* arena = vk::arena();
    // copy the archive into the arena so offsets behave like the demo's
    uint32_t worldOff = vk::arenaAlloc((uint32_t)world.size());
    memcpy(arena + worldOff, world.data(), world.size());
    uint32_t* tab = (uint32_t*)(arena + worldOff);
    for (uint32_t i = 0; i < count && i < 10; i++) {
        uint32_t off = worldOff + tab[1 + i];
        vk_load_object(arena, off, 0);
        uint32_t obj = lo_objects[i];
        int32_t type = *(int32_t*)(arena + obj + 0);
        int32_t nov  = *(int32_t*)(arena + obj + 4);
        int32_t nof  = *(int32_t*)(arena + obj + 8);
        vk::logPrint("[virtual] object %u: type=%d nov=%d nof=%d\n", i, type, nov, nof);
        std::printf("[virtual] object %u: type=%d nov=%d nof=%d\n", i, type, nov, nof);
    }
    std::printf("[virtual] %u object(s) loaded\n", count);

    if (checkOnly) { vk::logFlush(); return 0; }

    // minimal window (the original sat on a blank 13h screen until Escape)
    WNDCLASSW wc{};
    wc.lpfnWndProc = VWndProc;
    wc.hInstance = hInst;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.lpszClassName = kWinClass;
    wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
    RegisterClassW(&wc);
    HWND hwnd = CreateWindowExW(0, kWinClass, L"VIRTUAL viewer (Absence 1996) - Esc to quit",
                                WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT,
                                640, 400, nullptr, nullptr, hInst, nullptr);
    ShowWindow(hwnd, SW_SHOW);

    MSG msg;
    while (!g_quit && GetMessage(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    vk::logFlush();
    return 0;
}
