# VOODKA — a 1996 demoscene production, brought back to life

**VOODKA** is a native Windows x64 port of the 1996 MS-DOS demo by the
Polish demogroup **Absence**. The original was written in 32-bit x86 assembly
for a 386-class PC, an FPU, 8 MB of RAM, VGA mode 13h, and a Sound Blaster.
The port runs the production's eight parts on modern Windows hardware while
preserving its 320×200 indexed-palette character, fixed-point arithmetic,
music-driven timeline, and wonderfully strange late-1990s atmosphere.

This repository contains both the modern port and the original source and
release as archival material. The original trees are provenance, not build
scratch space; all active development happens under `port/` and `docs/`.

![The original and ported VOODKA P5 torus scene](reference/captures/port_p5_torus.png)

## The short version

```powershell
cd port
.\build.ps1 -Config Release -Test
.\bin\Release\VOODKA.exe
```

The build produces a self-contained `port/bin/Release/` directory with the
demo, packed data, and soundtrack. The window is 1280×800: an exact 4×,
point-sampled presentation of the original 320×200 logical framebuffer. The
demo runs at approximately 70 frames per second and plays all eight parts from
beginning to end.

## A little history

VOODKA came from the intensely inventive PC demoscene of the mid-1990s. The
release package describes it as first presented at **Digital Art 1.5** and as
a democompo winner. Its feature list is a charming snapshot of the era:
virtual-reality scenes, toonel shading, twisted Phong-mapped textures, water,
reflections, 2D bump mapping, palette fades, text, and more effects than a
386 had any reasonable right to perform.

The original program is not a conventional application. It is a linked DOS
executable built from TASM assembly, custom include files, hand-packed binary
assets, and the EOS kernel. A filename such as `TABLICA3`, `WORLD.P!`, or
`P5.AS^` is not a missing extension or an accident: it is part of the
production's build language. The code writes VGA memory directly, changes the
DAC palette as an effect in its own right, patches instructions while running,
and uses a music position called `ModPos` as its clock.

Nearly thirty years later, the goal was not to redesign VOODKA as a modern
3D demo. The goal was to understand what the original actually did, replace
only the pieces that belonged to DOS, and let the old assembly keep speaking
for itself.

## The porting story

The first step was archaeology. The original source, the shipped executable,
the linker manifest, the DOS release notes, and DOSBox captures each answered
different questions. Some answers were in the source; others had to be
recovered from binary objects or inferred from the code that consumed them.

The most interesting discoveries included:

- The Borland Pascal linker packs 76 named files behind an 8000-byte offset
  table. The rebuilt archive is checked against the archive embedded in the
  original `VOODKA.EXE`.
- VGA palettes are 6-bit values, not ordinary 8-bit RGB. The port keeps the
  original palette arithmetic and converts to 8-bit only when uploading the
  palette texture.
- `.V3D` and `.V3M` are custom virtual-reality mesh formats. Their headers,
  vertex data, UV blocks, face records, Phong modes, and morph targets were
  reconstructed from the loader and validated against the real assets.
- The P2 stadium and P5 colosseum are authored world tables with object
  records, camera paths, painter sorting, back-face tests, and texture
  selectors—not pre-rendered scenes.
- P5's torus is a morphing 3D object over a render-to-texture water polygon.
  The reflection pass has its own precise object composition, mirror step,
  ripple tables, palette behavior, and 16-bit wraparound rules.
- Several palettes lived inside assembled OMF object files rather than as
  obvious standalone assets. They were recovered byte-for-byte, including the
  distinct P4/P8 material palettes.
- The original modifies instruction immediates for water, bump maps, fades,
  and animation. Since executable code is read-only under modern DEP, those
  sites became explicit state variables with the same widths and wraparound.

Then came the less glamorous archaeology: a 64-bit load that swallowed a
neighboring dword, a missing painter sort, an x64 ABI stack alignment error, a
selector that could no longer be represented by `fs`, and a single extra
word in a P5 water reset that corrupted the reflection composition. Each bug
looked like an artistic problem until the assembly, the memory layout, and the
reference frame were compared together. That is the satisfying part of this
project: the strange image on screen is usually a precise clue about a tiny
piece of old machine code.

