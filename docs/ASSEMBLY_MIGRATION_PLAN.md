# VOODKA Assembly-Only Windows Migration Plan

## Objective and boundary

The target is:

- `VOODKA.exe`: NASM x64 production code only.
- No C or C++ object files linked into the demo.
- No `libxmp` dependency in the production executable.
- A dedicated NASM tracker player for `music/amnezja2.mod`.
- Existing C++ asset viewers, packers, validators, and `VIRTUAL.exe` may remain unchanged.
- Windows, D3D11, WASAPI, and GPU-driver code remain external system dependencies.

The current production boundary is defined by `port/platform/CMakeLists.txt`.
The shipped target has already removed `xmp_static` and the C++/libxmp player;
its D3D11/COM calls are now owned by the NASM presenter behind a narrow C++
dispatch. The migration must preserve the existing NASM core and replace the
remaining platform boundary incrementally.

The shortest credible answer to whether this is viable is not to port the easy
code first. The first feasibility gates are:

1. Assembly can reliably drive D3D11 and COM.
2. A dedicated assembly player can reproduce the soundtrack timeline and acceptable audio output.
3. A pure assembly Windows process can create, run, thread, diagnose, and shut down reliably.

If any of these gates fails, stop before converting the straightforward utility
code.

## Incremental build strategy

Every replacement should temporarily have three layers:

```text
current C++ implementation
        |
        v
C++ adapter with the same external behavior
        |
        v
candidate NASM implementation
```

Use distinct symbols during migration to avoid collisions:

```text
cpp_present_init
asm_present_init
vk_present_init        ; stable production-facing name later
```

The application must remain buildable and runnable after every phase. The C++
implementation is removed only after the NASM replacement passes the same
tests and runtime checks.

The C++ tools and tests remain outside the production target. They are useful
as behavioral oracles and must not be confused with code linked into
`VOODKA.exe`.

---

## Phase 0 — Baseline, contracts, and failure instrumentation

### Scope

Establish the evidence and ABI contracts needed to compare every assembly
replacement against the current implementation.

Affected components:

- `port/platform/app.cpp`
- `port/platform/audio.cpp`
- `port/platform/d3d11_present.cpp`
- `port/platform/bridge.cpp`
- the current NASM core
- `modules/libxmp`

### Required assembly contract

Create a shared NASM ABI include defining:

- MS x64 register and stack macros.
- 32-byte shadow-space handling.
- 16-byte call-site alignment.
- Nonvolatile-register save/restore macros.
- COM virtual-call helpers.
- HRESULT checks.
- Windows handle conventions.
- 32-bit arena-offset conventions.
- Pointer-sized Windows structure fields.

Document every production-facing entry point, including:

```text
asm_present_init
asm_present_frame
asm_present_shutdown

asm_audio_init
asm_audio_shutdown
asm_audio_play
asm_audio_stop
asm_audio_get_modpos
asm_audio_seek_modpos
asm_audio_seek_ms
asm_audio_seek_order
asm_audio_snapshot
```

### Baseline validation

Record the current behavior before changing the production target:

- Full eight-part run and exit code.
- 320x200 indexed framebuffer and palette recordings.
- GPU readback captures.
- ModPos trace at every frame.
- Current libxmp PCM output.
- Audio self-check results.
- Pause/resume behavior.
- canonical `--scene` plus historical `--part`, `--modpos`, `--ms`, and `--order` behavior.
- Window-close behavior in every part.
- Headless/no-audio behavior.
- Release executable size and link map.

### Go/no-go milestone G0

Proceed only when:

- The current C++ build is reproducible.
- A complete reference run is available.
- Frame, palette, PCM, and ModPos comparison tools exist.
- The C++ implementation can be restored immediately if a candidate fails.

---

## Phase 1 — D3D11 and COM assembly feasibility gate

This is the first production-feasibility gate.

### Scope

Replace the presenter core with NASM while initially keeping C++ responsible
for window creation and high-level diagnostics:

- D3D11 device and swapchain creation.
- Render-target acquisition.
- Indexed framebuffer texture.
- Palette texture.
- Shader resource views.
- Vertex buffer and input layout.
- Vertex and pixel shaders.
- Sampler and rasterizer state.
- Per-frame texture uploads.
- Fullscreen draw and `Present`.
- Resource release.

Affected component:

- `port/platform/d3d11_present.cpp`

### Assembly interfaces

```text
asm_present_init(hwnd, width, height) -> success
asm_present_set_palette(rgb_6bit_ptr)
asm_present_draw(arena_base, framebuffer_offset) -> status
asm_present_readback(rgba8_out, capacity) -> status
asm_present_present() -> HRESULT
asm_present_shutdown()
```

Resource pointers should be held in NASM globals:

```text
g_d3d_device
g_d3d_context
g_swapchain
g_index_texture
g_palette_texture
g_index_srv
g_palette_srv
g_vertex_buffer
g_input_layout
g_vertex_shader
g_pixel_shader
g_sampler
g_rasterizer
g_rtv
```

### Design decisions

Precompile the two shaders with a host-side tool and embed the bytecode as
binary data. This removes runtime `D3DCompile` from the first assembly
implementation while retaining identical shader behavior.

