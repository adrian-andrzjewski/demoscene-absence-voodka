# VOODKA asset format bible — every byte format, decoded and verified

Scope: every asset format the 1996 original consumes, how the original
assembly interprets it, and how the Windows x64 port (`port/`) reproduces it.
Companion docs: `ASSETS.md` (the 76-entry index map + recovery),
`WORLD_ARCHITECTURE.md` (how these assets become 3D worlds — world records,
object instancing, camera, render pipeline), `PORTING_NOTES.md`
(architecture/ABI), `KNOWN_DIFFERENCES.md` (validation).

Everything below was reverse-engineered from the original sources
(`demoscene-absence-voodka-master/`, cited as `CODE/...`) and hex-verified
against the shipped data files. Port behavior was verified by the 26-CTest
suite plus frame-recorded runtime checks (2026-08-05). Documentation audit
2026-08-06: added the full DATAS compile-time spec (§4.5), source-art-pipeline
section (§9), resolved every inferred texture dimension, and corrected the
camera-path text-source mapping and swiatynia city (P2) widoki entry count (§4.6).

---

## 1. The container: `vodka.dat`

### 1.1 Byte layout

```
[0x0000 .. 0x1F3F]  1000 entries x 8 bytes: { offset:u32le, size:u32le }
[0x1F40 ..       ]  76 file payloads, concatenated in VODKA.TXT order,
                    contiguous, no alignment/padding
EOF = 2,731,687 bytes (8,000 table + 2,723,687 payload)
```

- Producer: `CODE/LINKER/LINKER.PAS` (Borland Pascal) from manifest
  `CODE/LINKER/VODKA.TXT` (line 1 = count `76`, lines 2..77 = `dane\...`).
  `poz: array[1..1000] of array[1..2] of longint` is zero-initialized, so
  entries 76..999 are all zero. Files > 65535 B are appended in 65535-byte
  chunks with an unconditional (possibly 0-byte) tail chunk — byte-identical
  to a flat append.
- Offsets are **absolute within the archive** (table included): entry 0 =
  offset 8000, size 16384 (hex-verified).
- Addressing is **by index only** = 0-based manifest position. The
  `vodka <idx>, <var>` macro (`CODE/INC/VODKA:5-13`, duplicated inline in
  `DEMO.AS^:33-41`) reads `[table + idx*8]` (offset) and `[+4]` (size) and
  stores `_file_addr + offset` (a 32-bit arena offset) into `<var>`.
- Load: `DEMO.AS^:71` `LoadFile "voodka.dat",_file_addr` → EOS
  `Load_internal_file` resolves the name against the internal-file table
  embedded in `VOODKA.EXE`. Spelling quirk (do not "fix"): the packer writes
  `vodka.dat`, the demo requests `voodka.dat`, and index 45 is a 1-byte
  placeholder *also* named `voodka.dat` (payload `0x20`).
- **Port:** `port/tools/vodka_pack/vodka_pack.cpp` regenerates the archive
  byte-identically (CTest `vodka.golden_hash`, SHA-256
  `8D5C31D5…6D2C18E4`); provenance independently confirmed: the archive
  appears verbatim inside the release `VOODKA.EXE` at file offset 2677.
  `arena.cpp loadInternalFile` accepts both spellings, copies into the 64 MB
  arena (first alloc → `_file_addr = 0x40000`), idempotent. The ported
  `vodka` macro (`port/core/inc/vodka.inc`) stores the same arena offset;
  its trailing-register state differs from the original (size never read,
  `rsi` left as offset not pointer) — unobservable: every call site in both
  trees reloads from the stored dword.

## 2. Palettes

### 2.1 File format (`.PAL`)

768 bytes = 256 entries × (R,G,B), one byte per channel, **6-bit VGA DAC
values 0..63**. Verified empirically: all 7 archive palettes (ABSENCE, TULL,
DEATH, WODA, LAST, 2WORLD, OBRAZEK) have max byte 63. No header, no per-file
metadata; a `.PAL` never says which picture it belongs to — pairing is by
convention in the part source.

Compile-time palettes (incbin-style ASCII `DB r,g,b` includes, assembled into
the part OBJs): `rm_eye.pal` (oko + szklo (P1)), `jup.pal`/`tn.pal` (16 colors each, tunel + wygibasy (P3)),
`sw.pal`/`v_txr1.pal`/`proc.pal`/`metal.pal` (processorek Nevosolek/nad czerwonym lampa (P4/P8)). All recovered from the
shipped OBJs by `port/tools/pal_extract/extract_pals.py` (OMF LEDATA walk),
incbin'd by the ported parts, covered by `pal.integrity` + `pal.repro` tests.
Note: `CODE/P3/TN.PAL` survives in the tree as ASCII (60 values = 16 colors +
4 black; `set_pal …,16` only reads 48) — it matches the OBJ recovery exactly.

### 2.2 DAC programming semantics (original)

Two helpers only; **no part does its own DAC I/O**:

- `pal_set` (`CODE/INC/PAL:58-67`): wait retrace start (poll `03DAh` bit 3),
  write index 0 to `03C8h`, `rep outsb` 768 bytes to `03C9h`. Always all 256
  entries. The retrace wait doubles as a ~70 Hz pacer (nad czerwonym lampa (P8)'s `lopa`/`hopla`
  fades are paced by nothing else).
- `pal_read` (`PAL:36-46`): index 0 → `03C7h`, `rep insb` 768 from `03C9h`.
- `pal_fadein10` (`PAL:4-34`): read current DAC, step each channel ±`bl`
  toward a target with exact clamp-at-target, re-upload. One step per call;
  callers vary `bl` per frame for timed crossfades.
- `set_pal src,start,count` (external EOS `macro.inc`, absent from the repo):
  DAC sub-range write — index `start` → `03C8h`, then `3*count` bytes;
  entries outside `[start,start+count)` preserved (DAC auto-increment).

No palette cycling anywhere; no part relies on >63 values or DAC truncation.

### 2.3 Per-part palette usage (original → port: identical indices/semantics)

