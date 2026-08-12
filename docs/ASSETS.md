# VOODKA asset inventory & formats

Everything the demo uses at runtime is packed into a single archive,
`vodka.dat`, produced by the original Borland Pascal tool
`CODE/LINKER/LINKER.PAS` from the manifest `CODE/LINKER/VODKA.TXT`.
The port regenerates it byte-identically with `port/tools/vodka_pack`
(verified by the `vodka.golden_hash` CTest against the archive embedded in
the release `VOODKA.EXE`).

**For the full per-format reverse-engineering (structures, encodings,
consumption semantics, port parity) see `ASSET_FORMATS.md`.** This file is
the index map + recovery notes.

## Archive format (`vodka.dat`)

```
[0x0000 .. 0x1F3F]  1000 entries x 8 bytes: { offset:u32le, size:u32le }
[0x1F40 ..       ]  concatenated file payloads, in VODKA.TXT order
```

- 8000-byte header; only the first 76 entries are used.
- Files are addressed **by index = 0-based position in VODKA.TXT**.
  Code resolves one with the `vodka <index>, <addr>` macro
  (`CODE/INC/VODKA`; port: `port/core/inc/vodka.inc`), which reads
  `[tab + idx*8]` = offset, `[+4]` = size against the loaded archive base.
- Offsets in the table are relative to the start of the file (header included),
  i.e. the first payload starts at 8000.
- Total size: 2,731,687 bytes (8,000 header + 2,723,687 payload).
- Spelling quirk (do **not** "fix"): LINKER.PAS writes `vodka.dat`, while
  `DEMO.AS^` loads `voodka.dat` via EOS `Load_internal_file`. The production
  release embeds the archive in the EXE; `win32_arena.asm` accepts both names
  at the existing EOS service boundary.

## The 76-entry index map

Sizes in bytes. "Consumer" is where the index is referenced (`vodka n,...`
in the original source). Raw bitmap dimensions are the ones implied by the
consuming code; no dimensions remain marked *(inferred)* — every entry is
resolved to an exact division or a consumer-code-confirmed size (see the
notes below and ASSET_FORMATS.md §3.3).

