# Building & running the VOODKA Windows port

## Prerequisites

| Requirement | Notes |
|---|---|
| Windows 10/11 x64 | the only supported target |
| Visual Studio 2022 (Build Tools suffice) | 2026 also accepted; `build.ps1` prefers 2022 |
| CMake >= 3.24 | on PATH |
| PowerShell 7+ | for `build.ps1` |
| NASM + libxmp | **vendored** in `modules/` - nothing to install |

No package manager, no DOS toolchain, no external SDK.

## Build

```powershell
cd port
.\build.ps1 -Config Release          # configure + build
.\build.ps1 -Config Release -Test    # build + run the CTest suite (30 tests)
.\build.ps1 -Clean                   # wipe port/build first
```

The script locates VS via `vswhere`, imports the x64 dev environment, then
configures (`Visual Studio 17 2022`, x64) with the vendored NASM and builds
in parallel. Repo paths are derived from the script location, so the
checkout is relocatable.

> **Gotcha:** if you ever run `cmake -B` by hand, pass
> `-DCMAKE_ASM_NASM_COMPILER=<repo>/modules/nasm/nasm.exe`. A system NASM
> 3.x silently miscompiles `[rel X]` high-VA references (see
> docs/PORTING_NOTES.md).

## Outputs (`port/bin/<Config>/`)

```
VOODKA.exe          the demo (statically linked libxmp; no DLLs needed)
VIRTUAL.exe         the standalone VR-engine test viewer (Esc quits; --check loads+exits)
asset_viewer.exe   the V3D/V3M asset viewer (loads all 9 3D models from data/vodka.dat)
asset_viewer_selftest.exe  parse-only validation (CTest v3d.viewer_parse)
data/vodka.dat      packed assets, byte-identical to the 1996 release archive
data/world          VIRTUAL viewer object archive (byte-identical to the original)
music/amnezja2.mod  the 14-channel module the demo plays
*_selftest.exe      cross-check test binaries + tools
audio_oracle.exe    libxmp module/timing/PCM oracle for Phase 2 validation
```

`bin/<Config>` is self-contained: `VOODKA.exe` finds `data\vodka.dat` and
`music\amnezja2.mod` next to itself (dev-tree fallbacks exist for running
from elsewhere). To distribute, zip those three files (add `VIRTUAL.exe` +
`data\world` for the viewer).

## Running

```
VOODKA.exe                     full demo, all 8 parts (~70 fps, 1280x800 window)
VOODKA.exe --part N            start at part N (1..8), music seeked to match
VOODKA.exe --modpos N          start at ModPos N  ((order<<8)|row)
VOODKA.exe --order N           start at order N
VOODKA.exe --ms N              start N milliseconds into the module
VOODKA.exe --music <file>      override the module path
VOODKA.exe --record <dir>      dump every frame (320x200 index + palette)
VOODKA.exe --diag <dir>        GPU readback diagnostics
VOODKA.exe --audiocheck [sec]  audio subsystem self-check (default 20 s)
VOODKA.exe --selftest          render the built-in test pattern
Space                          pause/resume (freezes retrace + audio)
Esc                            quit immediately from any scene/loading state
```

`frames2img.exe` converts a `--record` `frames.raw` into PNG stills.

## Tests

```powershell
ctest --test-dir port\build\Release -C Release --output-on-failure
```

30 tests: 17 NASM-vs-C++ cross-checks (engine, txtr rasterizer, VR pipeline,
P2 data, toonel, palette), `vodka.golden_hash` (repacked archive SHA-256 ==
release EXE's embedded archive), `v3d.crosscheck` (real .V3D/.V3M decode via
the ported loader), `tablica3.crosscheck` (generated NASM tables vs original
TASM text), `pal.integrity` + `pal.repro` (palette copies + OBJ-extraction
reproducibility), `build.addr32` (COFF relocation hygiene),
`virtual.world_golden` + `virtual.load` (the viewer's archive is
byte-identical to the original and decodes), and `v3d.viewer_parse` (the
asset viewer's parser vs all 27 original 3D assets: 9 archive V3D/V3M
headers, all 16 CODE/DATAS mesh pair counts, 2 VIRTUAL world objects).
`audio.oracle` inventories `amnezja2.mod` and records the current libxmp
44.1 kHz stereo PCM and row-transition baseline for the dedicated assembly
player.
Python-based tests skip cleanly if no interpreter is found.

## Tools (`port/tools/`)

| Tool | Purpose |
|---|---|
| `vodka_pack` | C++ port of LINKER.PAS; packs `data/vodka.dat` from VODKA.TXT + DANE |
| `world_pack` | C++ port of WORLD.PAS; packs `data/world` from VIRTUAL/OBJECTS |
| `sin_tables` | generates `core/inc/sin_tables.asm` (`vkSin`, `sinus`) |
| `tabl2nasm` | converts TASM TABLICA3 water tables to NASM includes |
| `frames2img` | `frames.raw` -> PNG (dependency-free encoder) |
| `extract_pals.py` | recovers compile-time palettes from the original OMF OBJs |
| `audit_addr32.py` | COFF relocation hygiene audit (wired as `build.addr32`) |
| `extract_v3d` | pulls the 9 V3D/V3M assets (entries 12-15, 31-35) out of `data/vodka.dat` |
| `asset_viewer` | D3D11 viewer: flat-shaded/wireframe orbit view of every 3D asset in the original (9 archive V3D/V3M + 16 CODE/DATAS meshes + 2 VIRTUAL world objects) |
| `asset_viewer_selftest` | parse-only validation of all 27 assets (CTest `v3d.viewer_parse`) |
| `audio_oracle` | Phase 2A host-side libxmp module inventory, PCM hash, and row/tick trace oracle (CTest `audio.oracle`) |

## Troubleshooting

- **`voodka.log`** (next to the exe) is the first place to look: subsystem
  init, archive/module paths, scene changes, crash register dumps.
- Window is intentionally topmost; Alt+Tab works normally.
- `VOODKA_NOAUDIO=1` forces the headless (silent) timeline.
