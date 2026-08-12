# Phase 0 baseline: Windows x64 assembly migration

Status: **complete for the current baseline snapshot**
Snapshot date: **2026-08-09**
Target: `port/bin/Release/VOODKA.exe`
Scope: the demo executable only

This is a historical baseline, not the final architecture. The migration
completed on 2026-08-11; see `RELEASE_COMPLETION.md` for the validated
assembly-only release boundary and evidence.

This document records the starting point for the risk-first migration in
[`ASSEMBLY_MIGRATION_PLAN.md`](ASSEMBLY_MIGRATION_PLAN.md). The asset viewer,
`VIRTUAL.exe`, packers, and validation utilities are host tools and remain
allowed to use C/C++ as explicitly requested. The assembly-only requirement
applies to the shipped `VOODKA.exe` target and its production dependencies.

## Entry conditions and repository hygiene

Phase 0 did not clean, reset, or overwrite unrelated work. At entry the
worktree already contained changes to `README.md`, the existing build and
porting notes, and the platform sources (`app.cpp`, `arena.cpp`, `audio.cpp`,
`bridge.cpp`, `d3d11_present.cpp`, `input.cpp`, `log.cpp`, `platform_abi.h`,
and `timer.cpp`), plus an untracked `.sim/` directory. The migration plan was
also already present as an untracked documentation file. Those changes are
preserved and are not attributed to Phase 0.

The only Phase 0 source change is the declarative ABI include
[`win64_abi.inc`](../port/core/inc/win64_abi.inc), included by
[`eos_dispatch.asm`](../port/core/eos_replace/eos_dispatch.asm). It names the
stack-frame constant that was already hard-coded as `0x28`; it does not alter
the generated calling sequence.

## Current production inventory

The current `VOODKA` CMake target is a NASM core plus these ten C++ platform
translation units:

| Component | Current files | Phase 0 observation |
|---|---|---|
| Application/window/lifecycle | `platform/app.cpp` | WinMain, window class, message loop, startup/shutdown, command-line modes |
| Arena/archive/memory | `platform/arena.cpp` | 64 MiB arena, `vodka.dat` loading, 32-bit arena offsets |
| Logging | `platform/log.cpp` | file logging and formatted diagnostics |
| Input | `platform/input.cpp` | Win32 keyboard/window state and quit handling |
| Timing/synchronization | `platform/timer.cpp`, `platform/progress.cpp`, `platform/pause.cpp` | QPC pacing, pause/progress state, frame/audio coordination |
| DirectX 11/DXGI/COM | `platform/d3d11_present.cpp` | device, swap chain, palette texture, upload/present, readback diagnostics |
| Audio | `platform/audio.cpp` | libxmp module decode/mix, WASAPI render path, worker thread, timeline/seek checks |
| Assembly bridge | `platform/bridge.cpp`, `platform/platform_abi.h` | exported `vk_*` ABI used by the EOS replacement dispatcher |

The original demo logic is already in `port/core/*.asm`. The current
dispatcher calls these C++ bridge exports:

`vk_arena_get`, `vk_arena_alloc`, `vk_arena_free`, `vk_selector_alloc`,
`vk_selector_free`, `vk_selector_base`, `vk_wait_vbl`, `vk_get_modpos`,
`vk_load_internal_file`, `vk_audio_play`, `vk_audio_stop`,
`vk_audio_clear`, and `vk_audio_set_pattern`.

Additional presentation, palette, framebuffer, and audio seek exports exist
in `bridge.cpp` and are called directly by the assembly core. This list is the
Phase 0 bridge inventory, not the desired final ABI: every entry remains a
future replacement boundary until its C++ implementation is removed.

## Build and test baseline

The supported reproducible command is:

```powershell
cd D:\Project\voodka2\port
.\build.ps1 -Config Release -Test
```

The snapshot was built with:

- Visual Studio 2022 BuildTools, MSVC `19.44.35228.0`;
- Windows SDK `10.0.26100.0` targeting Windows 10.0.19045;
- vendored NASM at `modules/nasm/nasm.exe`;
- x64 Release configuration using the MSVC dynamic runtime (`/MD`).