| # | File | Size | Format / content | Consumer |
|--:|---|--:|---|---|
| 0 | `obrazek.dat` | 16,384 | 128x128 8-bit pic | swiatynia city (P2) (`PART2` -> `_obrazek`); **dead load** in the shipped swiatynia city (P2) (never drawn) |
| 1 | `t001.dat` | 32,768 | texture **256x128** (mapper stride is 256) | PART2 -> `textury[1]` (swiatynia city (P2)) |
| 2 | `t002.dat` | 40,896 | texture **256-wide, 160-row export** (159 full rows + 192-B partial row); **no header** (unpadded exporter truncation of a 160-row image, zero tail) | PART2 -> `textury[2..4]` (swiatynia city (P2)) |
| 3 | `env.dat` | 65,536 | 256x256 environment map | PART2 -> `textury` (swiatynia city (P2)) |
| 4 | `_rm.inc` | 51,200 | texture blob (binary despite .inc) | oko + szklo (P1) (`map` - head texture) |
| 5 | `_logo1.inc` | 5,880 | logo graphic | oko + szklo (P1) (`logo1`) |
| 6 | `_logo2.inc` | 9,702 | logo graphic | oko + szklo (P1) (`logo2`) |
| 7 | `_logo3.inc` | 6,300 | logo graphic | oko + szklo (P1) (`logo3`) |
| 8 | `_logo4.inc` | 6,804 | logo graphic | oko + szklo (P1) (`logo4`) |
| 9 | `_wlk1.dat` | 64,000 | 320x200 screen | oko + szklo (P1) (`_znik1`, "znika" pixel-fade frames) |
| 10 | `_wlk2.dat` | 64,000 | 320x200 screen | oko + szklo (P1) (`_znik2`) |
| 11 | `_wlk3.dat` | 64,000 | 320x200 screen | oko + szklo (P1) (`_znik3`) |
| 12 | `wall.v3d` | 140 | VR object (1 wall) | swiatynia city (P2) world |
| 13 | `wall2.v3d` | 140 | VR object | swiatynia city (P2) world |
| 14 | `wall3.v3d` | 140 | VR object | swiatynia city (P2) world |
| 15 | `torus.v3d` | 15,212 | VR object (torus) | swiatynia city (P2) world |
| 16 | `klatki.dat` | 147,456 | 36 frames x 4096 B (64x64 anim) | swiatynia city (P2) (`sun` sprite) |
| 17 | `absence.dat` | 64,000 | 320x200 screen | swiatynia city (P2) water part (`_obrazek2`) |
| 18 | `absence.pal` | 768 | palette | swiatynia city (P2) water part (`_paleta`) |
| 19 | `water.abc` | 64,000 | 320x200 screen | swiatynia city (P2) water part (`_waterPIC`) |
| 20 | `jup.inc` | 38,912 | texture blob **256x152** (38,912/256 = 152 exact — tunel + wygibasy (P3) 256-stride) | tunel + wygibasy (P3) `prepare_twist` (`map`) |
| 21 | `lgmap.inc` | 51,200 | texture blob | tunel + wygibasy (P3) `prepare_twist` (`lgmap`) |
| 22 | `4toonel.dat` | 65,536 | 256x256 tunnel texture | tunel + wygibasy (P3) (`_yayo`) |
| 23 | `s2.dat` | 147,456 | 36 x 4096 anim frames | tunel + wygibasy (P3) (`sun`) |
| 24 | `sw.inc` | 44,032 | texture blob **256x172** (44,032/256 = 172 exact) | processorek Nevosolek (P4) (`map1`), nad czerwonym lampa (P8) (`map1`) |
| 25 | `v_txr1.inc` | 51,200 | texture blob | processorek Nevosolek (P4) (`map2`) |
| 26 | `proc.inc` | 51,200 | texture blob | processorek Nevosolek (P4) (`map3`) |
| 27 | `metal.inc` | 51,200 | texture blob | processorek Nevosolek (P4) (`map4`), nad czerwonym lampa (P8) (`map2`) |
| 28 | `logo_a.dat` | 48,000 | **15-frame 64x50 sprite anim** (15x3200) | processorek Nevosolek (P4) (`show_logo`) |
| 29 | `tull.inc` | 64,000 | 320x200 screen | processorek Nevosolek (P4) (`pic_data`) |
| 30 | `tull.pal` | 768 | palette | processorek Nevosolek (P4) (`pic_pal`) |
| 31 | `2wall.v3d` | 140 | VR object | torus ustep village (P5) world |
| 32 | `2wall2.v3d` | 140 | VR object | torus ustep village (P5) world |
| 33 | `2wall3.v3d` | 140 | VR object | torus ustep village (P5) world |
| 34 | `2torus.v3d` | 5,668 | VR object | torus ustep village (P5) world |
| 35 | `2torus.v3m` | 5,632 | VR morph target | torus ustep village (P5) (`_torusMorph`) |
| 36 | `do_water` | 16,384 | 128x128 water picture (no extension) | torus ustep village (P5) (`_obrazek`) |
| 37 | `2WORLD.PAL` | 768 | palette | torus ustep village (P5) (`_pal`) |
| 38 | `2ENV.DAT` | 65,536 | 256x256 env map | torus ustep village (P5) (`fn` textures) |
| 39 | `2T001.DAT` | 32,768 | texture | torus ustep village (P5) (`fn`) |
| 40 | `2T002.DAT` | 32,768 | texture | torus ustep village (P5) (`fn`) |
| 41 | `w1.DAT` | 64,000 | 320x200 screen | torus ustep village (P5) phase pics (`_adr1`) |
| 42 | `w2.DAT` | 64,000 | 320x200 screen | torus ustep village (P5) (`_voodka2`) |
| 43 | `w3.DAT` | 64,000 | 320x200 screen | torus ustep village (P5) (`_adr1`) |
| 44 | `w4.DAT` | 64,000 | 320x200 screen | torus ustep village (P5) (`_voodka2`) |
| 45 | `voodka.dat` | 1 | **1-byte placeholder** (name collision with the archive itself) | torus ustep village (P5) (`_voodka`) |
| 46 | `h1.dat` | 14,976 | small bitmap **156x96** (14,976/96 = 156 exact — dead `voodka2:` blitter) | torus ustep village (P5) (`_voodka2`); loaded, never drawn |
| 47 | `h2.dat` | 14,976 | small bitmap | torus ustep village (P5) (`_adr1`); never drawn |
| 48 | `h3.dat` | 14,976 | small bitmap | torus ustep village (P5) (`_voodka2`); never drawn |
| 49 | `h4.dat` | 14,976 | small bitmap | torus ustep village (P5) (`_adr1`); never drawn |
| 50 | `death.dat` | 64,000 | 320x200 bump **height field** | gratki (P6) (`_pic`, bump-map gradients) |
| 51 | `death.pal` | 768 | palette (two 128-entry banks) | gratki (P6) (`_pal`) |
| 52 | `mapa.dat` | 16,384 | 128x128 bump **lighting LUT** (values 0..119) | gratki (P6) (`_bump`) |
| 53 | `jaszczur.dat` | 64,000 | 320x200 overlay mask ("lizard"; nonzero => +128) | gratki (P6) (`_jaszczur`) |
| 54 | `pulse.dat` | 16,000 | 160x100 water phase pic | gratki + woda (P7) phase **7** (`_pulse`) |
| 55 | `pls.dat` | 32,000 | 160x100 int16 water initial state | gratki + woda (P7) phase **7** (`_pulseW`) |
| 56 | `camorra.dat` | 16,000 | water phase pic | gratki + woda (P7) phase 1 |
| 57 | `cma.dat` | 32,000 | 160x100 int16 water initial state | gratki + woda (P7) phase 1 |
| 58 | `poison.dat` | 16,000 | water phase pic | gratki + woda (P7) phase 2 |
| 59 | `psn.dat` | 32,000 | water phase data | gratki + woda (P7) phase 2 |
| 60 | `substanc.dat` | 16,000 | water phase pic | gratki + woda (P7) phase 3 |
| 61 | `stc.dat` | 32,000 | water phase data | gratki + woda (P7) phase 3 |
| 62 | `tcman.dat` | 16,000 | water phase pic | gratki + woda (P7) phase 4 |
| 63 | `tcm.dat` | 32,000 | water phase data | gratki + woda (P7) phase 4 |
| 64 | `hypnotiz.dat` | 16,000 | water phase pic | gratki + woda (P7) phase 5 |
| 65 | `hpz.dat` | 32,000 | water phase data | gratki + woda (P7) phase 5 |
| 66 | `motion.dat` | 16,000 | water phase pic | gratki + woda (P7) phase **6** |
| 67 | `mtn.dat` | 32,000 | water phase data | gratki + woda (P7) phase **6** |
| 68 | `woda.dat` | 16,000 | final water pic | gratki + woda (P7) (`_obrazek2`) |
| 69 | `woda.pal` | 768 | palette | gratki + woda (P7) (`_paleta`) |
| 70 | `last.pal` | 768 | palette | nad czerwonym lampa (P8) (`last_pal`) |
| 71 | `last.dat` | 63,680 | 320x199 screen (one line short) | nad czerwonym lampa (P8) (`last_pic`) |
| 72 | `2world.inc` | 77,824 | **19-frame 64x64 sprite anim** (19x4096) | torus ustep village (P5) (`sun` sprite) |
| 73 | `log.inc` | 77,824 | 19-frame 64x64 sprite anim | nad czerwonym lampa (P8) (`sun` sprite) |
| 74 | `trasa.dat` | 106,704 | binary camera path (2,964 nodes x 9 dwords) | processorek Nevosolek (P4) (`ruchy`) |
| 75 | `tr2.dat` | 90,288 | binary camera path (2,508 nodes x 9 dwords) | nad czerwonym lampa (P8) (`ruchy`) |