COM calls must be made explicitly through interface vtables. Every call must:

- Put the interface pointer in `rcx`.
- Put the first three arguments in `rdx`, `r8`, and `r9`.
- Place additional arguments above the shadow space.
- Maintain `rsp % 16 == 0` at the call instruction.
- Check the HRESULT.
- Release every acquired interface on failure and shutdown.

### Major risks

- Incorrect COM vtable offsets.
- Incorrect D3D11 structure layout.
- Stack misalignment.
- Incorrect `D3D11_MAPPED_SUBRESOURCE.RowPitch` handling.
- Incorrect sampler or rasterizer state.
- Resource leaks during partial initialization failure.
- GPU readback synchronization errors.
- Accidental bilinear filtering or incorrect palette conversion.

### Dependencies

- Current C++ presenter.
- Existing self-test pattern.
- Existing `--record` and GPU diagnostic paths.
- Host-side shader compilation.
- Windows SDK import libraries.

The candidate is selectable with `VOODKA.exe --asm-present`; the C++ path is
still the default oracle and fallback. The C++ adapter may own HWND creation,
message pumping, diagnostic files, and selection policy, but in assembly mode
all D3D11 resource creation, vtable calls, uploads, draws, readback, Present,
and Release calls belong to NASM.

### Validation

1. Present the known 8-color quadrant pattern through the standalone NASM
   presenter and compare GPU readback against expected RGBA pixels.
2. Compare indexed framebuffer, palette, and GPU diagnostic captures against
   the C++ reference byte-for-byte.
3. Run the first four diagnostic frames from oko + szklo (P1), swiatynia city (P2), processorek Nevosolek (P4), gratki + woda (P7), and nad czerwonym lampa (P8) through
   both presenter implementations.
4. Confirm exact 4x nearest-neighbour scaling and row-pitch handling.
5. Exercise repeated initialization, partial-failure cleanup, and shutdown
   paths through the standalone probe.
6. Run the complete demo with `--asm-present`, current C++ window/input/timing,
   and current audio, ending with normal shutdown.

### Go/no-go milestone G1

Go only if:

- The assembly presenter passes the self-test and GPU readback.
- No resource leaks or device-removal faults occur.
- Real scene frames match the C++ presenter.
- The assembly presenter remains stable for a complete demo run.

No-go if D3D11 cannot be made reliable with explicit assembly COM calls. Do not
spend time converting input, logging, or allocators before this gate passes.

Current result (2026-08-09): **GO**. The standalone and integrated assembly
presenter gates passed, including byte-identical oko + szklo/swiatynia city/processorek Nevosolek/gratki + woda/nad czerwonym lampa captures and a
17,611-frame full eight-scene run. Phase 1C has since moved the C++ presenter into
the non-shipped `VOODKA_REFERENCE.exe` oracle; the shipped `VOODKA.exe` now
uses the NASM presenter by default and retains only a C++ recording/diagnostic
dispatch around it.

---

## Phase 2 — Dedicated assembly tracker player and WASAPI gate

This is the largest and most uncertain phase.

### Scope

Remove libxmp from the runtime path and implement:

- `amnezja2.mod` parsing.
- 14-channel tracker state.
- Order, pattern, row, and tick execution.
- Sample playback and loops.
- Volume and panning.
- Every effect actually used by this module.
- Tracker tempo and tick timing.
- PCM mixing.
- ModPos tracking.
- Seeking.
- Pause/resume.
- WASAPI output.
- Audio-thread lifecycle.
- Underrun detection.
- Headless fallback.

Affected components:

- `port/platform/audio.cpp`
- Audio wrappers in `port/platform/bridge.cpp`
- Audio declarations in `port/platform/platform_abi.h`
- The `xmp_static` production dependency.

### Preliminary host-side module analysis

Use a host-side analyzer before implementing the player. The analyzer may
remain C++ and may temporarily use libxmp, but it must produce an exact
module-specific inventory:

- Module format variant.
- Order table.
- Pattern count and lengths.
- Instrument and sample layout.
- Sample loop points.
- Volume ranges.
- Channel usage.
- Effect command frequencies.
- Effect parameter ranges.
- Tempo/BPM changes.
- Pattern jumps, breaks, and delays.
- Loop behavior.
- Actual row/tick timing.
- Output sample-rate assumptions.

The goal is a player for this soundtrack, not a generic replacement for every
format supported by libxmp.

### Assembly interfaces

```text
asm_audio_init(mod_path, sample_rate) -> success
asm_audio_shutdown()
asm_audio_play()
asm_audio_stop()
asm_audio_get_modpos() -> uint32
asm_audio_get_elapsed_us() -> uint64
asm_audio_seek_modpos(modpos) -> uint32
asm_audio_seek_ms(ms) -> uint32
asm_audio_seek_order(order) -> uint32
asm_audio_snapshot(snapshot_ptr)
asm_audio_selfcheck(seconds) -> result
```

The audio thread owns live tracker state. The main thread reads a published
snapshot:

```text
audio thread:
    advance tracker
    mix PCM
    publish order, row, loop base, and frame count

demo thread:
    read snapshot
    use ModPos for scene logic
```

This avoids querying mutable player state concurrently from multiple threads.

### WASAPI assembly layer

Implement:

- `CoInitializeEx`.
- `CoCreateInstance`.
- Default render endpoint selection.
- `IAudioClient` activation.
- `IAudioClient::Initialize`.
- Event handle creation.
- `IAudioClient::SetEventHandle`.
- `IAudioRenderClient::GetBuffer`.
- `IAudioRenderClient::ReleaseBuffer`.
- `WaitForMultipleObjects`.
- `CreateThread`.
- Thread priority.
- Stop event handling.
- COM and resource release.

Initially support the current 44.1 kHz stereo 16-bit path. Add the float-output
fallback only after the integer path is stable.

### Major risks

- Unknown tracker effects or nonstandard FastTracker behavior.
- Incorrect tick and row timing.
- Mixer rounding or interpolation differences.
- Sample loop edge behavior.
- Channel panning or volume differences.
- Races between the audio thread and ModPos readers.
- Seek landing on the wrong row.
- Deadlocks during shutdown.
- WASAPI underruns.
- Pause/resume drift.
- Audio quality regression despite correct scene timing.

The original DIAMOND player is binary-only and tied to EOS/Sound Blaster
behavior. It is not a reusable x64 implementation target.

### Dependencies

- Module analyzer.
- Current libxmp output as a development oracle.
- Current audio self-check.
- WASAPI probe and COM ABI work.
- Existing ModPos and scene-boundary expectations.

libxmp may remain temporarily in a reference-only validation configuration. It
must not be linked into the candidate `VOODKA.exe`.

### Validation

#### Player-level

- Decode the complete module without crashing.
- Compare order, row, and tick transitions against the oracle.
- Compare rendered PCM over the complete soundtrack.
- Compare representative channels and effect-heavy sections.
- Verify sample loop boundaries.
- Verify module looping.

#### Platform-level

- Run for at least 20 minutes with zero underruns.
- Pause and resume repeatedly.
- Seek to every part boundary.
- Seek into effect-heavy rows.
- Close the window during playback.
- Test unavailable or rejected audio devices.
- Test headless mode.
- Confirm no audio thread or COM object survives shutdown.

#### Demo-level

- Complete eight-part run.
- ModPos trace comparison.
- Frame-record comparison at all scene boundaries.
- Confirm no visual drift caused by audio-clock changes.

### Go/no-go milestone G2

Go only if:

- The player supports every feature used by the module.
- ModPos and scene transitions match the baseline.
- Audio is equivalent in quality and timing.
- No underruns, deadlocks, or shutdown leaks occur.
- Full-demo playback completes successfully.

No-go if the dedicated player cannot reproduce the soundtrack acceptably. A
stable 100% assembly demo has not been demonstrated without this gate.

