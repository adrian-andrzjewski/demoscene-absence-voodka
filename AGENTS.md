# AGENTS.md

## What this is

"VOODKA" — a 1990s PC demoscene demo by the Polish group Absence, written in
pure 32-bit x86 protected-mode assembly (Borland TASM 4.0) running on a DOS
386 extender/kernel called **EOS**. Not a web/modern project: no package manager,
no CI, no tests. Everything runs under DOS/DOSBox on 386+ with an FPU and 8MB RAM.

## Layout

- `demoscene-absence-voodka-master/` — **the working source tree; edit here.**
- `reference/source/demoscene-absence-voodka-master/` — byte-identical
  read-only mirror of the same source. Keep it untouched (provenance).
- `reference/release/` — read-only copy of the shipped release
  (`abc_voda/`, `VOODKA.EXE`). Don't modify.
- `music/amnezja2.mod` — the ProTracker module the demo plays (referenced as
  `amnezja2.mod` runtime filename in `CODE/DEMO.AS^`).
- `port/` — **native Windows x64 port** (Nasm assembly core + C++ platform
  layer). The original `demoscene-absence-voodka-master/` stays byte-identical;
  the port reads its data from there and rebuilds `vodka.dat`.
- `modules/` — vendored NASM 2.16.03 (`nasm.exe`) and libxmp 4.6.2 (MOD player).

## Windows port (port/) — how to build & debug

- **Build:** run `port/build.ps1 -Config Release -Test` (auto-locates
  VS2022/2026, applies vcvars, runs CMake with vendored NASM). Output goes to
  `port/bin/Release/VOODKA.exe`.
  **Gotcha:** if you reconfigure with `cmake -B`, pass
  `-DCMAKE_ASM_NASM_COMPILER=D:/Project/voodka2/modules/nasm/nasm.exe`. The
  CMake cache can otherwise resolve a system NASM (e.g. 3.01) whose codegen
  breaks `[rel X]` references into high-VA `.bss` (silent heap/stack corruption
  in the engine selftest — sort/n_calc fail or crash). Always verify
  `CMakeCache.txt` shows the vendored exe.
- **Run:** `VOODKA.exe [--record <dir>]` draws the demo in a 960x600 window
  (320x200x256 logic upscaled via D3D11 palette texture). `--record` dumps
  per-frame 320x200-index + 768-palette to `<dir>/frames.raw`; convert with
  `port/bin/Release/frames2img.exe`.
- **Architecture:** `port/core/*.asm` is the demo (faithful NASM x64 port of
  TASM parts); `port/platform/*.cpp` is the EOS replacement. The bridge
  (`bridge.cpp`) exposes the only C symbols NASM may call (`vk_*`).
- **Memory model:** the whole demo universe is one arena (64MB). The demo
  stores 32-bit `Code32_addr`-relative arena offsets in dwords; add the qword
  `Code32_addr` base before dereferencing. The two VGA overlays are fixed:
  `kBackbufferOffset` (0x10000, pt draws here) and `kFramebufferOffset`
  (0x20000, presented). See `port/platform/platform_abi.h`.
- **ABI rule (critical):** every NASM->C++ call must have `RSP%16==0` at the
  `call` instruction. Prologue accounting: entry RSP%16==8; after `push rbp` it
  is 0; each extra push moves it by 8. A function pushing 7 regs after rbp
  needs `sub rsp,0x28`; one pushing 4 needs `sub rsp,0x20`; an *inlined* block
  that pushes rbp+sub must reach 0 relative to the enclosing body. Getting this
  wrong crashes inside MSVCRT/NVIDIA D3D with `/GS` cookie or stack faults —
  the #1 gotcha in this port.
