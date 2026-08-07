# Porting notes - architecture & hard-won invariants

How the 1996 TASM/DOS demo became a native Windows x64 program without
losing behavioral fidelity. Read this before touching `port/core`.
For the asset formats themselves (container, palettes, bitmaps, V3D/V3M,
paths, water/bump data, MOD, presentation conversion) see
`docs/ASSET_FORMATS.md`.

## Big picture

```
+----------------------------------------------------------+
|  port/platform (C++17, Win32)                            |
|   app.cpp  window/CLI/crash filter   d3d11_present.cpp   |
|   audio.cpp (libxmp+WASAPI)          timer.cpp (QPC 70Hz)|
|   arena.cpp (64MB arena + archive)   input/pause/progress|
|   bridge.cpp  <-- the ONLY C symbols NASM may call (vk_*)|
+---------------------------+------------------------------+
                            | extern "C", MS x64 ABI
+---------------------------v------------------------------+
|  port/core (NASM x64, faithful port of the TASM sources) |
|   eos_replace/  boot.asm(DemoStart32) eos_dispatch toonel|
|   engine/       engine txtr mrotate cammat persp v2d ... |
|   parts/        p1..p8 (+ generated/data includes)       |
+----------------------------------------------------------+
```

- The demo core is **kept in assembly on purpose**: it is a line-faithful
  port, so every effect retains its original arithmetic (fixed-point,
  16/32-bit wraparound, FPU quirks). Behavior parity matters more than
  language purity.
- Every performance-critical routine also has a **C++ reference
  implementation inside the cross-check tests** (`port/tools/validate/*`),
  compared byte-for-byte (or within documented FPU tolerance) by CTest.
  Those references are the portable fallback and the documentation of intent.

## Memory model (the one arena rule)

- The whole demo universe is **one 64 MB arena** (`arena.cpp`,
  `VirtualAlloc`). The demo stores 32-bit `Code32_addr`-relative offsets in
  dwords; add the qword `Code32_addr` base before dereferencing.
- Two VGA overlays are at fixed arena offsets (`platform_abi.h`):
  `kBackbufferOffset = 0x10000` (parts draw here; the old `_screen`) and
  `kFramebufferOffset = 0x20000` (presented; the old `0xA0000`).
- Allocation is a bump allocator (`arenaAlloc`), free is a no-op - exactly
  like the original's EOS usage pattern (parts allocate, nobody frees mid-part).
- **There is NO module `.data`/`.bss` capacity limit.** Combined module data
  is ~40 KB and rip-relative `[rel X]` reaches any image offset. The early
  "arena migration" belief was a misdiagnosis - see the P4 case study below.
  (P4 itself was removed from the port on 2026-08-06 and restored the same
  day; the case studies are kept because the ABI/register lessons
  generalize.)

## ABI rule (critical, #1 crash source)

Every NASM -> C++ call must have **`RSP % 16 == 0` at the `call`**.
Prologue accounting: at function entry `RSP % 16 == 8`; after `push rbp` it
is 0; each extra push moves it by 8. Examples:

- pushes rbp + 7 regs -> `sub rsp,0x28`
- pushes rbp + 4 regs -> `sub rsp,0x20`
- an *inlined* block that pushes rbp + subs must reach 0 relative to the
  enclosing body

Getting this wrong crashes inside MSVCRT / the NVIDIA D3D stack with /GS
cookie or stack faults. When in doubt, count pushes.

## EOS kernel replacement

The original links binary-only `KERNEL.OBJ`/`EOS.OBJ` (EOS 2.07, sources
never in the repo). The port reimplements the used services:

- `eos_replace/eos.inc` defines service ids 0x01-0x11 (the original
  `EOS.INC` is absent, so these ids are our own) plus
  `AllocateMemory`/`AllocateMemoryFree`/`LoadFile`/`WaitVbl` macros.
- `eos_replace/eos_dispatch.asm` adapts the EOS register convention to the
  MS x64 ABI and forwards to `bridge.cpp`:
  memory/selector alloc, `wait_vbl`, `Get_Info` (ModPos), file load.
- `wait_vbl` = QPC-paced ~70 Hz retrace emulation (`timer.cpp`), sleep+spin.
- Audio services (`Load_module`/`Play_module`/`Stop_module`...) are
  deliberate no-ops in the dispatcher: the module is loaded and auto-started
  by the platform (`audio.cpp`) before `DemoStart32` runs. Only P8's final
  `EOS_STOP_MODULE` reaches the platform.
- Keyboard: EOS hooked int 09 and exposed a scancode `Key_Map`; the port
  fills the same table from Win32 messages (`input.cpp` maps virtual keys ->
  PC scancodes, layout-independent).

## Selectors (fs/gs are off-limits in user-mode x64)

