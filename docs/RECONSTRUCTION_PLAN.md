# Reconstruction plan & decision log

Status snapshot: 2026-08-05 (Phase 7 asset-format audit complete). Updated
2026-08-06: P4 removed, then restored (see Phase 3 note). Updated
2026-08-08: Phase 10 world-architecture analysis complete
(`docs/WORLD_ARCHITECTURE.md`). This
document records the audit, the decisions taken, and the remaining work.
Per-topic depth lives in `ASSETS.md`, `ASSET_FORMATS.md`,
`WORLD_ARCHITECTURE.md` (the VR scene engine: worlds, objects, camera,
render pipeline), `PORTING_NOTES.md`, `BUILDING.md`, `KNOWN_DIFFERENCES.md`.

## 1. Audit conclusions (what the repository contains)

- **Original source** (`demoscene-absence-voodka-master/`, byte-identical to
  `reference/source/`): complete TASM 4.0 source for the demo
  (`CODE/DEMO.AS^` -> `part1..part8`), shared includes (`CODE/INC/`), mesh
  data (`CODE/DATAS/`), art sources (`CODE/FLI/`), camera-path compiler
  (`CODE/COMS/`), the data packer (`CODE/LINKER/`), and the standalone VR
  viewer (`VIRTUAL/`).
- **Binary-only dependencies, sources absent:** EOS 2.07 kernel
  (`KERNEL/EOS/EOSLITE/DEBUG.OBJ` from `..\EOS207\`), the DIAMOND MOD player
  (`DIAMOND.OBJ`), `EOS.INC`, `macro.inc`, `sinus.inc`, and six compile-time
  `.pal` includes. A from-scratch TASM rebuild of the original is therefore
  impossible without reconstruction; the port replaces each piece
  (`eos_replace/`, libxmp, generated sine tables, OBJ-recovered palettes).
- **Assets:** all 76 runtime files exist in `CODE/LINKER/DANE/` and pack
  into `vodka.dat` (see `ASSETS.md` for the full index map). The release
  embeds the archive inside `VOODKA.EXE` (no external data file).
- **Hardware surface:** BIOS mode 13h + VGA DAC/retrace (`INC/PAL`,
  `VIDEO.PM`), DOS `int 21h` file I/O (`INC/FILE`), raw port-60h keyboard
  (`KEYS.!`), PIT/SB/GUS inside the EOS kernel + DIAMOND. Everything else
  goes through EOS services - which is why a service-level replacement
  (`eos_dispatch.asm`) was the right seam.

## 2. Decisions (locked 2026-08-04)

| Decision | Choice | Rationale |
|---|---|---|
| Core language | **Keep the faithful NASM x64 core**; C++ references in the cross-check tests are the portable fallback | ~50 commits of validated work; byte-exact tests; zero regression risk. A full C++ retranslation was explicitly declined. |
| Platform layer | Custom Win32 + D3D11 + WASAPI (no SDL) | Already complete and dependency-free; the brief allows this ("unless the repository already suggests a more suitable architecture"). |
| VIRTUAL viewer | **Port at the end**, as a bonus exe | Not linked into the demo, not part of the shipped production; its VR engine is already ported (P2/P5/P8 reuse it). |
| Reference validation | **Scene-level DOSBox comparison + ModPos calibration** | Frame-exact automated diffing is unrealistic across different MOD players and timing bases; tolerance documented instead. |
| Original files | Untouched (archival) | Cleanup limited to the port's own debris. |

## 3. Phase status

- [x] **Phase 0 - port the demo** (pre-existing): platform layer, EOS
  replacement, engine + all 8 parts in NASM x64, asset pipeline
  (`vodka_pack` byte-identical; palettes recovered), 17 cross-check tests.
- [x] **Phase 1 - housekeeping & relocatability**: stale cdb debris removed;
  duplicate `p8.asm` fixed; `enable_testing()` ordering; stale comments;
  empty `port/tests/` removed; `D:\Project\voodka2` hardcoding replaced by
  script/configure-time paths (`VOODKA_REPO_ROOT`); `--music` override;
  `bin/<Config>` self-contained (post-build staging of vodka.dat + module);
  18/18 tests green; `--audiocheck` passes from the staged dir.
- [x] **Phase 2 - documentation**: this file, `ASSETS.md`,
  `PORTING_NOTES.md`, `BUILDING.md`, root `README.md`.
- [x] **Phase 3 - DOSBox reference validation**: release runs clean under
  DOSBox 0.74-3 (251 timed screenshots + video; tooling in
  `reference/dosbox/`); all 8 transitions match the port's scene table within
  +/-1.7 s over 4 min; ModPos encoding confirmed; original playback rate
  measured at ~0.95x libxmp (documented); `docs/KNOWN_DIFFERENCES.md` +
  `reference/captures/` written. The validation pass found and fixed 10 port
  bugs (see KNOWN_DIFFERENCES "Fixed divergences"), ending with a clean full
  playthrough (exit 0, all 8 parts, ~66-70 fps). **P4 was removed from the
  port on 2026-08-06 and restored the same day**: `port/core/parts/p4.asm`
  (full NASM x64 port with the custom `face` rasterizer, ob/ca Euler
  matrices, 2,964-node camera path (swing-clamp `ruchow`=2,951; see
  ASSET_FORMATS.md §4.6), logo overlay, tull outro) is back,
  `--part 4` seeks to 0x0D40 again, and the sequence runs P1-P8 end to end
  (exit 0, ~66-70 fps, frame-recorded; v_txr1.pal + proc.pal recovered
  byte-identical from P4.OBJ).
- [x] **Phase 4 - test additions**: `v3d.crosscheck` (real .V3D/.V3M decode
  via the ported loader), `tablica3.crosscheck` (generated NASM tables vs
  original TASM text), `pal.integrity` + `pal.repro` (OBJ-extraction
  reproducibility; the extract_pals metal/v_txr1/proc offsets were verified
  against P4/P8.OBJ and corrected), `build.addr32` (COFF reloc hygiene as a
  CTest). A `--record` determinism test was considered and dropped: the demo
  is content-deterministic but the audio/video clock sampling phase is not
  (one-frame jitter at scene edges is expected, not a bug).
- [x] **Phase 5 - VIRTUAL viewer port**: `world_pack` (WORLD.PAS port) packs
  `data/world` byte-identically to the shipped archive (golden test);
  `VIRTUAL.exe` loads it and decodes every object through the real ported
  loader (`--check` for CTest, Escape to quit).
- [x] **Phase 6 - final polish**: dist recipe in BUILDING.md, docs synced,
  full playthrough + 25-test suite green.
- [x] **Phase 7 - asset-format audit (2026-08-05)**: every runtime format
  reverse-engineered and documented (`docs/ASSET_FORMATS.md`), original vs
  port compared at each decode stage, presentation color/scaling pipeline
  analyzed. Fixed 10 port bugs found along the way (P3 make_pal 8-bit clamp,
  P2 water faithful re-port + absence.pal, P5 sun load + RIP drops, P4/P8
  outro presents, water 99-row loop, palette 6->8 rounding, part-5 boundary,
  P6 word-cmp) - all frame-record-verified; 25/25 tests + full playthrough
  exit 0.
- [x] **Phase 9 - asset viewer (2026-08-06)**: `port/tools/asset_viewer/`
  standalone Win32+D3D11 viewer loads and renders **all 27 original 3D
  assets**: the 9 V3D/V3M in `vodka.dat` (entries 12-15, 31-35), the 16
  `CODE/DATAS` compile-time mesh pairs (via a TASM-text parser reading the
  original `.INC` files), and the 2 `VIRTUAL/OBJECTS` V3Ds (from the
  `objects/world` archive). Orbits flat-shaded/wireframe (1-9 + [ ]
  switch, Space wireframe, R auto-rotate, drag/wheel orbit+zoom; metadata
  in the title bar). `extract_v3d` pulls the raw V3D/V3M at build time;
  `asset_viewer_selftest` (CTest `v3d.viewer_parse`) validates all 27
  against known-good values. 27/27 tests green.
- [x] **Phase 10 - world architecture analysis (2026-08-08)**: reverse
  engineered the complete VR scene engine - the demo's two 3D worlds (P2
  stadium, P5 colosseum + VIRTUAL harness): 48-byte world records
  (flat instancing), the 21-dword object struct / `.V3D`, camera paths
  (`TRASA.!` / `WIDOKI`), `MakeCameraMatrix`, `CalculateVisiblating` +
  `VirSort` (far->near on low-16 of zet; P5 adds `sar bx,4`), per-face
  BITSORT, `tm_face`, and P5's render-to-texture water plane. Documented in
  `docs/WORLD_ARCHITECTURE.md`; data parity verified (P2 world 212/212,
  P5 world 45/45, trasa/widoki byte-identical). Corrections: `WORLD.V3D`
  is a dev snapshot of the P5 world (44/45 records match; record 0 adders
  (8,5,0)); world field `+44` is a texture-slot index, not a "type";
  `+56 adders-to-color` is allocated-but-unused (no VR lighting). 27/27
  tests green (fresh rebuild 2026-08-08).
- [x] **Phase 8 - P3 hero-object geometry/rotation audit (2026-08-05)**: the
  P3 tunnel's hero 3D object looked "hole-y / missing faces / not like the
  original cog". Runtime instrumentation (arena dumps + per-face/per-row
  traces) proved the whole pipeline faithful (shape/con, plane, cull
  646/646, zet sort, face() rasterizer) and found the real cause: P3's main
  loop waited on TWO 70 Hz VBLs per frame (~35 fps), halving the object's
  rotation rate so it never reached the solid-cog pose within P3. Removed the
  redundant v_sync wait (P3 now ~65-70 fps, reaches the cog pose mid-scene),
  plus two texture bugs: p3_slope span-step packing and the n_rot arena
  under-allocation. 26/26 tests + full-playthrough-frame verification.

## 4. Open questions / known approximations

- **ModPos calibration** (Phase 3): `kPartStartModPos` is derived from the
  parts' own exit thresholds; exact order/row at each scene transition in the
  *original* (DIAMOND player) may differ by a row - to be measured.
- **14-channel module**: unusual (FastTracker 14CH per libxmp). DIAMOND was
  a custom player; any playback nuance differences go to
  `KNOWN_DIFFERENCES.md`. The file's 233,984-byte trailing region (61%) is
  inert for both players (ASSET_FORMATS.md 6.1).
- **Odd-sized `.INC` blobs**: resolved by the Phase 7 audit - dimensions
  derived from consumer code for every blob (ASSET_FORMATS.md 3.3);
  `t002.dat` carries no header (256-wide, ~128 content rows, zero tail).
- **P5 `vodka 45` (1-byte `voodka.dat`)**: loaded but effectively unused;
  behavior preserved as-is.