The build completed successfully and **27/27 CTest tests passed** in 8.92 s.
The suite covers the assembly/C++ cross-checks, asset packing and hashes,
palette provenance, V3D parsing, address/relocation hygiene, and the VIRTUAL
load smoke test. It does not prove full visual, audio, or multi-minute
playback fidelity; those require the runtime checks below.

The build emitted warnings in existing code, including MSVC secure-CRT
warnings, a signed/unsigned conversion warning in `frames2img`, a nonstandard
class-rvalue warning in the D3D presenter, an unused local in the timer, and a
shadowed parameter in audio. They are recorded debt, not Phase 0 fixes.

## Runtime baseline

These checks were run against the freshly built Release executable:

### Assembly/platform self-test

```powershell
.\bin\Release\VOODKA.exe --selftest
```

Result: process exit code 0. The test initializes the current arena, module,
audio, Win32 window, and D3D11 presentation path, then renders the known
pattern and shuts down.

### Device-backed audio check

```powershell
.\bin\Release\VOODKA.exe --audiocheck 3
```

Result: pass, process exit code 0.

| Measurement | Result |
|---|---:|
| Wall time | 3.01 s |
| PCM served | 3.01 s |
| Tempo ratio | 1.000 |
| Audio/video drift | +0 ms |
| Decoded module clock | 3.14 s (reported tempo 1.043) |
| ModPos advancement | 31 units, monotonic |
| Frames served | 132,741 |
| Underruns/dropouts | 0 |
| Fill errors | 0 |
| Audio pumps | 94 |
| Stream | WASAPI device |

This is a short health check, not an equivalence proof for the future
dedicated assembly player. The replacement gate must compare decoded PCM and
ModPos over the complete module and the full demo timeline.

### Deterministic self-test capture

The existing capture hooks were exercised with:

```powershell
.\bin\Release\VOODKA.exe `
  --selftest `
  --record .\bin\Release\phase0_record `
  --diag .\bin\Release\phase0_diag
