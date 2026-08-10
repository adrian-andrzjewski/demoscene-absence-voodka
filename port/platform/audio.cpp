// audio.cpp - music via vendored libxmp + Windows WASAPI (event-driven render
// thread). Scenes sync to the module position via getModPos().
//
// NOTE: exact Sound Blaster mixing/filters are not bit-reproducible; this is
// an unavoidable difference. Position/timing sync is preserved.
//
// Reliability/correctness notes (hardening done here):
//  * The WASAPI stream is driven at an explicit 44100/2ch/16-bit (or float)
//    format that matches libxmp's PCM, so GetBuffer/ReleaseBuffer frame sizes
//    agree with the samples we write. We no longer blindly adopt the device
//    mix format (often 48 kHz float), which silently corrupted tempo/pitch and
//    inter-channel data on such devices.
//  * xmp_play_buffer()'s size is in BYTES (player.c memcpy semantics); every
//    call passes frames*channels*2 exactly.
//  * The render loop is event-driven (AUDCLNT_STREAMFLAGS_EVENTCALLBACK) so we
//    fill exactly when the engine needs data, instead of 10ms polling.
//  * xmp_start_player() is checked, modules are released on teardown, and a
//    failed audio-device init degrades gracefully to headless silent playback
//    so the demo timeline still advances without a sound device.

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
constexpr UINT32 kBufMs   = 60;      // WASAPI buffer length (headroom vs dropouts)

xmp_context g_xmp = nullptr;
bool        g_xmpCsInitialized = false;
bool        g_comInitialized = false;
HANDLE      g_thread = nullptr;
HANDLE      g_stop = nullptr;        // set to stop the render thread
HANDLE      g_event = nullptr;       // buffer-ready event (event-driven WASAPI)
volatile long g_playing = 0;
volatile long g_order = 0, g_row = 0;
volatile long g_posBase = 0;          // rows accumulated across module loops
volatile long g_prevOrder = -1;       // for loop-wrap detection
volatile long g_rowsPerLoop = 0;      // rows in one full pass of the order list
CRITICAL_SECTION g_xmpCs = {};   // serializes ALL libxmp access (not thread-safe)

IAudioClient*       g_ac = nullptr;
IAudioRenderClient* g_arc = nullptr;
UINT32              g_bufFrames = 0;
UINT32              g_chunkFrames = 0;
bool                g_outFloat = false;   // device wants IEEE float (convert)
std::vector<short>  g_tmp;                // float-path scratch (render thread)

// diagnostics / self-check counters
volatile long g_servedFrames = 0;  // frames handed to WASAPI successfully
volatile long g_underruns = 0;     // device drained while playing (dropouts)
volatile long g_fillErrors = 0;    // GetBuffer / xmp_play_buffer failures

// monotonic played-time bookkeeping (main-thread only: audioPump/seek/self-check)
long   g_loops = 0;       // whole passes completed since (re)start
double g_playedBase = 0;  // seconds accumulated across loops
double g_playedNow = 0;   // last known monotonic played-seconds
}

uint32_t getModLength() {
    if (!g_xmp) return 0;
    xmp_module_info mi;
    EnterCriticalSection(&g_xmpCs);
    xmp_get_module_info(g_xmp, &mi);
    LeaveCriticalSection(&g_xmpCs);
    return mi.mod ? mi.mod->len : 0;
}

