// platform_abi.h - the single narrow contract between the NASM demo core and
// the C++ Windows integration layer.
//
// Memory model (emulates EOS flat protected mode):
//   The demo's whole runtime universe lives in ONE contiguous arena
//   (g_arena). Every pointer the demo stores is a 32-bit OFFSET into that
//   arena ("linear address"), stored in 32-bit variables exactly like the
//   original. Before dereferencing, the demo adds the arena base:
//       r/esi = offset   (or: add esi, Code32_addr)
//   The arena base is exposed to NASM as the qword `Code32_addr`
//   (a 64-bit variable, so `add esi, Code32_addr` -> real pointer in x64).
//
// Screen model (emulates VGA mode 13h):
//   The platform owns two 64000-byte 8-bit regions inside the arena:
//     kBackbufferOffset  - the offscreen "screen" buffer (old _screen)
//     kFramebufferOffset - the presented frame (old 0xA0000 VGA memory)
//   After the demo draws it calls presentFrame() which reads the palette +
//   framebuffer and presents (vsync).
//
// Timing:
//   waitVbl() emulates the VGA retrace tick (~70 Hz) via a high-res clock;
//   getFrameCounter() mirrors the original `ramki`. 
//
// All cross-boundary functions are extern "C" and follow the MS x64 ABI
// (rcx,rdx,r8,r9 + 32-byte shadow space). The NASM dispatcher (eos.inc)
// adapts the EOS register calling convention to these prototypes.

#pragma once
#include <cstddef>
#include <cstdint>