## What is preserved

The port retains the original P1–P8 structure and its music-driven progression:

1. P1 — the head, texture work, logos, and palette fades
2. P2 — the stadium virtual-reality scene and reflective water
3. P3 — the twisted toonel and its textured hero object
4. P4 — the morphing plate/world sequence and picture outro
5. P5 — the torus, colosseum ring, sun sprite, morph animation, and water
6. P6 — 2D bump mapping
7. P7 — the multi-phase water effect
8. P8 — the rotating object viewer and final outro

The port's video path is deliberately simple and faithful: the assembly draws
indexed pixels into a 320×200 backbuffer, the platform layer presents that
frame, and a D3D11 shader looks up each index through a 256-entry palette
texture. Nearest-neighbour sampling and integer scaling keep the hard-edged
VGA look instead of smoothing it into a modern texture.

The original soundtrack is the 14-channel FastTracker module `<>Amnezja<>`
by Szudi, dated 29 July 1996 in the recovered asset metadata. The port uses
the vendored libxmp player with an event-driven WASAPI output path. Its
`ModPos` value is represented as `(order << 8) | row`, just as the demo expects,
so scene changes, palette flashes, morphs, camera movement, and animation are
driven by the same musical timeline rather than by an unrelated wall clock.

## Original authors: tribute and credits

> **The work that made VOODKA possible belongs to Absence and its original
> collaborators.** The Windows port is a preservation and appreciation
> project. It does not replace, re-author, or claim ownership of the 1996
> production, its code, its graphics, its music, or its tools.

The following is the credit block from the shipped release's `VOODKA.NFO`,
preserved here with the original names and roles:

| Original credit | Name(s) |
| --- | --- |
| Code | **Warlock & Nuke** |
| Music | **Szudi** |
| Graphics | **Grass, Orgy, Nuke & Warlock** |
| Design | **Warlock & Nuke** |
| Objects | **Walker** |
| Kernel | **E.O.S.** |
| Palette fading | **Warlock** |
| Moral support and some graphics | **Walker** |
| Exit to DOS | **Nuke** |
| “Bulka & Coclet” support | **Nuke's mother** |
| Rama | The release's playful “bzdety” credit |

The archival source NFO spells the musician's name `Sudi`; the shipped release
uses `Szudi`, and the module metadata identifies the author as Szudi / Szymon
Szuchaja. The complete original notes—including the authors' tool list,
special greetings, jokes, and period spelling—remain in
[`reference/release/abc_voda/VOODKA.NFO`](reference/release/abc_voda/VOODKA.NFO).

The original release also acknowledges the EOS kernel, the graphics catalog
sources used by the authors, and the people named in its extensive greetings.
Those acknowledgements remain part of the archival release and are not
silently rewritten as modern port credits.

## Building on Windows

### Requirements

- Windows 10 or 11, x64
- Visual Studio 2022 or its Build Tools, with the x64 C++ toolchain and Windows
  SDK (`build.ps1` can also locate a newer Visual Studio installation)
- CMake 3.24 or newer on `PATH`
- PowerShell 7 or newer

NASM 2.16.03 and libxmp 4.6.2 are vendored under `modules/`; no package
manager, DOS compiler, TASM installation, or external audio library is needed.

### Build and test

```powershell
cd port
.\build.ps1 -Config Release
.\build.ps1 -Config Release -Test
```

For a clean rebuild:

```powershell
.\build.ps1 -Clean -Config Release -Test
```

The script initializes the Visual Studio environment, configures CMake for
x64, explicitly selects the vendored NASM, builds the demo and tools, and can
run the complete CTest suite. The finished port currently has **27 tests**:
assembly-versus-reference checks, archive and palette reproducibility checks,
real V3D/V3M decoding, water-table verification, relocation hygiene, and
viewer parsing.

If configuring CMake manually, pass the vendored assembler explicitly:

```powershell
cmake -S . -B build\Release -G "Visual Studio 17 2022" -A x64 `
  -DCMAKE_ASM_NASM_COMPILER="$pwd\..\modules\nasm\nasm.exe"