Current Phase 2 result (2026-08-10): **GO through the native effect-state,
offline PCM mixer, stateful bounded mixer, persistent live tracker, concurrent
bounded PCM/timeline ring, WASAPI/COM device, assembly-worker, and bounded PCM
handoff and live ring-to-WASAPI gates; NO-GO to
the live production swap or libxmp removal.** The
host oracle passes and records a
263.429-second, 11,617,219-frame 44.1 kHz stereo PCM baseline, 2,688 row
transitions, and the module-specific effect inventory. `audio.mod_parse` passes
the complete module inventory, `audio.mod_trace` passes all 2,688 NASM row
transitions/13,440 replay frames, and `audio.mod_events` plus `audio.mod_voices`
pass all 34,944 events and 37,632 row/channel identity states. `audio.mod_ticks`
passes all 188,160 per-channel snapshots, including period, pitch bend, note,
instrument, sample, volume, pan, event, and logical sample-position behavior.
`audio.mod_pcm` passes all 11,613,525 direct-tick output frames with zero
sample mismatches and PCM FNV-1a `18C7451650A7C772`. The mixer covers the
checked-in signed-8-bit mono soundtrack path, including loop-boundary
interpolation, ramps, anti-click, one-shots, and E9 retriggers. Keep libxmp
as the oracle. The assembly-owned WASAPI probe now passes exact 44.1 kHz
stereo PCM negotiation, event delivery, render-buffer acquisition/release,
stop/reset, and 20 repeated teardown runs. The Phase 2H worker harness now
passes 10 repeated one-second lifecycles with real callback wakeups, 23,296 to
25,856 serviced frames per run, zero timeouts, and clean Stop/Reset/join results.
Phase 2I now passes 10 repeated bounded handoffs of the exact native PCM
stream: 45,864 to 46,305 device frames, 99 to 100 wakeups/snapshots, zero
timeouts, zero source wraps, and clean worker exit. That handoff is immutable
pre-rendered PCM, not yet the live production player. Phase 2J proves that the
same complete stream remains sample-identical through 78 irregular bounded
mixer calls with caller-owned anti-click/ramp history, retaining PCM FNV
`18C7451650A7C772`. The tracker is still an offline whole-stream state
generator, so this is a continuity GO but not a live-player or libxmp-removal
GO.
Phase 2K now runs the tracker incrementally for all 13,440 ticks: every state
byte matches the offline oracle, the completion sentinel is correct, and the
live states retain PCM FNV `18C7451650A7C772` through 78 continuous mixer
chunks. Phase 2L now passes the concurrent bounded ring gate: the live producer
and consumer transfer all 11,613,525 exact PCM frames and all 13,440 ModPos
markers through a wrapping SPSC queue, with zero marker mismatches, zero
producer or consumer failures, zero underrun/marker-overflow events, and 10/10
repeated runs. Phase 2M now passes the live ring-to-WASAPI gate: the assembly
worker consumes 45,864-46,305 exact PCM-prefix frames under 99-100 real device
wakeups, publishes 53 ModPos snapshots, matches an independent assembly PCM
witness, and records zero consumer underruns, marker overflows, timeouts, or
producer failures across 10 repeats. Production remains C++/libxmp until the
pause/resume command gate, seek/reposition equivalence, full-demo A/V
comparison, long-run starvation test, and shutdown stress gate are complete.
Phase 2N now passes ordered pause/resume control: the assembly worker
acknowledges both commands, holds the ring read position stable for the pause,
resumes without losing source frames, and retains the exact consumed PCM
prefix across 10 repeats. Phase 2O now passes the coordinated seek/reposition
gate across 10 direct repeats: the worker pauses at a render boundary, the
producer acknowledges quiescence, PCM and marker cursors are flushed, a fresh
assembly tracker and mixer history resume at tick 1,024, and the resulting
pre-seek prefix plus post-seek suffix has the expected PCM FNV and ModPos
timeline with zero underruns or marker overflows. Production and libxmp usage
remain unchanged pending scene-driven full-demo A/V comparison, long-run
starvation, repeated-seek stress, and shutdown stress. Phase 2P now passes
10/10 repeated-seek stress runs on a single live pipeline: ticks 1,024, 4,096,
and 8,192 are reached in order, every PCM segment and ModPos checkpoint is
exact, six control transitions complete per run, and zero underruns, marker
overflows, worker timeouts, or producer failures occur. Production and libxmp
usage remain unchanged pending full-demo A/V comparison, extended starvation,
production shutdown stress, and final application integration.

---

## Phase 3 — Pure Windows x64 runtime and thread substrate

### Scope

Implement assembly probes for:

- Custom process entry point.
- Command-line acquisition.
- `GetModuleHandle`.
- Window class registration.
- Window creation.
- `WndProc`.
- Message pumping.
- `CreateThread`.
- Events.
- `WaitForMultipleObjects`.
- `Interlocked*` operations.
- Critical sections or SRW locks.
- `SetUnhandledExceptionFilter`.
- `ExitProcess`.
- x64 unwind metadata.

Affected components:

- `port/platform/app.cpp`
- `port/platform/input.cpp`
- `port/platform/timer.cpp`
- `port/platform/pause.cpp`
- Parts of `port/platform/log.cpp`
- Audio thread support in `audio.cpp`

### Assembly interfaces

```text
asm_process_start()
asm_window_create()
asm_window_proc(hwnd, message, wparam, lparam)
asm_message_pump()
asm_thread_start()
asm_thread_stop()
asm_exception_filter(exception_pointers)
asm_process_exit(code)
```

### Major risks

- Incorrect `WPARAM`/`LPARAM` pointer handling.
- Window callback stack corruption.
- Missing x64 unwind metadata.
- Invalid crash-handler register offsets.
- Incorrect event or thread ownership.
- Deadlock during window-close cleanup.
- Incorrect memory ordering around pause and audio state.
- CRT dependencies accidentally pulled in by formatting or string routines.

### Validation

- Assembly-only window probe starts and closes repeatedly.
- Keyboard messages arrive with correct scancodes.
- A worker thread starts, signals, waits, and shuts down.
- Window close during active D3D and audio execution terminates cleanly.
- Deliberate test exceptions reach the crash filter with correct RIP/RSP/register data.
- The probe does not require CRT startup objects.

### Go/no-go milestone G3

Go only if:

- A pure assembly Win32 process can create and destroy a window reliably.
- Thread and event shutdown is deterministic.
- Crash reporting and stack unwinding are usable.
- The process can exit from inside the assembly demo loop without leaving threads or COM objects.

---

### Current execution checkpoint — Phase 3B.6.7C

The risk-first platform migration is active. The shipped target now has native
x64 assembly implementations for the D3D11/COM presenter, the dedicated MOD
player and WASAPI path, the Win32 substrate, logging/timeline/arena/startup
services, the 70 Hz QPC timer, and the bridge ABI groups (selectors,
palette, presentation, fixed overlay pointers, arena forwarders, wait-vbl,
ModPos, dedicated-audio forwarding, archive loading, and key-map copying). The
reference target and host tools remain C++ where they provide the differential
oracle. The current bridge gate is 83/83 Release tests green, including live
WASAPI, P1 playback, pause, close, file/input forwarding, and the direct
decorated input ABI probe, as well as the new
shutdown/logging bridge probes. The P4 rasterizer is already assembly-owned
and remains covered by its framebuffer-equivalence probe. The shipped arena
namespace veneer has also been removed; `bridge_arena.asm` now exposes the
decorated `vk::` ABI over the native archive service while reference/tools keep
the C++ oracle.