### Manifest quirks

- `dane\voodka.dat` (index 45) is a 1-byte placeholder inside DANE - it
  collides in name with the archive itself; the linker just packs it like any
  other file. torus ustep village (P5) references it (`vodka 45,_voodka`) but a 1-byte payload is
  effectively unused.
- Two DANE files are **not** in the manifest and are never packed:
  `OBRAZEK.PAL` (768 B, palette for `obrazek.dat` - swiatynia city (P2) installs its world
  palette from elsewhere) and `LAMER.TXT` (17 B, content: "EOS suxx 4ever...").

## Format notes

- **`.PAL`** - 768 bytes = 256 x (r,g,b), 6-bit VGA DAC values (0..63).
- **`.DAT` raw bitmaps** - headerless 8-bit indexed pixels. Common sizes:
  64,000 = 320x200; 32,000 = 160x100 **int16 words** (water initial states);
  16,000 = 160x100; 65,536 = 256x256; 16,384 = 128x128; 147,456 = 36 frames
  of 64x64; 77,824 = 19 frames of 64x64; 63,680 = 320x199 (`last.dat`);
  14,976 = h1-h4 small pics (156x96 per the only consumer code).
- **`.INC` (in DANE)** - binary texture/screen blobs despite the extension
  (256-stride mapper textures: 51,200 = 256x200, 44,032 = 256x172,
  38,912 = 256x152; 77,824 = 19x64x64 sprite stacks). See ASSET_FORMATS.md
  §3.3 for the full derivation table.
