# VOODKA `lampa` and synchronized screen flashes

This document is the source and port reference for VOODKA's full-screen flash
effects. It records the original DOS implementation, the soundtrack timeline
conditions, the palette data involved, and the Windows/D3D11 translation. The
word `lampa` ("lamp") is the explicit name used by P2 for one of the flashes;
the production uses the same visual technique in several other parts under
names such as `flesze`, `tablica`, and `brum`.

## 1. The effect is a VGA palette operation, not a white overlay

The original runs in 320x200 mode 13h as an 8-bit indexed framebuffer. A pixel
contains a palette index, not an RGB color. The visible RGB value comes from
the 256-entry VGA DAC palette, which contains 768 components (R, G, B for each
entry), each in the 6-bit range 0..63.

The original `CODE/INC/PAL` implementation is:

- `pal_set`: wait for VGA retrace by polling port `3DAh`, then write all 768
  components to the DAC through ports `3C8h/3C9h`.
- `pal_read`: read all 768 current DAC components.
- `pal_fadein10`: read the current palette, move every component toward a
  target by `BL`, clamp at the target, and call `pal_set`.
- `synch`: the retrace polling primitive used by `pal_set`.

The common full-white palette is the `white` buffer containing 768 bytes of
`3Fh`. Applying it does not change the indexed framebuffer. It changes the
color lookup for every pixel, so the already displayed picture becomes a
white screen for the interval during which the DAC contains that palette.
There is no alpha blend, translucent quad, RGB compositing, or pixel-buffer
blend in the original effect.

The source frequently uses this sequence:

```asm
lea     esi,white
call    pal_set
; one or more retrace-paced operations
lea     esi,<normal-palette>
call    pal_set
```

Each `pal_set` waits for a retrace before changing the DAC. Consequently, two
successive `pal_set` calls make the flash visible for approximately one
retrace interval. Two consecutive white `pal_set` calls, followed by a normal
palette `pal_set`, keep white visible for approximately two intervals.

The intensity is not always binary white:

- A true white flash uses 63 for every R/G/B component.
- A brighten flash computes `current_component + delta`, clamps to 63, and
  temporarily displays that resulting palette. It preserves the indexed
  image and most of its color relationships until components saturate.
- A gradual fade calls `pal_fadein10` once per frame with changing `BL`; it is
  not a discrete flash even when its target is white.

## 2. Soundtrack synchronization and `ModPos`

The timing coordinate is the module position returned by `GetModPos`:

```text
ModPos = (order << 8) | row
```

The low byte is the ProTracker row, normally 0..63. Tests such as
`ModPos & 3Fh` therefore select a position within an order, while values such
as `1338h` select an order/row boundary. The flash schedule is driven by these
assembly comparisons and tables; there is no independent wall-clock schedule
for the effect.

The port obtains the same logical position from the playing
`music/amnezja2.mod`. `GetModPos` pumps the MOD player and returns the port's
`(order << 8) | row` value. Animation and transition loops use the EOS
`wait_vbl` replacement, which is QPC-paced at approximately 70 Hz. A flash
hold consumes the same kind of retrace-paced tick as the original blocking
`pal_set`/`v_sync` sequence. The display's physical refresh rate is not used as
a second timing clock.

This means that a difference in audio implementation or playback rate can
change the wall-clock second at which a flash occurs, while the intended
trigger remains the same `ModPos`. The original DOS playback and the libxmp
port also have a known small rate difference; compare phase/`ModPos`, not only
elapsed seconds, when validating synchronization.

## 3. Original trigger and palette map

The following is the authoritative event map reconstructed from the original
assembly and its included data tables.

