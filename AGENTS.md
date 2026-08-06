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
- **Run:** `VOODKA.exe [--record <dir>]` draws the demo in a 1280x800 window
  (320x200x256 logic upscaled 4x via a point-sampled D3D11 palette texture).
  `--record` dumps
  per-frame 320x200-index + 768-palette to `<dir>/frames.raw`; convert with
  `port/bin/Release/frames2img.exe`. `bin/<Config>/` is self-contained
  (post-build stages `data/vodka.dat` + `music/amnezja2.mod` next to the
  exe); `--music <file>` overrides the module path. Dev-tree fallbacks use
  the configure-time `VOODKA_REPO_ROOT` define, not hardcoded paths.
- **Architecture:** `port/core/*.asm` is the demo (faithful NASM x64 port of
  TASM parts); `port/platform/*.cpp` is the EOS replacement. The bridge
  (`bridge.cpp`) exposes the only C symbols NASM may call (`vk_*`).
- **Memory model:** the whole demo universe is one arena (64MB). The demo
  stores 32-bit `Code32_addr`-relative arena offsets in dwords; add the qword
  `Code32_addr` base before dereferencing. The two VGA overlays are fixed:
  `kBackbufferOffset` (0x10000, pt draws here) and `kFramebufferOffset`
  (0x20000, presented). See `port/platform/platform_abi.h`.
  **There is NO module `.data`/`.bss` "capacity" limit** (combined module data
  is only ~40 KB; rip-relative `[rel X]` reaches any image offset). An early
  P4 "arena migration" was done under the belief the module data was full —
  a misdiagnosis; the real P4 bugs were ported-register collisions, and P4
  was removed from the port entirely on 2026-08-06 (see Status). The generic
  lesson stands: use a spare register (e.g. `r8`) for scratch so `ecx` stays
  a loop counter, and never load a memory variable whose helper macro
  clobbers a value you still hold live in a register.
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
  (`timer.cpp`); `GetModPos` = libxmp pattern position as **(order<<8)|row**
  (proven from DEMO.AS^'s `mov al,bl` merge + P1's `0ff00h` order mask;
  validated against DOSBox scene timing).
- **Selectors:** user-mode x64 forbids arbitrary fs/gs bases. `sel_base_table`
  in `bridge.cpp` maps alloc_selector handles -> base pointers; texture mappers
  read the base up front instead of `fs:[...]`.
- **Self-modifying code:** the original patches instruction immediates
  (P6 `BUMPXXX`/`BUMPYYY`, water `WaterX/Y`/`innerWater`, `DESTINY`) — it's
  read-only under DEP. These are ported as explicit memory state with identical
  arithmetic (see `p6.asm`, `water.inc`).