- **EOS services** (Allocate_Memory, Allocate_Selector, wait_vbl, Get_Info,
  Load/Play/Stop_module, use_int_08/09) go through `eos_dispatch.asm` with
  service ids defined in `eos.inc` (original `EOS.INC` is not in the repo, so
  the port defines its own ids). `wait_vbl` = QPC-paced ~70Hz retrace emulation
  (`timer.cpp`); `GetModPos` = libxmp pattern position (order<<6|row, to be
  calibrated against the original's ModPos in Phase 8).
- **Selectors:** user-mode x64 forbids arbitrary fs/gs bases. `sel_base_table`
  in `bridge.cpp` maps alloc_selector handles -> base pointers; texture mappers
  read the base up front instead of `fs:[...]`.
- **Self-modifying code:** the original patches instruction immediates
  (P6 `BUMPXXX`/`BUMPYYY`, water `WaterX/Y`/`innerWater`, `DESTINY`) — it's
  read-only under DEP. These are ported as explicit memory state with identical
  arithmetic (see `p6.asm`, `water.inc`).
- **Status:** platform layer, EOS-replacement ABI, and parts P6 (2D bump map)
  and P7 (7-phase water, 160x100->320x200 upscale) run end-to-end at
  69.9 fps with audio and per-frame recording. P1-P5, P8, the engine
  (ENGINE.ASM/TXTR.ASM), VR/objects pipeline, and precise ModPos
  calibration remain.

## Original DOS build (reference only)

Requires TASM/TASMX + TLINK, and the **EOS kernel headers are external and NOT
in this repo**. Source includes absolute machine paths like
`D:\TASM\EOS\EOS.INC`, `c:\TASM\EOS\EOS.INC`, `\TASM\EOS\EOS.INC`
(inconsistent across files) — you must have EOS.INC reachable at each path.
Flow:
1. Assemble each part `P1..P8` to `.OBJ` (e.g. `CODE/P2/P2.BAT` runs
   `tasmx /kh32768 p2.as^`; `P5/M.BAT`, `P6/M.BAT`, `COMS/M.BAT` exist; others
   assemble with plain `tasmx part.as(^)`).
2. Link everything from `CODE/`:
   `tlink /3 /x kernel eos diamond engine txtr demo p1\p1 p2\p2 p3\p3 p4\p4 p5\p5 p6\p6 p7\p7 p8\p8, demo` (this is exactly `CODE/M.BAT`).

## Data packaging (important)

All shared runtime data is packed into one archive (`vodka.dat`) by a Borland
Pascal tool: `CODE/LINKER/LINKER.PAS` (build `LINKER.EXE`) reads the manifest
`CODE/LINKER/VODKA.TXT` (76 files under `DANE/`) and writes `vodka.dat` with an
offset table (1000 × two longints: offset, size) at the front.

- Files are addressed **by index = position in VODKA.TXT**. Code uses
  `vodka <index>, <addr>` (macro in `CODE/INC/VODKA`) to resolve one.
- Reordering/adding files in `VODKA.TXT` shifts every index; the change must be
  mirrored in every `vodka n,...` call site.
- Note the spelling mismatch: linker writes `vodka.dat`, source loads
  `voodka.dat` — don't "fix" either without confirming the full pipeline.

## Source conventions

- `.AS^` (and `.ASM`) are TASM source; `.PM` and extension-less files in
  `CODE/INC/` (e.g. `PAL`, `SIN`, `FILE`, `OUR`, `VODKA`, `KEYS.!`, `TABLICA3`,
  `RIP`, `PLE2`) are assembly includes pulled in via `INCLUDE`. None are junk;
  the odd names are intentional.
- The demo (entry `CODE/DEMO.AS^`, `Start32` → `part1..part8`) is the real
  entrypoint; `partN` are `EXTRN` PUBLIC routines from each `P*.AS^`/`P*.ASM`.
- Heavy FPU use (`fpatan`, `fsqrt`, `fimul`) — 286-only refactors won't work.
- Comments are in Polish and frequently crude; don't interpret them literally.
- `VIRTUAL/` is a separate standalone VR-engine viewer, **not** part of the
  main demo link. `VIRTUAL/OBJECTS` `.V3D` files are packed into `objects/world`
  by `VIRTUAL/OBJECTS/WORLD.PAS` (manifest `WORLD.TXT`).