| Part | Source routine/data | Trigger | Flash palette and duration | Restore and side effects |
|---|---|---|---|---|
| P1 | `CODE/P1/P1.ASM`, `main_loop` | `0300h <= ModPos <= 0400h`; part exits when `ModPos > 0400h` | Current DAC palette brightened toward `white` by `ModPos & 3Fh`; one `pal_fadein10` palette interval | Restore `pal` (`rm_eye.pal`) on the next palette write |
| P2 | `CODE/P2/P2.AS^`, `ruchamy`; `lampa db 0` | First loop with `ModPos > 0500h` while still in the `trasa` camera path (`ModPos <= 063Fh`) | Full `white`, one retrace | Restore `_pal`; set `lampa` to 1, so the event is one-shot |
| P2 | `CODE/P2/P2.AS^`, WIDOKI branch; `CODE/P2/WIDOKI` | `ModPos > 063Fh`, selected WIDOKI record has dword 7 = 1, and `ModPos != plum` | Full `white`, one retrace-scale palette interval | The normal world palette is restored by the surrounding P2 palette path; negate `bolek` |
| P2 water | `CODE/P2/P2.AS^`, `wodda`; `CODE/P2/WATER/WATER` | Water transition after the P2 main loop passes `ModPos > 0730h`; WATER's final transition is gated at `073Fh` | Full `white` over the saved pre-water picture, one retrace | Restore `_pal`; enter the Main2 water scene |
| P3 | `CODE/P3/P3.ASM`, `flesze` | `0D19h < ModPos <= 0D3Eh`, low-six-bit table entry is flagged and its second dword is zero | Full `white`, one retrace | Restore the full `pal` and the final 16 entries from `tunel_pal` |
| P4 | `CODE/P4/P4.ASM`, `brum`; `tablica` | After `ModPos >= 1338h`, flagged low-six-bit indices 58, 59, 60, or 62 | Full `white` for two retrace intervals | Restore `pic_pal`; each table entry is latched so it fires once |
| P5 | `CODE/P5/P5.AS^`, scene-3/scene-4 `intro_fade` | Every iteration of the scene-3 and scene-4 loops | Current palette brightened toward white by the low byte of `ModPos`; one bright-palette interval | Restore `_pal`; source performs three restore `pal_set` calls, so two additional unchanged retrace waits remain after the visible bright interval |
| P6 | `CODE/P6/P6.AS^`, `Keye` | Part start, not a discrete flash | Set full `white`, then fade toward loaded `_pal` with `znika = 1..63`, once per frame | Gradual palette transition; deliberately not routed through the flash primitive |
| P7 | `CODE/P7/P7.AS^`, `FFirst` and phase setup blocks | Initial phase, then first frame after `1D1Fh`, `1D3Fh`, `1E1Fh`, `1E3Fh`, `1F1Fh`, and `1F3Fh` | Full `white`, one retrace | Restore newly mixed `_paleta`; load the next pulse/palette assets |
| P8 | `CODE/P8/P8.ASM`, `brum`; `tablica` | `2630h <= ModPos < 2700h`, flagged low-six-bit entry whose latch is not set | `bialy` full-white palette, one retrace | Restore mutable `white`; set the table latch to 1 |

### P1 brighten window

P1 first copies the rendered image to the displayed VGA target. In the
`0300h..0400h` window it calls `pal_fadein10` toward the all-white palette,
using `BL = ModPos & 63`, then writes `pal`. This is a repeated per-loop
brightening event, not a one-time state transition. The low row value controls
intensity: 0 has no visible brightening and 63 moves every component to full
brightness, subject to the source clamp.

### P2 `lampa` and WIDOKI camera flashes

P2 has two camera-transition mechanisms:

1. In `ruchamy`, once the trasa position passes `0500h`, the byte `lampa`
   guards one `white -> _pal` flash. This is the explicit `lampa` event.
2. After `063Fh`, the camera is selected from WIDOKI. Each record is seven
   dwords: six camera values followed by a flash flag. `CODE/P2/WIDOKI`
   groups four records per camera pose and sets the flag on the first record
   of each group. With the `ModPos & 3Fh` index, this produces flags at
   indices `0,4,8,...,60`, repeated for each 64-row block while the WIDOKI
   portion is active. The `plum` value stores the previous position and
   prevents retriggering while the audio position is held on the same row.

The WIDOKI source calls `pal_set white` at the camera cut and flips `bolek`.
The surrounding P2 loop later restores `_pal`. The port carries the seventh
dword through a dedicated `vk_p2_camera_flash_flag` global because the public
camera output remains the original six-dword `{x,y,z,ax,ay,az}` structure.

P2's water transition is special because the source intentionally flashes the
saved pre-water picture. The source copies `stary` back to VGA memory while
the palette is white. The port therefore copies `stary` to
`framebuffer_off`—the presented framebuffer—not merely to the offscreen render
buffer before invoking the flash primitive.

### P3 `flesze` table

