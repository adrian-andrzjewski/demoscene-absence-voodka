// viewer_main.cpp - standalone V3D/V3M asset viewer (validation tool).
//
// Loads all 9 V3D/V3M models from the vodka.dat archive (entries 12-15,
// 31-35), renders the current one flat-shaded or wireframe with an orbit
// camera, and shows the model's debug metadata in the window title.
//
// Keys:             1-9 or [ ]  switch model,  Space  wireframe,
//                    R    auto-rotate,   Esc    quit
//  Mouse:            drag orbit camera,  wheel  zoom

#include <windows.h>

#include <cstdarg>
#include <cstdio>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "v3d_entries.h"
#include "v3d_parser.h"
#include "datas_entries.h"
#include "datas_parser.h"
#include "renderer.h"

namespace {

// Optional diagnostics: set VOODKA_VIEWER_LOG to a file path to trace
// init/render/frame pacing (normal runs are unaffected).
FILE* g_log = nullptr;

void logLine(const char* fmt, ...) {
    if (!g_log) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
    fprintf(g_log, "\n");
    fflush(g_log);
}

// ---- archive access ---------------------------------------------------------
std::vector<uint8_t> g_archive;

uint32_t le32(const uint8_t* p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

bool loadArchive() {
    wchar_t exePath[MAX_PATH] = {};
    GetModuleFileNameW(nullptr, exePath, MAX_PATH);
    std::wstring dir(exePath);
    auto slash = dir.find_last_of(L"\\/");
    if (slash != std::wstring::npos) dir = dir.substr(0, slash + 1);

    std::vector<std::wstring> cands;
    cands.push_back(dir + L"data\\vodka.dat");
    cands.push_back(dir + L"vodka.dat");
#ifdef VOODKA_REPO_ROOT
    {
        std::wstring dev(VOODKA_REPO_ROOT, VOODKA_REPO_ROOT + strlen(VOODKA_REPO_ROOT));
        cands.push_back(dev + L"/port/data/vodka.dat");
    }
#endif

    for (const auto& c : cands) {
        HANDLE h = CreateFileW(c.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                               OPEN_EXISTING, 0, nullptr);
        if (h == INVALID_HANDLE_VALUE) continue;
        LARGE_INTEGER sz{};
        GetFileSizeEx(h, &sz);
        g_archive.resize((size_t)sz.QuadPart);
        DWORD rd = 0;
        ReadFile(h, g_archive.data(), (DWORD)sz.QuadPart, &rd, nullptr);
        CloseHandle(h);
        std::printf("[viewer] loaded archive %ls (%zu bytes)\n", c.c_str(),
                    g_archive.size());
        return true;
    }
    return false;
}

bool archiveEntry(unsigned idx, std::vector<uint8_t>& out) {
    if (g_archive.size() < 8000) return false;
    const uint8_t* ent = &g_archive[(size_t)idx * 8];
    uint32_t off = le32(ent);
    uint32_t sz = le32(ent + 4);
    if ((size_t)off + sz > g_archive.size()) return false;
    out.assign(g_archive.begin() + off, g_archive.begin() + off + sz);
    return true;
}

// ---- state ------------------------------------------------------------------
std::vector<V3DAsset> g_assets;   // loaded models, archive order
int                  g_current = -1;
Renderer             g_renderer;
bool                 g_wireframe = false;
bool                 g_autoRotate = true;
float                g_rotAngle = 0.0f;
float                g_elevAngle = 0.5f;
float                g_orbitRadius = 10.0f;
float                g_near = 0.01f, g_far = 1000.0f;
float                g_defaultOrbit = 10.0f;
float                g_camTarget[3] = {0, 0, 0};
bool                 g_dragging = false;
int                  g_lastX = 0, g_lastY = 0;
HWND                 g_hwnd = nullptr;

bool isV3M(const char* name) {
    size_t n = strlen(name);
    const char* dot = name + n - 4;
    return n > 4 && dot[0] == '.' &&
           (dot[1] == 'v' || dot[1] == 'V') &&
           (dot[2] == '3') && (dot[3] == 'm' || dot[3] == 'M');
}

const char* typeName(int t) {
    switch (t) {
        case 0: return "PIXELS";
        case 1: return "TEXTURES";
        case 3: return "DATAS";
        default: return "PHONG";
    }
}

// Expand faces into a 6-float-per-vertex render stream (x,y,z + face normal),
// i.e. flat shading: every corner of every face carries its face's normal.
std::vector<float> g_faceStream;

bool buildFaceStream(const V3DAsset& a) {
    g_faceStream.resize((size_t)a.faceCount * 3 * 6);
    for (int f = 0; f < a.faceCount; ++f) {
        const float* n = &a.faceNormals[(size_t)f * 3];
        for (int k = 0; k < 3; ++k) {
            uint32_t vi = a.faces[(size_t)f * 3 + (size_t)k];
            const float* v = &a.vertices[(size_t)vi * 3];
            float* d = &g_faceStream[((size_t)f * 3 + (size_t)k) * 6];
            d[0] = v[0]; d[1] = v[1]; d[2] = v[2];
            d[3] = n[0]; d[4] = n[1]; d[5] = n[2];
        }
    }
    return true;
}

void computeBounds(const V3DAsset& a, float& cx, float& cy, float& cz,
                   float& radius) {
    cx = cy = cz = 0.0f;
    for (int i = 0; i < a.vertexCount; ++i) {
        cx += a.vertices[(size_t)i * 3 + 0];
        cy += a.vertices[(size_t)i * 3 + 1];
        cz += a.vertices[(size_t)i * 3 + 2];
    }
    cx /= (float)a.vertexCount;
    cy /= (float)a.vertexCount;
    cz /= (float)a.vertexCount;
    radius = 0.0f;
    for (int i = 0; i < a.vertexCount; ++i) {
        float dx = a.vertices[(size_t)i * 3 + 0] - cx;
        float dy = a.vertices[(size_t)i * 3 + 1] - cy;
        float dz = a.vertices[(size_t)i * 3 + 2] - cz;
        float d = std::sqrt(dx * dx + dy * dy + dz * dz);
        if (d > radius) radius = d;
    }
}

void showAsset(int index) {
    if (index < 0 || index >= (int)g_assets.size()) return;
    const V3DAsset& a = g_assets[index];
    if (!buildFaceStream(a)) return;
    g_renderer.setModel(g_faceStream.data(), a.faceCount);

    float r;
    computeBounds(a, g_camTarget[0], g_camTarget[1], g_camTarget[2], r);
    g_orbitRadius = r * 2.0f;
    if (g_orbitRadius < 0.001f) g_orbitRadius = 10.0f;
    g_defaultOrbit = g_orbitRadius;
    g_near = r * 0.01f;
    if (g_near < 0.001f) g_near = 0.001f;
    g_far = (r == 0.0f) ? 1000.0f : r * 20.0f;
    g_rotAngle = 0.0f;
    g_elevAngle = 0.5f;

    char title[256];
    std::snprintf(title, sizeof title,
                  "V3D Asset Viewer - %s [%d/%d] %dv %df [%s]   "
                  "(1-9 or [ ] switch, Space wireframe, R rotate, drag orbit, wheel zoom)",
                  a.name.c_str(), index + 1, (int)g_assets.size(),
                  a.vertexCount, a.faceCount, typeName(a.type));
    if (g_hwnd) SetWindowTextA(g_hwnd, title);
    g_current = index;
}

int selectTorus() {
    for (size_t i = 0; i < g_assets.size(); ++i)
        if (g_assets[i].name == "torus.v3d")
            return (int)i;
    return 0;
}

// ---- window procedure -------------------------------------------------------
LRESULT CALLBACK wndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
        case WM_KEYDOWN:
            if (wp >= '1' && wp <= '9') {
                int idx = (int)(wp - '1');
                if (idx < (int)g_assets.size()) showAsset(idx);
                return 0;
            }
            if (wp == VK_OEM_4) {   // '[' - previous model (wraps)
                int n = (int)g_assets.size();
                int cur = g_current < 0 ? 0 : g_current;
                if (n > 0) showAsset((cur + n - 1) % n);
                return 0;
            }
            if (wp == VK_OEM_6) {   // ']' - next model (wraps)
                int n = (int)g_assets.size();
                int cur = g_current < 0 ? 0 : g_current;
                if (n > 0) showAsset((cur + 1) % n);
                return 0;
            }
            if (wp == VK_SPACE) {
                g_wireframe = !g_wireframe;
                g_renderer.setWireframe(g_wireframe);
                return 0;
            }
            if (wp == 'R' || wp == 'r') {
                g_autoRotate = !g_autoRotate;
                return 0;
            }
            if (wp == VK_ESCAPE) {
                DestroyWindow(hwnd);
                return 0;
            }
            return 0;

        case WM_LBUTTONDOWN:
            g_dragging = true;
            g_lastX = (int)(short)LOWORD(lp);
            g_lastY = (int)(short)HIWORD(lp);
            SetCapture(hwnd);
            return 0;
        case WM_LBUTTONUP:
            g_dragging = false;
            ReleaseCapture();
            return 0;
        case WM_MOUSEMOVE:
            if (g_dragging) {
                int x = (int)(short)LOWORD(lp);
                int y = (int)(short)HIWORD(lp);
                g_rotAngle += (float)(x - g_lastX) * 0.005f;
                g_elevAngle += (float)(y - g_lastY) * 0.005f;
                if (g_elevAngle > 1.2f) g_elevAngle = 1.2f;
                if (g_elevAngle < -1.2f) g_elevAngle = -1.2f;
                g_autoRotate = false;
                g_lastX = x;
                g_lastY = y;
            }
            return 0;
        case WM_MOUSEWHEEL: {
            // zoom: /120 notches; clamp to [0.2x, 10x] of the model's
            // default orbit distance
            float delta = -(float)(short)HIWORD(wp) / 120.0f;
            g_orbitRadius *= (1.0f + delta * 0.2f);
            if (g_orbitRadius < g_defaultOrbit * 0.2f)
                g_orbitRadius = g_defaultOrbit * 0.2f;
            if (g_orbitRadius > g_defaultOrbit * 10.0f)
                g_orbitRadius = g_defaultOrbit * 10.0f;
            return 0;
        }
        case WM_SIZE:
            if (g_renderer.swapchain() && wp != SIZE_MINIMIZED) {
                int w = (int)(short)LOWORD(lp);
                int h = (int)(short)HIWORD(lp);
                if (w > 0 && h > 0) g_renderer.resize(w, h);
            }
            return 0;
        case WM_DESTROY:
            PostQuitMessage(0);
            return 0;
    }
    return DefWindowProc(hwnd, msg, wp, lp);
}

}  // namespace

