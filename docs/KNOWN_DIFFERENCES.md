# Known differences - port vs original

Validation is scene-level: the original 1996 release running in DOSBox 0.74-3
(SB16) vs the Windows x64 port, compared by timed screenshots against the
module's deterministic ModPos timeline. Evidence: `reference/captures/`.

## Timing & synchronization

- **Scene sync: matches.** All eight part transitions in the port occur at
  the same module positions as the original (least-squares residual <= ~1.7 s
  ~ 18 rows over 4 minutes; `reference/captures/README.md` has the table).
  `kPartStartModPos` in `app.cpp` is validated; ModPos = (order<<8)|row
  confirmed against the original's scene behavior.
- **Playback rate: the original plays ~5% slower.** Under DOSBox/SB16 the
  original's wall-clock scene times fit `W = B + M/0.950` (r = 0.950 vs
  libxmp's nominal ProTracker timeline). The demo stays internally in sync in
  both versions (scenes are ModPos-driven), so this shows only as absolute
  pacing/pitch. Leading hypothesis: DIAMOND programs the SB16 DSP time
  constant for the requested 44000 Hz and the SB16's nearest rate below is
  41667 Hz (TC=232) -> playback ~5.3% slow with a ~0.9 semitone pitch drop.
  Unverified without disassembling DIAMOND.OBJ (binary-only; EOS 2.07 source
  is not in the repo). The port plays the module as written at 44.1 kHz via
  libxmp — the pitch-correct choice; documented, not "fixed".
- **Frame rate: ~70 fps, like the original.** waitVbl is QPC-paced 70 Hz
  retrace emulation; the presenter uses immediate Present(0) (a former
  Present(1) vsync lock summed two clocks to ~31 fps). Per-frame deltas come
  from EOS-faithful wait_vbl semantics (ticks since the last call), so
  animation speed is frame-rate independent and matches the original.
- **Boot/precalc:** the original spends a few seconds in DOSBox on the FPU
  toonel precalc before the music starts; the port is effectively instant.

## Fixed divergences found by this validation (2026-08-04)

These were port bugs exposed by the first full playthroughs; all fixed and
covered by the test suite:

1. P2 entry crash in full runs: 64-bit load of the dword `_file_addr`
   scooped P1's `len`=81 into the high half (`mov rsi` -> `mov esi`).
2. P5 mirror pass: 32-bit adds zeroed the upper halves of 64-bit pointers.
3. P5 water: the sample index is 16-bit in the original (wraps mod 65536);
   the port's 32-bit math zero-extended negatives to +4 GB. Now `& 0xffff`,
   exactly the original's wrap.
4. P5 `vk_p2_render_frame` call site: MS-ABI stack args were shifted +8, so
   the callee saw `trace=textury` and traced into the texture table instead
   of drawing.
5. P5 `vodkasel`: selector base was the file pointer missing `_file_addr`
   and truncated to 32 bits -> garbage texture base.
6. `_scrSel` was never initialized; standalone parts (P5/P8) inherited a null
   screen selector. boot.asm now allocates it at Start32 like DEMO.AS^.
7. VR face painter sort was missing entirely: `DrawZielonyLudek` calls
   BITSORT's Sort per object per frame (sumZ pack, 4x4-bit radix descending,
   NaGut); now `pz_sort` in p2draw.asm, with `prep_sort` (SortMem) called by
   P2/P5 init. Cross-checked by p2draw.crosscheck.
8. EOS `wait_vbl` returned the absolute counter instead of the EOS delta;
   broke P8's sun sprite (ran past the 19-frame table) and sped up every
   delta-driven animation. Dispatcher now returns the delta; P8's sun_step
   clamp wraps robustly (the original's one-shot +-18 relied on ~1 deltas).
9. P2 texture slots shifted: t[1]/t[2] were obrazek/t001; the original
   CODE/PART2 maps t[1]=t001, t[2..4]=t002, t[5]=env.
10. Presentation vs 60 Hz vsync (see above).

## Remaining known differences

- **P2 env-mapped object shade**: the stadium's env-mapped centerpiece
  renders gold-ish where the original reads bluer. Structural content,
  textures, water and camera path match; the shade nuance likely comes from
  the env/normals arithmetic and is under observation, not blocking.
- **P8 tone**: the port's P8 viewer reads slightly brighter/whiter than the
  original's silver-blue at some phases (palette-range nuance under
  observation). The sw/metal palettes themselves were verified byte-exact
  against the OBJ-recovered data.
- **Transient first-frame deltas:** after a part stall the EOS delta is
  large for one frame; the original shows a momentary animation jump (and in
  P8's case read harmless garbage in DOS). The port wraps the sprite index
  instead — visually cleaner, same steady state.
- **Windowed 960x600 D3D11 vs fullscreen mode 13h**; integer 3x upscale,
  point-sampled, 6-bit palette DAC behavior reproduced. Possible one-line
  tearing under Present(0), as on real VGA.
- **Audio:** libxmp 4.6.2 vs the custom DIAMOND player (14-channel
  FastTracker module). Playback-rate difference noted above; mixing/filter
  nuances are those of libxmp's FT2-accurate mixer vs DIAMOND's SB16 output.
- **Input:** Esc skips parts in the original; the port maps PC scancodes
  identically. Space = pause (port addition).

## Not differences (verified identical)

- `vodka.dat` is byte-identical to the archive embedded in the release EXE
  (SHA-256 golden test).
- Engine math (sqrt, rotate, n_calc, radix sort), the tm_face rasterizer,
  MROTATE matrices, camera matrix, projection, normals, object loader, VR
  visibility/sort/prepare, the P2 camera path and world data, and the toonel
  table: byte-exact vs C++ references re-deriving the original arithmetic
  (17 CTests).