| Part | Palette(s) | Mechanism |
|---|---|---|
| DEMO | — | 64-pass startup fade-to-black (`DEMO.AS^:125-136`); not ported (port starts black = end state) |
| oko + szklo (P1) | `rm_eye.pal` ×2 (`pal`/`pal2`); `white` | white flash via `pal_fadein10` `bl=ModPos&63`; `znika` effects are **pixel dissolves** (threshold vs `_wlk1-3.dat`), not palette ops |
| swiatynia city (P2) | inline `jjdj` (`WORLD.P!`; see §2.5) | fade-in from white `bl=ileFadow>>1`; `lampa`/`bolek`/`wodda` flashes; end fade `bl=(ModPos&31)*2` |
| swiatynia city (P2) water | `absence.pal` (vodka 18) | `SetPal` once at phase start |
| tunel + wygibasy (P3) | `jup.pal`→16-level ramp + `tn.pal` at 240 | `make_pal` ramp (see §2.4), `set_pal tunel_pal,256-16,16`, entry 0 forced black |
| processorek Nevosolek (P4) | `pal` built by 2× `make_pal` from sw/v_txr1/proc/metal; `tull.pal` for outro | per-channel signed deltas; ranges installed `set_pal spal1,0,64 / spal3,144,33 / spal4,192,64` |
| torus ustep village (P5) | `2WORLD.PAL` (vodka 37) | `pal_fadein10` `bl=znikanie>>1` intro + main-loop fade |
| gratki (P6) | `death.pal` (vodka 51) — **two 128-entry banks** | fade from white `bl=znika`; see §2.4 for the bank trick |
| gratki + woda (P7) | `woda.pal` (vodka 69) | white flash at each of 7 phase changes; end fade `bl=(ModPos&0x3f)-0x14` |
| nad czerwonym lampa (P8) | built palette (sw ramp + metal at 192) + `last.pal` (vodka 70) | all through `pal_set`; `lopa`/`hopla` clamp-fades vs `last_pal` |

### 2.4 Palette-as-LUT tricks (the clever parts)

- **tunel + wygibasy (P3) ramp:** `make_pal` (`P3.ASM:432-450`) expands 16-color `jup.pal` into a
  16-level brightness ramp covering palette entries 0..239: level L adds
  `bl = 63-11L` to every channel with **8-bit wrap + signed clamps**
  (`add al,bl / jns` → 0 if negative-as-int8; `cmp al,63 / jle` → 63).
  `4toonel.dat` texels are biased +240 at load so tunnel pixels land on
  `tn.pal` at 240..255. (The port's tunel + wygibasy (P3) `make_pal` originally used a 32-bit
  add, defeating the negative clamp — fixed 2026-08-05; recorded palettes now
  match the original ramp byte-for-byte.)
- **processorek Nevosolek/nad czerwonym lampa (P4/P8) `make_pal`:** per-channel deltas from a 64/22/33/64-color source
  set build shading ramps (e.g. sw → +64 range with (−2,+4,+6) per channel).
  The texture mappers then add a per-face shade offset to each fetched texel
  (`add al,cl`) — palette arithmetic as Gouraud shading.
- **gratki (P6) two-bank overlay:** `death.pal` = 128-entry gray bump ramp + 128-entry
  lizard image colors. The bump LUT output is the palette index directly;
  `jaszczur.dat` ≠ 0 adds **128** (bit 7 = image select) (`P6.AS^:152-156`).
- **torus ustep village (P5) water:** water pixels are masked `& 31` — 32 water colors at the
  bottom of `2WORLD.PAL`; the mirror pass ORs `(screen-224)&31` into the same
  range (`P5.AS^:432-450`).

### 2.5 The swiatynia city (P2) world palette: jjdj (resolved 2026-08-05 audit)

The original `P2.AS^` installs the inline palette `jjdj` (`_pal dd jjdj`,
`WORLD.P!`, 768 bytes) — **not** `2WORLD.PAL`. `2WORLD.PAL` (vodka 37) is
torus ustep village (P5)'s palette (used by P5.AS^) and maps the swiatynia city (P2) stadium textures to
olive/gold/tan instead of the shipped red/maroon/blue world.

The DOSBox stadium capture settles the earlier "tree vs release" ambiguity:
100% of the release's stadium pixels (all 46 used 6-bit colors) appear in
`jjdj`, and zero appear in `2WORLD.PAL` outside the shared black/white. The
prior claim that "`jjdj` is absent from the release EXE" was a false negative
(a byte-layout assumption in the search), and the port's use of `2WORLD.PAL`
was the bug. The port now incbin's `jjdj.pal` (extracted from the tree's
`WORLD.P!`, guarded by the `jjdj.repro` CTest) and copies it into the arena
at part start, matching the original's `_pal dd jjdj` semantics.

Verified by frame recording: the swiatynia city (P2) phase now shows the original capture's
exact colors — e.g. t001 renders (158,8,8)/(190,48,32)/(206,130,89)/(231,
166,130) and the env-mapped torus reads dark blue, matching the original's
stadium; previously it read gold/brown under 2WORLD.PAL.

## 3. Raw bitmaps & textures (`.DAT`, `.INC` in DANE)

### 3.1 Format