static void logModuleInfo() {
    xmp_module_info mi;
    EnterCriticalSection(&g_xmpCs);
    xmp_get_module_info(g_xmp, &mi);
    LeaveCriticalSection(&g_xmpCs);
    if (!mi.mod) return;
    logPrint("[audio] module \"%s\", type=%s, %d ch, %d orders, %d ins, %d pat\n",
             mi.mod->name, mi.mod->type, mi.mod->chn, mi.mod->len,
             mi.mod->ins, mi.mod->pat);
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
// ---------------------------------------------------------------------------
// The demo timeline is the original EOS ModPos: (orderIndex << 8) | row.
// That is, the order-list index lives in the high byte and the pattern row in
// the low byte, so each order advances ModPos by 256 units (rows 0..63 land in
// 0x00..0x3F, leaving 0x40..0xFF as "one-past-the-end" boundary markers used by
// the part-window constants like 0x0B40). One full loop of the order list
// therefore spans rowsPerLoop * 4 ModPos units (rowsPerLoop/64 orders * 256).

// ModPos units spanned by one full pass of the order list.
static long modPosPerLoop() {
    long rpl = _InterlockedOr(&g_rowsPerLoop, 0);
    if (rpl <= 0) rpl = (long)getModLength() * 64;
    return rpl * 4;
}

// Convert an absolute ModPos ((order<<8)|row, possibly across loops) into the
// equivalent cumulative row count used internally by libxmp seeking.
static uint32_t modPosToRows(uint32_t mp) {
    long mpl = modPosPerLoop();
    if (mpl <= 0) return mp;
    long loop = (long)(mp / (uint32_t)mpl);
    long rest = (long)(mp % (uint32_t)mpl);
    long order = rest >> 8;
    long rowOff = rest & 0xff;      // may exceed 63 for "past-the-end" markers
    long rpl = _InterlockedOr(&g_rowsPerLoop, 0);
    if (rpl <= 0) rpl = (long)getModLength() * 64;
    return (uint32_t)((loop * rpl) + (order * 64) + rowOff);
}

// Break a cumulative row count into (loop, order, row). Returns true if resolvable.
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
            long lastRows = (p >= 0 && p < mi.mod->pat && mi.mod->xxp[p])
                            ? mi.mod->xxp[p]->rows : 64;
            *rowOut = lastRows - 1;
            ok = true;
        }
    }
    LeaveCriticalSection(&g_xmpCs);
    return ok;
}

static bool seekRowsInternal(uint32_t rows) {
    long loop, order, row;
    if (!splitRows(rows, &loop, &order, &row)) return false;

    EnterCriticalSection(&g_xmpCs);
    xmp_set_position(g_xmp, (int)order);
    xmp_set_row(g_xmp, (int)row);
    LeaveCriticalSection(&g_xmpCs);

    InterlockedExchange(&g_posBase, loop * modPosPerLoop());
    InterlockedExchange(&g_prevOrder, order);
    InterlockedExchange(&g_order, order);
    InterlockedExchange(&g_row, row);
    return true;
}

uint32_t audioSeekRows(uint32_t mp) {
    if (!g_xmp) return 0;
    if (!seekRowsInternal(modPosToRows(mp))) return 0;
    return getModPos();                 // reached ModPos (original encoding)
}

uint32_t audioSeekOrder(int order) {
    if (!g_xmp) return 0;
    if (!seekRowsInternal(modPosToRows((uint32_t)((long)order << 8)))) return 0;
    return getModPos();                 // order start, row 0
}

uint32_t audioSeekMs(int ms) {
    if (!g_xmp) return 0;
    xmp_frame_info fi;
    EnterCriticalSection(&g_xmpCs);
    xmp_seek_time(g_xmp, ms);
    xmp_get_frame_info(g_xmp, &fi);
    LeaveCriticalSection(&g_xmpCs);
    if (modPosPerLoop() <= 0) return 0;
    long loop = 0;
    if (fi.total_time > 0 && ms > fi.total_time) {
        loop = ms / fi.total_time;
    }
    long base = loop * modPosPerLoop();
    InterlockedExchange(&g_posBase, base);
    InterlockedExchange(&g_prevOrder, fi.pos);
    InterlockedExchange(&g_order, fi.pos);
    InterlockedExchange(&g_row, fi.row);
    g_playedBase = loop * (fi.total_time > 0 ? fi.total_time * 0.001 : 1.0);
    g_loops = loop;
    return (uint32_t)(base + ((fi.pos << 8) | fi.row));
}

