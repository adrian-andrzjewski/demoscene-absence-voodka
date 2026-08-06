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

## Fixed divergences - asset-format audit (2026-08-05)

A full asset-format reverse-engineering pass (docs/ASSET_FORMATS.md) compared
every loader/decoder against the original sources and found these port bugs,
all fixed and verified by frame recording (`--record` + palette/pixel diff):

11. **P3 `make_pal` clamp semantics.** The port used a 32-bit `add eax,ebx`,
    so the `jns` negative-clamp tested bit 31 instead of bit 7: wrapped bytes
    128..255 passed through and `&63` mapped them to bright values where the
    original clamps to black (dark ramp levels 6..14). Fixed to the original
    8-bit `add al,bl`; recorded ramp now matches the original semantics for
    all 720 bytes (tn.pal region exact too).
12. **P2 water stage was a different effect.** The port reused the P7-style
    water engine (160x100 field, 2x2 upscale) sampling `obrazek.dat`, cleared
    the screen to black, and never installed `absence.pal` - ~1.5 s of
    all-white frames. Now a faithful port of `P2/WATER/WATER.PM`
    (`parts/water.p2.inc`): 320x200 int16 field, 318x80 sim, 320x80 1:1 strip
    at screen rows 61..140 sampling `absence.dat` over the `water.abc`
    backdrop, `absence.pal` installed via SetPal, drops from the correct
    `P2/WATER/TAB` table (`p2_watertab.asm`; the shared `P2/TABLICA3` copy is
    unreferenced by the original P2 build). Verified: palette == absence.pal
    (768/768), live strip, correct backdrop.
13. **P4 tull-picture outro was never presented (moot).** The picture blit
    and the 64-step `pic_lo` fade + `brum` flashes ran, but no
    `vk_present_frame` occurred between the last 3D frame (~0x1200) and P5's
    first frame (~0x1400). Presents were added (v_sync-paced fade steps,
    flash loop, wait loop) and verified (P4 was briefly removed and restored
    2026-08-06 with these presents intact) - the same fix lives on in P8's
    outro.
14. **P8 end screen was never presented.** Same class: the 3-slice last.dat
    reveal + `lopa`/`hopla` fades only touched the DAC/VGA memory in the
    original. Presents added (fades v_sync-paced, matching the original's
    pal_set retrace pacing); verified: slices -> fade-in -> 274-VBL hold ->
    fade to all-black -> exit 0.
15. **P5 sun sprite was never loaded.** `vodka 72,sun` (P5.AS^:156) had no
    port equivalent; the sprite sampled the archive header. Added
    (`p5_sun`); verified animating 19-frame 2world.inc sprite on screen.
16. **P5 water had no drops.** The original's `RIP` include injects a drop
    into `_bufor1` every `calculateWater` call (crawling `P5/TABLICA3`);
    the port had none, so the water surface was static. Added to
    `water.p5.inc`, including the original's duplicated `[esi+256]` poke bug
    and odd byte offsets; table converted as `p5_tablica3.asm` (covered by
    tablica3.crosscheck).
17. **P7/P2-shared water drew 100 rows instead of 99** (`inc/water.inc`),
    writing 2 bytes past the 64,000-byte frame each frame. Fixed to the
    original's 99.
18. **Palette 6->8-bit conversion truncated** (`(v*255)/63`), losing <=1 LSB
    on ~half the values and disagreeing with frames2img's rounding. Now
    `round(v*255/63)` exactly (`(v*255+31)/63`) in both - the linear mapping
    the VGA DAC's analog output implements.