Headerless 8-bit indexed pixels, row-major, top-down. No dimensions, no
palette, no transparency flag anywhere in the data — geometry is defined by
the consuming code. Transparency, where it exists, is a per-blitter
convention (index 0, or 0x60 for tunel + wygibasy (P3)'s sun), never a file property.

### 3.2 The texture-mapper contract (`CODE/INC/TXTR.ASM`, `tm_face`)

- Scanline triangle mapper; per-vertex UVs are **8.8 fixed point** repacked
  so `edx = (U<<16)|V`.
- Texel fetch: `bl = high(V); shld ebx,edx,8; al = fs:[bx]` — i.e.
  **`texel = texture[v_int*256 + u_int]`**. Row stride is hard-wired to 256;
  the 16-bit `bx` window caps textures at 64 KB.
- U and V **wrap mod 256** (8.8 overflow, no masks).
- Width must be 256; height is whatever the file holds (128, 152, 172, 200,
  256 in use). No transparency test — texels are written unconditionally.
- The VIRTUAL engine (swiatynia city/torus ustep village (P2/P5)) stores per-vertex UV dwords in the `.V3D`; for
  PHONG (type 2) objects UVs come from rotated normals `(n>>1)+128` →
  env-maps are 256×256.
- Port: `port/core/engine/txtr.asm` is instruction-identical (`shld` fetch
  via `sel_base_table` bases); cross-checked by `txtr.crosscheck`.

### 3.3 Per-asset geometry (derived from consumer code; sizes hex-verified)

| # | File | Size | Dims | Consumer / notes |
|--:|---|--:|---|---|
| 0 | `obrazek.dat` | 16384 | 128×128 | swiatynia city (P2) (`PART2:2` → `_obrazek`); **dead load** in the shipped swiatynia city (P2) (the port's swiatynia city (P2) no longer loads it at all — its earlier water reuse was wrong) |
| 1 | `t001.dat` | 32768 | **256×128** | swiatynia city (P2) `textury[1]` (mapper stride is 256 → wide, not tall) |
| 2 | `t002.dat` | 40896 | **256-wide, 160-row export** (159 full 256-B rows + a 192-B partial row) | swiatynia city (P2) `textury[2..4]`; **no header** (first/last bytes zero; non-zero content rows 0..127; 40896 = 256×159.75 — an unpadded exporter truncation of a 160-row image; the mapper's 256-stride wrap makes the odd size harmless) |
| 3 | `env.dat` | 65536 | 256×256 | swiatynia city (P2) `textury[5]` env map (phong UV from normals) |
| 4 | `_rm.inc` | 51200 | **256×200** | oko + szklo (P1) head texture; oko + szklo (P1) sets the selector limit to 256·200 (`P1.ASM:183-188`) — direct evidence |
| 5-8 | `_logo1-4.inc` | 5880/9702/6300/6804 | 140×42 / 231×42 / 150×42 / 162×42 | oko + szklo (P1) text overlays; index-0 transparent; biased `+240` into the palette top (dims from `logo_tab`, `P1.ASM:85-107`; sizes divide exactly) |
| 9-11 | `_wlk1-3.dat` | 64000 ×3 | 320×200 | oko + szklo (P1) "znika" dissolve masks (per-pixel threshold vs level) |
| 17 | `absence.dat` | 64000 | 320×200 | swiatynia city (P2) water refraction source (sampled from row 60) |
| 19 | `water.abc` | 64000 | 320×200 | swiatynia city (P2) water backdrop (re-copied to `_screen` every frame) |
| 20 | `jup.inc` | 38912 | **256×152** (38912/256 = 152 exact — confirmed by the tunel + wygibasy (P3) 256-stride sample) | tunel + wygibasy (P3) face texture (UV from vertex pos +128/+96); **added** to the lgmap sample |
| 21 | `lgmap.inc` | 51200 | 256×200 | tunel + wygibasy (P3) light map (UV from normals); pre-shifted `shl al,4` per texel at load |
| 22 | `4toonel.dat` | 65536 | 256×256 | tunel + wygibasy (P3) tunnel texture; every texel += 240 at load (into `tn.pal`) |
| 24 | `sw.inc` | 44032 | **256×172** (44032/256 = 172 exact) | processorek Nevosolek (P4) `map1`, nad czerwonym lampa (P8) `map1`; shade offset `add al,cl` per texel |
| 25-27 | `v_txr1/proc/metal.inc` | 51200 | 256×200 | processorek Nevosolek (P4) `map2..4`; metal also nad czerwonym lampa (P8) `map2` (phong) |
| 28 | `logo_a.dat` | 48000 | **15 frames × 64×50** | processorek Nevosolek (P4) `show_logo` anim (not "240×200" — 15·3200 = 48000 exactly) |
| 29 | `tull.inc` | 64000 | 320×200 | processorek Nevosolek (P4) outro picture |
| 36 | `do_water` | 16384 | 128×128 | torus ustep village (P5) water source pic (sampled with 16-bit index wrap) |
| 38-40 | `2ENV/2T001/2T002.DAT` | 65536/32768/32768 | 256×256 / 256×128 / 256×128 | torus ustep village (P5) `textury[3]` env, `[1]`, `[2]` |
| 41-44 | `w1-w4.dat` | 64000 ×4 | 320×200 | torus ustep village (P5) intro overlays (full-screen copies) |
| 45 | `voodka.dat` | 1 | — | placeholder; its torus ustep village (P5) drawer is dead code |
| 46-49 | `h1-h4.dat` | 14976 ×4 | **156×96** (14976/96 = 156 exact — confirmed by the dead `voodka2:` blitter: 96 rows × 156 cols) | per torus ustep village (P5)'s (dead) `voodka2:` blitter (96 rows × 156 cols, index-0 skip); loaded but never drawn. 128×117 also multiplies to 14976, but the only consumer code says 156×96 |
| 50 | `death.dat` | 64000 | 320×200 | gratki (P6) bump **height field** |
| 52 | `mapa.dat` | 16384 | 128×128 | gratki (P6) bump **lighting LUT** (values 0..119) — not a height map |
| 53 | `jaszczur.dat` | 64000 | 320×200 | gratki (P6) overlay mask (nonzero ⇒ shade += 128) |
| 54-67 | gratki + woda (P7) phase pics | 16000 ×7 | 160×100 | overlays; **0 = transparent** over `woda.dat` |
| 55-67 | gratki + woda (P7) phase data | 32000 ×7 | **160×100 int16** | initial wave-field states (one plane each; measured range −515..0) |
| 68 | `woda.dat` | 16000 | 160×100 | gratki + woda (P7) base water pic |
| 71 | `last.dat` | 63680 | **320×199** (63680/320 = 199 exact) | nad czerwonym lampa (P8) end pic, revealed in strips 100+60+39 rows |
| 72 | `2world.inc` | 77824 | **19 frames × 64×64** | torus ustep village (P5) sun sprite anim |
| 73 | `log.inc` | 77824 | 19 × 64×64 | nad czerwonym lampa (P8) sun sprite anim (same size/extents as 72 — same sequence) |

### 3.4 Sprite animation stacks

Headerless frame stacks with per-part blitters (`sloneczko`/`show_logo`):

| Blob | Frames | Frame | Advance | Transparent key | Dest (x,y) |
|---|--:|---|---|---|---|
| `klatki.dat` (swiatynia city (P2)) | 36 | 64×64 | `shl 12`, wrap `cmp 36/sub 35` | **0** | (254,141) |
| `s2.dat` (tunel + wygibasy (P3)) | 36 | 64×64 | same | **0x60** | (254,142) |
| `2world.inc` (torus ustep village (P5)) | 19 | 64×64 | wrap 19 | 0 | (254,141) |
| `log.inc` (nad czerwonym lampa (P8)) | 19 | 64×64 | wrap 19 | 0 | (254,-2) (partly off-screen) |
| `logo_a.dat` (processorek Nevosolek (P4)) | 15 | 64×50 | `imul 3200`, wrap 15 | 0 | (255,4) |

Frame advance is `ramki`-scaled (frame-delta driven, reversible in P2/P4).
Port: identical code; **the torus ustep village (P5) sun load (`vodka 72`) was missing and was
added 2026-08-05** — before that the sprite sampled the archive header.

## 4. 3D assets

### 4.1 `.V3D` object files (hex-verified)

Built as tiny-model .COM images (`tasm` + `tlink /x/3/t`, renamed .v3d per
`CODE/WORLD/VC.EXT`) — hence no file header; data starts at byte 0.

| Offset | Size | Field |
|---:|---:|---|
| +0 | 4 | type: 0=PIXELS, 1=TEXTURES, 2=PHONG |
| +4 | 4 | `nov` = vertex count |
| +8 | 4 | `nof` = face count |
| +12/16/20 | 12 | per-frame spin adders (AngleX/Y/Z) |
| +24..+32 | 12 | unused by the parser |
| +36 | nov×12 | vertices: nov × (x,y,z) `dd` |
| … | nof×12 | faces: nof × (i0,i1,i2) `dd` |
| … | nov×8 | **per-vertex UVs**: nov × (u,v) `dd` — read only for type 1 |

Proof of the per-vertex UV block: WALL.V3D = 140 = 36 + 4·12 + 2·12 + **4·8**,
UVs (5,5)(120,5)(120,120)(5,120); the draw path indexes it by vertex index
with 8-byte stride (`OBJECTS.PM:189-194`). PHONG files carry the block too
(exporter leftovers) but never read it. `TORUS.V3D`: type 2, 346 v / 688 f,
spin (2,2,2). `2TORUS.V3D`: 128 v / 256 f. All six walls share the header
`(1,4,2,0,0,0,0,1,0)`.

Load semantics (`OBJECTS.PM Load_Object`): vertices are scaled **×16 in
place** in the file image; type 2 additionally builds face normals
(cross-product normalized to length 250) and averaged vertex normals
(`NORMALS.PM`). The runtime object header is 21 dwords (+0 type … +44 pUV,
+48 pFaceNormals … +80 pSortOrder); working blocks are `nof·32` +
`nov·44` bytes. `OBJECTS2.PM` (torus ustep village (P5)) is byte-identical parser code (6
comment/dead-line diffs).

**Port:** `port/core/engine/loader.asm vk_load_object` is field-exact;
CTest `v3d.crosscheck` decodes all 8 real DANE objects through the ASM loader
(fields, offsets, ×16 scale, PHONG normals).

### 4.2 `.V3M` morph target (torus ustep village (P5))

`2TORUS.V3M` (5,632 B) = `2TORUS.V3D` **minus its 36-byte header**; only the
first 1,536 B (128 verts × 12 B) are consumed (the 4,096-B tail is a
byte-identical copy of the V3D's face/UV tail). torus ustep village (P5) scales the verts ×16, then
`MakeMorphTable` precomputes **64 chained frames** of a vertex lerp
(16.16 fixed deltas `((target−source)<<16)>>6`), and per frame patches the
object's vertex pointer to `MorphAddreses[ktoryMorph]` (ping-pong ±5).
Port: identical (`p5.asm:597-705`).

### 4.3 World data (48-byte records)

swiatynia city (P2) world (`CODE/INC/WORLD`, 212 records) and torus ustep village (P5) world (`CODE/P5/WORLD`, 45):
`+0 visible, +4/8/12 x,y,z, +16 object no, +20/24/28 angles, +32/36/40 angle
adders, +44 texture slot`. Ports: `core/data/p2world.inc`,
`parts/p5_world.inc` (verbatim data, cross-checked by `swiatynia_city.world.crosscheck`).
`CODE/WORLD/WORLD.V3D` (2,164 B = 4 + 45×48) is a *world table* in a
misnamed extension — a **dev snapshot of the torus ustep village (P5) world**: 44/45 records are
byte-identical to `P5/WORLD`; only record 0 (the torus) differs (angle adders
(8,5,0) vs the shipped (0,0,0)). See `WORLD_ARCHITECTURE.md` §12.1.

### 4.4 VIRTUAL `objects/world` archive

`VIRTUAL/OBJECTS/WORLD.PAS`: `[count:u32][count × u32 offsets][raw blobs]`,
`ofs[0] = 4 + count*4`. Hex-verified: `02 | 0C | 30 16 | …` (2 objects at
12 and 5680). Port `world_pack` reproduces it byte-identically (golden CTest);
`VIRTUAL.exe --check` decodes both torus objects through the real loader.

### 4.5 `CODE/DATAS` compile-time meshes (full spec)

Assembly-time **text** includes consumed by oko + szklo/tunel + wygibasy/processorek Nevosolek/nad czerwonym lampa (P1/P3/P4/P8) — not binary blobs.
TASM `INCLUDE`s the text and assembles the rows into raw word tables inside
the part OBJ. The `;Vertices:`/`;Faces:` line is a comment and is stripped;
the emitted bytes are pure 16-bit words.

**Vertex tables `*_S.INC`:** header comment `;Vertices: N`, then **N rows of
`dw x,y,z`** → **6 B/vertex** assembled. Coordinates are signed 16-bit in
object-space units (oko + szklo (P1)'s torus spans ≈ −1200..+1150; a few thousand max).

**Face tables `*_C.INC`:** header comment `;Faces: M`, then **M rows of
`dw i0,i1,i2`** → **6 B/face**; 0-based vertex indices into the matching
`*_S` table. Winding is CCW for front-facing.

**Consumption:** rows are addressed as `shape[ebp*2+ebp]` = vertex index×3
words (×6 B). The `prepare` routine doubles each face index into **byte
offsets** for the `con2` table (stride ×2), which `rotate`/`show` consume
against `rcalc[ebx*2]` — the byte stride the port initially got wrong (see
KNOWN_DIFFERENCES).

**processorek Nevosolek (P4) morph:** `shape` = vws_1 (222 v); `src1/2/3` = vws_2/3/4 (81/8/256 v)
with zero-filled interpolation buffers `s1/s2/s3`
(`dw NN*3 dup (0)`); per frame the morph lerps src→shape across the three
pairs. Faces: `con1` = vwc_1 (440), `c1/c2/c3` = vwc_2/3/4 (158/12/384).
Ported to `p4_vws_1..4.inc` / `p4_vwc_1..4.inc`.

**nad czerwonym lampa (P8) morph:** `shape` = sw_s_1 (40 v), `s2` = sw_s_2 (33 v), sources
`src3/4/5` = ob_s_1/2/3 (114/128/128 v); the same ob_s files are re-included
as buffers `s3/s4/s5`, and `s6` re-includes sw_s_1 (each `INCLUDE` emits its
own copy). Faces: `con1` = sw_c_1 (40), `c2` = sw_c_2 (48), `c3/c4/c5` =
ob_c_1/2/3 (224/256/256), `c6` = sw_c_1 again. Ported to `p8_sw_*.inc` /
`p8_ob_*.inc`.

**Complete DATAS inventory** (counts verified equal to the `;Vertices/Faces:`
header AND the actual `dw` row count in every file):

| File | Kind | Count | Consumer |
|---|---|--:|---|
| `SHAPE3.INC` | V | 602 | oko + szklo (P1) `shape` |
| `CONSTR3.INC` | F | 1156 | oko + szklo (P1) `con` |
| `LOG_S.INC` | V | 341 | tunel + wygibasy (P3) `shape` |
| `LOG_C.INC` | F | 646 | tunel + wygibasy (P3) `con` |
| `VWS_1.INC` | V | 222 | processorek Nevosolek (P4) `shape` |
| `VWS_2.INC` | V | 81 | processorek Nevosolek (P4) `src1` / `s1` |
| `VWS_3.INC` | V | 8 | processorek Nevosolek (P4) `src2` / `s2` |
| `VWS_4.INC` | V | 256 | processorek Nevosolek (P4) `src3` / `s3` |
| `VWC_1.INC` | F | 440 | processorek Nevosolek (P4) `con1` |
| `VWC_2.INC` | F | 158 | processorek Nevosolek (P4) `c1` |
| `VWC_3.INC` | F | 12 | processorek Nevosolek (P4) `c2` |
| `VWC_4.INC` | F | 384 | processorek Nevosolek (P4) `c3` |
| `SW_S_1.INC` | V | 40 | nad czerwonym lampa (P8) `shape` / `s6` |
| `SW_S_2.INC` | V | 33 | nad czerwonym lampa (P8) `s2` |
| `SW_S_3.INC` | V | 40 | **orphan** |
| `SW_S_4.INC` | V | 40 | **orphan** |
| `SW_C_1.INC` | F | 40 | nad czerwonym lampa (P8) `con1` / `c6` |
| `SW_C_2.INC` | F | 48 | nad czerwonym lampa (P8) `c2` |
| `SW_C_3.INC` | F | 40 | **orphan** |
| `SW_C_4.INC` | F | 40 | **orphan** |
| `OB_S_1.INC` | V | 114 | nad czerwonym lampa (P8) `src3` / `s3` |
| `OB_S_2.INC` | V | 128 | nad czerwonym lampa (P8) `src4` / `s4` |
| `OB_S_3.INC` | V | 128 | nad czerwonym lampa (P8) `src5` / `s5` |
| `OB_C_1.INC` | F | 224 | nad czerwonym lampa (P8) `c3` |
| `OB_C_2.INC` | F | 256 | nad czerwonym lampa (P8) `c4` |
| `OB_C_3.INC` | F | 256 | nad czerwonym lampa (P8) `c5` |
| `SHAPE.INC` | V | 434 | **orphan** |
| `CONSTR.INC` | F | 820 | **orphan** |
| `TOR_S.INC` | V | 384 | **orphan** |
| `TOR_C.INC` | F | 768 | **orphan** |
| `CND.INC` | F | 516 | **orphan** |
| `SHD.INC` | V | 270 | **orphan** |

**Orphans (10, not 6):** `SHAPE.INC`, `CONSTR.INC`, `TOR_S.INC`, `TOR_C.INC`,
`CND.INC`, `SHD.INC`, `SW_S_3/4.INC`, `SW_C_3/4.INC` are **referenced by no
current source** — verified by grep of the entire tree (working copy +
reference mirror); nothing else references them. CND/SHD (516 f/270 v) and
TOR (768 f/384 v) look like earlier, coarser iterations of the P1/P4 torus
families. Document them as development artifacts from earlier iterations, not
consumed by the shipped demo link (`CODE/M.BAT`). Earlier notes claiming
"six orphaned includes" missed the four `SW_*_3/4` pairs.

**Port status:** the 22 consumed files are ported as NASM includes under
`port/core/parts/` (`p1_shape/p1_con`, `log_s/log_c`, `p4_vws_1..4`/`p4_vwc_1..4`,
`p8_sw_s_1..2`/`p8_sw_c_1..2`, `p8_ob_s_1..3`/`p8_ob_c_1..3`); the orphans
are not ported. `vr_object_draw.crosscheck` and the engine selftests validate the
rotation/render pipeline consuming them.

### 4.6 Camera paths

Text sources and their compiled binary node arrays.

- **Binary, processorek Nevosolek/nad czerwonym lampa (P4/P8)** (`trasa.dat` idx 74, `tr2.dat` idx 75): **36 bytes/node
  = 9 dwords** — (o_x,o_y,o_z) full dwords, (r_x,r_y,r_z) and (cm_x,cm_y,cm_z)
  word-truncated on read; **2,964 / 2,508 nodes** (sizes divide exactly:
  106,704 / 90,288 B). Compiled from text by `CODE/COMS/MALE.ASM` — a 4-line
  trivial assembler (`INCLUDE trasa.dat` inside a `use32` segment, `tlink /t`
  to a `.COM`, renamed `.DAT`); node 0 hex-verified against the text sources.
  The path **ping-pongs** (`mnoznik` ±1, clamped at 0/`ruchow`), advanced
  `frames*2*mnoznik` nodes/frame. No interpolation.
- **Text, processorek Nevosolek/nad czerwonym lampa (P4/P8) (9 dwords/node):** `P4/TRASA.DAT` = **2,964 rows** of
  `dd o_x,o_y,o_z,r_x,r_y,r_z,cm_x,cm_y,cm_z` (compiles to `trasa.dat`);
  `COMS/TRASA.DAT` = **2,508 rows** of the same 9 `dd` form (compiles to
  `tr2.dat`). Note `P4/TRASA.DAT` ends `ruchow equ 2951` — the swing-clamp
  constant, not the row count. `COMS/TR2.DAT` is **not** a camera path (a
  19-line scancode/string table); do not treat it as a path source.
- **Text, swiatynia city/torus ustep village (P2/P5) (6 dwords/node, 24 B):** `P2/TRASA.!` = **2,964 rows**,
  `P5/TRASA.!` = **3,876 rows** of
  `dd CameraX,CameraY,CameraZ,EyeAx,EyeAy,EyeAz`, included at assembly time
  (not compiled); `trasa_ruch × 24`, advanced by `ramki`, torus ustep village (P5) wraps at
  `ruchow-2`.
- **swiatynia city (P2) widoki** (scripted still cameras, `P2/WIDOKI`): **7 dwords/entry** =
  `dd x,y,z,ax,ay,az,flashFlag` (28 B/entry). Written with `rept`/`endm`
  blocks that expand to **64 entries** (8 blocks × 4 + `rept 2` × 4 blocks
  × 4 = 32 + 32), each entry pairing the flash variant (flag 1) with three
  non-flash copies (flag 0). Consumer (`P2.AS^:148-181`): active when
  `ModPos > 0x63f`; index = `ModPos & 0x3f` (0..63) × 28 B → reads exactly
  the 64-entry table, **no over-read** (the flag triggers the `plum` flash).
  Earlier notes claiming 49 entries with a benign over-read were wrong.
- Ports: `core/data/p2trasa.inc`, `core/data/p2widoki.inc` (NASM `%rep`
  mirror of the original expansion), `parts/p5_trasa.inc` verbatim;
  `swiatynia_city.path.crosscheck` validates the camera switch logic.

## 5. Water, bump & drop-path data

### 5.1 `TABLICA3` drop-path tables (text `dd` includes)

129 dword entries (128 reachable, `&127`). Each entry is a **byte offset into
the 16-bit water page buffer** (`2*(y*W+x)`) — a precomputed crawl path for
the drop cursor, not random points. Variants:

| File | Buffer width | Used by |
|---|---|---|
| `P2/WATER/TAB` | 320 | **the table swiatynia city (P2)'s water actually uses** (`WATER.PM:106`) → port `p2_watertab.asm` (label `watertab`) |
| `P2/TABLICA3` ≡ `P7/TABLICA3` (byte-identical) | 320/160 | gratki + woda (P7) production water (`woda` macro); the swiatynia city (P2) copy is unreferenced by the original build |
| `P5/TABLICA3` | 128 | torus ustep village (P5) `RIP` drop path → port `p5_tablica3.asm` |
| `INC/TABLICA3` (+ `INC/RIP`) | 128 | dead dev files (random-scatter variant; `P5/RIP` shadows `INC/RIP`) |

Port conversion: `tabl2nasm`; CTest `tablica3.crosscheck` now verifies all
five tables value-for-value against the TASM text.

### 5.2 `P6/TABLICA3` + `TABLICA.PAS` — the bump light path

Not a water table: 129 **pairs** of dwords =
`(round(156·cos k·sin²k)−160, round(20·(sin k−cos k))−100)`, k = 0..2π step
π/64 (`CODE/P6/TABLICA.PAS:17-23`) — a Lissajous/teardrop path for the bump
light position, seeded per frame into `BUMPXXX/BUMPYYY` (SMC → port
`bump_x_base/bump_y_base`).

### 5.3 gratki (P6) bump mapping (exact per-pixel formula)

Interior 318×197; light at `(bump_x, bump_y)` (path point + screen pos);
skip if |Δ| > 128. From the **height field `death.dat`**: `gx = p[i+1]−p[i−1]`,
`gy = p[i+320]−p[i−320]`. Falloff `u = max(120−|gx−lx|,0)`,
`v = max(120−|gy−ly|,0)`. Shade = **`mapa.dat[u*128 + v]`** (the 128×128
lighting LUT). Overlay: `jaszczur[i] ≠ 0 ⇒ shade += 128` (palette bank
select, §2.4). Port `p6.asm` is semantically exact.

### 5.4 Water engines (three different geometries!)

All variants share the sim `new = (h[N]+h[S]+h[E]+h[W])/2 − old`,
damped `new −= new >> D` on a page-flipped **signed-16-bit** field, and the
draw: refraction displacement = gradient ≫ 3, brightness `(128 − vgrad) & 0xff`,
`out = (sample × bright) >> 8`.

| | swiatynia city (P2) (`WATER.PM`) | torus ustep village (P5) (`WATER.PM`) | gratki + woda (P7) (`WATER.PM`) |
|---|---|---|---|
| Field | 320×200 int16 | 128×128 int16 | 160×100 int16 |
| Sim region | 318×80 @ word 321 | 126×126 @ word 129 | 158×98 @ word 161 |
| Damping D | 6 | 6 | 4 |
| Draw | 320×80 strip, 1:1, screen rows 61..140 | 2×2 into the 256×256 `_waterWorld` texture, `& 31` | 2×2 upscale to screen, **99 rows** (rows 1..198) |
| Source pic | `absence.dat` (320-wide, from row 60) | `do_water` (128-wide, 16-bit index wrap) | `_obrazek` = `woda.dat` ⊕ phase overlay |
| Backdrop | `water.abc` re-copied per frame | (3D world) | (self) |
| Drops | 3×2 words at `TAB[…]` into `_bufor1` | RIP: `+0,+1,+256,+256` (dup bug preserved) every sim call | 1 byte at `tablica3[…]` |
| Palette | `absence.pal` | `2WORLD.PAL` | `woda.pal` |

gratki + woda (P7)'s per-phase assets: the 32,000-B file is **one 160×100 int16 initial
ripple state** (copied verbatim into `_bufor1`; measured value range
−515..0, so the sim's 16-bit wrapping is provably never exercised); the
16,000-B file is a 160×100 overlay composited 0-transparent over
`woda.dat` (`mieszanie`). Phase order: camorra, poison, substanc, tcman,
hypnotiz, **motion (6th), pulse (7th)**.

Port: `inc/water.inc` (gratki + woda (P7)), `parts/water.p5.inc` (torus ustep village (P5)), `parts/water.p2.inc`
(swiatynia city (P2) — added 2026-08-05, replacing a gratki + woda (P7) engine reuse that sampled the wrong
picture and never installed `absence.pal`). Deliberate deviations, all
documented in-code: row/col clamps instead of the original's out-of-grid DOS
reads (only undefined edge cells differ); torus ustep village (P5)'s final offset keeps the 16-bit
wrap exactly; the gratki + woda (P7) port loops the correct 99 rows (a 100th row wrote 2
bytes past the 64,000-byte frame — fixed). The propagation sum itself keeps
the original's 16-bit signed `ax/dx` arithmetic: an earlier port used 32-bit
`movzx` loads that zero-extended negative ripple values into large positives,
corrupting the average/diff/damping into full-field noise — fixed 2026-08-05
in both `inc/water.inc` and `parts/water.p5.inc` (swiatynia city (P2) already used `ax`/`dx`).

### 5.5 Sine tables

- `CODE/INC/SIN`: 1024 × `dd`, **`round(32766·sin(2πi/1023))`** — a
  1023-*interval* table (sin[255]=sin[256]=32766 plateau, zero crossing
  between 511/512, sin[1023]=0; hex-verified). Used Q15 by `MROTATE.PM`
  (`cos a = sin[(a+256)&0x3ff]`, `shrd eax,edx,15`).
- `sinus.inc` (word table): **missing from the repo**. Consumers
  (`ENGINE.ASM:332-475`, `P3.ASM:577`) read cos at word 256+a ≤ 1279, so the
  original had ≥1280 entries (or over-read deliberately).
- Port: `sin_tables.cpp` generates `vkSin` (1024 dd) + `sinus` (2048 dw =
  two periods, covering the cos over-read) as `round(32767·sin(2πi/1024))` —
  a true 1024-step sine. Max deviation vs `INC/SIN` is 201 (~0.6% of full
  scale) — documented, deliberate (the missing `sinus.inc` forces a
  reconstruction either way; visually indistinguishable).

### 5.6 Toonel precalc (tunel + wygibasy (P3))

`_tableToonel` = 128,000 B, built once at boot by x87 (`DEMO.AS^:174-225`,
the few-seconds DOS pause): per pixel (x=−160..159, y=−100..99):
`u = int(atan2(x,y)·128/π) mod 256` (`fpatan`), `v = int(3000/√(x²+y²)) mod
256` (`fsqrt`), packed as (u|v<<8) words — even pixels at +0, odd at +64000
(the `xchg ah,bl` shuffle). tunel + wygibasy (P3) reads two consecutive words per 2 pixels,
adds the frame counter (16-bit: angle scroll with carry into depth), fetches
`4toonel.dat[bx]/[cx]`. Port `toonel.asm` reproduces the x87 sequence
instruction-for-instruction (`toonel.selftest` spot-checks vs doubles,
tolerance 3 for 80-bit-vs-64 rounding).

## 6. Audio: `music/amnezja2.mod`

### 6.1 Module anatomy (byte-parsed)

| Field | Value |
|---|---|
| Size | 381,890 B |
| Title | `<>Amnezja<>` (by Szudi/Szymon Szuchaja, 29.07.1996) |
| Magic @1080 | **`14CH`** — FastTracker-family 14-channel |
| Orders | **42** (restart 0 → loops to order 0) |
| Patterns | **39** (max index 38; orders reference patterns 3,4,23 twice) |
| Instruments | 31 headers (25 non-empty), 8-bit **signed** samples, 7,046 B total, 5 looped |
| Pattern data | 39 × 64 rows × 14 ch × 4 B = 139,776 B @1084 (34,944 cells decode 100% clean, classic PT periods 113..856) |
| Tempo | 125 BPM speed 5 (pattern 1 row 0: `F7D F05`) |
| **Trailing data** | **233,984 B (61% of the file!)** past the well-formed module end at 147,906 — no MOD magic, not an integral pattern count for any channel width; inert for both DIAMOND and libxmp (merged session leftover, most likely) |

### 6.2 Original playback & sync

EOS/DIAMOND (`DIAMOND.OBJ`, binary-only): `Load_Module` with **bx = 44,000**
requested Hz (`DEMO.AS^:112`), `Set_Pattern 0`, `Play_Module`. Measured
DOSBox/SB16 playback is ~5% slow (fit r = 0.950; hypothesis: SB16 DSP time
constant quantization 44,000 → 41,667 Hz, ≈0.9 semitone flat) — the port
plays pitch-correct at 44,100 Hz via the dedicated NASM tracker/mixer and
WASAPI worker (documented, not "fixed"). libxmp is a reference oracle only.

**ModPos = (order << 8) | row** — proven by `DEMO.AS^:240-244`
(`mov al,bl` merges BL's row into AH's order), oko + szklo (P1)'s `and bx,0ff00h / sub bh,2`
order extraction, every row mask being 6-bit, and all exit constants decoding
to order ≤ 41/row ≤ 63 (swiatynia city (P2) `0x0B3F` = order 11 row 63; under the alternative
`(order<<6)|row` it would need order 44 of 42). The AGENTS.md "(order<<6)"
note was stale and has been corrected.

Per-part exit constants (original source ↔ port `kPartStartModPos`):

| Boundary | Original condition | Port |
|---|---|---|
| oko + szklo (P1)→swiatynia city (P2) | > 0x0400 | 0x0400 ✓ |
| swiatynia city (P2)→tunel + wygibasy (P3) | > 0x0B3F | 0x0B40 ✓ |
| tunel + wygibasy (P3)→processorek Nevosolek (P4) | > 0x0D3E | 0x0D40 (1 row late, seek-only) |
| processorek Nevosolek (P4)→torus ustep village (P5) | **≥ 0x1400** | 0x1400 (was 0x1200 — processorek Nevosolek (P4)'s *outro* start; fixed) |
| torus ustep village (P5)→gratki (P6) | > 0x1B3F | 0x1B40 ✓ |
| gratki (P6)→gratki + woda (P7) | > 0x1C3F | 0x1C40 ✓ |
| gratki + woda (P7)→nad czerwonym lampa (P8) | ≥ 0x203F | 0x2040 (1 row late, seek-only) |
| end | ≥ 0x2700 (nad czerwonym lampa (P8)), stops module at 0x2708 | 0x2640 ✓ |

Orders 40–41 (patterns 37–38) are never played in either version.

## 7. Presentation: mode 13h → D3D11

How the DOS pixel path maps to the modern one, and the fidelity choices.

### 7.1 Memory model

Original: parts render into a 64,000-B offscreen buffer (`_screen`), then
`Ekran` (`VIDEO.PM`) `rep movsw`s it to VGA memory `0xA0000`; some effects
(processorek Nevosolek/nad czerwonym lampa (P4/P8) outros, swiatynia city (P2) water pre-loop) write VGA directly. Palette writes go to
the DAC instantly (visible mid-frame in principle).

Port: two fixed arena overlays (`platform_abi.h`): `kBackbufferOffset`
(0x10000, `_screen`) and `kFramebufferOffset` (0x20000, the "VGA memory").
`Ekran` blits backbuffer→framebuffer **and calls `vk_present_frame`**
(`core/inc/video.inc`). **Rule enforced by this audit:** any framebuffer/
palette change that was directly visible on DOS needs an explicit present —
the processorek Nevosolek (P4) tull-picture outro and the nad czerwonym lampa (P8) end-screen sequence were invisible in
the port until presents were added (2026-08-05); the nad czerwonym lampa (P8) outro now ends
all-black with exit 0, frame-verified.

### 7.2 Color conversion (6-bit DAC → 8-bit)

- All demo palette math stays in **6-bit space** exactly like the original
  (`setPalette` stores `v & 63`; fades/clamps behave identically).
- At upload, each channel maps to 8-bit by **`round(v·255/63)`, computed
  exactly as `(v·255 + 31) / 63`** (`d3d11_asm_present.asm`). This is the linear
  mapping the VGA DAC's analog output implements (v/63 of full scale), and it
  matches `frames2img.cpp`, so recordings and on-screen output agree
  pixel-for-pixel. (The port previously truncated `v·255/63`, losing ≤1 LSB
  on ~half the values — fixed.)
- The palette lives in a 256×1 `R8G8B8A8_UNORM` texture; the frame is an
  `R8_UNORM` 320×200 index texture; the pixel shader maps index → palette
  texel with texel-center addressing (`(idx+0.5)/256`) — pixel-identical to
  DAC behavior, no filtering of indices.

### 7.3 Gamma

The original chain is: 6-bit value → DAC voltage (linear) → CRT phosphors
(≈ power law γ≈2.2, i.e. the *display* applied the gamma). The port outputs
the linear values untouched to an `R8G8B8A8` swapchain (no sRGB conversion).
On a modern sRGB monitor this is visually near-identical to the CRT result,
because sRGB's electro-optical curve closely approximates the CRT's native
power law — applying any *additional* gamma/sRGB encode would double-correct
and wash the image out. So: **no gamma conversion, deliberately**. The demo's
art was tuned on CRTs and its dark ranges (e.g. tunel + wygibasy (P3)'s ramp levels 6-14) sit
exactly where naive brightening would be most visible.

### 7.4 Scaling, filtering, aspect ratio

- `D3D11_FILTER_MIN_MAG_MIP_POINT`, `CLAMP`: nearest-neighbour, no
  interpolation — preserves the hard pixel edges of mode 13h art. The sampler
  is explicitly created with **all** fields set (a zero-initialised desc left
  `AddressW=0`, an invalid address mode, so `CreateSamplerState` returned
  `E_INVALIDARG` and the pipeline silently ran D3D11's *default* sampler,
  `MIN_MAG_MIP_LINEAR` — a blurred bilinear upscale. Fixed 2026-08-05; the
  GPU readback now contains only exact palette texels, no blend colours).
- Window is **1280×800 = exact integer 4×** of 320×200: every source pixel
  becomes a uniform 4×4 block, no fractional resampling anywhere.
- Aspect: real mode 13h on a 4:3 CRT displayed 320×200 with 1.2:1
  (tall) pixels — a 4:3-stretched image. The port presents square pixels
  (16:10 content), the same choice DOSBox and most emulators make by default;
  a windowed 1280×800 with CRT-stretch would need ~1067×800 and was rejected
  to keep integer scaling. The demo's art is pixel-native (fonts, logos drawn
  for square-ish editing tools), so the difference is a mild vertical
  compression vs a 1996 CRT, not a distortion of layout.
- Presentation: `Present(0)` (immediate). The demo is paced by the EOS
  `wait_vbl` emulation (QPC, 70.0 Hz target, sleep+spin) — vsync-locking the
  swapchain summed two clocks (70 Hz software + 60 Hz display) to ~31 fps.
  Like real VGA writes, a one-line tear is possible; delta-driven animation
  keeps exact speed regardless.

### 7.5 Timing semantics

`wait_vbl` returns the EOS-faithful **delta since the previous call** (~1 per
frame), which every part multiplies into animation (`ramki`/`frames`).
ModPos drives scene sync, so the 70.0 vs 70.086 Hz (real 13h retrace)
0.12% deviation is irrelevant to sequencing.

## 8. Verification status (2026-08-05)

**Byte-exact (CTest-enforced):** `vodka.dat` (golden SHA-256 vs the archive
embedded in the release EXE); `objects/world` (world_pack golden); all five
water drop tables (`tablica3.crosscheck`); V3D/V3M decode (`v3d.crosscheck`);
the 6 OBJ-recovered palettes (`pal.integrity`/`pal.repro`); engine math
(sqrt/rotate/sort/normals/persp/cammat/txtr/v2d/p2draw/p2loop/p2path/p2world);
`build.addr32` reloc hygiene.

**Runtime-verified this audit (frame-recorded):** tunel + wygibasy (P3) palette ramp == original
8-bit semantics for all 720 bytes + tn.pal region exact; swiatynia city (P2) water installs
absence.pal (768/768 match), draws the live 320×80 strip over water.abc; torus ustep village (P5)
sun sprite present and animating; processorek Nevosolek (P4) outro presents the tull fade-in
(palette converges white→tull.pal progressively); nad czerwonym lampa (P8) outro slices + lopa +
274-VBL hold + hopla fade to all-black, exit 0; full playthrough exit 0 in
252 s.

**Fixed during this audit:** tunel + wygibasy (P3) `make_pal` 8-bit clamp; swiatynia city (P2) water engine
rewritten faithful (was a gratki + woda (P7) engine reuse, wrong pic, no palette); torus ustep village (P5)
`vodka 72` sun load; torus ustep village (P5) RIP drop injection (with the original's duplicate
`+256` poke); water.inc 99-row loop; processorek Nevosolek/nad czerwonym lampa (P4/P8) outro presents; palette 6→8-bit
rounding; part-5 seek boundary 0x1200→0x1400; gratki (P6) dword→word ModPos compare;
loader UV-block comments (per-vertex, not per-face).

**Remaining known nuances (all documented, none blocking):** swiatynia city (P2) env-object
shade nuance; nad czerwonym lampa (P8) tone nuance; sin-table 1023-interval vs 1024-step (max 201
Q15 units); MOD 44.1 kHz pitch-correct vs the original's ~5%-slow SB16 rate;
square vs CRT-tall pixels; out-of-grid water samples clamped where DOS read
undefined memory.

## 9. Source art pipeline (`CODE/FLI/`)

The `CODE/FLI/` directory holds the raw art sources that became the packed
sun/eye animation blobs (§3.4 `klatki.dat` idx 16 / `s2.dat` idx 23):

- **`EYE_AN01..36.GIF`** (36 files): 64×64 GIF frames of the eye animation.
  These were dumped to raw `.DAT` frames (K1..K36.DAT, each 4,096 B = 64×64
  8-bit indexed) and concatenated into `klatki.dat` (swiatynia city (P2) sun, idx 16) and
  `s2.dat` (tunel + wygibasy (P3) sun, idx 23). Each `.DAT` has an accompanying `.PAL`
  (768 B, per-frame palette — some frames share palette-only files).
- **`K1..K36.DAT`** (36 × 4,096 B): raw 64×64 indexed pixel dumps, the
  primary frames.
- **`K1..K36.PAL`** (36 × 768 B): per-frame palettes (31 `K*.PAL` + 5
  `EYE_AN15..19.PAL` palette-only files).
- **`CLAT/K1..K36.DAT`** (36 × 4,096 B): the same frames as raw pixel
  extractions — the **authoritative source** for the packed animation blobs.
- **`CLAT/K1..K36.CEL`** (36 × 4,896 B): Autodesk Animator CEL frames;
  **not RLE as previously guessed**. 4,896 = 4,096 pixels + 768 palette
  + 32-byte header. Hex-verified from K1.CEL: first 8 bytes
  `19 91 40 00 40 00 00 00` — byte 0 = `0x19` (header size? not 0x0A), bytes
  2-3/4-5 = width/height `0x0040` = 64, not the textbook 8-byte CEL header
  `width:u16,height:u16,xoff:s16,yoff:s16`. Constant 4,896-B size across all
  36 files confirms **raw, not RLE**.
- **`EYE_ANI.FLC` / `EYE_AN2.FLC`** (~46 KB each): Autodesk Animator FLC
  animations — the sequence containers. **Not consumed by the demo at
  runtime.**
- **`AA.CFG`** (84 B): Autodesk Animator config file. Not consumed.
- **`2`** (147,456 B = 36 × 4,096): raw dump of the first animation sequence
  — the concatenation source, matching `klatki.dat`/`s2.dat` size.

**Pipeline:** GIF/FLC → Autodesk Animator → per-frame CEL + raw
`.DAT`/`.PAL` → concatenate the raw frames → `klatki.dat`/`s2.dat` in
DANE/ → packed into vodka.dat. Nothing in FLI/ is read at runtime; it is
the recoverable source art for the animation blobs.