// ---------------------------------------------------------------------------
// Output plumbing
// ---------------------------------------------------------------------------
// Fill `frames` frames of output into dst. The destination layout follows the
// negotiated WASAPI format: 16-bit short (kChannels interleaved) or 32-bit
// IEEE float (converted from short). xmp_play_buffer() consumes a byte size
// exactly frames*kChannels*2 (interleaved short PCM).
// ---------------------------------------------------------------------------
static void fillOutput(BYTE* dst, long frames) {
    const long shorts = frames * kChannels;
    const long bytes = shorts * sizeof(short);
    const long outBytes = (g_outFloat ? shorts * 4 : bytes);
    // Paused: keep the device fed with silence but DO NOT advance libxmp, so
    // the music (and ModPos) freeze at the exact current position/row. Resume
    // then continues seamlessly from that note.
    if (!g_playing || isPaused()) { memset(dst, 0, (size_t)outBytes); return; }

    EnterCriticalSection(&g_xmpCs);
    int rc;
    if (g_outFloat) {
        g_tmp.resize((size_t)shorts);
        rc = xmp_play_buffer(g_xmp, g_tmp.data(), (int)bytes, 0);
        if (rc != 0) {
            InterlockedExchange(&g_playing, 0);
            memset(dst, 0, (size_t)outBytes);
        } else {
            float* f = (float*)dst;
            for (long i = 0; i < shorts; i++)
                f[i] = (float)g_tmp[(size_t)i] * (1.0f / 32768.0f);
        }
    } else {
        rc = xmp_play_buffer(g_xmp, dst, (int)bytes, 0);
        if (rc != 0) {
            InterlockedExchange(&g_playing, 0);
            memset(dst, 0, (size_t)outBytes);
        }
    }
    LeaveCriticalSection(&g_xmpCs);
}

static void fillChunk(BYTE* data, long frames) {
    const long outStep = kChannels * (g_outFloat ? 4 : 2);
    BYTE* cur = data;
    long n = frames;
    while (n > 0) {
        long want = n;
        fillOutput(cur, want);
        cur += want * outStep;
        n -= want;
    }
    InterlockedAdd(&g_servedFrames, (long)frames);
}

static DWORD WINAPI renderThread(LPVOID) {
    HRESULT hr = g_ac->Start();
    if (FAILED(hr)) { InterlockedIncrement(&g_fillErrors); return 1; }

    // prefill the whole buffer so playback starts cleanly with no underrun.
    {
        UINT32 pad = 0;
        g_ac->GetCurrentPadding(&pad);
        UINT32 avail = g_bufFrames - pad;
        if (avail > 0) {
            BYTE* data = nullptr;
            if (SUCCEEDED(g_arc->GetBuffer(avail, &data))) {
                fillChunk(data, (long)avail);
                g_arc->ReleaseBuffer(avail, 0);
            } else {
                InterlockedIncrement(&g_fillErrors);
            }
        }
    }

    HANDLE waiters[2] = { g_stop, g_event };
    for (;;) {
        DWORD w = WaitForMultipleObjects(2, waiters, FALSE, INFINITE);
        if (w == WAIT_OBJECT_0) break;        // stop requested
        if (w != WAIT_OBJECT_0 + 1) break;    // unexpected wait failure

        UINT32 pad = 0;
        g_ac->GetCurrentPadding(&pad);
        if (pad > g_bufFrames) pad = g_bufFrames;
        UINT32 avail = g_bufFrames - pad;
        if (avail == 0) {
            if (g_playing) InterlockedIncrement(&g_underruns);
            continue;
        }
        UINT32 toFill = avail > g_chunkFrames ? g_chunkFrames : avail;
        BYTE* data = nullptr;
        if (FAILED(g_arc->GetBuffer(toFill, &data))) {
            InterlockedIncrement(&g_fillErrors);
            continue;
        }
        fillChunk(data, (long)toFill);
        g_arc->ReleaseBuffer(toFill, 0);
    }
    g_ac->Stop();
    return 0;
}

