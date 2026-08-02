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
volatile long g_posBase = 0;          // rows accumulated across module loops
volatile long g_prevOrder = -1;        // for loop-wrap detection
volatile long g_rowsPerLoop = 0;       // rows in one full pass of the order list
CRITICAL_SECTION g_xmpCs = {};   // serializes ALL libxmp access (not thread-safe)

IAudioClient*       g_ac = nullptr;
IAudioRenderClient* g_arc = nullptr;
UINT32              g_bufFrames = 0;
UINT32              g_chunkFrames = 0;
}

uint32_t getModLength() {
    if (!g_xmp) return 0;
    xmp_module_info mi;
    EnterCriticalSection(&g_xmpCs);
    xmp_get_module_info(g_xmp, &mi);
    LeaveCriticalSection(&g_xmpCs);
    return mi.mod ? mi.mod->len : 0;
}

// rowsPerLoop: the number of pattern-rows in one full pass of the order list.
// Computed once after the module is loaded (libxmp data is immutable after
// load). Falls back to len*64 for safety.
static void computeRowsPerLoop() {
    if (!g_xmp) return;
    xmp_module_info mi;
    EnterCriticalSection(&g_xmpCs);
    xmp_get_module_info(g_xmp, &mi);
    if (mi.mod) {
        long total = 0;
        for (int i = 0; i < mi.mod->len; i++) {
            int p = mi.mod->xxo[i];
            if (p >= 0 && p < mi.mod->pat && mi.mod->xxp[p])
                total += mi.mod->xxp[p]->rows;
            else
                total += 64;   // unknown pattern: assume classic MOD 64 rows
        }
        _InterlockedExchange(&g_rowsPerLoop, total ? total : (long)mi.mod->len * 64);
    } else {
        _InterlockedExchange(&g_rowsPerLoop, (long)getModLength() * 64);
    }
    LeaveCriticalSection(&g_xmpCs);
}

// ---------------------------------------------------------------------------
// Seeking
//
// The timeline is ModPos = cumulative pattern-rows. A target row count maps to
//   loop = rows / rowsPerLoop
//   rest = rows % rowsPerLoop
//   order = first order where cumulative rows > rest  (scan pattern lengths)
//   row   = rest - rows-below-we-start-that-order
// We then xmp_set_position(order); xmp_set_row(row) and fix our counters so
// getModPos() == rows exactly. Note libxmp's set_position resets to the start
// of a pattern in the *current* pass; row is set after via xmp_set_row.
// ---------------------------------------------------------------------------

// Break a ModPos row count into (loop, order, row). Returns true if resolvable.
static bool splitRows(uint32_t rows, long* loopOut, long* orderOut, long* rowOut) {
    long rpl = _InterlockedOr(&g_rowsPerLoop, 0);
    if (rpl <= 0) rpl = (long)getModLength() * 64;
    if (rpl <= 0) return false;
    long loop = (long)(rows / (uint32_t)rpl);
    long rest = (long)(rows % (uint32_t)rpl);

    xmp_module_info mi;
    EnterCriticalSection(&g_xmpCs);
    xmp_get_module_info(g_xmp, &mi);
    bool ok = false;
    if (mi.mod && mi.mod->len > 0) {
        long acc = 0;
        for (int o = 0; o < mi.mod->len; o++) {
            int p = mi.mod->xxo[o];
            long rows = (p >= 0 && p < mi.mod->pat && mi.mod->xxp[p])
                            ? mi.mod->xxp[p]->rows : 64;
            if (rest < acc + rows) {
                *loopOut = loop;
                *orderOut = o;
                *rowOut = rest - acc;
                ok = true;
                break;
            }
            acc += rows;
        }
        if (!ok && mi.mod->len > 0) {          // target at/after end of a pass
            *loopOut = loop == 0 ? 0 : loop;   // clamp into the last order
            *orderOut = mi.mod->len - 1;
            int p = mi.mod->xxo[*orderOut];
            long rows = (p >= 0 && p < mi.mod->pat && mi.mod->xxp[p])
                            ? mi.mod->xxp[p]->rows : 64;
            *rowOut = rows - 1;
            ok = true;
        }
    }
    LeaveCriticalSection(&g_xmpCs);
    return ok;
}

uint32_t audioSeekRows(uint32_t rows) {
    if (!g_xmp) return 0;
    long loop, order, row;
    if (!splitRows(rows, &loop, &order, &row)) return 0;

    EnterCriticalSection(&g_xmpCs);
    xmp_set_position(g_xmp, (int)order);
    xmp_set_row(g_xmp, (int)row);
    LeaveCriticalSection(&g_xmpCs);

    InterlockedExchange(&g_posBase, loop * _InterlockedOr(&g_rowsPerLoop, 0));
    InterlockedExchange(&g_prevOrder, order);
    InterlockedExchange(&g_order, order);
    InterlockedExchange(&g_row, row);
    return rows;
}