`flesze` is 64 pairs of dwords `{flash, latch}`. The first dword is 1 at:

```text
20h, 21h, 24h, 26h, 28h, 29h, 2Ah,
2Ch, 2Dh, 2Eh, 30h..3Fh
```

The active timeline ends at `0D3Eh`, so the stored `3Fh` entry is outside the
active end boundary. The source tests the second dword for zero and then
literally executes `mov [flesze+eax*8+4],0`. That is not a typo in this
documentation or port: it leaves the latch zero, so a flagged low-six-bit
position can flash again on subsequent frames while the position remains in
the active range. The port preserves this unusual repeated-flash behavior.

The source restores the first 256 palette entries from `pal` and the final 16
entries from `tunel_pal`. The port's `pal_flash_current` restores the complete
current 768-byte palette, which is equivalent when the current palette has
been maintained by the normal P3 `set_pal` calls.

### P4 and P8 latched tables

P4's table is:

```text
64-6 pairs of {0,0}, then:
{1,0}, {1,0}, {1,0}, {0,0}, {1,0}, {0,0}
```

Therefore the flagged indices are 58, 59, 60, and 62. P4 sets the second
dword to 1 after firing. It calls `pal_set white` twice and then
`pal_set pic_pal`, giving two white retrace intervals.

P8's last 15 table pairs, at indices 49..63, are:

```text
49:1  50:0  51:1  52:1  53:1  54:0  55:1  56:1
57:1  58:0  59:1  60:1  61:1  62:0  63:1
```

P8 calls `brum` after `ModPos >= 2630h`; it tests the flag and latch, sets the
latch to 1, then calls `pal_set bialy` followed by `pal_set white`. `bialy`
is the dedicated all-63 palette. P8's `white` buffer is mutable and is also
used by `fade`, `lopa`, and `hopla`, so confusing `bialy` and `white` loses
the true-white flash or restores the wrong fade state.

## 4. Modern Windows/D3D11 translation

The port keeps the original indexed/palette separation:

```text
NASM render target (_screen/backbuffer)
        -- Ekran: copy 320x200 indices -->
presented arena framebuffer (framebuffer_off)
        -- vk_present_frame -->
D3D11 R8 index texture + 256x1 palette texture
        -- point-sampled pixel-shader lookup -->
1280x800 window and DXGI Present(0)
```

The two important arena offsets are `kBackbufferOffset` (`010000h`) and
`kFramebufferOffset` (`020000h`). Most renderers draw to `_screen`, and the
`Ekran` macro copies it to `framebuffer_off` before calling
`vk_present_frame`. A palette update alone changes only the platform-side
palette state; it does not automatically redraw or present the indexed frame.

### Why the explicit flash primitive is required

The port's normal `pal_set` is intentionally a palette-state upload. If a
ported source sequence did this:

```asm
pal_set white
pal_set normal
Ekran
```

the modern renderer would only present the final normal palette. The white
state would never be visible, even though the original VGA DAC did display it
between retrace writes.

`port/core/inc/pal.inc` therefore adds three primitives:

`pal_flash`:

```text
inputs: RSI = flash palette, RDI = restore palette, EBX = white retrace count

vk_set_palette(flash)
vk_present_frame()
repeat EBX times: EOS_WAIT_VBL
vk_set_palette(restore)
vk_present_frame()
```

The indexed data in `framebuffer_off` is unchanged. Both palette states are
explicitly presented over that same indexed image. `EBX = 1` models one white
retrace interval; P4 uses `EBX = 2` for its two-white-write sequence.

`pal_flash_current` first calls `vk_get_palette` into a 768-byte local save
buffer, then uses `pal_flash`. It is used where the source restores a palette
assembled from multiple ranges or where restoring the exact current state is
safer than naming a single source buffer.

`pal_flash_brighten` saves the current palette, builds a second 768-byte
palette with:

```text
bright[i] = min(63, current[i] + delta)
```

and flashes that palette before restoring the saved state. P1 passes
`delta = ModPos & 63`; P5 passes `delta = low_byte(ModPos)` as the original
`intro_fade` does. The P5 caller then performs two additional `v_sync` calls
to preserve the source's three unchanged restore `pal_set` waits.

The primitives call the platform bridge directly rather than `pal_set`, since
the latter does not present. Their prologues also preserve the Windows x64
ABI rule that every NASM-to-C++ call has `RSP % 16 == 0`; this matters in
particular for P8's one-register `brum` helper.