namespace vk {

// Stable POD contract for the production NASM startup coordinator. The
// reference executable intentionally keeps the C++ sequence as its oracle;
// VOODKA passes this record once so assembly owns ordering and rollback.
struct AppStartupConfig {
    void* hwnd;
    const char* recDir;
    const char* diagDir;
    const char* timelinePath;
    const char* musicPath;
    int32_t asmAudio;
    int32_t referenceAudio;
    int32_t asmPresenter;
    int32_t autoPauseMs;
    int32_t autoCloseMs;
};
static_assert(offsetof(AppStartupConfig, hwnd) == 0);
static_assert(offsetof(AppStartupConfig, recDir) == 8);
static_assert(offsetof(AppStartupConfig, diagDir) == 16);
static_assert(offsetof(AppStartupConfig, timelinePath) == 24);
static_assert(offsetof(AppStartupConfig, musicPath) == 32);
static_assert(offsetof(AppStartupConfig, asmAudio) == 40);
static_assert(offsetof(AppStartupConfig, referenceAudio) == 44);
static_assert(offsetof(AppStartupConfig, asmPresenter) == 48);
static_assert(offsetof(AppStartupConfig, autoPauseMs) == 52);
static_assert(offsetof(AppStartupConfig, autoCloseMs) == 56);
static_assert(sizeof(AppStartupConfig) == 64);

// ---- arena memory ----------------------------------------------------------
uint8_t* arena();                     // base of the demo arena
bool     platformInit();              // allocate arena + layout overlay regions
void     platformShutdown();          // release the arena and archive
uint32_t arenaAlloc(uint32_t bytes);  // allocate zeroed block -> offset (linear)
void     arenaFree(uint32_t offset);  // no-op free (mark released)
// packaged data archive (vodka.dat): Load_internal_file equivalent.
// name is a NUL-terminated ASCII path (e.g. "voodka.dat"). Returns offset
// into arena, or 0 on failure.
uint32_t loadInternalFile(const char* name);
const void* archiveBytes();
size_t      archiveSize();

// ---- screen / palette ------------------------------------------------------
enum { kScreenW = 320, kScreenH = 200, kFramebufferBytes = kScreenW * kScreenH };
enum { kPaletteBytes = 768 };
extern const uint32_t kFramebufferOffset;   // arena offset of presented frame
extern const uint32_t kBackbufferOffset;    // arena offset of offscreen buffer
bool initPresent(void* hwnd, int w, int h); // create D3D11 swapchain + resources
void shutdownPresent();                       // release all D3D11 resources
void setAssemblyPresenter(bool enabled);     // reference selector; production is assembly-only
void setPalette(const uint8_t r[256], const uint8_t g[256], const uint8_t b[256]);
void currentPalette(uint8_t out[768]);  // copy current 6->8 stored palette
void presentFrame();                      // palette+frame -> D3D11 -> present
void recInit(const char* dir);            // enable deterministic frame recording
void recClose();

// Presentation self-test: fills the arena framebuffer with a known pattern
// and uploads a known palette, bypassing the demo, so the GPU readback can
// be compared 1:1 against the expected image to isolate presentation bugs.
void selfTestPattern();

// Presentation diagnostics: when enabled, after each present the swapchain
// back buffer is copied back to CPU and, along with the source framebuffer
// and palette, saved to files for byte-level validation of the display path.
void diagReadbackInit(const char* dir);   // start readback capture into dir
void diagReadbackShutdown();
bool diagReadbackEnabled();

// ---- timing ----------------------------------------------------------------
void     timerInit();          // start the 70Hz retrace emulation
uint64_t getFrameCounter();   // VGA-retrace emulated counter
void     waitVbl();           // block until next presented retrace tick
uint64_t getQpcUs();          // high-resolution microseconds since app start
void     timelineInit(const char* path); // optional per-frame A/V witness
void     timelineFrame(uint64_t frame, uint64_t qpcUs, uint32_t modpos);
void     timelineClose();

// ---- progress reporting ------------------------------------------------------
// Centralized run-progress: updates the window title + structured log whenever
// the active demo part/scene/effect changes (driven by the ModPos timeline).
void progressInit(void* hwnd);   // set the HWND whose title reflects progress
void progressUpdate();           // call once per frame (waitVbl); emits on change

// ---- pause / resume (Space key) ----------------------------------------------
bool isPaused();            // current pause state (1 = paused)
void pauseToggle();         // toggle pause (WndProc Space key-down edge)

// ---- input -----------------------------------------------------------------
// PC scancode -> pressed (1)/released(0), mirrors EOS Key_Map.
bool inputInit(void* hwnd);       // start the global ESC watcher
void inputShutdown();             // stop and join the watcher
int  isKeyDown(int scancode);
void updateInput();           // pump Win32 messages; call each frame
void keyDown(uint8_t sc);     // Win32 WndProc hook
void keyUp(uint8_t sc);
void keyReset();
uint8_t* rawKeyMap();
void clearEscapeQueue();
bool escapeQueued();

// ---- lifecycle / quit ---------------------------------------------------------
// The demo core runs on the main thread (DemoStart32), so a window-close
// (WM_CLOSE -> WM_DESTROY -> PostQuitMessage) lands in updateInput() as a
// WM_QUIT message. It is recorded here; the per-frame choke points
// (waitVbl / presentFrame) observe it and run a full deterministic teardown.
void requestQuit();          // mark a quit request (earliest source wins)
bool quitRequested();        // ESC or a window-close is pending
void resetSelectors();       // release the emulated selector table

// ---- audio (libxmp MOD player) ----------------------------------------------
void audioSetAssemblyMode(bool enabled); // production default; false = libxmp oracle
int  audioInit(const char* modFilePath, int sampleRate);
void audioShutdown();
int  audioPlay();
int  audioStop();
uint32_t getModPos();         // Get_Info: song-position scalar for sync
uint32_t getModLength();      // total positions, for calibration
double   audioElapsedSec();   // monotonic playback elapsed seconds (audio clock)
void     audioPump();         // must be called periodically from main loop

// ---- seeking ----------------------------------------------------------------
// The demo timeline is ModPos as reported by the original EOS Get_Info: an
// order-list position in the high byte and a pattern ROW in the low byte, i.e.
//   ModPos = (orderIndex << 8) | row    (order index = position in the order list)
// This is the authoritative clock every ported part compares against (e.g. P2
// exits at ModPos > 0xB3F, P5 starts at 0x1400, ...). It is monotonic across module
// loops by adding `orders * 256` (== rowsPerLoop * 4) per loop. Seek can be
// expressed in several units:
//   audioSeekRows(modpos) : absolute ModPos ((order<<8)|row). Primary API.
//   audioSeekMs(ms)       : milliseconds from module start (incl. loops).
//   audioSeekOrder(order) : order-list index (pattern start, row 0).
// All return the actual ModPos ((order<<8)|row) reached, or 0 on failure. After
// a seek, getModPos() and the running demo both start from the new point,
// keeping audio and visuals synchronized regardless of entry position.
uint32_t audioSeekRows(uint32_t modpos);
uint32_t audioSeekMs(int ms);
uint32_t audioSeekOrder(int order);

// ---- audio self-check (--audiocheck) ----------------------------------------
// Exercise init/load/playback for `seconds`, verify tempo accuracy, audio-video
// drift and dropouts, log a full report. Returns 0 (pass) / nonzero (fail).
int  audioSelfCheck(int seconds);

// ---- logging ---------------------------------------------------------------
void logInit();                        // open debugger + voodka.log (once)
void logPrint(const char* fmt, ...);      // printf-style to debugger+file
void logFlush();
void logShutdown();                    // flush, close file, delete lock

// ---- shutdown / exit ---------------------------------------------------------
// Deterministic wind-down, identical to the end-of-demo path. The shipped
// target owns the coordinator and quit handoff in win32_shutdown.asm; the
// reference target retains the C++ implementation as the differential oracle.
// Both paths stop and join input/audio workers, close recording/readback
// outputs, release D3D11/selector/arena state, destroy the window, and close
// the log. shutdownAndExit() additionally terminates the process so nothing
// outlives the closed window or assembly demo stack.
void shutdownAll();          // release all subsystems (safe on normal exit)
void shutdownAndExit();      // shutdownAll() then terminate the process

}  // namespace vk