The shipped input namespace veneer has now also been removed; the next gate is
pause/progress and the remaining application/startup namespace surface. This
keeps the executable buildable after each slice and postpones removal of the
C++ bridge, CRT startup, and remaining CRT imports until the high-risk platform
behavior and lifecycle contracts are proven equivalent.

---

## Phase 4 — Replace the C ABI bridge and EOS platform boundary

### Scope

Replace `bridge.cpp` with assembly implementations of the symbols already
consumed by the NASM core.

Affected components:

- `port/platform/bridge.cpp`
- `port/platform/platform_abi.h`
- `port/platform/demo_entry.h`
- `port/core/eos_replace/eos_dispatch.asm`
- Temporary C++ presenter and audio adapters

Implement:

- Arena access.
- Arena allocation and freeing.
- Selector allocation and lookup.
- `wait_vbl`.
- ModPos access.
- File loading.
- Palette set/get/range operations.
- Framebuffer access.
- Audio calls.
- Entry-part selection.
- Key-map copy.
- Logging bridge.
- processorek Nevosolek (P4) triangle rasterizer.

### Assembly interfaces

Preserve the existing NASM-facing names where possible:

```text
vk_arena_get
vk_arena_alloc
vk_arena_free
vk_selector_alloc
vk_selector_free
vk_selector_base
vk_wait_vbl
vk_get_modpos
vk_load_internal_file
vk_set_palette
vk_get_palette
vk_set_palette_range
vk_present_frame
vk_audio_play
vk_audio_stop
vk_audio_seek_rows
vk_audio_seek_ms
vk_audio_seek_order
vk_key_map_copy
vk_log_printf
vk_processorek_nevosolek_draw_triangle
```

### processorek Nevosolek (P4) rasterizer

Port the current `vk_processorek_nevosolek_draw_triangle` independently and compare it against
the C++ implementation using randomized triangles, edge cases, UV wrapping,
clipping, and degenerate geometry.

The main risks are:

- `ceil` and `floor` behavior.
- Signed coordinate conversion.
- Double-to-integer conversion.
- Texture-index wrapping.
- Left/right edge selection.
- Exact fill coverage.

### Go/no-go milestone G4

Go only if:

- Every NASM-core call resolves to assembly or an approved external Windows import.
- EOS service behavior remains unchanged.
- processorek Nevosolek (P4) output matches the C++ reference.
- Existing NASM-vs-C++ bridge tests pass.
- The complete demo runs using the assembly bridge.

---

## Phase 5 — Assembly memory, asset loading, and data ownership

### Scope

Replace:

- `port/platform/arena.cpp`
- Archive-loading portions of `app.cpp`.
- C++ `std::vector` archive storage.
- Path and file staging logic.

Implement in assembly:

- 64 MB `VirtualAlloc` arena.
- 16-byte bump allocation.
- Fixed framebuffer/backbuffer offsets.
- Archive-file search.
- `CreateFileW`.
- `GetFileSizeEx`.
- `ReadFile`.
- `CloseHandle`.
- Archive copy into the arena.
- `voodka.dat` name resolution.
- Bounds and overflow checks.

The inner archive indexing is already handled by the NASM core and should not
be redesigned.

### Major risks

- 64-bit file-size truncation.
- UTF-16 path handling.
- Malformed archive lengths.
- Arena exhaustion.
- Accidental changes to allocation offsets.
- Changed zero-initialization behavior.

### Validation

- Arena allocation offsets match the C++ implementation.
- All 76 archive entries decode identically.
- Staged output runs without the development tree.
- Missing and malformed files fail cleanly.
- Full-demo arena addresses and asset contents remain compatible.

### Go/no-go milestone G5

Go only if all assets load from the self-contained runtime directory and the
complete demo remains frame-equivalent.

---

## Phase 6 — Assembly utility services

Only after the difficult runtime gates pass, convert the low-risk services.

### Scope

Replace:

- `port/platform/input.cpp`
- `port/platform/timer.cpp`
- `port/platform/log.cpp`
- `port/platform/progress.cpp`
- `port/platform/pause.cpp`
- Simple portions of `port/platform/app.cpp`

Implement:

- 128-entry scancode table.
- Message-to-scancode mapping.
- QPC timing.
- Sleep and spin pacing.
- Scene-table lookup.
- Elapsed-time formatting.
- File logging.
- Fixed-size formatting routines.
- Pause state and interlocked toggle count.

### Major risks

- Timing drift.
- Incorrect `wait_vbl` delta semantics.
- Log formatter buffer overruns.
- Changed pause behavior.
- Key auto-repeat differences.
- Incorrect scene-title transitions.

### Validation

- Compare frame pacing over complete runs.
- Compare ModPos/frame timing.
- Test key repeat and window activation.
- Pause and resume in every part.
- Log from both main and audio threads.
- Run without a debugger attached.

### Go/no-go milestone G6