### D3D11 palette conversion

`port/platform/bridge.cpp` exposes `vk_set_palette`, `vk_get_palette`, and
`vk_present_frame` to NASM. `vk_set_palette` stores raw 6-bit values in the
platform palette. `port/platform/d3d11_present.cpp` then:

1. uploads the 320x200 indexed framebuffer to an `R8_UNORM` texture;
2. converts each 0..63 DAC component to 8-bit using
   `(value * 255 + 31) / 63`;
3. uploads the result to a 256x1 RGBA palette texture;
4. uses a point sampler and a palette lookup pixel shader; and
5. calls `Present(0)`.

The point sampler is important: bilinear filtering of palette indices or the
palette lookup would create colors that never existed in the original indexed
pipeline. A full-white palette is therefore exactly 255,255,255 in the
presented D3D11 texture for every palette entry.

`Present(0)` is deliberate. The port's `waitVbl` emulates the original
approximately 70 Hz retrace with QPC; enabling DXGI vsync as a second clock
would reduce the effective rate and change scene/audio timing.

## 5. Port call-site and data mapping

| Original source | Port location | Port translation |
|---|---|---|
| `CODE/INC/PAL`, `pal_set`/DAC write | `port/core/inc/pal.inc:pal_set` | Uploads the 768-byte raw palette without presenting; normal palette behavior |
| `CODE/INC/PAL`, retrace sequencing | `port/core/inc/pal.inc:pal_flash` | Explicit flash present, EOS retrace hold, restore present |
| P1 `pal_fadein10` toward `white` then `pal` | `port/core/parts/p1.asm` | `pal_flash_brighten`, one retrace, restore current `pal` |
| P2 WIDOKI seventh dword | `port/core/engine/p2path.asm` | Six camera dwords still go to `p2_cam_out`; dword seven goes to `vk_p2_camera_flash_flag` |
| P2 WIDOKI camera flash | `port/core/parts/p2.asm` | `pal_flash_current`, then `bolek` negation and `plum` guard |
| P2 `lampa` | `port/core/parts/p2.asm` | `pal_flash(white, _pal, 1)` under the original `lampa` one-shot condition |
| P2 water `stary` transition | `port/core/parts/p2.asm` | Copy `stary` to `framebuffer_off`, then `pal_flash(white, _pal, 1)` |
| P3 `flesze` | `port/core/parts/p3.asm` | Exact static 64-pair mask and source's zero-write behavior; `pal_flash_current` |
| P4 `brum`/`tablica` | `port/core/parts/p4.asm` | `pal_flash(white, pic_pal, 2)` after the source table/latch tests |
| P5 scene-3/4 `intro_fade` | `port/core/parts/p5.asm:intro_fade` | `pal_flash_brighten` plus two restore-only `v_sync` calls |
| P7 phase setup | `port/core/parts/p7.asm:PHASE_BODY` and phase 7 | `pal_flash(white, _paleta, 1)` at each source phase setup |
| P8 `brum`/`tablica` | `port/core/parts/p8_more.asm:brum` | `pal_flash(bialy, white, 1)` after the one-shot latch test |

The source palette names are not interchangeable:

- P1 `pal` is the `rm_eye.pal` normal palette.
- P2 `_pal` is the P2 world palette; the port reconstructs the source's
  inline `jjdj` palette rather than using P5's similarly indexed asset.
- P3 restores `pal` plus the `tunel_pal` tail.
- P4 restores `pic_pal` for the outro picture.
- P5 restores `_pal` after its brightening intervals.
- P7 restores the newly mixed `_paleta` for each water phase.
- P8 uses `bialy` for true white and mutable `white` for the normal/fade
  palette.

## 6. Differences and intentional compromises

The following differences are architectural or environment limitations, not
unknown trigger behavior:

1. **No physical VGA retrace or DAC.** QPC `waitVbl` approximates the original
   70 Hz tick. It cannot reproduce the exact phase of a particular CRT scanout.
2. **Explicit presents are added.** The original DAC write was visible without
   a framebuffer flip. The D3D11 port must call `vk_present_frame` for the
   white and restored palette states, so the flash is not lost between two
   palette uploads.