- **Status:** platform layer, EOS-replacement ABI, and parts P6 (2D bump map)
  and P7 (7-phase water, 160x100->320x200 upscale) run end-to-end at
  69.9 fps with audio and per-frame recording. **P4 is ported and wired
  (2026-08-06)**: `port/core/parts/p4.asm` (multi-object 3D viewer with its
  own `face` rasterizer, ob/ca Euler matrices, 2951-key camera path from
  vodka 74, logo overlay, tull picture outro) runs `--part 4` (seek 0x0D40)
  and the full sequence P1-P8 end to end, exit 0, frame-recorded. The
  missing `v_txr1.pal`/`proc.pal` were recovered byte-identical from
  `P4.OBJ` (16 grays + 6 black; 33 warm colors - verified against the
  textures' pixel ranges). P1-P3 are
  ported and wired; part P5 (`--part 5`, the
  morphing-torus-over-water VR scene) is now ported and wired into boot.asm
  (+ core CMake) and runs crash-free: it reuses the P2 VR layer
  (vk_p2_render_frame / vk_load_object / vk_prepare+VKdraw / textury) plus a
  P5-specific 128x128->256x256 water engine (`parts/water.p5.inc`), with its
  own World + TRASA camera data (`parts/p5_world.inc`, `parts/p5_trasa.inc`).
  P8 is now wired and runs crash-free (~70 fps with live animation): the
  frame-1 sort crash was P8's `prepare`/`co_prepare` doubling con vertex indices
  into byte-space, so `rotate`'s rcalc/check writes (reference `rcalc[idx*2]`)
  overran module .bss into the engine's `addr_tab` - fixed by moving rcalc/check
  to the arena and using the reference's byte*2 rcalc stride (the port had *4)
  plus reading show()'s face vertex index from con (not rcalc).
- **Asset-format audit (2026-08-05)** reverse-engineered every runtime format
  (docs/ASSET_FORMATS.md) and fixed another 10 port bugs: P3 `make_pal` 8-bit
  clamp semantics, P2 water rewritten faithful to `P2/WATER/WATER.PM` (was a
  P7-engine reuse: wrong picture, no absence.pal, white screen) as
  `parts/water.p2.inc` + `p2_watertab.asm`, P5 `vodka 72` sun load, P5 RIP
  drop injection (`p5_tablica3.asm`, duplicate-+256 bug preserved), P8
  outros now actually presented (DAC/VGA writes need explicit
  `vk_present_frame`), water.inc 99-row loop (was 100 = 2-byte OOB write),
  palette 6->8-bit rounding, `--part 5` boundary 0x1200->0x1400, P6 word-cmp.
  Full playthrough exit 0; P3 ramp/P2 water palette/P8 outros
  frame-record-verified.
- **Full-pipeline audit (2026-08-05, second pass)** compared every stage
  (decode/palette/present) against the DOSBox captures: fixed P2's world
  palette (was P5's 2WORLD.PAL, now the original inline `jjdj` from
  `CODE/P2/WORLD.P!` -> `parts/jjdj.pal`; stadium renders red/maroon like
  the original, env torus dark blue not gold), P3's face rasterizer sampled
  map/lgmap swapped (`lgmap[edx]+map[ecx]`) and its `licznik` scroll offset
  used `mov` instead of `add`, and P1 applied its ModPos>=0x300 white wash
  BEFORE presenting (the original's fade is a post-present sub-frame
  transient, so the red/blue edges + logos were never meant to show
  brightened). Verified the P8 last.dat fullscreen is already
  byte-exact (the checked-in `port_outro.png` capture predates the present
  fixes). New `jjdj.repro` CTest guards the P2 palette provenance.
- **Full playthrough runs clean end-to-end (exit 0, ~66-70 fps)** after the
  2026-08-04 validation pass fixed: P2 `_file_addr` qword load (64-bit read
  of a dword var scooped P1's `len`=81), P5 mirror/water 32-bit-vs-16-bit
  index truncation (the original water samples with a 16-bit wrap - mask
  `& 0xffff`), P5 `vk_p2_render_frame` stack-arg shift (+8) and `vodkasel`
  truncated selector base, `_scrSel` init (boot allocates it like DEMO.AS^),
  the VR face painter-sort (BITSORT Sort was never ported - now `pz_sort` in
  p2draw.asm + `prep_sort` in P2/P5 init), EOS `wait_vbl` now returns the EOS
  tick DELTA not the absolute counter (P2's local workaround macro reverted;
  P8's sun_step clamp wraps robustly), P2 texture slots t[1]=t001 t[2..4]=t002
  (was shifted), and Present(0) instead of vsync (two clocks had summed to
  ~31 fps). ModPos scene table validated vs DOSBox (<=1.7 s over 4 min;
  original plays ~5% slower - DIAMOND/SB16 rate, documented). See
  docs/KNOWN_DIFFERENCES.md + reference/captures/.
- **VIRTUAL viewer ported** (`VIRTUAL.exe`): `world_pack` (WORLD.PAS port)
  repacks `data/world` byte-identically to the shipped object archive
  (golden CTest); the exe decodes both torus objects through the real ported
  loader (`--check` = load+exit for CI; Escape/window-close to quit).
- **Docs:** `docs/` holds the reconstruction documentation -
  `RECONSTRUCTION_PLAN.md` (audit/decisions/phase status), `ASSETS.md`
  (vodka.dat format + 76-asset index map + recovery), `ASSET_FORMATS.md`
  (per-format reverse-engineering bible: structures, encodings, consumption,
  port parity, presentation color/scaling pipeline), `PORTING_NOTES.md`
  (architecture/ABI/memory model/case studies), `BUILDING.md` (build/run/
  test), `KNOWN_DIFFERENCES.md` (port vs original, Phase 3 output). Keep
  them in sync with the work.
- **V3D asset viewer:** `port/tools/asset_viewer/` is a standalone
  Win32+D3D11 tool that loads all 9 V3D/V3M models from `vodka.dat`
  (archive entries 12-15 + 31-35) and renders the current one flat-shaded
  or wireframe with an orbit camera (keys 1-9 switch model, Space =
  wireframe, R = auto-rotate, mouse drag/wheel = orbit/zoom; metadata in
  the title bar). `extract_v3d` pulls the raw files at build time for the
  CTest; `asset_viewer_selftest` (CTest `v3d.viewer_parse`) validates every
  header/count/index/spin against the known-good values.
- **Tests:** 27 CTests (`port/build.ps1 -Config Release -Test`), sources in
  `port/tools/validate/` (the old empty `port/tests/` was removed): 17
  NASM-vs-C++ cross-checks + `vodka.golden_hash` + `v3d.crosscheck` (real
  .V3D/.V3M decode via the ported loader) + `tablica3.crosscheck` (generated
  NASM tables vs original TASM text, all five water/drop tables) +
  `pal.integrity` + `pal.repro`
  (OBJ-extraction reproducibility) + `jjdj.repro` (P2 world-palette
  provenance vs `CODE/P2/WORLD.P!`) + `build.addr32` (COFF reloc hygiene) +
  `v3d.viewer_parse` (the asset_viewer's own parse selftest: every V3D/V3M
  header/count/index/spin verified); the Python ones are skipped if no
  interpreter is found.

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