uint32_t audioSeekOrder(int order) {
    if (!g_xmp) return 0;
    long rpl = _InterlockedOr(&g_rowsPerLoop, 0);
    if (rpl <= 0) rpl = (long)getModLength() * 64;
    return audioSeekRows((uint32_t)((long)order * 64));  // order start, row 0
}

uint32_t audioSeekMs(int ms) {
    if (!g_xmp) return 0;
    xmp_frame_info fi;
    EnterCriticalSection(&g_xmpCs);
    xmp_seek_time(g_xmp, ms);
    xmp_get_frame_info(g_xmp, &fi);
    LeaveCriticalSection(&g_xmpCs);
    // rebuild counters so getModPos() reflects the sought position.
    long rpl = _InterlockedOr(&g_rowsPerLoop, 0);
    if (rpl <= 0) rpl = (long)getModLength() * 64;
    if (rpl <= 0) return 0;
    // Determine the current pass from libxmp's loop counter if we can, else
    // derive from elapsed ms so repeated loops keep ModPos monotonic.
    long loop = 0;
    if (fi.total_time > 0 && ms > fi.total_time) {
        loop = ms / fi.total_time;
    }
    long base = loop * rpl;
    InterlockedExchange(&g_posBase, base);
    InterlockedExchange(&g_prevOrder, fi.pos);
    InterlockedExchange(&g_order, fi.pos);
    InterlockedExchange(&g_row, fi.row);
    return (uint32_t)(base + ((fi.pos << 6) | fi.row));
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

    // Headless mode (VOODKA_NOAUDIO): no WASAPI render thread, so advance the
    // module manually at ~playback rate so the timeline (ModPos) keeps moving.
    // This makes scene testing/timeline jumps work without a sound device.
    {
        static int64_t lastQpc = 0;
        static bool first = true;
        int64_t now = 0;
        QueryPerformanceCounter((LARGE_INTEGER*)&now);
        int64_t freq = 0;
        QueryPerformanceFrequency((LARGE_INTEGER*)&freq);
        if (first) { lastQpc = now; first = false; }
        if (g_thread == nullptr) {   // headless
            int64_t elapsedUs = (now - lastQpc) * 1000000 / freq;
            lastQpc = now;
            if (elapsedUs > 0) {
                // advance in small chunks: 10ms of audio ~ 441 frames
                int frames = (int)(elapsedUs / 22.676);   // ~44100Hz
                if (frames > 0) {
                    EnterCriticalSection(&g_xmpCs);
                    // silence buffer, just to make libxmp consume time
                    static short silent[8192];
                    while (frames > 0) {
                        int n = frames > 4096 ? 4096 : frames;
                        if (xmp_play_buffer(g_xmp, silent, n * 2 * sizeof(short), 0) != 0) {
                            // module ended: let the wrap-detection handle it
                            break;
                        }
                        frames -= n;
                    }
                    LeaveCriticalSection(&g_xmpCs);
                }
            }
        }
    }

    xmp_frame_info fi;
    EnterCriticalSection(&g_xmpCs);
    xmp_get_frame_info(g_xmp, &fi);
    LeaveCriticalSection(&g_xmpCs);
    // cumulative song position: when the order list wraps back to a lower
    // order, add one full loop of rows so ModPos stays monotonic.
    long prev = _InterlockedOr(&g_prevOrder, 0);
    if (prev >= 0 && fi.pos < prev) {
        long rpl = _InterlockedOr(&g_rowsPerLoop, 0);
        if (rpl <= 0) rpl = (long)getModLength() * 64;
        _InterlockedExchange(&g_posBase, g_posBase + rpl);
    }
    _InterlockedExchange(&g_prevOrder, fi.pos);
    InterlockedExchange(&g_order, fi.pos);
    InterlockedExchange(&g_row, fi.row);
}

uint32_t getModPos() {
    // monotonic song position in rows: base + ((order<<6) | row)
    long base = _InterlockedOr(&g_posBase, 0);
    long o = _InterlockedOr(&g_order, 0), r = _InterlockedOr(&g_row, 0);
    uint32_t pos = (uint32_t)(base + ((o << 6) | r));
    // heartbeat: log every ~512th query so seek/advance is observable
    static long hb = 0;
    if ((hb++ & 0x1ff) == 0)
        logPrint("[audio] ModPos=%u (order=%ld row=%ld base=%ld)\n", pos, o, r, base);
    return pos;
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
        computeRowsPerLoop();
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
    computeRowsPerLoop();

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
    // reset seek state (allows a clean re-init with a new entry point)
    InterlockedExchange(&g_posBase, 0);
    InterlockedExchange(&g_prevOrder, -1);
    InterlockedExchange(&g_order, 0);
    InterlockedExchange(&g_row, 0);
    InterlockedExchange(&g_rowsPerLoop, 0);
}

int audioPlay() { InterlockedExchange(&g_playing, 1); return 1; }
int audioStop() { InterlockedExchange(&g_playing, 0); return 1; }

}  // namespace vk