```

Using a different NASM version can silently break `[rel X]` references in
high-address data and produce convincing but corrupted failures. The build
script avoids that trap.

### Build output

`port/bin/Release/` contains:

```text
VOODKA.exe                 the complete demo
VIRTUAL.exe                standalone VR-engine loader/viewer harness
asset_viewer.exe           explorer for the original 3D assets
data/vodka.dat             packed demo assets
data/world                 packed VIRTUAL world objects
music/amnezja2.mod         the original soundtrack
*_selftest.exe              validation tools used by CTest
frames2img.exe             recorded-frame converter
```

The demo directory is self-contained. To distribute a playable build, copy
`VOODKA.exe`, `data/vodka.dat`, and `music/amnezja2.mod` together.

## Running the demo

From `port`:

```powershell
.\bin\Release\VOODKA.exe
```

Useful entry and diagnostic options:

```text
VOODKA.exe --part N             start at part N (1..8), seeking the music
VOODKA.exe --modpos N           start at an absolute (order<<8)|row position
VOODKA.exe --order N            start at a module order
VOODKA.exe --ms N               start at a millisecond offset
VOODKA.exe --music <file>       use a different module file
VOODKA.exe --record <directory> record each 320x200 frame and its palette
VOODKA.exe --diag <directory>   enable GPU readback diagnostics
VOODKA.exe --audiocheck [sec]   exercise the audio path without the demo
VOODKA.exe --selftest           show the built-in presentation test pattern
```

Controls:

- **Space** pauses or resumes the demo, including its retrace-paced timeline
  and audio.
- **Esc** quits, following the original's scene-dependent input convention.
- The window is intentionally topmost; normal Alt+Tab switching remains
  available.

For a silent timing run, set `VOODKA_NOAUDIO=1` before launching. The file
`voodka.log` beside the executable records initialization, asset paths, scene
transitions, and crash diagnostics.

## Explorers and debugging tools

The port includes tools that make the reconstruction inspectable rather than
turning it into a black box:

- `asset_viewer.exe` loads every shipped 3D asset: archive V3D/V3M files,
  compile-time `CODE/DATAS` meshes, and the two VIRTUAL objects. Number keys
  select models, `[` and `]` browse, **Space** toggles wireframe, **R** toggles
  rotation, and mouse drag/wheel controls the orbit camera.
- `VIRTUAL.exe --check` loads the standalone world archive through the real
  ported object loader and exits; without `--check`, it opens the interactive
  viewer.
- `frames2img.exe` converts `frames.raw` from `--record` into PNG frames for
  phase-aligned visual comparison.
- `vodka_pack`, `world_pack`, `tabl2nasm`, `extract_v3d`, palette extractors,
  and the `*_selftest.exe` programs expose the data and format pipeline used
  during reconstruction.

The most useful debugging loop is often: run a single part with `--part N`,
record a short sequence, convert it with `frames2img`, and compare it with the
matching DOSBox capture under [`reference/captures/`](reference/captures/).
The raw indexed frame and palette are more informative than a screenshot when
the question is whether an old DAC effect, texture index, or rasterizer branch
is correct.

## Architecture

```text
port/platform/   C++17 Win32 layer: window, D3D11, WASAPI, timer, input,
                 archive loading, logging, and the EOS bridge
        |
        | MS x64 ABI, through the vk_* bridge
        v
port/core/       NASM x64 port of the demo: boot/EOS replacement, engine,
                 rasterizers, VR worlds, P1..P8, tables, and data includes
        |
        v
original source  TASM-era assembly, includes, assets, linker manifests,
                 and the release executable kept for reference