```

The resulting artifacts are build-output evidence and are intentionally not
source-controlled:

| Artifact | Size | SHA-256 |
|---|---:|---|
| `phase0_record/frames.raw` | 3,886,080 B | `5EFE1E501B9643EEEFE600D8F4B10FF82C4E46329EB29A79FC68E090884F4DEE` |
| `phase0_diag/frame_src.raw` | 256,000 B | `83BF48DA54C23F15D7C04833432943BB82AC8C9B8AE77ADFE0609289E3D5DDB3` |
| `phase0_diag/frame_pal.raw` | 3,072 B | `FBAD52080DC60DDF1E177B127D6ED4EE13B9E943E0B22FC4DEA750E07A6F0D2B` |
| `phase0_diag/frame_gpu.raw` | 16,384,000 B | `CC4F6810967B97DA7FE22F6FDDB77EBB76F91C2E30B650E82AAA13E746E702BC` |

`frames.raw` contains 60 deterministic 320x200 indexed frames plus their
768-byte palettes. The GPU diagnostic contains four completed 1280x800
readbacks in this run because the readback is asynchronous; that artifact is
useful for validating the path, while the indexed recorder is the stable
frame-by-frame reference.

## Binary and dependency baseline

| Item | Size | SHA-256 / note |
|---|---:|---|
| `VOODKA.exe` | 960,512 B | `B7BCA1C0EC63FC40F2E01C36E4C793EB43C10EF33FE62DE33A99F9CBE536F58D` |
| `voodka_core.lib` | 420,860 B | NASM demo core archive |
| `libxmp-static.lib` | 1,834,134 B | current static third-party player archive |
| `music/amnezja2.mod` | 381,890 B | `09B0198ABF4DADCD864EA9A0BBE6E1DABE07A1E2F3E0C572C822CED2392474E5` |
| staged `data/vodka.dat` | 2,731,687 B | 8,000-byte offset table + 2,723,687-byte payload |

The repository contains 1,188 C/C++ source/header files under the vendored
libxmp tree; the `VOODKA` target links the selected static player archive.
This is why audio is a feasibility gate rather than a routine translation.

`dumpbin /DEPENDENTS` on the current executable reports these observed PE
imports:

```text
d3d11.dll
D3DCOMPILER_47.dll
ole32.dll
KERNEL32.dll
USER32.dll
GDI32.dll
MSVCP140.dll
VCRUNTIME140.dll
VCRUNTIME140_1.dll
api-ms-win-crt-runtime-l1-1-0.dll
api-ms-win-crt-string-l1-1-0.dll
api-ms-win-crt-convert-l1-1-0.dll
api-ms-win-crt-stdio-l1-1-0.dll
api-ms-win-crt-math-l1-1-0.dll
api-ms-win-crt-heap-l1-1-0.dll
api-ms-win-crt-environment-l1-1-0.dll
api-ms-win-crt-time-l1-1-0.dll
api-ms-win-crt-filesystem-l1-1-0.dll
api-ms-win-crt-utility-l1-1-0.dll
api-ms-win-crt-locale-l1-1-0.dll
```

This list is the observed import table, not a claim that every configured
link input is imported directly. The current CMake link inputs also include
`d3dcompiler`, `dxgi`, `winmm`, `oleaut32`, `uuid`, and `avrt`. The final
assembly-only build must explicitly measure and approve every remaining
import; in particular it must contain no libxmp or C++ runtime dependency if
“100% assembly” means no compiled C/C++ support code in the demo binary.

## Assembly ABI contract established by Phase 0

[`win64_abi.inc`](../port/core/inc/win64_abi.inc) records the rules that later
phases must preserve:

- Microsoft x64 integer/pointer arguments are `RCX`, `RDX`, `R8`, `R9`, with
  scalar/pointer returns in `RAX`.
- Every call target receives 32 bytes of caller-provided shadow space.
- `RSP % 16 == 0` is required at the `CALL` instruction. A normal function
  enters with `RSP % 16 == 8`.
- `RBX`, `RBP`, `RSI`, `RDI`, `R12`–`R15`, and `XMM6`–`XMM15` are nonvolatile.
- COM and DirectX vtable calls use the same ABI; `RCX` is the interface
  pointer and the caller still owns alignment, shadow space, and lifetime.
- `eos_dispatch` currently saves eight GPRs (64 bytes) and reserves `0x28`
  bytes before forwarding to C++. The constant is now named and build-tested
  rather than being an unexplained literal.

This contract is intentionally not a compatibility promise for arbitrary
compiler-generated C++ objects. Future assembly-owned platform interfaces
must use fixed-width fields, explicit ownership, explicit error returns, and
documented thread affinity. COM interface lifetime and vtable offsets remain
Phase 1 work.

## Phase 0 exit criteria

| Criterion | Result | Decision |
|---|---|---|
| Supported x64 Release build | Passed | GO |
| Vendored NASM selected | Passed | GO |
| Existing validation suite | 27/27 passed | GO |
| Self-test startup/shutdown | Exit 0 | GO |
| Device-backed audio health | Pass, 0 underruns, +0 ms short-run drift | GO to feasibility gates; not parity proof |
| Deterministic capture path | Recorder/readback artifacts produced | GO |
| C++/libxmp production dependencies removed | Not attempted | NO-GO for assembly-only completion |

**Phase 0 milestone: GO to Phase 1 feasibility work.** The project is
buildable, testable, and instrumented well enough to attempt the hard gates.
This is not a claim that a stable 100% assembly Windows demo is yet feasible.
Phase 1 must prove native x64 DirectX 11/COM interoperability in assembly while
retaining the current visual output and capture hashes. If that gate fails,
the migration should stop before converting low-risk utilities.

## Required evidence for subsequent gates

Every subsystem replacement must be built beside its C++ reference and pass
the existing suite plus a differential check before the old implementation is
removed. The minimum evidence set is:

1. indexed frame and palette comparison at phase-aligned ModPos values;
2. GPU readback comparison for representative scenes and the full demo;
3. decoded stereo PCM comparison, module order/row trace, and drift report;
4. repeated startup, close, focus-loss, resize, and device-error smoke tests;
5. PE import, map-file, and executable-size reports;
6. clean Release rebuild using the vendored NASM compiler.

The acceptance claim remains deliberately narrow: only after the final C++
production target is gone, the libxmp dependency is gone, the imports are
audited, and the full-playback evidence passes may the build be called a
stable, maintainable, 100% x64 assembly Windows demo.