Go only if timing, pause, input, and diagnostics remain behaviorally identical
and no CRT functions are required.

---

## Phase 7 — Remove the C++ production application

### Scope

Replace the remaining application shell:

- `app.cpp`
- Remaining presenter adapters.
- Remaining audio adapters.
- Remaining bridge code.

The production target should contain only:

```text
NASM core
NASM Windows/platform layer
NASM dedicated audio player
embedded/generated binary data
Windows import libraries
precompiled shader bytecode
```

The repository may still build:

```text
asset_viewer
VIRTUAL
vodka_pack
world_pack
sin_tables
validators
```

### Build changes

- Remove C++ sources from the `VOODKA` target.
- Remove `xmp_static` from the `VOODKA` link.
- Remove libxmp from the default production dependency graph.
- Keep libxmp only in a temporary reference configuration until G2 passes.
- Use a custom assembly entry point.
- Explicitly control `/SUBSYSTEM`, `/ENTRY`, and default-library behavior.
- Audit for accidental CRT imports.
- Generate a linker map for every Release build.

### Final structural checks

- No `.cpp` or `.c` object appears in the `VOODKA` link map.
- No `xmp_*` symbols.
- No C++ mangled symbols.
- No unexpected CRT, exception, or C++ runtime imports.
- No unresolved assembly ABI stubs.
- All production data paths are intentional.

### Go/no-go milestone G7

Go only if the assembly-only production target builds, starts, plays, renders,
seeks, pauses, and shuts down without any C or C++ implementation object.

---

## Phase 8 — Final fidelity and maintainability qualification

### Functional validation

- Full eight-part playback.
- Normal audio.
- Headless audio mode.
- Every supported seek mode.
- Pause and resume.
- Window close during each scene.
- Multiple monitor and DPI configurations.
- Repeated launch and shutdown.
- Audio-device failure.
- D3D initialization failure.
- Missing or corrupt archive.
- Long-duration run.

### Fidelity validation

- Phase-aligned framebuffer comparison.
- Palette byte comparison.
- GPU readback comparison.
- processorek Nevosolek (P4) rasterizer randomized comparison.
- ModPos trace comparison.
- Full PCM comparison where possible.
- Perceptual and spectral audio comparison where exact PCM differs.
- Scene-boundary timing comparison.
- No additional dropped frames or audio underruns.

### Maintainability requirements

Assembly-only is maintainable only if the project retains:

- One documented ABI include.
- Generated Windows and D3D constants.
- Explicit ownership tables.
- Resource-release paths.
- Unwind metadata.
- C++ reference tests.
- Host-side asset and module analysis tools.
- Link-map and import audits.
- Frame and audio regression artifacts.

The helper tools and validators should remain. They are not part of the
production executable and are important evidence that future assembly changes
preserve behavior.

### Go/no-go milestone G8

The project qualifies as a stable assembly Windows demo only if:

- `VOODKA.exe` contains no C or C++ production objects.
- libxmp is absent from the production build.
- D3D11 and WASAPI paths are stable.
- The dedicated tracker player passes audio and ModPos validation.
- Full playback remains visually and temporally equivalent.
- Shutdown and crash behavior are reliable.
- The assembly code has documented ABI, ownership, and validation contracts.

## Feasibility checkpoint and schedule

The shortest credible route to answering the central question is:

1. Phase 0: baseline and contracts.
2. Phase 1: D3D11/COM assembly vertical slice.
3. Phase 2: dedicated assembly audio vertical slice.
4. Phase 3: pure Win32/thread/SEH probe.

Those gates may require several months. If they pass, the remaining migration
is difficult but credible. A complete migration of `VOODKA.exe` is roughly an
8–14 person-month effort for one experienced developer, with the dedicated
audio player representing approximately one-third to one-half of the work.

If G1, G2, or G3 fails, retain the hybrid assembly-core/C++-platform build.
There is little value in converting allocators, logging, or input if the
production executable cannot reliably present frames, play the soundtrack, and
operate as a native assembly Windows process.

## Current implementation checkpoint: Phase 3B.6.7C.1 (after Phase 1C and 2X)