```

The assembly core remains assembly on purpose. That preserves the original's
16-bit and 32-bit truncation, signed arithmetic, x87 operations, fixed-point
formats, save/restore discipline, and deliberately unusual data layout. The
port's C++ reference implementations are primarily verification or platform
code, not a replacement rendering engine.

The major platform substitutions are:

- EOS memory, selectors, timing, input, and file services become a small
  Win32/C++ compatibility layer over one 64 MB arena.
- The original `fs`-based selector convention becomes an explicit selector
  table because user-mode x64 cannot assign arbitrary segment bases.
- VGA framebuffer copies become an R8 index texture plus a 256×1 palette
  lookup texture in D3D11.
- The original Sound Blaster/DIAMOND path becomes libxmp plus WASAPI.
- DOS retrace waits become a QPC-paced ~70 Hz tick source. The audio position
  still supplies the scene timeline, so visual timing and soundtrack remain
  coupled.

For the source-level details, see:

- [`docs/BUILDING.md`](docs/BUILDING.md) — build, run, test, and tool reference
- [`docs/PORTING_NOTES.md`](docs/PORTING_NOTES.md) — architecture and hard-won
  invariants
- [`docs/ASSET_FORMATS.md`](docs/ASSET_FORMATS.md) — reconstructed binary
  formats and color pipeline
- [`docs/WORLD_ARCHITECTURE.md`](docs/WORLD_ARCHITECTURE.md) — P2/P5 worlds,
  camera paths, sorting, morphs, and water
- [`docs/P4_P8_SCENES.md`](docs/P4_P8_SCENES.md) — detailed P4/P8 scene
  reconstruction
- [`docs/ASSETS.md`](docs/ASSETS.md) — the 76-entry archive inventory
- [`docs/KNOWN_DIFFERENCES.md`](docs/KNOWN_DIFFERENCES.md) — measured port
  differences and validation notes
- [`docs/FLASH_EFFECTS.md`](docs/FLASH_EFFECTS.md) — palette/DAC flash timing

## Known differences from the 1996 release

The port aims for behavioral and visual fidelity, but it is not pretending to
be the same hardware:

- The presentation is a windowed 1280×800 D3D11 surface rather than fullscreen
  VGA mode 13h. It uses square pixels; the original CRT/DOS display had a
  different physical pixel aspect.
- The original uses its binary-only DIAMOND player and Sound Blaster output.
  The port uses libxmp at 44.1 kHz through WASAPI. Under DOSBox/SB16 the
  original's measured playback is about five percent slower; both versions
  remain internally synchronized because scene changes are driven by
  `ModPos`.
- The original's FPU precalculation creates a visible startup pause in DOSBox;
  the port performs the same required work much faster.
- A few extreme out-of-grid water samples in the P2/P7 effects read undefined
  DOS memory in the original. The port clamps those edge reads for safety;
  P5 retains its original 16-bit sample wrap.
- The regenerated sine table uses the mathematically equivalent port table
  where the original source table is absent; the measured deviation is small
  and documented.
- Space-to-pause is a small port addition. Esc and the scene's input behavior
  otherwise follow the original PC scancode contract.

The archive, world records, mesh decoders, palettes, camera data, rasterizer
math, effects, synchronized flashes, and final presentation stages are covered
by the reconstruction tests and reference captures. Differences that are
hardware-specific or not safely defined by the original are documented rather
than hidden.

## Repository map and provenance

```text
demoscene-absence-voodka-master/   working archival source tree
reference/source/                  byte-identical read-only source mirror
reference/release/                 shipped 1996 release and original NFO
reference/captures/                DOSBox reference frames and comparisons
music/amnezja2.mod                 original soundtrack used by the port
modules/                           vendored NASM and libxmp
port/                              active native Windows x64 implementation
docs/                              reconstruction and validation notes
```

Please preserve the original source and release trees. They are part of the
historical record, and the port is most useful when its modern code can still
be compared directly with the material that inspired it.

## License and respect for the source

This repository is a preservation/reconstruction project. The original
VOODKA code, art, music, names, and release materials remain associated with
their original authors and respective rights holders. Please retain the
original credits and archive contents when redistributing or building on this
work, and do not present the modern port as the original production.

The most important result is simple: VOODKA can once again be run, inspected,
and enjoyed without needing a 386, a Sound Blaster, or a trip through a DOS
memory map. The old demo gets to keep its palette flashes, its impossible
water, its wobbly virtual worlds, and its soundtrack—and we get to see how it
was done.