- **`.V3D` / `.V3M`** - VR-engine object files. Per `CODE/WORLD/VC.EXT` they
  are literally renamed `.COM` images built from `WORLD.ASM`-style sources
  (`tasm`, `tlink /x/3/t`, `ren !.com !.v3d`). Header dwords carry
  type/vertex/face counts + spin adders, then novx12 vertices, nofx12 faces,
  and a **per-vertex** UV block (novx8; hex-proven via WALL.V3D) - parsed by
  `OBJECTS.PM Load_Object`
  (port: `engine/loader.asm vk_load_object`, covered by `v3d.crosscheck`).
  `.V3M` is the same blob minus the 36-byte header (torus ustep village (P5) morph target).
- **`trasa.dat` / `tr2.dat`** - binary camera-path node arrays consumed by processorek Nevosolek (P4)
  and nad czerwonym lampa (P8) (9 dwords per node). Text sources: `P4/TRASA.DAT` (2,964 rows)
  compiles to `trasa.dat`; `COMS/TRASA.DAT` (2,508 rows) compiles to
  `tr2.dat`; both via `CODE/COMS/MALE.ASM` (a 4-line include-assembler,
  `tlink /t`). `COMS/TR2.DAT` is **not** a camera path (19-line string
  table). swiatynia city/torus ustep village (P2/P5) use `P2/TRASA.!` (2,964 rows) and `P5/TRASA.!` (3,876 rows)
  of `dd` — **6 dwords/node, 24 B** — included at assembly time, not
  compiled. swiatynia city (P2) `WIDOKI` = 7 dwords/entry (x,y,z,ax,ay,az,flashFlag),
  `rept`-expanded to 64 entries, indexed `ModPos & 0x3f` (in-bounds, no
  over-read). Full spec: ASSET_FORMATS.md §4.6.
- **`do_water`, `mapa.dat`** - 128x128 8-bit grids (torus ustep village (P5) water source pic /
  gratki (P6) bump lighting LUT).

## Compile-time assets (NOT in vodka.dat)

These were `INCLUDE`d / `incbin`'d into the part .OBJs at assembly time:

| Asset | Used by | Status / recovery |
|---|---|---|
| `rm_eye.pal` (768 B) | oko + szklo (P1) | missing from repo; recovered from `P1.OBJ` |
| `jup.pal` | tunel + wygibasy (P3) | missing; recovered from `P3.OBJ` LEDATA |
| `tn.pal` (16 colors) | tunel + wygibasy (P3) | ASCII `CODE/P3/TN.PAL` survives in-tree (60 values = 16 colors + 4 black; only 48 read) and matches the `P3.OBJ` recovery byte-for-byte |
| `sw.pal`, `v_txr1.pal`, `proc.pal`, `metal.pal` | processorek Nevosolek (P4) | missing; recovered from `P4.OBJ` (sw/metal byte-identical to the nad czerwonym lampa (P8) files; v_txr1 = 16 grays + 6 black, proc = 33 warm colors, verified against the textures' pixel ranges) |
| `p8_sw.pal`, `metal.pal` | nad czerwonym lampa (P8) | missing; recovered from `P8.OBJ`; nad czerwonym lampa (P8)'s `p8_sw.pal` includes black entry 0 and is distinct from processorek Nevosolek (P4)'s `sw.pal` |
| `macro.inc` | oko + szklo/tunel + wygibasy/processorek Nevosolek/nad czerwonym lampa (P1/P3/P4/P8) | missing; semantics reconstructed in the port |
| `sinus.inc` | DEMO.AS^ | missing; regenerated as `core/inc/sin_tables.asm` by the `sin_tables` tool |
EOS.INC | all | external EOS 2.07 kernel header, never in the repo; replaced by `port/core/eos_replace/eos.inc` |

**Compile-time meshes (`CODE/DATAS/*.INC`)** — also assembled into the part
OBJs, not in vodka.dat. These are the .obj mesh data (vertices `*_S.INC` /
faces `*_C.INC`): oko + szklo (P1) `shape3`/`constr3` (602 v / 1156 f), tunel + wygibasy (P3) `log_s`/`log_c`
(341 / 646), processorek Nevosolek (P4) `vws_1..4` + `vwc_1..4` morph targets (222/81/8/256 v +
440/158/12/384 f, plus zero-filled `s1..s3` interpolate buffers), nad czerwonym lampa (P8) `sw_s/c`
and `ob_s/c` sets (40/33 + 40/48 v·f, 114/128/128 v + 224/256/256 f).
Ported to `port/core/parts/p{1,4,8}_*.inc` + `log_*.inc`. Full format
spec (§4.5): text `dw` rows → raw word tables; the 10 orphan files
(`TOR_C/TOR_S/SHAPE/CONSTR/CND/SHD.INC` + `SW_S_3/4` + `SW_C_3/4.INC`) are
referenced by no current source.

Palette recovery tool: `port/tools/pal_extract/extract_pals.py` walks OMF
LEDATA records of the original OBJs (the palettes were ASCII `DB r,g,b`
includes that TASM turned into raw 6-bit bytes). Outputs live in
`port/core/parts/*.pal` (incbin'd by the ported parts); a reference copy is
in `port/data/pal/`.

## Generated / source-of-truth assets elsewhere in the tree

- `CODE/FLI/` + `CODE/FLI/CLAT/` - GIF/FLC eye-animation art sources and the
  dumped key frames that became `klatki.dat`/`s2.dat`-style anim blobs.
- `CODE/DATAS/` - **compile-time mesh includes** (text `dw` rows → raw word
  tables in the part OBJs), NOT in vodka.dat. Consumed: oko + szklo (P1)
  (`shape3`/`constr3`, 602 v/1156 f), tunel + wygibasy (P3) (`log_s`/`log_c`, 341/646), processorek Nevosolek (P4)
  (`vws_1..4` + `vwc_1..4`, morph targets 222/81/8/256 v + 440/158/12/384 f,
  with zero-filled `s1..s3` buffers), nad czerwonym lampa (P8) (`sw_s/c`, `ob_s/c`, 40/33 + 40/48 + 114/128/128 v, 224/256/256 f). **Ten** orphaned includes
  (`TOR_C/TOR_S/SHAPE/CONSTR/CND/SHD.INC` + `SW_S_3/SW_S_4/SW_C_3/SW_C_4.INC`)
  are referenced by no current source (verified by grep of the whole tree).
  Ported to `port/core/parts/p{1,4,8}_*.inc`, `log_*.inc`; full spec +
  complete 32-file inventory: ASSET_FORMATS.md §4.5.
- `CODE/P2/TABLICA3`, `P6/TABLICA3`, `P7/TABLICA3`, `P5/TABLICA3`,
  `P2/WATER/TAB` - precomputed drop-path/light-path tables
  (`P6/TABLICA.PAS` is the 480 B generator for gratki (P6)'s Lissajous light path);
  converted to NASM by `port/tools/vodka_pack/tabl2nasm.cpp`. Note: swiatynia city (P2)'s
  production water uses `P2/WATER/TAB` (`WATER.PM:106`), not the
  same-named `P2/TABLICA3` (a byte-identical stray copy of gratki + woda (P7)'s table);
  gratki (P6)'s table is the bump-light path, not water. All five are covered by
  `tablica3.crosscheck`.
- `CODE/P2/TRASA.!`, `P5/TRASA.!`, `P4/TRASA.DAT`, `COMS/TRASA.DAT` - camera
  paths as text `dd` rows; ported to `core/data/p2trasa.inc` /
  `parts/p5_trasa.inc`. (See Format notes above; `P2/WIDOKI` →
  `core/data/p2widoki.inc`.)
- `music/amnezja2.mod` - the music: **14-channel** module ("<>Amnezja<>" by
  Sudi; libxmp identifies it as "Fast Tracker 14CH", 42 orders, 31
  instruments, 39 patterns), 381,890 bytes. Loaded by the original via EOS /
  DIAMOND at 44,000 Hz; played by the dedicated NASM tracker/mixer and
  WASAPI worker in the shipped port. libxmp is used only by the reference
  oracle and host-side audio comparisons.
- `NFO/FO.TXT` - binary block-structured data (font/ANSI), not recovered as
  text; not used by the demo itself.

## Not recoverable / notes

- No asset is unrecoverable: every runtime file exists in `DANE/`, and every
  compile-time palette was recovered from the shipped OBJs.
- `CODE/WATER/*.DAT` are truncated older scraps (e.g. `OBRAZEK.DAT` 6,524 B);
  the authoritative copies are the DANE ones inside the archive.
- Same-name files elsewhere differ in content (`CODE/FLI/2` vs
  `DANE/KLATKI.DAT`; `P2/T001.DAT` vs `DANE/T001.DAT`) - always trust DANE.
