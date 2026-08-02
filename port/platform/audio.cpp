// audio.cpp - music via vendored libxmp + Windows WASAPI (event-driven render
// thread). Scenes sync to the module position via getModPos().
//
// NOTE: exact Sound Blaster mixing/filters are not bit-reproducible; this is
// an unavoidable difference. Position/timing sync is preserved.

#include "platform_abi.h"
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <combaseapi.h>
#include <xmp.h>
#include <cstdio>
#include <cstring>
#include <vector>

#pragma comment(lib, "ole32.lib")

namespace vk {

namespace {
constexpr int kSampleRate = 44100;
constexpr int kChannels   = 2;
constexpr UINT32 kBufMs   = 40;

xmp_context g_xmp = nullptr;
HANDLE      g_thread = nullptr;
HANDLE      g_stop = nullptr;
volatile long g_playing = 0;
volatile long g_order = 0, g_row = 0;
CRITICAL_SECTION g_xmpCs = {};   // serializes ALL libxmp access (not thread-safe)

IAudioClient*       g_ac = nullptr;
IAudioRenderClient* g_arc = nullptr;
UINT32              g_bufFrames = 0;
UINT32              g_chunkFrames = 0;
}

uint32_t getModPos() {
    // calibration: ModPos = (order<<6)|row  (64 rows per ProTracker pattern)
    long o = _InterlockedOr(&g_order, 0), r = _InterlockedOr(&g_row, 0);
    return (uint32_t)((o << 6) | r);
}

uint32_t getModLength() {
    if (!g_xmp) return 0;
    xmp_module_info mi;
    EnterCriticalSection(&g_xmpCs);
    xmp_get_module_info(g_xmp, &mi);
    LeaveCriticalSection(&g_xmpCs);
    return mi.mod ? mi.mod->len : 0;
}

static DWORD WINAPI renderThread(LPVOID) {
    HRESULT hr = g_ac->Start();
    if (FAILED(hr)) return 1;

    // prefill
    {
        UINT32 pad = 0;
        g_ac->GetCurrentPadding(&pad);
        UINT32 need = g_bufFrames - pad;
        BYTE* data = nullptr;
        if (SUCCEEDED(g_arc->GetBuffer(need, &data))) {
            short* p = (short*)data;
            int n = (int)need;
            while (n > 0) {
                int want = n;
                if (g_playing) {
                    EnterCriticalSection(&g_xmpCs);
                    int rc = xmp_play_buffer(g_xmp, (short*)p, (long)(want * 2), 0);
                    LeaveCriticalSection(&g_xmpCs);
                    if (rc != 0) {
                        InterlockedExchange(&g_playing, 0);
                        memset(p, 0, (size_t)want * 2 * sizeof(short));
                    }
                } else {
                    memset(p, 0, (size_t)want * 2 * sizeof(short));
                }
                p += want * 2;
                n -= want;
            }
            g_arc->ReleaseBuffer(need, 0);
        }
    }

    for (;;) {
        if (WaitForSingleObject(g_stop, 0) == WAIT_OBJECT_0) break;
        UINT32 pad = 0;
        g_ac->GetCurrentPadding(&pad);
        UINT32 framesAvail = g_bufFrames - pad;
        if (framesAvail < g_chunkFrames) {
            WaitForSingleObject(g_stop, (DWORD)(kBufMs / 4));
            continue;
        }
        BYTE* data = nullptr;
        if (FAILED(g_arc->GetBuffer(g_chunkFrames, &data))) continue;
        short* p = (short*)data;
        int n = (int)g_chunkFrames;
        while (n > 0) {
            int want = n;
            if (g_playing) {
                EnterCriticalSection(&g_xmpCs);
                int rc2 = xmp_play_buffer(g_xmp, (short*)p, (long)(want * 2), 0);
                LeaveCriticalSection(&g_xmpCs);
                if (rc2 != 0) {
                    InterlockedExchange(&g_playing, 0);
                    memset(p, 0, (size_t)want * 2 * sizeof(short));
                }
            } else {
                memset(p, 0, (size_t)want * 2 * sizeof(short));
            }
            p += want * 2;
            n -= want;
        }
        g_arc->ReleaseBuffer(g_chunkFrames, 0);
    }
    g_ac->Stop();
    return 0;
}

void audioPump() {
    if (!g_xmp) return;
    if (!InterlockedCompareExchange(&g_playing, 1, 0)) return;
    xmp_frame_info fi;
    EnterCriticalSection(&g_xmpCs);
    xmp_get_frame_info(g_xmp, &fi);
    LeaveCriticalSection(&g_xmpCs);
    InterlockedExchange(&g_order, fi.pos);
    InterlockedExchange(&g_row, fi.row);
}

int audioInit(const char* modPath, int) {
    if (!modPath) return 0;
    // When VOODKA_NOAUDIO is set (diagnostics), don't start a thread at all.
    if (GetEnvironmentVariableA("VOODKA_NOAUDIO", nullptr, 0) > 0) {
        logPrint("[audio] audio disabled (VOODKA_NOAUDIO)\n");
        // still create the context so ModPos advances via silent playback
        InitializeCriticalSection(&g_xmpCs);
        g_xmp = xmp_create_context();
        if (!g_xmp) return 0;
        FILE* f = fopen(modPath, "rb");
        if (f) {
            fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
            std::vector<uint8_t> buf((size_t)sz);
            size_t rd = fread(buf.data(), 1, (size_t)sz, f); fclose(f);
            if (rd == (size_t)sz && xmp_load_module_from_memory(g_xmp, buf.data(), (long)sz) == 0) {
                xmp_start_player(g_xmp, kSampleRate, 0);
            }
        }
        logPrint("[audio] loaded order len=%lu (headless)\n", getModLength());
        InterlockedExchange(&g_playing, 1);
        return 1;
    }
    InitializeCriticalSection(&g_xmpCs);
    g_stop = CreateEventA(nullptr, TRUE, FALSE, nullptr);

    g_xmp = xmp_create_context();
    if (!g_xmp) return 0;
    FILE* f = fopen(modPath, "rb");
    if (!f) { logPrint("[audio] cannot open %s\n", modPath); return 0; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> buf((size_t)sz);
    size_t rd = fread(buf.data(), 1, (size_t)sz, f);
    fclose(f);
    if (rd != (size_t)sz) return 0;
    if (xmp_load_module_from_memory(g_xmp, buf.data(), (long)sz) < 0) {
        logPrint("[audio] libxmp failed to load module\n");
        return 0;
    }
    xmp_start_player(g_xmp, kSampleRate, 0);

    HRESULT hr = 0;
    IMMDeviceEnumerator* denum = nullptr;
    IMMDevice* dev = nullptr;
    WAVEFORMATEX* mix = nullptr;
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);

    // UUIDs for the WASAPI COM endpoints (local consts beat SDK static-iid obj)
    static const IID clsid_denum = { 0xBCDE0395, 0xE52F, 0x467C, { 0x8E,0x3D,0xC4,0x57,0x92,0x91,0x69,0x2E } };
    static const IID iid_denum   = { 0xA95664D2, 0x9614, 0x4F35, { 0xA7,0x46,0xDE,0x8D,0xB6,0x36,0x17,0xE6 } };
    static const IID iid_dev     = { 0xD666063F, 0x1587, 0x4E43, { 0x81,0xF1,0xB9,0x48,0xE8,0x07,0x36,0x3F } };
    static const IID iid_ac      = { 0x1CB9AD4C, 0xDBFA, 0x4C32, { 0xB1,0x78,0xC2,0xF5,0x68,0xA7,0x03,0xB2 } };
    static const IID iid_arc     = { 0xF294ACFC, 0x3146, 0x4483, { 0xA7,0xBF,0xAD,0xDC,0xA7,0xC2,0x60,0xE2 } };

    hr = CoCreateInstance(clsid_denum, nullptr, CLSCTX_ALL, iid_denum,
                          reinterpret_cast<void**>(&denum));
    if (SUCCEEDED(hr)) hr = denum->GetDefaultAudioEndpoint(eRender, eConsole, &dev);
    if (SUCCEEDED(hr)) hr = dev->Activate(iid_ac, CLSCTX_ALL,
                                     nullptr, reinterpret_cast<void**>(&g_ac));
    if (SUCCEEDED(hr)) hr = g_ac->GetMixFormat(&mix);
    if (SUCCEEDED(hr)) hr = g_ac->Initialize(
        AUDCLNT_SHAREMODE_SHARED, 0,
        (REFERENCE_TIME)(10000.0 * kBufMs), 0, mix, nullptr);
    if (SUCCEEDED(hr)) hr = g_ac->GetBufferSize(&g_bufFrames);
    if (SUCCEEDED(hr)) hr = g_ac->GetService(iid_arc, reinterpret_cast<void**>(&g_arc));
    g_chunkFrames = g_bufFrames / 2;
    if (mix) CoTaskMemFree(mix);
    if (dev) dev->Release();
    if (denum) denum->Release();

    if (FAILED(hr)) {
        logPrint("[audio] WASAPI init failed hr=%08x\n", (unsigned)hr);
        return 0;
    }

    g_thread = CreateThread(nullptr, 0, renderThread, nullptr, 0, nullptr);
    SetThreadPriority(g_thread, THREAD_PRIORITY_ABOVE_NORMAL);
    InterlockedExchange(&g_playing, 1);
    logPrint("[audio] module loaded, orders=%lu, %dHz\n", getModLength(), kSampleRate);
    return 1;
}

void audioShutdown() {
    InterlockedExchange(&g_playing, 0);
    if (g_stop) SetEvent(g_stop);
    if (g_thread) WaitForSingleObject(g_thread, 3000);
    if (g_xmp) { EnterCriticalSection(&g_xmpCs); xmp_end_player(g_xmp); xmp_free_context(g_xmp); g_xmp = nullptr; LeaveCriticalSection(&g_xmpCs); }
    if (g_arc) g_arc->Release();
    if (g_ac)  g_ac->Release();
    if (g_stop) CloseHandle(g_stop);
    DeleteCriticalSection(&g_xmpCs);
    CoUninitialize();
}

int audioPlay() { InterlockedExchange(&g_playing, 1); return 1; }
int audioStop() { InterlockedExchange(&g_playing, 0); return 1; }

}  // namespace vk