// ---- original-tree CODE/DATAS compile-time meshes ---------------------------
// 16 vertex/face (.INC) pairs assembled into the EXE at TASM time; read
// straight from the original source tree (dev/reference fallback via
// VOODKA_REPO_ROOT).
void loadDatasModels() {
#ifdef VOODKA_REPO_ROOT
    std::string base = std::string(VOODKA_REPO_ROOT) +
                       "/demoscene-absence-voodka-master/CODE/DATAS/";
    int loaded = 0;
    for (int i = 0; i < kDatasPairCount; ++i) {
        const DatasPair& p = kDatasPairs[i];
        auto asset = loadDatasMesh(base + p.verts, base + p.faces, p.name);
        if (!asset) {
            std::fprintf(stderr, "[viewer] failed to parse DATAS %s\n", p.name);
            continue;
        }
        loaded++;
        std::printf("[viewer] %s: DATAS nov=%d nof=%d\n",
                    p.name, asset->vertexCount, asset->faceCount);
        g_assets.push_back(std::move(*asset));
    }
    if (!loaded)
        std::fprintf(stderr,
                     "[viewer] no DATAS meshes loaded (original tree missing at %s)\n",
                     base.c_str());
#else
    std::fprintf(stderr, "[viewer] VOODKA_REPO_ROOT undefined; DATAS meshes skipped\n");
#endif
}