The original allocates *selectors* for texture data and reads them via
`fs:[...]`. User-mode x64 forbids arbitrary fs/gs bases, so
`sel_base_table[512]` in `bridge.cpp` maps `Allocate_Selector` handles to
base pointers; the texture mappers read the base up front
(`engine/txtr.asm`, P8's dual mapper).

## Self-modifying code -> explicit state

The original patches instruction immediates, which is read-only under DEP.
These are ported as memory variables with identical arithmetic:

- P6 bump map: `BUMPXXX`/`BUMPYYY` -> `bump_x`/`bump_y` (`parts/p6.asm`)
- P7 water: `WaterX`/`WaterY`, `innerWater` patch sites (`core/inc/water.inc`);
  same treatment for the P2 water (`parts/water.p2.inc`, DESTINY=6) and the
  P5 water (`parts/water.p5.inc`, DESTINY=6, 16-bit index wrap)
- P8: `DESTINY` immediate
- `cammat.asm`: VIRTUAL.INC SMC sites -> bss vars

## Register-collision case studies (why fidelity beats cleverness)

Two of the nastiest port bugs were *introduced* by "optimizing" the ported
code. Both are fixed; keep the pattern in mind.

1. **P4 `calc_pts` runaway loop.** The original used a memory-operand
   `shape[ebp*2+ebp]` + `loop`, never touching `ecx`. The port rewrote it as
   `lea rcx,[rbp*2+rbp]`, clobbering the `ecx` loop counter; a garbage face
   count (~millions) walked `rsi` past the 64 MB arena. Fix: use a spare
   register (`r8`) for scratch so `ecx` stays the counter.
2. **P4 `show()` texture selector.** The con3 face index was computed in
   `eax`, then `P4AR con3_a, rbx` - and the `P4AR` macro internally does
   `mov eax,[rel con3_a]`, clobbering the live index; the texture handle
   read garbage (mapQ -> 0, crash in `face()`). Fix: keep live values in a
   register the macro never touches (`r8`).
3. **P8 frame-1 sort crash.** P8's `prepare`/`co_prepare` double con vertex
   indices into byte-space, so `rotate`'s `rcalc[idx*2]` writes overran
   module .bss into the engine's `addr_tab`. Fixed by moving rcalc/check to
   the arena, using the reference's byte*2 rcalc stride (the port had *4),
   and reading show()'s face vertex index from con (not rcalc).

4. **P5 morph-frame chain (golden-torus flicker).** The original's `CalcRest`
   restores `esi/edi`/`ebx` to the start of the just-read/written frame with a
   `push`/`pop` before its single `add 1536`; the port dropped the save/restore
   and instead added 1536 to `rsi`/`rdi` on top of the inner 128-vertex walk
   (which already advances them one full 1536-byte frame). Every outer
   iteration then read the still-zero *next-next* frame, so each built morph
   frame collapsed to ~0: a collapsed (all-vertices-identical) frame projects
   to a single screen point, the 16-bit back-face test culled all 256 faces
   (`skBF=256`), and the rotating torus vanished except on the occasional
   ktoryMorph pass through frame 0 - the intermittent appear/disappear.
   Fix (`p5.asm MakeMorphTable`): rewind only the delta pointer (`rbx`) each
   iteration; `rsi`/`rdi` are already parked at `frame[i]`/`frame[i+1]`.
   Verified: frames lerp exactly like a Python replication of the reference
   chain, and the torus emits ~100-125 faces every rotation frame.

Rule of thumb: **port arithmetic exactly; reach for spare registers (r8+)
for scratch; never reuse a register the original left live; preserve the
original's save/restore (push/pop) discipline instead of 'simplifying'
pointer advancement.**

## FPU & fixed point

- Heavy x87 use is preserved (`fpatan`, `fsqrt`, `fimul` in the toonel table
  builder, engine `sqrt`). x64 still has x87; semantics are identical.
- 15-bit fixed-point rotation (MROTATE.PM) and the 1024-entry `vkSin` /
  2048-entry `sinus` tables are regenerated at build time
  (`tools/vodka_pack/sin_tables.cpp`) and cross-checked byte-exact.
- `normals.crosscheck` compares within documented FPU tolerance; everything
  else compares byte-exact.

## Video path

- Parts render 320x200x256 into the backbuffer; `Ekran`/`ShowPicture`
  (`core/inc/video.inc`) copies backbuffer -> framebuffer and calls
  `vk_present_frame`.
- `d3d11_present.cpp` uploads the 64,000-byte index frame to an R8 texture
  and the 768-byte palette to a 256x1 texture; a point-sampled fullscreen
  quad maps indices through the palette - pixel-identical to VGA DAC
  behavior, 4x integer upscale into a 1280x800 window.
- **Sampler pitfall (audit 2026-08-05):** the point sampler must be created
  with every `D3D11_SAMPLER_DESC` field set. The original code only set
  `Filter`/`AddressU/V`, leaving `AddressW=0` (not a valid address mode) in
  the zero-init'd desc, so `CreateSamplerState` failed and the NULL state
  bound via `PSSetSamplers` silently became D3D11's default
  `MIN_MAG_MIP_LINEAR` - the "nearest-neighbour" upscale was actually
  bilinear-smoothed. Verified by GPU-readback: with the fix, every presented
  pixel is an exact palette texel (0 interpolated colours in a full frame).
- 6-bit DAC -> 8-bit conversion happens only at palette-texture upload:
  **`round(v*255/63)` = `(v*255+31)/63`** (the linear mapping the DAC's
  analog output implements; identical formula in `frames2img`, so recordings
  match the screen pixel-for-pixel). All demo palette math stays in 6-bit
  space (`setPalette` masks `& 63`).
- **Present rule (audit 2026-08-05):** anything that was directly visible in
  DOS - framebuffer writes *or* palette/DAC changes - needs an explicit
  `vk_present_frame` to reach the window. The P8 outros (and P4's, before
  its removal) are VGA-memory writes + pal_set fades with no `Ekran` and
  were invisible until presents were added; when porting a new sequence,
  find every `rep movsd`/`pal_set` aimed at the visible screen and ensure a
  present follows.
- Palette writes (`set_pal` macro / `pal_set`) go through
  `applyPaletteRange` (`pal_range.h`), shared with `palette.crosscheck`.
- Aspect/gamma rationale (square pixels, no gamma encode): see
  `docs/ASSET_FORMATS.md` section 7.

## Audio path

- Original: DIAMOND.OBJ player (binary-only) driven by EOS, 44,000 Hz,
  "SB & GUZ ONLY".
- Port: **libxmp 4.6.2** (vendored, statically linked) + event-driven WASAPI
  render thread at 44,100 Hz / 2 ch (`audio.cpp`). The module is a
  14-channel FastTracker file ("<>Amnezja<>", 42 orders).
- `ModPos = (order << 8) | row` is the demo's timeline currency; the parts
  poll it via EOS `Get_Info`. `audio.cpp` tracks it with loop handling and
  supports seeks (`--modpos/--ms/--order/--part`). Scene-start constants
  (`kPartStartModPos` in `app.cpp`) are calibration-tuned - see
  `docs/KNOWN_DIFFERENCES.md`.

## Lifecycle / window close (the quit path)

- `DemoStart32` (**and every part loop inside it**) runs on the main thread
  and never checks a quit flag - the original demo only ever exited when the
  timeline ran out. A titlebar-X close therefore must not just destroy the
  window (`WM_DESTROY -> PostQuitMessage`); something still on the main
  thread has to notice and run the teardown.
- The chain: `WM_CLOSE` (explicit in `app.cpp`'s `WndProc`) -> `DestroyWindow`
  -> `WM_DESTROY` -> `PostQuitMessage(0)` -> **`WM_QUIT`** lands in
  `updateInput()` (called from `waitVbl` and `presentFrame` every frame).
  `updateInput` records it (`vk::requestQuit`/`quitRequested`) instead of
  dispatching - `WM_QUIT` has no window.
- The per-frame choke points (`waitVbl` in `timer.cpp` - including its
  pause-park loop - and `presentFrame`) call `vk::shutdownAndExit()` when a
  quit is pending: `recClose` -> `diagReadbackShutdown` -> `audioShutdown`
  (stops the WASAPI thread, joins it, releases libxmp/COM) -> `logFlush` ->
  `ExitProcess(0)`. `ExitProcess` is deliberate: the demo core is still on
  the stack (assembly frames have no unwind info), so a normal return cannot
  reach `WinMain`'s tail. `WinMain`'s tail path is the same `vk::shutdownAll()`
  minus the exit, so both routes run one shared teardown sequence.

## Build hygiene

- **Always use the vendored NASM 2.16.03** (`modules/nasm/nasm.exe`). A
  system NASM 3.x miscompiles `[rel X]` references into high-VA `.bss`
  (silent heap/stack corruption; sort/n_calc fail). `build.ps1` passes
  `-DCMAKE_ASM_NASM_COMPILER=...` explicitly; if you reconfigure by hand,
  verify `CMakeCache.txt`.
- `tools/validate/audit_addr32.py` audits COFF relocations for unwanted
  ADDR32 (run manually; a CTest wrapper is planned).
- Frame capture: `VOODKA.exe --record <dir>` dumps per-frame
  320x200-index + 768-palette to `frames.raw`; `frames2img` converts to PNG.
  `--diag <dir>` does a GPU readback comparison.

## DOS/DOSBox reference

The original release (`reference/release/abc_voda/VOODKA.EXE`) runs under
DOSBox 0.74-3 with SB16 emulation. Validation methodology and observed
differences are in `docs/KNOWN_DIFFERENCES.md`; captures live in
`reference/captures/`.