// ---------------------------------------------------------------------------
// Pump / position
// ---------------------------------------------------------------------------
void audioPump() {
    if (!g_xmp) return;
    if (!InterlockedCompareExchange(&g_playing, 1, 0)) return;

    if (g_thread == nullptr && !isPaused()) {
        // Headless mode (VOODKA_NOAUDIO or no audio device): no WASAPI render
        // thread, so advance the module manually at ~playback rate so the
        // timeline (ModPos) keeps moving for scene testing/--audiocheck.
        // (Skipped while paused so the timeline freezes like real audio.)
        static int64_t lastQpc = 0;
        static bool first = true;
        int64_t now = 0, freq = 0;
        QueryPerformanceCounter((LARGE_INTEGER*)&now);
        QueryPerformanceFrequency((LARGE_INTEGER*)&freq);
        if (first) { lastQpc = now; first = false; }
        int64_t elapsedUs = (now - lastQpc) * 1000000 / freq;
        lastQpc = now;
        if (elapsedUs > 0) {
            int frames = (int)(elapsedUs * kSampleRate / 1000000);
            if (frames > 0) {
                EnterCriticalSection(&g_xmpCs);
                static short silent[8192];
                while (frames > 0) {
                    int n = frames > 4096 ? 4096 : frames;
                    if (xmp_play_buffer(g_xmp, silent, n * kChannels * sizeof(short), 0) != 0)
                        break;
                    frames -= n;
                }
                LeaveCriticalSection(&g_xmpCs);
            }
        }
    }

    xmp_frame_info fi;
    EnterCriticalSection(&g_xmpCs);
    xmp_get_frame_info(g_xmp, &fi);
    LeaveCriticalSection(&g_xmpCs);

    // cumulative song position: when the order list wraps back to a lower
    // order, add one full loop of ModPos units so ModPos stays monotonic.
    long prev = _InterlockedOr(&g_prevOrder, 0);
    if (prev >= 0 && fi.pos < prev) {
        long mpl = modPosPerLoop();
        if (mpl > 0)
            _InterlockedExchange(&g_posBase, _InterlockedOr(&g_posBase, 0) + mpl);
        g_loops++;
        if (fi.total_time > 0) g_playedBase += fi.total_time * 0.001;
    }
    _InterlockedExchange(&g_prevOrder, fi.pos);
    InterlockedExchange(&g_order, fi.pos);
    InterlockedExchange(&g_row, fi.row);
    g_playedNow = g_playedBase + fi.time * 0.001;
}

uint32_t getModPos() {
    long base = _InterlockedOr(&g_posBase, 0);
    long o = _InterlockedOr(&g_order, 0), r = _InterlockedOr(&g_row, 0);
    // original-encoding ModPos: (orderIndex << 8) | row, monotonic across loops
    uint32_t pos = (uint32_t)(base + ((o << 8) | r));
    static long hb = 0;
    if ((hb++ & 0x1ff) == 0)
        logPrint("[audio] ModPos=%u (order=%ld row=%ld base=%ld)\n", pos, o, r, base);
    return pos;
}

static double getPlayedSeconds() {
    return g_playedNow;
}

double audioElapsedSec() { return getPlayedSeconds(); }