// ---- VIRTUAL/OBJECTS V3Ds (packed into the objects/world archive) ----------
// [count:u32][count x u32 offsets][raw blobs] (WORLD.PAS semantics).
void loadWorldModels() {
    wchar_t exePath[MAX_PATH] = {};
    GetModuleFileNameW(nullptr, exePath, MAX_PATH);
    std::wstring wdir(exePath);
    auto slash = wdir.find_last_of(L"\\/");
    if (slash != std::wstring::npos) wdir = wdir.substr(0, slash + 1);
    std::string dir;
    dir.reserve(wdir.size());
    for (wchar_t ch : wdir) dir.push_back(static_cast<char>(ch));

    std::vector<std::string> cands;
    cands.push_back(dir + "data\\world");
    cands.push_back(dir + "world");
#ifdef VOODKA_REPO_ROOT
    cands.push_back(std::string(VOODKA_REPO_ROOT) + "/port/data/world");
#endif

    std::vector<uint8_t> data;
    for (const std::string& c : cands) {
        FILE* f = std::fopen(c.c_str(), "rb");
        if (!f) continue;
        std::fseek(f, 0, SEEK_END);
        long n = std::ftell(f);
        std::fseek(f, 0, SEEK_SET);
        data.resize(n > 0 ? (size_t)n : 0);
        if (n > 0) std::fread(data.data(), 1, (size_t)n, f);
        std::fclose(f);
        std::printf("[viewer] world archive %s (%zu bytes)\n", c.c_str(),
                    data.size());
        break;
    }
    if (data.size() < 12) {
        std::fprintf(stderr, "[viewer] objects/world archive not found; VIRTUAL objects skipped\n");
        return;
    }

    uint32_t count = le32(&data[0]);
    for (uint32_t i = 0; i < count; ++i) {
        uint32_t ofs = le32(&data[4 + i * 4]);
        uint32_t end = (i + 1 < count) ? le32(&data[8 + i * 4])
                                       : (uint32_t)data.size();
        if (ofs >= end || end > data.size()) {
            std::fprintf(stderr, "[viewer] world blob %u bounds %u..%u invalid\n",
                         i, ofs, end);
            continue;
        }
        // VIRTUAL/OBJECTS names: TORUS.V3D, TORUS2.V3D (indices 0/1)
        std::string nm = (i == 0) ? "torus.v3d (virtual)" : "torus2.v3d (virtual)";
        auto asset = loadV3DFromMemory(&data[ofs], (size_t)(end - ofs), nm);
        if (!asset) {
            std::fprintf(stderr, "[viewer] failed to parse world blob %u\n", i);
            continue;
        }
        std::printf("[viewer] %s: %s nov=%d nof=%d\n",
                    nm.c_str(), typeName(asset->type),
                    asset->vertexCount, asset->faceCount);
        g_assets.push_back(std::move(*asset));
    }
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE, LPSTR, int nCmdShow) {
    (void)hInst;
    // Match the port's window setup: per-monitor DPI awareness keeps the
    // swapchain's backbuffer size = physical client pixels so DWM composites
    // without bitmap scaling (a DPI-virtualized window can present blank).
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    const char* logPath = getenv("VOODKA_VIEWER_LOG");
    if (logPath && logPath[0]) g_log = fopen(logPath, "w");
    logLine("[viewer] start");
    if (!loadArchive()) {
        logLine("[viewer] archive not found");
        MessageBoxA(nullptr,
                    "vodka.dat not found.\n"
                    "Look for it next to the exe, or in port/data/ (build output).",
                    "V3D Asset Viewer", MB_ICONERROR);
        return 1;
    }

    // ---- load every 3D asset the original offers --------------------------
    // 1) the 9 V3D/V3M packed in vodka.dat
    for (int i = 0; i < kV3DEntryCount; ++i) {
        const V3DEntry& e = kV3DEntries[i];
        std::vector<uint8_t> blob;
        if (!archiveEntry(e.index, blob)) {
            std::fprintf(stderr, "[viewer] archive entry %u (%s) missing\n",
                         e.index, e.name);
            continue;
        }
        if (blob.size() != e.size) {
            std::fprintf(stderr,
                         "[viewer] %s: size %zu != expected %zu\n",
                         e.name, blob.size(), e.size);
            continue;
        }
        std::optional<V3DAsset> asset;
        if (isV3M(e.name)) {
            // V3M = headerless morph target; needs the companion V3D's counts.
            // 2torus.v3d precedes 2torus.v3m in the table.
            int nov = 128, nof = 256;   // 2TORUS defaults (verified)
            for (const auto& a : g_assets)
                if (a.name == "2torus.v3d") { nov = a.vertexCount; nof = a.faceCount; }
            asset = loadV3MFromMemory(blob.data(), blob.size(),
                                      nov, nof, e.name);
        } else {
            asset = loadV3DFromMemory(blob.data(), blob.size(), e.name);
        }
        if (!asset) {
            std::fprintf(stderr, "[viewer] failed to parse %s\n", e.name);
            continue;
        }
        std::printf("[viewer] %s: type=%d (%s) nov=%d nof=%d spin=(%d,%d,%d)\n",
                    e.name, asset->type, typeName(asset->type),
                    asset->vertexCount, asset->faceCount,
                    asset->spinAdderX, asset->spinAdderY, asset->spinAdderZ);
        g_assets.push_back(std::move(*asset));
    }

    // 2) the 16 CODE/DATAS compile-time meshes (original source tree)
    loadDatasModels();
    // 3) the 2 VIRTUAL/OBJECTS V3Ds (objects/world archive)
    loadWorldModels();

    std::printf("[viewer] loaded %zu 3D assets total\n", g_assets.size());
    if (g_assets.empty()) {
        MessageBoxA(nullptr, "No 3D assets could be parsed.",
                    "V3D Asset Viewer", MB_ICONERROR);
        return 1;
    }

    // ---- window + renderer --------------------------------------------------
    WNDCLASSEXA wc{};
    wc.cbSize = sizeof wc;
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = wndProc;
    wc.hInstance = hInst;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
    wc.lpszClassName = "V3DAssetViewer";
    RegisterClassExA(&wc);

    RECT wrc{0, 0, 1280, 800};
    AdjustWindowRectEx(&wrc, WS_OVERLAPPEDWINDOW, FALSE, 0);
    int winW = wrc.right - wrc.left;
    int winH = wrc.bottom - wrc.top;

    g_hwnd = CreateWindowExA(0, "V3DAssetViewer", "V3D Asset Viewer",
                             WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT,
                             winW, winH, nullptr, nullptr, hInst, nullptr);
    if (!g_hwnd) {
        std::fprintf(stderr, "[viewer] CreateWindow failed\n");
        return 1;
    }
    // Match the port's lifecycle: make the window visible BEFORE the
    // swapchain is created (a swapchain created on a hidden window can bind
    // a stale composition path that never reaches DWM once shown).
    ShowWindow(g_hwnd, nCmdShow);
    UpdateWindow(g_hwnd);
    SetForegroundWindow(g_hwnd);

    if (!g_renderer.init(g_hwnd, 1280, 800)) {
        logLine("[viewer] D3D11 init failed");
        MessageBoxA(nullptr, "D3D11 init failed.", "V3D Asset Viewer",
                    MB_ICONERROR);
        return 1;
    }
    logLine("[viewer] D3D11 init OK");
    int startIdx = selectTorus();
    const char* st = getenv("VOODKA_VIEWER_START");
    if (st && st[0]) {
        int v = std::atoi(st);
        if (v >= 0 && v < (int)g_assets.size()) startIdx = v;
    }
    showAsset(startIdx);
    logLine("[viewer] showing asset %d of %d", g_current, (int)g_assets.size());

    // ---- main loop ----------------------------------------------------------
    MSG msg{};
    bool running = true;
    long frame = 0;
    while (running) {
        while (PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE)) {
            if (msg.message == WM_QUIT) { running = false; break; }
            TranslateMessage(&msg);
            DispatchMessage(&msg);
        }
        if (!running) break;

        if (g_autoRotate) g_rotAngle += 0.015f;

        float ce = std::cos(g_elevAngle), se = std::sin(g_elevAngle);
        float ca = std::cos(g_rotAngle),   sa = std::sin(g_rotAngle);
        float ex = g_camTarget[0] + g_orbitRadius * ce * ca;
        float ey = g_camTarget[1] + g_orbitRadius * se;
        float ez = g_camTarget[2] + g_orbitRadius * ce * sa;

        RECT rc{};
        GetClientRect(g_hwnd, &rc);
        float aspect = (float)(rc.right - rc.left) /
                       (float)(rc.bottom - rc.top > 0 ? rc.bottom - rc.top : 1);
        g_renderer.setCamera(ex, ey, ez,
                             g_camTarget[0], g_camTarget[1], g_camTarget[2],
                             60.0f, aspect, g_near, g_far);
        g_renderer.render();
        frame++;
        logLine("[frame] %d", frame);
        Sleep(16);
    }

    g_renderer.shutdown();
    logLine("[viewer] exit");
    if (g_log) fclose(g_log);
    return 0;
}
