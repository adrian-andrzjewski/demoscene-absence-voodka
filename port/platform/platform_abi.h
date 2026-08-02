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
#include <cstdint>

namespace vk {

// ---- arena memory ----------------------------------------------------------
uint8_t* arena();                     // base of the demo arena
bool     platformInit();              // allocate arena + layout overlay regions
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
void setPalette(const uint8_t r[256], const uint8_t g[256], const uint8_t b[256]);
void currentPalette(uint8_t out[768]);  // copy current 6->8 stored palette
void presentFrame();                      // palette+frame -> D3D11 -> present
void recInit(const char* dir);            // enable deterministic frame recording
void recClose();

// ---- timing ----------------------------------------------------------------
void     timerInit();          // start the 70Hz retrace emulation
uint64_t getFrameCounter();   // VGA-retrace emulated counter
void     waitVbl();           // block until next presented retrace tick
uint64_t getQpcUs();          // high-resolution microseconds since app start

// ---- input -----------------------------------------------------------------
// PC scancode -> pressed (1)/released(0), mirrors EOS Key_Map.
int  isKeyDown(int scancode);
void updateInput();           // pump Win32 messages; call each frame
void keyDown(uint8_t sc);     // Win32 WndProc hook
void keyUp(uint8_t sc);
void keyReset();
uint8_t* rawKeyMap();
void clearEscapeQueue();
bool escapeQueued();

// ---- audio (libxmp MOD player) ----------------------------------------------
int  audioInit(const char* modFilePath, int sampleRate);
void audioShutdown();
int  audioPlay();
int  audioStop();
uint32_t getModPos();         // Get_Info: song-position scalar for sync
uint32_t getModLength();      // total positions, for calibration
void     audioPump();         // must be called periodically from main loop

// ---- seeking ----------------------------------------------------------------
// The demo timeline is ModPos = cumulative pattern-rows since playback start
// (monotonic across module loops). Seek can be expressed in several units:
//   audioSeekRows(modpos) : absolute ModPos (rows). Primary API.
//   audioSeekMs(ms)       : milliseconds from module start (incl. loops).
//   audioSeekOrder(order) : order-list index (pattern start, row 0).
// All return the actual ModPos (rows) reached, or 0 on failure. After a seek,
// getModPos() and the running demo both start from the new point, keeping
// audio and visuals synchronized regardless of entry position.
uint32_t audioSeekRows(uint32_t rows);
uint32_t audioSeekMs(int ms);
uint32_t audioSeekOrder(int order);

// ---- logging ---------------------------------------------------------------
void logInit();                        // open debugger + voodka.log (once)
void logPrint(const char* fmt, ...);      // printf-style to debugger+file
void logFlush();

}  // namespace vk