// ---------------------------------------------------------------------------
// Init / shutdown
// ---------------------------------------------------------------------------
static bool loadModule(const char* modPath) {
    FILE* f = fopen(modPath, "rb");
    if (!f) { logPrint("[audio] cannot open %s\n", modPath); return false; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> buf((size_t)sz);
    size_t rd = fread(buf.data(), 1, (size_t)sz, f);
    fclose(f);
    if (rd != (size_t)sz) { logPrint("[audio] short read on %s\n", modPath); return false; }
    if (xmp_load_module_from_memory(g_xmp, buf.data(), (long)sz) < 0) {
        logPrint("[audio] libxmp failed to load module\n");
        return false;
    }
    if (xmp_start_player(g_xmp, kSampleRate, 0) != 0) {
        logPrint("[audio] xmp_start_player failed\n");
        return false;
    }
    return true;
}

// Try to activate the default render endpoint and negotiate an explicit
// 44100/2ch format (16-bit PCM preferred, IEEE-float fallback). On success
// leaves g_ac/g_arc/g_bufFrames/g_chunkFrames/g_outFloat set and returns true.
static bool setupWasapi() {
    static const IID clsid_denum = { 0xBCDE0395, 0xE52F, 0x467C, { 0x8E,0x3D,0xC4,0x57,0x92,0x91,0x69,0x2E } };
    static const IID iid_denum   = { 0xA95664D2, 0x9614, 0x4F35, { 0xA7,0x46,0xDE,0x8D,0xB6,0x36,0x17,0xE6 } };
    static const IID iid_dev     = { 0xD666063F, 0x1587, 0x4E43, { 0x81,0xF1,0xB9,0x48,0xE8,0x07,0x36,0x3F } };
    static const IID iid_ac      = { 0x1CB9AD4C, 0xDBFA, 0x4C32, { 0xB1,0x78,0xC2,0xF5,0x68,0xA7,0x03,0xB2 } };
    static const IID iid_arc     = { 0xF294ACFC, 0x3146, 0x4483, { 0xA7,0xBF,0xAD,0xDC,0xA7,0xC2,0x60,0xE2 } };

    auto mkFmt = [](WORD tag, DWORD rate, WORD bits) -> WAVEFORMATEX {
        WAVEFORMATEX w{};
        w.wFormatTag = tag;
        w.nChannels = (WORD)kChannels;
        w.nSamplesPerSec = rate;
        w.wBitsPerSample = bits;
        w.nBlockAlign = (WORD)(bits / 8 * kChannels);
        w.nAvgBytesPerSec = rate * w.nBlockAlign;
        return w;
    };

    IMMDeviceEnumerator* denum = nullptr;
    IMMDevice* dev = nullptr;
    HRESULT hr = CoCreateInstance(clsid_denum, nullptr, CLSCTX_ALL, iid_denum,
                                  reinterpret_cast<void**>(&denum));
    if (SUCCEEDED(hr)) hr = denum->GetDefaultAudioEndpoint(eRender, eConsole, &dev);
    if (SUCCEEDED(hr)) hr = dev->Activate(iid_ac, CLSCTX_ALL, nullptr,
                                          reinterpret_cast<void**>(&g_ac));
    WAVEFORMATEX* chosen = nullptr;
    if (SUCCEEDED(hr)) {
        // Prefer 16-bit PCM at the engine rate; fall back to IEEE float.
        WAVEFORMATEX fmt16 = mkFmt(WAVE_FORMAT_PCM, kSampleRate, 16);
        WAVEFORMATEX* closest = nullptr;
        hr = g_ac->IsFormatSupported(AUDCLNT_SHAREMODE_SHARED, &fmt16, &closest);
        if (closest) CoTaskMemFree(closest);
        if (hr == S_OK) {
            chosen = (WAVEFORMATEX*)CoTaskMemAlloc(sizeof(fmt16));
            memcpy(chosen, &fmt16, sizeof(fmt16));
            g_outFloat = false;
        } else {
            WAVEFORMATEX fmtF = mkFmt(WAVE_FORMAT_IEEE_FLOAT, kSampleRate, 32);
            closest = nullptr;
            hr = g_ac->IsFormatSupported(AUDCLNT_SHAREMODE_SHARED, &fmtF, &closest);
            if (closest) CoTaskMemFree(closest);
            if (hr == S_OK) {
                chosen = (WAVEFORMATEX*)CoTaskMemAlloc(sizeof(fmtF));
                memcpy(chosen, &fmtF, sizeof(fmtF));
                g_outFloat = true;
            }
        }
    }
    if (SUCCEEDED(hr))
        hr = g_ac->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                              (REFERENCE_TIME)(10000.0 * kBufMs), 0, chosen, nullptr);
    if (SUCCEEDED(hr)) hr = g_ac->GetBufferSize(&g_bufFrames);
    g_chunkFrames = g_bufFrames / 2;
    if (chosen) {
        logPrint("[audio] stream fmt = %s %luHz %dch (%s)\n",
                 g_outFloat ? "IEEEFLOAT" : "PCM",
                 (unsigned long)chosen->nSamplesPerSec, (int)chosen->nChannels,
                 g_outFloat ? "16->32bit convert" : "native 16bit");
        CoTaskMemFree(chosen);
    }
    if (SUCCEEDED(hr)) hr = g_ac->GetService(iid_arc, reinterpret_cast<void**>(&g_arc));

    if (dev) dev->Release();
    if (denum) denum->Release();

    if (FAILED(hr)) {
        logPrint("[audio] WASAPI init failed hr=%08x; degrading to silent headless playback\n",
                 (unsigned)hr);
        if (g_arc) { g_arc->Release(); g_arc = nullptr; }
        if (g_ac)  { g_ac->Release();  g_ac = nullptr; }
        return false;
    }
    return true;
}