19. **`--part 5` seeked 2 orders early** (`kPartStartModPos[4]` was 0x1200 =
    P4's outro start; P4 exited at >= 0x1400). Fixed to 0x1400; progress.cpp
    gained the missing "P4 tull outro" scene row (kept with P4's restore).
20. **P6 exit compared a dword at the word var `ModPos`** (worked only
    because the adjacent `framebuffer_off` low word is 0). Now a word
    compare.

Also corrected in docs/comments: the .V3D UV block is per-vertex (nov*8),
not per-face (loader.asm/v3d_crosscheck.cpp comments); `EOS_GET_INFO`
comment said `bl` but the dispatcher returns `eax`.

## Fixed divergences - full-pipeline audit (2026-08-05, second pass)

A stage-by-stage audit (assets -> decode -> palette -> present) against the
DOSBox reference captures and the recording of the current build found four
port bugs and confirmed two already-faithful static pictures:

21. **P2 world palette was P5's 2WORLD.PAL.** The original `P2.AS^` installs
    the inline `jjdj` palette (`CODE/P2/WORLD.P!`); the port loaded vodka-37
    (= `2WORLD.PAL`, which is P5's palette). Under 2WORLD.PAL the P2 stadium
    textures rendered olive/gold/tan instead of the shipped red/maroon/blue
    world (t001 -> olive, env -> gold; the "gold centerpiece" note below).
    Fixed: `port/core/parts/jjdj.pal` copied into the arena at part start
    (original `_pal dd jjdj` semantics). Frame-recorded: the P2 phase now
    contains the original capture's exact 6-bit colors (e.g. t001's
    (158,8,8),(190,48,32),(206,130,89),(231,166,130)). Guarded by
    `jjdj.repro`.
22. **P3 face shaded with swapped textures.** P3.ASM fo_1/fo_2 sample
    `al=lgmap[es:bx(edx)]` + `ah=map[fs:bx(ecx)]`; the port sampled
    `map[edx]` + `lgmap[ecx]`, so every shaded tunnel face used the wrong
    texture in each coordinate channel. Fixed p3.asm `.fo_1` to the original
    order. The tunnel's palette (make_pal ramp) was already byte-exact; the
    wrong colors came from this sample swap.
23. **P3 tunnel scroll offset did not accumulate.** Original tooneling ends
    `add licznik,ax`; the port used `mov`, freezing the scrolling _yayo
    window. Fixed to `add`.
24. **P1 flash was presented instead of being a sub-frame transient.**
    P1.ASM I_nie_znika copies the frame to the VGA first, then does a
    `pal_fadein10` toward white and immediately restores rm_eye, so the wash
    is a DAC-time transient no presented frame samples. The port faded
    BEFORE `Ekran`, presenting every frame of ModPos 0x300..0x400 whitened
    (up to full white at ModPos&63==63) - washing the red/blue edge bands
    (indices 132/212) and the 240..255 logo pixels bright. Restored the
    original order (present, then fade, then restore); frame-recorded: the
    flash-window palette is now byte-identical to rm_eye.pal.

Also verified faithful (no change needed): the P8 last.dat
end screen is byte-exact (framebuffer AND palette) in the current build (the
P4 tull outro was verified the same way before P4's removal); the
stale `reference/captures/port_outro.png` (pre-"presents added" fix) is what
showed the old broken bright output. The logos blit byte-exactly to the source
`_logoN.inc` data for every displayed frame.

## Fixed divergences - P3 hero-object geometry/rotation audit (2026-08-05)

A deep pass on the P3 tunnel's hero 3D object ("missing vertices/faces, mesh
full of holes, doesn't resemble the original cog"). Runtime instrumentation
(arena table dumps + per-face/per-row traces) verified the ENTIRE pipeline is
faithful: shape/con tables byte-identical after the prepare double, plane
projection, per-face backface cull (646/646 match the re-derived original
arithmetic), the zet sort, and the face() rasterizer (dx1 edge switches to
the v2->v3 slope at row y2 exactly like the original). The "holes" were a
frame-rate/phase mismatch, plus two texture-interpolation bugs:

25. **P3 main loop waited for TWO VBL ticks per frame (~35 fps, not 70).**
    The ORIGINAL P3.ASM main loop calls EOS `wait_vbl` then `v_sync`; the
    port forwarded BOTH to `EOS_WAIT_VBL` (a full QPC-paced 70 Hz wait). Two
    waits per frame halved the frame rate, so the hero object's rotation
    (advanced by `ramki` once per frame) ran at half the original's rate:
    over the fixed music timeline P3 produced 433 frames (rotation r 32..465)
    and never reached the solid-cog pose (r~528 at frame ~496), so the mesh
    only ever showed its thin/fragmented/lobed phases while the original
    cycles through the solid cog mid-scene. Since `wait_vbl` at the top of
    the loop already lands on the frame boundary, the port now drops the
    redundant `v_sync` (original `v_sync` is a VGA retrace poll that returns
    at that same boundary). P3 now runs 860 frames (~65-70 fps); the object's
    fill cycle peaks at the same ~53-67% of P3 as the original's, reaching
    hollow cog-ring + central emblem pose.
26. **P3 `p3_slope` dropped the first slope and ORed garbage into the span
    step.** The original packs `(first_slope<<16)|second_slope`; the port's
    `p3_slope` had an extra `shl esi/ebp,16` + `or ...edi` that shifted away
    the first slope and ORed a stale face offset into the sub-pixel texture
    step for every shaded tunnel face. Removed the extra `shl`/`or` (matches
    the original packing).
27. **P3 `n_rot` arena block under-allocated (`p_num*2` = 682 B, needs
    `p_num*4` = 1364 B).** `rotate_normals` writes 4 bytes/vertex; the 682-byte
    shortfall overflowed into `n_vert` every frame, corrupting the normals
    (and thus the p/n_rot texture coordinates) of the first ~114 vertices.
    Fixed the allocation size - no more cross-frame n_vert corruption.

## Fixed divergences - P8 palette audit (2026-08-06)

Verified the full P8 color pipeline end-to-end against the original assembly
and shipped OBJs; all color data/math is byte-faithful except the two `white`
vs `bialy` substitutions below, now fixed:

- `sw.pal`/`metal.pal` recover byte-identical from both P8.OBJ (0x524/0x821)
  and P4.OBJ (0xdb2), cross-checked; `pal.repro` regenerates them. The working
  palette is built exactly as the original (`make_pal` 8-bit signed clamps,
  regions 0/64/128/192 = sw / sw+(-2,+4,+6) / sw+(1,-1,3) / metal).
- `con3` per-face col offsets (0/64/128/192), the `face`/`show` texel fetch
  (`add al,cl`), the projection/minus-`cdq` `imul`+`idiv` divides, the 6->8-bit
  DAC conversion (round(v*255/63)) and the fade-in (`pal+1` end state) all
  match the original; `sw.inc` (vodka 24) and `metal.inc` (vodka 27) loads are
  byte-identical. Aligned frame captures (port vs DOSBox) match at region level
  (ground C 74-86% overlap, same-texel fraction consistent with camera desync).
- FIXED: the original uses the dedicated `bialy` (768 x 0x3f) table for the
  part-start white screen, the three outro picture reveals and the `brum`
  flash (`pal_set(bialy)` then `pal_set(white)`); the port reused the shared
  `white` buffer there, which by then holds the stale fade output (approx the
  working palette) instead of pure white. Added a local `bialy` table and
  switched those call sites to it (`brum` now flashes bialy then white; the
  outro reveals and part-start use bialy). Sub-frame transients, but now
  faithful.

## Remaining known differences

- **P8 tone**: fixed 2026-08-06. The port's P8/P4 `metal.pal` had been a
  white placeholder (extract_pals pinned P8.OBJ 0x8fb = the all-0x3f `bialy`
  table), which rendered the P8 hero torus as a flat pure-white blob. The real
  chrome/silver-blue ramp (64 entries, (5,6,7)->(63,63,63)) is now recovered
  byte-identical from P8.OBJ 0x821 and P4.OBJ 0xdb2; the port copy (P8's) was
  updated and the extracter offset/assert fixed, so `pal.repro` regenerates
  the same data; the torus now shows the original's metallic gradient
  shading. (P4's copy of metal.pal is back with P4.)
- **Sine table variant**: `INC/SIN` is `round(32766*sin(2pi*i/1023))` (a
  1023-interval table, hex-verified); the port generates a true 1024-step
  `round(32767*sin(2pi*i/1024))`. Max deviation 201 Q15 units (~0.6%); the
  word-format `sinus.inc` is missing from the repo entirely, so a
  reconstruction was required regardless (the port's 2048-word two-period
  table also safely covers the engine's cos over-reads up to word 1279).
- **Out-of-grid water samples**: the P2/P7 water draw clamps the sample
  row/col where the original's 16-bit index wrapped into adjacent DOS memory
  (undefined bytes). Only extreme-gradient edge cells differ; the P5 final
  offset keeps the exact 16-bit wrap (arena-safe).
- **Transient first-frame deltas:** after a part stall the EOS delta is
  large for one frame; the original shows a momentary animation jump (and in
  P8's case read harmless garbage in DOS). The port wraps the sprite index
  instead — visually cleaner, same steady state.
- **Windowed 1280x800 D3D11 vs fullscreen mode 13h**; integer 4x upscale,
  point-sampled, 6-bit palette DAC behavior reproduced (round(v*255/63),
  no gamma encode - sRGB displays approximate the CRT's native gamma;
  ASSET_FORMATS.md section 7). Square pixels vs the CRT's 1.2:1 tall-pixel
  stretch (same choice as DOSBox's default). Possible one-line tearing under
  Present(0), as on real VGA.
- **Audio:** libxmp 4.6.2 vs the custom DIAMOND player (14-channel
  FastTracker module). Playback-rate difference noted above; mixing/filter
  nuances are those of libxmp's FT2-accurate mixer vs DIAMOND's SB16 output.
  The module file carries 233,984 trailing bytes (61%) past the well-formed
  module end - inert for both players (ASSET_FORMATS.md section 6.1).
- **Sub-frame palette transients**: same-retrace white flashes (P2 lampa,
  P7 phase changes, P8 brum) were DAC updates inside one frame in the
  original; in the port the last state before a present wins. Effectively
  invisible in both.
- **Input:** Esc skips parts in the original; the port maps PC scancodes
  identically. Space = pause (port addition).

## Not differences (verified identical)

- `vodka.dat` is byte-identical to the archive embedded in the release EXE
  (SHA-256 golden test).
- Engine math (sqrt, rotate, n_calc, radix sort), the tm_face rasterizer,
  MROTATE matrices, camera matrix, projection, normals, object loader, VR
  visibility/sort/prepare, the P2 camera path and world data, and the toonel
  table: byte-exact vs C++ references re-deriving the original arithmetic
  (25 CTests, incl. all five water drop tables and the V3D/V3M decode).
- Asset-level runtime checks (2026-08-05, frame-recorded): P3 palette ramp
  matches the original's 8-bit make_pal semantics for all 720 bytes; the P2
  water installs absence.pal exactly (768/768); the P8 end screen equals
  last.dat/last.pal and fades to all-black. (The P4 outro's tull.pal
  convergence was verified the same way before P4's removal.)