The live assembly tracker, mixer, SPSC PCM/timeline ring, assembly-owned
WASAPI worker entry, native assembly producer, fixed assembly-owned storage and
timeline preparation, native Win32 module loading, pause/resume protocol,
coordinated seek, repeated-seek stress, production-clock witnesses, and
deterministic lifecycle/device-failure hooks are now implemented as reversible
gates. The shipped target also uses the NASM D3D11/COM presenter by default;
the complete C++ presenter is retained only in `VOODKA_REFERENCE.exe`.
Phase 3A has proven a standalone no-CRT assembly process with Win32 window,
WndProc, message-pump, worker-thread, event, atomic, exception-filter, and
deterministic teardown ownership. Phase 3B.1 now uses a NASM x64 WndProc in the
shipped target while retaining the C++ callback in `VOODKA_REFERENCE.exe` as
the differential oracle. The callback preserves keyboard, pause, activation,
paint, close, destroy, and default-message behavior.
Phase 3B.2 now moves production `WNDCLASSW` construction, monitor-aware
geometry, `CreateWindowExW`, show/focus/topmost handoff, and window/class
teardown into NASM. `VOODKA_REFERENCE.exe` retains the C++ bootstrap as the
differential oracle.
Phase 3B.3 now transfers the production CRT `WinMain` shim into a NASM host
handoff that obtains the module handle and raw command line, applies DPI policy,
and calls the existing C++ host ABI. The reference target keeps direct C++
entry. This is intentionally not a custom `/ENTRY` yet because the host still
depends on CRT/STL initialization.
Phase 3B.4 stores the raw command-line pointer in assembly, registers the
production assembly exception-filter entry, and moves the production Escape
watcher event/thread lifecycle into NASM. Phase 3B.5 extends that ownership to
command-line interpretation and the remaining input bridge: NASM now stores and
parses the production flags, scalar/path selectors, seek controls, and
recording/diagnostic switches, and owns the 128-byte key map plus the main
thread message pump. The parser preserves the former C++ token behavior so
this is an implementation migration rather than a command-line redesign.
The shipped logger/progress/bridge formatting paths, including live fixed-point
floating diagnostics, are now NASM-owned. Phase 3B.6.6 also moved production
timeline record formatting and its Win32 file sink into NASM. Phase 3B.6.7A
now moves the production 64 MiB arena, archive discovery/read, bump allocator,
and `Load_internal_file` copy boundary into NASM. Phase 3B.6 moved the
production pause/close
automation worker,
its event/thread state, and deterministic join/handle cleanup into NASM.
Phase 3B.6.1 now moves the production global shutdown coordinator, atomic
one-shot guard, window-state handoff, teardown order, and quit-to-ExitProcess
path into NASM. The C++ host retains narrow service wrappers; the reference
target retains the complete C++ coordinator. Release validation includes the
58-test suite and focused normal/ESC/close lifecycle gates. Phase 3B.6.2 moved
the production exception formatter into NASM while preserving the C++ logging
sink and reference formatter. Its synthetic ABI witness verifies the complete
three-line output and Win64 stack arguments. Phase 3B.6.3 moved the production
file/path/critical-section/write/flush/close sink into NASM. Phase 3B.6.4 moved
the proven integer/string/pointer formatter subset into NASM. Phase 3B.6.5
moved the live fixed-point floating formatter into NASM and routed production
logger, crash trace, and progress-title formatting through it. Phase 3B.6.6
moved the formatted timeline/file service behind an assembly formatter and
Win32 file ABI; its byte-level probe and the complete 59-test suite pass. Phase
3B.6.7A moved the arena/archive service behind an assembly ABI; its focused
probe and the complete 60-test suite pass. Phase 3B.6.7B.1 now moves the
production soundtrack-path resolver into NASM, removes the production host's
dead command-line getter/storage path, and passes a stable assembly path
pointer directly into the dedicated audio initializer. Its focused path/arena
gates and complete 61-test suite pass. Phase 3B.6.7B.2 now moves the
production seek precedence, scene-start table, self-test loop, audio-check
dispatch, crash-filter handoff, and DemoStart32 result branch into NASM. Its
mode probe and complete 62-test suite pass. Phase 3B.6.7B.3 now moves the
production subsystem initialization order, quit checkpoints, service argument
contract, lifecycle automation handoff, and ordinary failure rollback into
`win32_app_startup.asm`, with a fixed-layout `AppStartupConfig` and a focused
service-stub witness. Its startup probe and complete 63-test suite pass. Phase
3B.6.7B.4 now removes the production `app.cpp` host body: NASM owns production
configuration logging, window/startup failure handling, seek/run dispatch, and
final return/shutdown, while `production_entry.cpp` remains only the CRT
`WinMain` transfer stub. Its host probe and complete 64-test suite pass. Phase
3B.6.7B.5 now removes the production `log.cpp` and `timeline.cpp`
implementation objects. NASM exports their exact MSVC-decorated namespace
symbols, owns the logger/timeline forwarding and formatting boundary, and
retains only the narrow `vk_log_printf` bridge for remaining C++ services.
The ABI probe and complete 65-test suite pass; the reference target retains
the C++ implementations as the behavioral oracle. Phase 3B.6.7B.6 now moves
the production processorek Nevosolek (P4) textured-triangle bridge from `bridge.cpp` into a standalone
NASM SSE2/double-precision scan converter. Its complete-frame raster probe and
the complete 66-test suite pass; the reference target retains the C++
rasterizer as the oracle.
Phase 3B.6.7B.7 now removes the production `d3d11_dispatch.cpp` object. NASM
owns the decorated presenter ABI, palette and self-test state, frame recording,
bounded GPU readback diagnostics, Win32 file handles, VirtualAlloc storage, and
presenter lifecycle; the real 67-test suite including production P1/pause/close
playback passes, while the reference presenter remains C++.
Phase 3B.6.7B.8 now removes the production `audio_dispatch.cpp` object. NASM
owns the exact decorated namespace-vk audio forwarding ABI, preserving enabled
and disabled-mode results, the rejection log, floating-point elapsed-time
return, and unconditional shutdown while the dedicated player orchestration
remains the C++ transitional owner. The focused dispatch probe and complete
68-test suite pass, including live WASAPI, seek/stress, and P1/pause/close
playback gates.
Phase 3B.6.7B.9.1 now replaces the two production `std::lower_bound` seek
lookups in `audio_asm.cpp` with a stateless NASM `audio_lookup.asm` primitive.
Its empty-table, duplicate, boundary, and randomized-table probe matches the
C++ oracle, and the complete 69-test suite—including live seek/stress and
P1/pause/close playback—passes. The C++ audio runtime record, worker handles,
acknowledgement loops, and storage/path ownership remain intentionally intact
for the next higher-risk gate.
Phase 3B.6.7B.9.2 now moves the backing storage for that C++ runtime record to
the loader-zeroed, 64-byte-aligned NASM block `asm_audio_runtime_state`. The
C++ POD view and all field offsets remain unchanged under a compile-time size
guard; the complete 69-test suite still passes, including live control/seek/
stress and P1/pause/close playback. The worker handles, acknowledgement loops,
and teardown behavior remain C++ until the next gate.
Phase 3B.6.7B.9.3 now moves the production `issueState` acknowledgement loop
into NASM. Atomic state publication, sequence increment, bounded acknowledgement
polling, cached-state updates, and optional sequence output are covered by a
real helper-thread probe; the complete 70-test suite—including live control,
seek/stress, and P1/pause/close playback—passes. Worker creation, handle
ownership, seek quiescence, and teardown remain C++ for the next gate.
Phase 3B.6.7B.9.4 moved the production `CreateThread`, wait, and `CloseHandle`
calls into `audio_workers.asm`, preserving timeout/status and caller-owned
handle-slot semantics. Phase 3B.6.7B.9.5 now moves producer/controller startup,
prebuffer polling, early-exit detection, failure-coded rollback, stop-state
publication, worker-before-producer join ordering, and handle cleanup into the
same assembly boundary. The expanded lifecycle probe and complete 71-test
suite—including live WASAPI lifecycle/seek/stress and P1/pause/close
playback—pass. The reference target remains the C++ behavioral oracle; seek
quiescence and ring flushing are the next higher-risk audio gate.
Phase 3B.6.7B.9.6 now moves the controller-side seek transaction into
`audio_seek.asm`: pause acknowledgement, consumed-frame capture, producer
seek acknowledgement, PCM/marker cursor flush, commit, prebuffer, and resume
acknowledgement. Its real two-worker probe and complete 72-test suite—including
live seek/stress, long-run audio, and P1/pause/close playback—pass. Phase
3B.6.7B.9.7 now moves the production ModPos/order-length/elapsed-time queries,
pause/resume pump, and self-check/report wrapper into `audio_controller.asm`.
The fixed 600-byte runtime view is guarded by compile-time offsets, while the
controller probe covers default values, seek-relative elapsed time, a real
acknowledgement helper thread, boolean return handling, logging, and failure
status. The obsolete C++ state-pump wrapper is removed. The focused probe and
complete 73-test suite—including live WASAPI control/seek/stress/long-run and
P1/pause/close playback—pass. Phase 3B.6.7B.9.8.1 now moves dedicated-player
initialization, fixed record construction, startup rollback, shutdown, and
play/stop publication into `audio_lifecycle.asm`. Its lifecycle witness checks
the exact producer/worker pointer contract, null/forced-failure paths, and
runtime clearing; the complete 74-test suite—including live WASAPI lifecycle,
seek/stress/long-run, P1/pause/close playback, and reference close—passes. Phase
3B.6.7B.9.8.2 now moves the final public seek wrappers and seek-relative
metadata commit into `audio_seek_controller.asm`, then removes `audio_asm.cpp`
from both target source lists. Its duplicate/boundary/status probe and complete
75-test suite—including live WASAPI seek/stress/long-run and P1/pause/close
playback—pass. The dedicated shipped audio implementation is now entirely
NASM; the reference target remains the C++ behavioral oracle.
The default `VOODKA.exe` path now uses the persistent assembly service through
the production `audioInit`, `audioPump`, seek, pause, and shutdown ABI. The
dedicated path no longer uses C++ vectors or C++ file I/O. `VOODKA.exe` now
contains neither `audio.cpp` nor `xmp_static`; `VOODKA_REFERENCE.exe` retains
both as a non-shipped behavioral oracle, and the host probes continue to use
libxmp for differential validation. Phase 3B.6.7C.1 now moves the shipped
QPC/70 Hz timer state machine from `timer.cpp` into `timer.asm`, retaining the
C++ timer only in the reference target. Its pause/QPC/progress witness and
complete 76-test suite—including full assembly playback and live audio timing—
pass. A production PE/object audit now attributes the remaining CRT imports to
the production entry shim and the `bridge.cpp`, `progress.cpp`, and `pause.cpp`
objects; arena/input are primarily wrappers over existing assembly services.
The next gate is Phase 3B.6.7C.2: migrate the broad C ABI adapter in
`bridge.cpp` by dependency group while retaining all visual/audio/lifecycle
gates.