int audioInit(const char* modPath, int) {
    if (!modPath) return 0;
    if (g_xmp) return 1;
    InitializeCriticalSection(&g_xmpCs);
    g_xmpCsInitialized = true;

    g_xmp = xmp_create_context();
    if (!g_xmp) {
        DeleteCriticalSection(&g_xmpCs);
        g_xmpCsInitialized = false;
        return 0;
    }

    if (!loadModule(modPath)) {
        xmp_free_context(g_xmp);
        g_xmp = nullptr;
        DeleteCriticalSection(&g_xmpCs);
        g_xmpCsInitialized = false;
        return 0;
    }
    computeRowsPerLoop();

    // VOODKA_NOAUDIO: intentionally skip the device entirely (diagnostics).
    bool skipDevice = GetEnvironmentVariableA("VOODKA_NOAUDIO", nullptr, 0) > 0;
    if (skipDevice) {
        logPrint("[audio] audio disabled (VOODKA_NOAUDIO); headless silent mode\n");
    } else {
        HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        g_comInitialized = SUCCEEDED(co);
        if (g_comInitialized && setupWasapi()) {
            g_stop = CreateEventA(nullptr, TRUE, FALSE, nullptr);
            g_event = CreateEventA(nullptr, FALSE, FALSE, nullptr);
            if (g_stop && g_event && SUCCEEDED(g_ac->SetEventHandle(g_event))) {
                g_thread = CreateThread(nullptr, 0, renderThread, nullptr, 0, nullptr);
                if (g_thread)
                    SetThreadPriority(g_thread, THREAD_PRIORITY_ABOVE_NORMAL);
            } else {
                logPrint("[audio] could not create render thread; falling back to headless\n");
                g_thread = nullptr;
            }
        }
    }

    logModuleInfo();
    InterlockedExchange(&g_playing, 1);
    logPrint("[audio] module loaded, orders=%lu, %dHz, headless=%d\n",
             getModLength(), kSampleRate, (g_thread == nullptr) ? 1 : 0);
    return 1;
}

void audioShutdown() {
    InterlockedExchange(&g_playing, 0);
    if (g_stop) SetEvent(g_stop);
    if (g_thread) {
        // The process must not outlive the render thread. The stop event is
        // observed by the event-driven loop, so an unbounded join is both
        // deterministic and safer than closing live WASAPI/libxmp state.
        WaitForSingleObject(g_thread, INFINITE);
        CloseHandle(g_thread);
        g_thread = nullptr;
    }
    if (g_xmp && g_xmpCsInitialized) {
        EnterCriticalSection(&g_xmpCs);
        xmp_end_player(g_xmp);
        xmp_release_module(g_xmp);
        xmp_free_context(g_xmp);
        g_xmp = nullptr;
        LeaveCriticalSection(&g_xmpCs);
    }
    if (g_arc) g_arc->Release();
    if (g_ac)  g_ac->Release();
    g_arc = nullptr;
    g_ac = nullptr;
    if (g_event) CloseHandle(g_event);
    if (g_stop) CloseHandle(g_stop);
    g_event = nullptr;
    g_stop = nullptr;
    if (g_xmpCsInitialized) {
        DeleteCriticalSection(&g_xmpCs);
        g_xmpCsInitialized = false;
    }
    if (g_comInitialized) {
        CoUninitialize();
        g_comInitialized = false;
    }
    InterlockedExchange(&g_posBase, 0);
    InterlockedExchange(&g_prevOrder, -1);
    InterlockedExchange(&g_order, 0);
    InterlockedExchange(&g_row, 0);
    InterlockedExchange(&g_rowsPerLoop, 0);
    g_loops = 0;
    g_playedBase = 0;
    g_playedNow = 0;
}

int audioPlay() { InterlockedExchange(&g_playing, 1); return 1; }
int audioStop() { InterlockedExchange(&g_playing, 0); return 1; }