3. **The flash helper operates on the currently presented framebuffer.** This
   is the correct model for a palette-only flash. At call sites that occur
   before the next render, the port may show the previously presented indexed
   image in white and restore before the new render, whereas the original DAC
   could remain white while the next frame was being drawn. The visual event,
   palette state, and soundtrack trigger are preserved; the exact sub-retrace
   choice of indexed frame is a consequence of the modern copy/present split.
4. **P2 water is handled explicitly.** Because that source transition flashes
   `stary`, the port copies it to the presented framebuffer before flashing;
   copying only to `_screen` would show the wrong image.
5. **P3 restores a complete palette.** The source restores two ranges. The
   port's full current-palette restore is equivalent only if no unrelated
   palette mutation has been inserted between the source range updates and
   the flash. Keep P3 palette ownership unchanged when modifying that part.
6. **Audio rate can shift wall-clock time.** The event conditions remain
   `ModPos`-based, but the original DOS module player and libxmp do not have
   identical elapsed-time behavior. Validate by order/row and phase-aligned
   frames.

The one-retrace flash is intentionally not represented by a normal one-second
reference screenshot. A screenshot can land before or after it. Use the port's
raw frame recorder when checking flashes.

## 7. Validation and debugging guide

Build and run the existing validation suite with:

```powershell
rtk pwsh -NoProfile -Command "& '.\port\build.ps1' -Config Release -Test"
```

The port has 27 CTests covering the assembly/data/rendering slices. They do
not by themselves prove palette-flash timing or pixel fidelity.

For a runtime capture:

```powershell
rtk pwsh -NoProfile -Command "& '.\port\bin\Release\VOODKA.exe' --record 'D:\tmp\voodka-flash'"
```

`frames.raw` consists of repeated records:

```text
64000 bytes  320x200 indexed framebuffer
768 bytes    raw 6-bit palette (256 * RGB)
```

To locate a true-white flash, inspect the palette portion of each record for
768 bytes equal to `3Fh`. A brightening flash has non-white values but usually
has a higher per-channel maximum/mean than the surrounding normal palette.
The record's framebuffer bytes should remain unchanged across a pure palette
flash unless the caller intentionally copied a different frame, as P2 water
does.

Useful source/port checks when debugging a mismatch:

- confirm the MOD `ModPos` at the event before changing any wall-clock code;
- check the low-six-bit table index and its latch word;
- confirm that the correct palette buffer is used for both flash and restore;
- confirm the call is after a presented frame, or intentionally copies the
  required frame to `framebuffer_off` first;
- confirm `pal_flash`'s retrace count matches the number of source `pal_set`
  calls that write the flash palette before the restore;
- confirm the D3D11 point sampler and 6-bit-to-8-bit conversion remain intact;
- preserve the P3 zero-write quirk and P8/P4 one-shot latches; do not replace
  them with a generic edge detector.

The source-of-truth files are the original `CODE/P1` through `CODE/P8` files,
`CODE/INC/PAL`, and the included P2 `WIDOKI`/water tables. The modern effect
implementation is concentrated in `port/core/inc/pal.inc` plus the part call
sites listed above. `docs/KNOWN_DIFFERENCES.md` records the historical port
bug where palette-only flashes were uploaded and immediately overwritten
before presentation; that issue is resolved by this design.

## 8. Validation status

The current implementation was validated on 2026-08-09 as follows:

- `port/build.ps1 -Config Release -Test` completed with all 27 CTests passing.
- Recorded P3, P7, and P8 runtime smoke paths exited successfully.
- A bounded P2 recording progressed through the stadium/camera sequence and
  reached the P2 water transition without a runtime crash.
- The recorded P2 stream contained single-record full-white palette states;
  P3 contained repeated white records at the flagged positions, consistent
  with its source zero-write quirk; and P7 contained the initial white state
  plus the six phase-boundary white states.

The existing `reference/captures/` material contains useful original/port
scene stills, but a one-second still capture cannot reliably land on a
one-retrace flash. A fresh frame-by-frame DOSBox comparison of the shipped
`reference/release/VOODKA.EXE` was not available in the validation
environment because the original EOS/DOS runtime is external to this
repository. Therefore the trigger semantics are source-verified and the
modern palette states are runtime-record-verified; exact CRT scanline phase
against a newly captured original remains an environmental follow-up.
