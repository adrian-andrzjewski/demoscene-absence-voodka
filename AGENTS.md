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

## Build (DOS only, Borland toolchain)

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