// ---------------------------------------------------------------------------
// Self-check (--audiocheck): exercise init/load/playback for `seconds`,
// measure tempo accuracy + audio/video drift + dropouts, log a full report
// and return 0 (pass) / nonzero (fail).
// ---------------------------------------------------------------------------
int audioSelfCheck(int seconds) {
    if (seconds <= 0) seconds = 20;
    if (!g_xmp) { logPrint("[audio] self-check: FAIL, no module loaded\n"); return 1; }

    int64_t freq = 0, w0 = 0, w1 = 0;
    QueryPerformanceFrequency((LARGE_INTEGER*)&freq);
    QueryPerformanceCounter((LARGE_INTEGER*)&w0);

    double p0 = getPlayedSeconds();
    long modpos0 = g_posBase + ((g_order << 8) | g_row);
    _InterlockedExchange(&g_servedFrames, 0);
    _InterlockedExchange(&g_underruns, 0);
    _InterlockedExchange(&g_fillErrors, 0);
    audioPlay();

    // run for `seconds` of wall-clock time, pumping the timeline like the demo
    int frames = 0;
    for (;;) {
        QueryPerformanceCounter((LARGE_INTEGER*)&w1);
        int64_t elapsedUs = (w1 - w0) * 1000000 / freq;
        if (elapsedUs >= (int64_t)seconds * 1000000) break;
        // Service the queue so a window-close (X) aborts the check instead of
        // letting the process linger; WinMain's tail shuts audio down after.
        updateInput();
        if (quitRequested()) {
            logPrint("[audio] self-check aborted (ESC/window close)\n");
            shutdownAndExit();   // does not return
        }
        audioPump();
        if (g_stop && WaitForSingleObject(g_stop, 10) == WAIT_OBJECT_0) break;
        Sleep(10);
        frames++;
    }

    double wallSec = (double)(w1 - w0) / (double)freq;
    double p1 = getPlayedSeconds();
    double playedSec = p1 - p0;            // libxmp internal clock (fi.time ms)
    long served = _InterlockedOr(&g_servedFrames, 0);
    long under = _InterlockedOr(&g_underruns, 0);
    long fillErr = _InterlockedOr(&g_fillErrors, 0);
    long modpos1 = g_posBase + ((g_order << 8) | g_row);
    long rowsAdv = modpos1 - modpos0;

    // Audible tempo = PCM frames actually delivered to the device / rate, vs
    // wall clock. libxmp's internal fi.time clock can drift a few tenths of a
    // percent from rendered samples (normal for MOD players), so it is reported
    // as informational only -- actual rendered-sample rate is the true tempo.
    double servedSec = (double)served / (double)kSampleRate;
    double tempo = wallSec > 0 ? servedSec / wallSec : 0.0;
    double driftMs = (servedSec - wallSec) * 1000.0;
    double decodeTempo = wallSec > 0 ? playedSec / wallSec : 0.0;

    logPrint("\n----- [audio] self-check report -----\n");
    logPrint("[audio] wall: %.2fs  pcm served: %.2fs  tempo=%.3f  drift=%+.0f ms\n",
             wallSec, servedSec, tempo, driftMs);
    logPrint("[audio] decode clock (fi.time): %.2fs (tempo=%.3f)\n",
             playedSec, decodeTempo);
    logPrint("[audio] ModPos advanced by %ld units (monotonic across loops)\n", rowsAdv);
    logPrint("[audio] frames served=%ld  underruns(dropouts)=%ld  fill errors=%ld\n",
             served, under, fillErr);
    logPrint("[audio] pumps=%d  stream=%s\n", frames,
             g_thread ? "device" : "headless-silent");

    // Tempo reference: with a real device the audible/persisted rate is the PCM
    // frames served; headless has no device so the QPC-paced decode clock rules.
    bool device = (g_thread != nullptr);
    double tempoRef = device ? tempo : decodeTempo;
    double driftRefMs = device ? driftMs : (playedSec - wallSec) * 1000.0;

    int pass = 1;
    if (playedSec <= 0.0) { logPrint("[audio] FAIL: audio did not advance\n"); pass = 0; }
    if (device && served <= 0) { logPrint("[audio] FAIL: no frames reached the device\n"); pass = 0; }
    if (wallSec > 0.5 && (tempoRef < 0.995 || tempoRef > 1.005)) {
        logPrint("[audio] FAIL: temno %.3f outside +-0.5%%\n", tempoRef); pass = 0;
    }
    if (driftRefMs > 250.0 || driftRefMs < -250.0) {
        logPrint("[audio] FAIL: drift %.0f ms > 250 ms\n", driftRefMs); pass = 0;
    }
    if (under > 0) { logPrint("[audio] FAIL: %ld dropout(s) -- playback not glitch-free\n", under); pass = 0; }
    if (fillErr > 0) { logPrint("[audio] FAIL: %ld fill error(s)\n", fillErr); pass = 0; }
    if (rowsAdv <= 0) { logPrint("[audio] FAIL: ModPos did not advance\n"); pass = 0; }

    logPrint("[audio] self-check: %s\n", pass ? "PASS" : "FAIL");
    logPrint("----- end report -----\n");
    return pass ? 0 : 1;
}

}  // namespace vk
