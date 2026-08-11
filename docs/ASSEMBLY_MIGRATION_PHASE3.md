# Phase 3 progress: pure Win32/thread runtime and callback integration

Status: **Phase 3A and Phase 3B.1-3B.6.7B.2 passed; remaining host migration is in progress.**

Snapshot date: **2026-08-11**

Phase 3 begins the highest-risk remaining platform work. It tests whether a
native x64 assembly process can perform the Windows startup, window, message,
thread, synchronization, exception-filter registration, and shutdown work
without relying on C/C++ startup objects. The first production integration
slice now uses the proven assembly callback while retaining the C++ host and
reference executable.

## Phase 3A scope

[`win32_runtime_probe.asm`](../port/core/eos_replace/win32_runtime_probe.asm)
is a standalone `WIN32` executable with a custom `/ENTRY` and
`/NODEFAULTLIB`. It owns:

- process entry and Win64 call-site alignment;
- `GetModuleHandleA`, `WNDCLASSEXA`, and `RegisterClassExA`;
- hidden `CreateWindowExA`, `ShowWindow`, and `UpdateWindow`;
- an assembly `WndProc` handling `WM_CLOSE` and `WM_DESTROY`;
- `CreateThread`, a manual-reset event, `SetEvent`, and
  `WaitForSingleObject`;
- an atomic worker counter using the locked instruction equivalent of the
  MSVC `InterlockedIncrement` intrinsic;
- `SetUnhandledExceptionFilter` registration;
- synchronous `WM_CLOSE` dispatch through `DestroyWindow`, `PostQuitMessage`,
  `GetMessageA`, `TranslateMessage`, and `DispatchMessageA`; and
- `CloseHandle`, `UnregisterClassA`, and `ExitProcess` teardown.

The successful path has no C or C++ object and no CRT startup or shutdown
dependency. A failed path terminates through `ExitProcess`, so this probe
cannot leave a worker thread running after the test process exits.

## ABI and ownership contract

The probe follows the same Win64 rules required by the demo:

- RCX, RDX, R8, and R9 carry the first four arguments;
- every API call has 32 bytes of shadow space;
- additional `CreateWindowExA` and `CreateThread` arguments are placed at the
  caller-side stack offsets;
- nonvolatile registers used by the worker and callback are preserved; and
- all successful resources have an explicit close/unregister path.

This is intentionally a probe contract, not yet the production `app.cpp`
contract. It does not yet validate command-line parsing, custom exception
unwind metadata, a deliberate exception, DPI policy, D3D/audio ownership, or
the demo's global quit path.

## Phase 3A validation

```text
CTest win32.runtime_probe                         1/1 passed; 0.12 s
repeat-until-fail lifecycle stress                20/20 passed; 0.80 s
probe executable                                  4,608 bytes
imports                                            KERNEL32.dll, USER32.dll only
CRT/C++ runtime imports                            none
```

This was a **GO** for Phase 3B: moving the real application callback behind an
assembly adapter while retaining the current C++ host as the reference target.
It remains a **NO-GO** for claiming a pure assembly demo process: the
production application still owns process entry, window creation, command-line
parsing, input watcher startup, timing, logging, crash handling, and shutdown
in C++.

## Phase 3B callback integration

[`win32_app_wndproc.asm`](../port/core/eos_replace/win32_app_wndproc.asm) is
now linked into the production core. `VOODKA.exe` registers this native x64
callback; `VOODKA_REFERENCE.exe` continues to register the original C++
`WndProc` for differential validation.

The assembly callback preserves the current behavior for:

- keyboard make/break scancode translation, including extended keys;
- Space edge detection and pause/resume dispatch;
- `WM_PAINT` validation with `BeginPaint`/`EndPaint`;
- topmost-window restoration on activation;
- `WM_CLOSE` -> `DestroyWindow` and quit request;
- `WM_DESTROY` -> `PostQuitMessage` and quit request; and
- default messages through `DefWindowProcW`.

The four C++ calls are fixed C ABI wrappers (`vk_key_down`, `vk_key_up`,
`vk_pause_toggle`, and `vk_request_quit`). They preserve the existing input,
pause, and global-cancellation ownership while making the callback itself
native assembly.

### Phase 3B validation

```text
Release build                                      passed
focused production/reference lifecycle gates      3/3 passed; 32.23 s
full regression suite                              54/54 passed; 104.31 s
production callback                                NASM x64
reference callback                                 C++ differential oracle
```

The focused gates exercised production pause/resume, production close, and
reference close. The full suite retained all rendering, audio, timing, asset,
Win32, D3D11, and dedicated assembly-audio checks.

## Phase 3B.2 window bootstrap

[`win32_app_window.asm`](../port/core/eos_replace/win32_app_window.asm) now
owns the production window bootstrap and teardown. It implements:

- `WNDCLASSW` construction and registration with the assembly callback;
- cursor/background setup through `LoadCursorW` and `GetStockObject`;
- client-to-outer geometry conversion through `AdjustWindowRectEx`;
- primary-monitor work-area discovery with full-screen fallback;
- centered and clamped window placement;
- `CreateWindowExW` with the exact production style, title, and instance;
- show, update, topmost, foreground, active-window, and focus handoff; and
- `IsWindow`, `DestroyWindow`, and `UnregisterClassW` teardown.

`VOODKA.exe` now receives only the resulting HWND before continuing through the
existing C++ subsystem order. `VOODKA_REFERENCE.exe` retains the original
C++ registration, geometry, creation, and teardown path.

### Phase 3B.2 validation

```text
Release build                                      passed
focused bootstrap/lifecycle gates                  4/4 passed; 58.43 s
full regression suite                              54/54 passed; 104.27 s
production bootstrap                               NASM x64
reference bootstrap                                C++ differential oracle
```

The focused gates covered production oko + szklo (P1) playback, production pause/resume,
production close, and reference close. No rendering, audio, timing, or
shutdown regressions were observed.

## Phase 3B.3 assembly host handoff

[`win32_app_entry.asm`](../port/core/eos_replace/win32_app_entry.asm) is now
the production handoff immediately after the CRT invokes the trivial C++
`WinMain` shim. It:

- obtains the process instance through `GetModuleHandleA`;
- obtains the raw process command line through `GetCommandLineA`;
- applies `DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2` through Win32; and
- calls the existing C++ host through the fixed
  `vk_voodka_host_main(HINSTANCE, LPSTR, int)` ABI.

The reference executable continues to call the host directly from its C++
`WinMain`. This is deliberately an assembly handoff, not yet a custom linker
entry: the C++ host still uses the CRT and STL, so bypassing CRT initialization
would be unsafe at this stage.

### Phase 3B.3 validation

```text
Release build                                      passed
production/reference handoff gates                3/3 passed; 31.12 s
full regression suite                              54/54 passed; 104.31 s
production handoff                                 NASM x64
reference handoff                                  C++ direct path
```

The production tests exercised raw command-line acquisition, oko + szklo (P1) startup,
clean close, and normal host/subsystem sequencing. The complete suite retained
all rendering, audio, timing, asset, Win32, D3D11, and assembly-audio checks.

## Phase 3B.4 early host services

The production early-host path now has three additional assembly-owned pieces:

- `win32_app_entry.asm` stores the raw `GetCommandLineA` pointer and exposes it
  through `asm_voodka_command_line` for the production host;
- `win32_crash.asm` registers the native exception-filter entry and forwards
  `EXCEPTION_POINTERS` to the existing C++ diagnostic logger; and
- `win32_input.asm` owns the production global Escape watcher, manual-reset
  stop event, worker thread, polling edge detector, quit request, close message,
  join, and handle cleanup.

The C++ reference target retains its original crash-filter and input-watcher
implementations. The production C++ layer still owns formatted crash output,
argument interpretation, the 128-byte key map, and the main-thread message
pump; those are intentionally later boundaries.

### Phase 3B.4 validation

```text
Release build                                      passed
focused production/reference lifecycle gates      3/3 passed; 32.20 s
full regression suite                              54/54 passed; 104.36 s
production crash/input startup                    NASM x64
reference crash/input startup                     C++ differential oracle
```

The focused gates covered production pause/resume, production close, and
reference close. The full suite retained all rendering, audio, timing, asset,
Win32, D3D11, and dedicated assembly-audio checks.

## Phase 3B.5 command-line and input bridge

Phase 3B.5 moves the production command-line and main-thread input boundary into
NASM while keeping the C++ target as a differential oracle.

- `win32_args.asm` owns raw command-line interpretation, the flag/value state,
  fixed-size path storage, and getters for recording, diagnostics, music,
  timeline, pause/close automation, ModPos, millisecond/order seeks, and part
  selection. Its token and substring behavior intentionally matches the former
  C++ parser, including its existing path-with-spaces limitation.
- `win32_input.asm` owns the production 128-byte key map, key transitions,
  Escape queue state, and the `PeekMessageW`/translate/dispatch loop. The
  assembly Escape watcher and its event/thread lifecycle remain the Phase 3B.4
  implementation.
- `app.cpp` now consumes assembly getters for the shipped target. The
  reference target retains the original C++ parser and input implementation so
  every migration can still be compared against the established behavior.
- The C++ ABI remains deliberately narrow: the assembly message handler uses
  the existing key/pause/quit wrappers, while host orchestration, logging, and
  subsystem startup remain C++ until their own gates are proven.

### Phase 3B.5 validation

```text
Release build                                      passed
focused parser/input/lifecycle gates               5/5 passed; 58.57 s
direct --selftest                                  ExitCode=0
direct --audiocheck 1                              ExitCode=0
full regression suite                              54/54 passed; 107.86 s
production command-line/input path                NASM x64
reference command-line/input path                 C++ differential oracle
```

The focused gates cover assembly-audio startup, pause/resume, production close,
reference close, and rejection of the removed production libxmp path. The full
suite retains rendering, audio, timing, asset, Win32, D3D11, and dedicated
assembly-audio coverage. This is a **GO** for the next platform boundary, but
not yet a claim that the shipped process is assembly-only: C++ still owns the
host handoff after the assembly entry point, formatted logging, and final demo
orchestration.

## Phase 3B.6 scope

Phase 3B.6 moves the remaining production host bridge and application
lifecycle orchestration behind assembly-owned interfaces, beginning with the
smallest stable service boundaries. The C++ reference executable and all
existing full-demo visual, audio, timing, and stability witnesses remain
mandatory before removing each C++ implementation.

## Phase 3B.6 lifecycle automation worker

The first Phase 3B.6 boundary moves the optional lifecycle automation worker
into `win32_lifecycle.asm` for the production target. This is a deliberately
small threading gate before attempting the larger shutdown coordinator.

- `asm_lifecycle_start` owns the production automation event, thread, HWND,
  pause/close thresholds, and CreateThread stack-argument setup.
- `asm_lifecycle_worker` preserves the reference behavior: it waits in 5 ms
  increments, posts one real Space key-down/up pair at the pause threshold,
  posts the matching pair one second later, and posts a real `WM_CLOSE` at the
  close threshold.
- `asm_lifecycle_stop` signals the event, joins the worker, closes both handles,
  and clears all state. It is safe when automation was not requested or startup
  failed.
- The production C++ host retains only the narrow ABI wrapper and status log;
  the C++ reference target retains the original state structure and worker as
  the behavioral oracle.

### Phase 3B.6 validation

```text
Release production/reference build                     passed
focused lifecycle/audio gates                          5/5 passed; 58.46 s
full regression suite                                  54/54 passed; 104.31 s
production lifecycle automation worker                 NASM x64
reference lifecycle automation worker                  C++ differential oracle
```

The focused gates cover normal assembly-audio startup, production pause/resume,
production close, reference close, and rejection of the removed production
libxmp path. The full suite still covers all renderer, asset, timing, audio,
Win32, D3D11, and dedicated-player checks. This is a **GO** for the next
shutdown boundary, but not a claim that application lifecycle ownership is yet
assembly-only: C++ still coordinates subsystem initialization, logging, and
the global teardown sequence.

## Phase 3B.6.1 scope

Phase 3B.6.1 migrates the idempotent shutdown coordinator and its quit handoff
behind an assembly-owned lifecycle interface. It must preserve worker join
order, resource-release order, window destruction, process termination, and the
reference target's clean normal/ESC/close behavior.

## Phase 3B.6.1 shutdown coordinator

The production shutdown coordinator is now native x64 assembly in
`win32_shutdown.asm`.

- `asm_shutdown_set_window` receives the production HWND/HINSTANCE after
  assembly window creation and stores them outside the C++ host state.
- `asm_shutdown_all` performs an atomic one-shot claim, logs the transition,
  stops lifecycle automation, joins input/audio workers, closes recording and
  diagnostics, closes the timeline, releases the D3D11 presenter, clears
  selectors, releases the arena/archive, destroys/unregisters the window, and
  finally flushes and closes the log.
- `asm_shutdown_and_exit` logs the quit cause, invokes the same idempotent
  sequence, and calls `ExitProcess(0)` so no demo stack or worker can outlive a
  close-triggered termination.
- `bridge.cpp` exposes one narrow C ABI wrapper per existing platform teardown
  operation. The wrappers do not change subsystem implementations or their
  release order; the order is now explicit and reviewable in NASM.
- `VOODKA_REFERENCE.exe` retains the original C++ coordinator, including its
  atomic guard and window-state handling, as the differential oracle.

### Phase 3B.6.1 validation

```text
Release production/reference build                     passed
focused shutdown/lifecycle gates                       5/5 passed; 58.54 s
full regression suite                                  54/54 passed; 104.40 s
production shutdown coordinator                        NASM x64
reference shutdown coordinator                         C++ differential oracle
```

The focused gates cover normal production completion, production pause/resume
cleanup, production close-triggered process exit, reference close, and the
removed production libxmp rejection path. The full suite retains all existing
rendering, audio, timing, asset, Win32, D3D11, and dedicated-player coverage.
This is a **GO** for the next host boundary, but the production executable
still contains C++ subsystem implementations, the formatted logging sink, path
resolution, and startup orchestration.

## Phase 3B.6.2 crash-report formatter

The production exception filter now formats its diagnostics in
`win32_crash.asm`. It reads the Win64 `EXCEPTION_POINTERS`/AMD64 `CONTEXT`
layout directly, emits the same three `[CRASH]` lines through `vk_log_printf`,
flushes through the shutdown logging ABI, and returns
`EXCEPTION_CONTINUE_SEARCH`. The C++ logger remains the sink and the reference
target retains `vk_crash_report` as the differential oracle.

The test-only `win32_crash_probe` constructs synthetic exception/context
records and verifies the complete formatted output, including the fifth and
sixth values passed in Win64 stack slots. The production symbol scan confirms
that `VOODKA.exe` no longer references `vk_crash_report`.

### Phase 3B.6.2 validation

```text
Release production/reference build                     passed
crash/runtime probes                                   2/2 passed; 0.11 s
full regression suite                                  55/55 passed; 104.48 s
production crash filter/formatter                     NASM x64
reference crash formatter                              C++ differential oracle
```

This is a **GO** for the next host boundary. The production executable still
contains the C++ logging sink, path resolution, and startup orchestration, but
the exception registration, formatter, flush handoff, and shutdown path are
now assembly-owned.

## Phase 3B.6.3 low-level logging sink

The production low-level file sink is now native x64 assembly in
`win32_log.asm`.

- `asm_log_init` constructs the module-directory `voodka.log` path, initializes
  the x64 `CRITICAL_SECTION`, and opens the file with the existing
  `CREATE_ALWAYS`/read-sharing behavior.
- `asm_log_write` serializes bytes with the assembly-owned critical section and
  calls `WriteFile`; `asm_log_flush` and `asm_log_shutdown` own flush, close,
  and critical-section deletion.
- `log.cpp` still performs `va_list`/`vsnprintf` formatting and forwards the
  resulting bytes through the fixed assembly ABI. This preserves every current
  format string while removing production file-I/O ownership from C++.
- `VOODKA_REFERENCE.exe` and `VIRTUAL.exe` retain their C++ logger paths. The
  test-only `win32_log_probe` verifies an assembly-written marker on disk.

### Phase 3B.6.3 validation

```text
Release production/reference/tools build               passed
Win32 runtime/crash/log probes                         3/3 passed; 0.17 s
full regression suite                                  56/56 passed; 104.45 s
production low-level logging sink                     NASM x64
production message formatting                         C++ CRT oracle
reference/VIRTUAL logging paths                        C++ differential paths
```

The full suite retains all rendering, audio, timing, asset, Win32, D3D11, and
dedicated-player coverage. This is a **GO** for the next host boundary. The
remaining production logging dependency is the C++ formatting stage and its
CRT/STL startup context; path resolution and broader startup orchestration are
also still C++.

## Phase 3B.6.4 production integer/string formatter

The first production formatter slice is now native x64 assembly in
`win32_log_format.asm`.

- `asm_log_format_supported` scans the format grammar without touching the
  argument cursor. `asm_log_vformat` then consumes the MSVC x64 `va_list`
  eight-byte slots and formats integer, pointer, character, narrow-string,
  wide-string, literal-percent, width, sign, and zero-padding conversions.
- The Windows `long` width remains 32-bit, while `ll` and `z` consume qwords;
  `%p` uses the MSVC-compatible 16-digit zero-padded representation. The
  output is caller-owned and bounded, so concurrent log calls retain the
  assembly sink's serialization contract.
- Production `log.cpp` selects the assembly formatter before consuming the
  varargs. Floating-point and unsupported conversions intentionally retain the
  C++ `vsnprintf` oracle path; this gate therefore reduces, but does not yet
  eliminate, the production CRT formatting dependency.
- `win32_log_format_probe` compares representative output byte-for-byte with
  MSVC `snprintf`, including `%S` and truncation. `win32_log_api_probe` drives
  the real production `vk::logInit`/`vk::logPrint`/`vk::logShutdown` wrapper.

### Phase 3B.6.4 validation

```text
Release production/reference/tools rebuild             passed
logging sink/formatter/API focused gates               3/3 passed; 0.14 s
production lifecycle gates after relink               5/5 passed; 56.69 s
full regression suite                                  58/58 passed; 104.87 s
integer/string/pointer formatter                        NASM x64
floating/unsupported formatter fallback                C++ CRT oracle
reference/VIRTUAL logging paths                        C++ differential paths
```

This is a **GO** for the next boundary. The remaining production logging
formatter dependency is now specifically floating-point and any future
unsupported format grammar; host/startup orchestration and the broader C++
platform layer remain unchanged.

## Phase 3B.6.5 production fixed-point float formatter

The remaining live floating-point formats are now native x64 assembly in
`win32_log_format.asm`.

- The formatter supports fixed `%f` with precision zero through six, including
  signs, explicit plus, rounded scaled-integer conversion, trailing zeroes,
  width/padding, and multiple floating arguments in one MSVC x64 `va_list`.
- The production `log.cpp` path no longer contains a `vsnprintf` fallback.
  `bridge.cpp` crash/shutdown trace formatting and `progress.cpp` elapsed/title
  formatting also route through the same bounded NASM formatter. The reference
  target keeps its C++ paths as the behavioral oracle.
- `win32_log_format_probe` compares the live `%.2f`, `%+.0f`, and `%.3f`
  cases, the exact pause format with a following `%ld`, truncation, flags, and
  mixed integer/string/pointer records against MSVC. A shipped-binary symbol
  audit reports no `vsnprintf`, `snprintf`, or `__stdio_common` reference.

### Phase 3B.6.5 validation

```text
fixed-point formatter / logger / sink gates              3/3 passed; 0.09 s
exact pause-format + lifecycle gate                    2/2 passed; 27.45 s
full regression suite                                  58/58 passed; 104.38 s
production log/progress/bridge formatting               NASM x64
reference/VIRTUAL formatting paths                      C++ differential paths
remaining formatted file output                        C++ timeline service
```

This is a **GO** for the next boundary. The shipped logger, crash trace,
progress title, and live floating diagnostics no longer depend on CRT printf
formatting. The remaining formatted production output is the timeline/file
service, while host/startup orchestration and the broader C++ platform layer
remain unchanged.

## Phase 3B.6.6 production timeline/file sink

The production timeline service now uses native x64 assembly for both record
formatting and Win32 file I/O.

- `timeline.cpp` keeps the existing public timeline contract and audio-clock
  calculation, but production record strings go through `asm_log_vformat` and
  the file lifecycle goes through `asm_timeline_open`, `asm_timeline_write`,
  `asm_timeline_flush`, and `asm_timeline_close`.
- `win32_timeline.asm` owns `CreateFileA`, `WriteFile`,
  `FlushFileBuffers`, and `CloseHandle`, including the invalid-handle and
  short-write failure paths. The reference target retains `fopen`/`fprintf`
  and remains the C++ behavioral oracle.
- `win32_timeline_probe` reads the generated file back and compares the header
  plus QPC, ModPos, and audio-elapsed records byte-for-byte. The shipped
  binary audit continues to report no `vsnprintf`, `snprintf`,
  `__stdio_common`, or `fprintf` symbol.

### Phase 3B.6.6 validation

```text
Release production/reference/tools rebuild               passed
assembly timeline sink probe                             1/1 passed; 0.15 s
full regression suite                                    59/59 passed; 104.89 s
production timeline formatting/file sink                 NASM x64
reference/VIRTUAL timeline paths                         C++ differential paths
production formatted-output symbol audit                 no printf/file-format symbols
```

This is a **GO** for the final Phase 3B.6 host boundary. All currently live
production formatted output and low-level Win32 file sinks are assembly-owned.
The remaining production C++ surface is now concentrated in host orchestration,
CRT/STL startup, path/asset service boundaries, and the higher-level platform
wrappers. Those must be reassessed before attempting custom `/ENTRY` startup.

## Phase 3B.6.7A production arena/archive service

The production EOS memory and packaged-asset boundary is now native x64
assembly in `win32_arena.asm`.

- `asm_arena_platform_init` preserves the existing 64 MiB arena layout and
  archive search order: executable `data\vodka.dat`, executable `vodka.dat`,
  then the configure-time development-tree fallback.
- `asm_arena_alloc` preserves 16-byte alignment, zero-filled allocations,
  the fixed overlay reservation, and the existing fail-fast exhaustion path.
  `asm_arena_platform_shutdown` releases both the archive block and arena.
- `asm_arena_load_internal_file` preserves case-insensitive `voodka.dat` /
  `vodka.dat` resolution, one cached arena copy, and the 32-bit offset ABI.
  The C++ reference target retains its `std::vector`/`std::wstring` loader;
  the production `arena.cpp` branch is now only a narrow C ABI adapter.
- `win32_arena_probe` validates base allocation, zeroing, alignment, mixed-case
  archive lookup, archive-header copy, and post-shutdown state. The probe also
  caught and closed Win64 shadow-space and nonvolatile-register violations
  before the production gate was accepted.

### Phase 3B.6.7A validation

```text
Release production/reference rebuild                         passed
assembly arena/archive focused gate                           1/1 passed; 0.07 s
full regression suite                                        60/60 passed; 104.78 s
production arena/archive ownership                            NASM x64
reference/VIRTUAL arena/archive paths                         C++ differential paths
```

This is a **GO** for the next host inventory boundary. It removes the largest
remaining production STL/data-loading owner without changing scene bytes,
overlay offsets, audio, timing, or rendering. It does **not** yet qualify the
process for custom `/ENTRY`: the shipped image still imports CRT/STL support
through the host, diagnostics, and optional capture paths.

## Phase 3B.6.7 production ownership inventory

The post-arena binary and source audit identifies the remaining shipped C++
owners:

| Component | Current production ownership | Migration risk |
|---|---|---|
| `app.cpp` / `production_entry.cpp` | `app.cpp` is now reference-only; production retains only the minimal CRT `WinMain` shim, while `win32_app_host.asm` owns host configuration, logging, window failure, startup, seek, run, and final return | Medium-high: the remaining shim still requires CRT entry initialization; C++ platform services and the bridge remain live owners |
| `bridge.cpp` | EOS C ABI wrappers, selector table, palette conversion, processorek Nevosolek (P4) software triangle rasterizer | High: wrappers are simple, but processorek Nevosolek (P4) uses `ceil`/`floor`, double precision, clipping, and byte-exact raster behavior |
| `audio_asm.cpp` | Dedicated assembly player orchestration, Win32 handles/events, seek/pause protocol, `lower_bound` calibration | High: the mixer/player is assembly, but worker ownership and A/V clock behavior still cross a C++ state machine |
| `d3d11_dispatch.cpp` | Reference-only historical presenter adapter; production recording/readback service is now `win32_d3d_dispatch.asm` | Closed for production; the C++ implementation remains an oracle |
| `timer.cpp` | QPC calibration, 70 Hz wait, pause/quit choke point | Medium-high: timing changes can alter every scene and A/V boundary |
| `input.cpp` / `pause.cpp` | Main-thread message pump, key-state bridge, atomics, pause state | Medium: the assembly WndProc/watcher already exist, but queue semantics and global cancellation remain live C++ behavior |
| `progress.cpp` | Scene table, title updates, transition bookkeeping | Low-medium: bounded state and Win32 `SetWindowTextA`, but title/log timing is observable |
| `audio_dispatch.cpp` | Reference-only historical production dispatch; `audio_dispatch.asm` now owns the shipped namespace ABI | Closed for production; forwarding behavior is covered by `audio_dispatch_probe` |
| `timeline.cpp` / `log.cpp` | Public C++ adapters over assembly formatter/sinks | Low: no production formatted CRT path remains, but adapters still contribute C++ objects until final removal |

The current Release import audit for `VOODKA.exe` reports `VCRUNTIME140.dll`,
the API-set UCRT runtime/math/stdio/locale/heap imports, `d3d11.dll`,
`ole32.dll`, `KERNEL32.dll`, `USER32.dll`, and `GDI32.dll`; it reports no
`libxmp`, `MSVCP140`, or standalone `xmp` dependency. The remaining CRT/UCRT
imports come from the still-live C++ audio orchestration and platform bridge,
not from the removed production D3D11/audio dispatch shims. D3D11/COM and
Win32 imports are expected platform dependencies. `audio.cpp`,
`d3d11_present.cpp`, asset viewer, VIRTUAL, and packaging/validation tools
remain intentionally outside the shipped production dependency boundary.

## Phase 3B.6.7B.1 production soundtrack path ABI

The production host no longer constructs a C++ string/vector path object for
the soundtrack. `win32_paths.asm` now preserves the existing resolver contract:

- a non-empty `--music` override is returned unchanged;
- `<exe>\music\amnezja2.mod` is tried first;
- `<exe>\amnezja2.mod` is tried second; and
- the configure-time repository fallback is tried last.

The assembly service owns the fixed path buffer, `GetModuleFileNameA`, and
regular-file checks. The reference executable retains the original wide Win32
plus STL resolver. The production host now passes the returned stable pointer
directly to the dedicated assembly audio initializer, and the obsolete
production command-line getter/storage path was removed from the host handoff.

### Phase 3B.6.7B.1 validation

```text
Release production/reference/tools rebuild                 passed
assembly arena/path focused gates                           2/2 passed; 0.20 s
full regression suite                                      61/61 passed; 105.03 s
production soundtrack path resolution                      NASM x64
reference soundtrack path resolution                       C++ differential path
```

This is a **GO** for the next host slice. It removes one production STL/path
owner without changing the module search order, audio initialization contract,
soundtrack, scene timing, or reference behavior. The process still cannot use
custom `/ENTRY`: remaining production C++ host, diagnostic, timing, bridge,
and audio-orchestration objects still contribute CRT/STL imports.

## Phase 3B.6.7B.2 production mode and entry-seek dispatcher

The production host's mode-control branch is now native x64 assembly in
`win32_app_modes.asm`.

- `asm_voodka_apply_entry_seek` preserves selector precedence exactly as
  `--modpos`, `--ms`, `--order`, then canonical `--scene`, including all eight
  scene slugs and the calibrated scene-start ModPos table; numeric `--part`
  remains the historical compatibility selector.
- `asm_voodka_run_mode` preserves self-test priority, the 60-frame diagnostic
  loop, the default 20-second audio-check duration, crash-filter installation,
  `DemoStart32` arguments, and result-code propagation.
- The remaining namespace-vk calls use explicit `vk_app_*` C ABI adapters in
  `bridge.cpp`; the reference executable retains its original C++ branch.
- `win32_app_modes_probe` stubs those service adapters and validates every
  selector/mode branch without requiring a window, GPU, or audio device.

### Phase 3B.6.7B.2 validation

```text
Release production/reference/tools rebuild                 passed
NASM mode/seek dispatcher probe                            1/1 passed; 0.20 s
full regression suite                                      62/62 passed; 106.54 s
production seek/mode/result branch                         NASM x64
reference seek/mode/result branch                          C++ differential path
```

This is a **GO** for the next host slice. Production `app.cpp` no longer owns
the seek table, selector precedence, self-test loop, audio-check dispatch, or
demo result branch. The remaining high-risk C++ owners are subsystem ordering,
audio worker orchestration, D3D11 diagnostics/capture, timing, and input/state
adapters. The CRT/STL import audit still blocks custom `/ENTRY` startup.

## Phase 3B.6.7B.3 production subsystem-startup coordinator

The production initialization contract is now native x64 assembly in
`win32_app_startup.asm`. `AppStartupConfig` is a fixed-layout POD record with
explicit `offsetof`/size assertions; it carries only handles, stable path
pointers, mode flags, and signed millisecond values. The coordinator preserves
the existing order and checkpoints:

- progress and input initialization precede arena/archive work;
- arena failure, audio failure, presenter failure, and automation failure each
  log the existing message, call the complete shutdown coordinator, and return
  failure;
- quit checks remain immediately after arena, audio, and diagnostics setup and
  use the no-return shutdown-and-exit path;
- timer, timeline, recording, dedicated audio, assembly presenter, diagnostics,
  and lifecycle automation receive the same arguments and constants as C++; and
- the reference executable retains the complete C++ initialization sequence.

`bridge.cpp` now contains only narrow `vk_app_*` operation adapters. The
focused probe stubs those services and checks the full success sequence,
Win64 argument preservation, sample rate/window dimensions, reference-audio
diagnostic selection, and every ordinary rollback branch without a window,
GPU, or audio device.

### Phase 3B.6.7B.3 validation

```text
Release production/reference/tools rebuild                 passed
NASM startup-coordinator probe                             1/1 passed; 0.10 s
full regression suite                                      63/63 passed; 105.31 s
production startup ordering/rollback                        NASM x64
reference startup ordering                                  C++ differential path
```

This is a **GO** for the next host slice. The production host no longer owns
subsystem ordering or ordinary initialization rollback. It still owns command
line/configuration display, the window-bootstrap failure boundary, the final
host return boundary, and C++ wrapper code used by diagnostics and platform
services. Those must be reduced and measured before a custom `/ENTRY` attempt.

## Phase 3B.6.7B.4 production host removal

The shipped target no longer compiles `app.cpp`. `win32_app_host.asm` now owns
the production host body and preserves the former order:

- initialize the assembly logger and emit the startup/configuration messages;
- consume the assembly-parsed recording, diagnostics, timeline, music, audio,
  and automation selectors;
- build the fixed `AppStartupConfig`, create the window, and hand off to the
  Phase B3 startup coordinator;
- apply entry seeking, obtain the 64 MiB arena, run the selected mode, and
  propagate the demo result; and
- perform the final idempotent assembly shutdown, including window failure and
  startup failure behavior.

`production_entry.cpp` is only a CRT-owned `WinMain` transfer stub. The full
C++ `app.cpp` remains in `VOODKA_REFERENCE.exe`, including its C++ lifecycle,
window, and differential behavior. `bridge.cpp` supplies the narrow resolver
and production shutdown symbols needed by the remaining C++ platform services.
The focused host probe validates success, no-option defaults, window failure,
startup failure, configuration fields, and all run/shutdown arguments without
a window, GPU, audio device, or filesystem dependency.

### Phase 3B.6.7B.4 validation

```text
Release production/reference/tools rebuild                 passed
NASM host-coordinator probe                                1/1 passed; 0.10 s
full regression suite                                      64/64 passed; 106.08 s
production host body                                       NASM x64
reference host body                                        C++ differential path
```

This is a **GO** for the next boundary. The shipped production host is now
assembly except for the minimal CRT `WinMain` transfer. Remaining all-assembly
blockers are the C++ platform services: bridge/P4 rasterization, dedicated
audio orchestration, D3D11 capture/diagnostics, timing, input/pause, progress,
timeline/log adapters, and their CRT/STL imports.

## Phase 3B.6.7B.5 production logging/timeline ABI

The shipped target no longer compiles the production implementations in
`log.cpp` or `timeline.cpp`. `win32_platform_abi.asm` now exports the exact
MSVC-decorated symbols declared by `platform_abi.h`:

- `vk::logInit`, `vk::logPrint`, `vk::logFlush`, and `vk::logShutdown` forward
  to the assembly sink/formatter while retaining `vk_log_printf` only as the
  narrow variadic bridge still needed by other C++ services;
- `vk::timelineInit`, `vk::timelineFrame`, and `vk::timelineClose` own the
  timeline header, frame-line formatting, audio-clock sample, file writes,
  flush, and close sequence; and
- the reference target retains the original C++ logger and timeline files as
  differential behavior oracles.

The phase also fixes the platform target's CMake language filter so C++ `/W4`
does not get passed to NASM when a platform target contains assembly sources.
The focused probe checks decorated-symbol linkage, Win64 variadic forwarding,
the exact timeline bytes, flush/close ordering, and the audio-clock call.

### Phase 3B.6.7B.5 validation

```text
Release production/reference/tools rebuild                 passed
NASM platform-ABI probe                                    1/1 passed; 0.08 s
full regression suite                                      65/65 passed; 104.69 s
production log.cpp/timeline.cpp                            not compiled
reference log.cpp/timeline.cpp                             retained as oracle
```

This is a **GO** for the next boundary. The production logger and timeline
implementation objects are now assembly-owned. The remaining substantial
production C++ boundary is bridge/render-service orchestration, followed by
the smaller timing/input/progress/resource wrappers and the CRT/STL imports.

## Phase 3B.6.7B.6 processorek Nevosolek (P4) rasterizer bridge

The shipped target no longer compiles the C++ `ProcessorekNevosolekDrawArgs` scan converter in
`bridge.cpp`. `p4_raster.asm` now exports the production
`vk_processorek_nevosolek_draw_triangle` ABI used by `parts/p4.asm` and a probe alias for direct
comparison. It preserves the C++ oracle's vertex-Y ordering, double-precision
edge interpolation, integer ceil/floor clipping, zero-area behavior, packed
8-bit UV extraction, 16-bit texture wrapping, and palette-color addition.
The reference target retains the C++ implementation unchanged. The assembly
path has no CRT or C++ calls; its only state is the caller-provided fixed
layout record and the texture/framebuffer pointers.

The focused probe compares complete 320x200 framebuffer results for normal,
reversed, clipped, horizontal, degenerate, fully off-screen, and UV-wrapping
triangles. This is the rasterizer equivalence gate; a generic direct `--scene
4` host smoke is not counted as visual proof until the existing entry-seek
trace produces a reliable processorek Nevosolek (P4) scene boundary.

### Phase 3B.6.7B.6 validation

```text
Release production/reference/tools rebuild                 passed
NASM-vs-C++ processorek Nevosolek (P4) raster probe                                1/1 passed; 0.10 s
production oko + szklo (P1) playback gate                                passed; 26.29 s
full regression suite                                      66/66 passed; 104.65 s
production processorek Nevosolek (P4) bridge implementation                        NASM x64
reference processorek Nevosolek (P4) bridge implementation                          C++ oracle
```

This is a **GO** for the next boundary. The highest-risk algorithmic render
bridge is now assembly-owned and independently equivalent. Remaining render
surface is the C++ recording/readback diagnostics around the assembly D3D11
presenter, followed by the lower-risk timing/input/progress/resource wrappers.

## Phase 3B.6.7B.7 D3D11 recording/diagnostic service

The shipped target no longer compiles `d3d11_dispatch.cpp`. The assembly
`win32_d3d_dispatch.asm` exports the exact decorated `vk::` presenter-service
ABI and now owns the remaining host-side D3D11 boundary around the already
assembly-native COM presenter:

- palette conversion/current-palette state and the deterministic self-test
  framebuffer pattern;
- `frames.raw` recording with the original frame/palette ordering and flush
  behavior;
- readback diagnostics with separate `frame_src.raw`, `frame_pal.raw`, and
  `frame_gpu.raw` files, a bounded four-frame capture, dynamic `VirtualAlloc`
  storage, and Win32 `CreateFileA`/`WriteFile`/`FlushFileBuffers`/`CloseHandle`
  ownership; and
- presenter initialization, draw/Present error reporting, input/quit
  boundary calls, and complete state teardown.

`bridge.cpp` retains only narrow C ABI wrappers for the input/quit/arena
services needed by the assembly service. The C++ production `std::string`,
`FILE*`, `std::vector`, and `fopen_s`/stdio path are no longer compiled into
`VOODKA.exe`; the reference target retains `d3d11_present.cpp` as the C++
presenter oracle.

The focused probe uses real Win32 files and virtual memory while stubbing only
the lower assembly COM presenter. It verifies exact output files, byte counts,
palette masking, self-test pixels, readback capacity, decorated ABI linkage,
input/quit call order, and teardown.

### Phase 3B.6.7B.7 validation

```text
Release production/reference/tools rebuild                 passed
NASM D3D11-service probe                                   1/1 passed; 0.07 s
full regression suite                                      67/67 passed; 104.38 s
production d3d11_dispatch.cpp                              not compiled
production D3D11 host service                              NASM x64
reference D3D11 presenter                                  C++ oracle
```

This is a **GO** for the next boundary. The production render path is now
assembly from processorek Nevosolek (P4) rasterization through COM presentation and host-side frame/
diagnostic output. Remaining production C++ is concentrated in the bridge's
service wrappers, timing/input/pause/progress, audio dispatch, and the minimal
CRT entry boundary.

## Phase 3B.6.7B.8 audio dispatch ABI

The shipped target no longer compiles `audio_dispatch.cpp`. The new
`audio_dispatch.asm` exports the exact decorated `vk::` audio ABI and forwards
to the already-tested dedicated-player orchestration in `audio_asm.cpp`:

- enabled-mode initialization, play/stop, pump, position/length, elapsed-time,
  seek, and self-check calls preserve the existing argument and return-value
  contracts;
- disabled mode retains the former production rejection behavior, including
  the exact log message and zero/one default results; and
- shutdown remains unconditional, matching the old C++ dispatch behavior.

`audio_dispatch_probe` supplies deterministic player stubs and checks every
forward, disabled-mode branch, double return, variadic log call, and shutdown
path. The complete Release suite passes 68/68, including the real dedicated
audio/WASAPI tests and P1/pause/close demo playback. `audio_asm.cpp` remains
the next audio migration boundary because it still owns Win32 thread handles,
waits, state transitions, seek calibration, and C++ container algorithms.

### Phase 3B.6.7B.8 validation

```text
Release production/reference/tools rebuild                 passed
NASM audio-dispatch probe                                  1/1 passed; 0.04 s
full regression suite                                      68/68 passed; 104.91 s
production audio_dispatch.cpp                              not compiled
production namespace-vk audio ABI                          NASM x64
dedicated player orchestration                              C++ transitional owner
reference/libxmp path                                       retained outside VOODKA.exe
```

This is a **GO** for the next audio/runtime boundary. The dispatch shim is no
longer a blocker; the next risk is moving the C++ audio orchestration without
altering PCM output, WASAPI lifecycle, seek behavior, or A/V synchronization.

## Phase 3B.6.7B.9.1 audio seek lookup primitive

The first audio-orchestration slice replaces both `std::lower_bound` calls in
`audio_asm.cpp` with `asm_audio_lower_bound_u32` from `audio_lookup.asm`. The
primitive is stateless and preserves the former boundary contract: it returns
the first index whose value is at least the requested key, or `count - 1` when
the key is above the table, including the old `UINT32_MAX` result for an empty
table. No worker, PCM, WASAPI, clock, or seek-state ownership changed in this
slice.

`audio_lookup_probe` compares the NASM result with `std::lower_bound` for empty
tables, duplicates, exact hits, gaps, high keys, and deterministic sorted
tables through 257 entries. The full Release suite passes 69/69, including
live seek/stress, audio playback, and P1/pause/close demo gates.

### Phase 3B.6.7B.9.1 validation

```text
Release production/reference/tools rebuild                 passed
NASM seek-lookup probe                                     1/1 passed; 0.08 s
full regression suite                                      69/69 passed; 104.86 s
production std::lower_bound calls                          removed from audio_asm.cpp
production seek lookup                                     NASM x64
audio worker/state ownership                               unchanged C++ transitional owner
```

This is a **GO** for the next audio-orchestration gate. The remaining high-risk
boundary is the C++ runtime state machine: Win32 worker handles, atomic control
records, pause/seek acknowledgements, and deterministic teardown.

## Phase 3B.6.7B.9.2 assembly-owned audio runtime storage

The dedicated player `Runtime` POD layout remains visible to the transitional
C++ orchestration, but its backing storage is now `asm_audio_runtime_state` in
`audio_runtime_state.asm`: a 64-byte-aligned, loader-zeroed 0x2000-byte block
shared by the shipped and reference targets. A compile-time size assertion
guards the C++ view against overrunning that fixed assembly allocation. No
field offsets, handles, atomics, ring pointers, seek bases, or teardown order
were changed.

This deliberately separates state ownership from behavior. The Release build
and complete 69/69 suite pass, including live WASAPI control/seek/stress,
device-failure cleanup, and P1/pause/close playback. The C++ state machine is
still retained as the oracle for the next synchronization migration.

### Phase 3B.6.7B.9.2 validation

```text
Release production/reference/tools rebuild                 passed
full regression suite                                      69/69 passed; 104.63 s
audio Runtime storage                                      NASM x64 fixed BSS block
Runtime layout guard                                       C++ static_assert passed
worker/control behavior                                    unchanged and fully green
```

This is a **GO** for synchronization ownership. The next slice must move the
Win32 worker handles and acknowledgement loops while preserving PCM output,
pause/seek semantics, failure injection, and deterministic join/teardown.

## Phase 3B.6.7B.9.3 state-command acknowledgement

The first synchronization slice moves `issueState` from `audio_asm.cpp` to
`audio_sync.asm`. The assembly helper preserves the former contract: atomic
requested-state publication, atomic sequence increment, a bounded 5000-poll
one-millisecond acknowledgement wait, matching state/sequence validation,
cached-state updates, and the optional sequence output.

`audio_sync_probe` uses a real Win32 helper thread to acknowledge the published
command asynchronously and checks the complete control record plus cached
outputs. The full Release suite passes 70/70, including live WASAPI
control/seek/stress, device-failure cleanup, and P1/pause/close playback. The
worker creation, handle ownership, seek quiescence, and teardown remain C++.

### Phase 3B.6.7B.9.3 validation

```text
Release production/reference/tools rebuild                 passed
NASM state-sync probe                                      1/1 passed; 0.03 s
full regression suite                                      70/70 passed; 105.28 s
production issueState loop                                 NASM x64
real asynchronous acknowledgement                          passed
worker creation/join/teardown                              C++ transitional owner
```

This is a **GO** for the next synchronization slice. The remaining risk is
moving worker creation and deterministic join/teardown without allowing a
producer or WASAPI thread to outlive the assembly-owned runtime block.

## Phase 3B.6.7B.9.4 worker handle ownership

The first worker-lifecycle slice moves the Win32 handle calls used by
`audio_asm.cpp` into `audio_workers.asm`:

- `asm_audio_create_worker` owns the exact `CreateThread` ABI and stores the
  returned handle into the caller-owned Runtime slot;
- `asm_audio_wait_worker` preserves the original `WaitForSingleObject` status
  and timeout behavior; and
- `asm_audio_close_worker` owns `CloseHandle` and clears the slot, including
  safe null-slot cleanup.

The C++ orchestration still controls producer-before-worker startup, prebuffer
rollback, the worker-exited-during-startup check, stop-state publication, and
join order. `audio_workers_probe` exercises a real delayed thread, timeout,
completion, marker publication, slot clearing, and null cleanup. The full
Release suite passes 71/71, including live WASAPI lifecycle/seek/stress,
device-failure cleanup, and P1/pause/close playback.

### Phase 3B.6.7B.9.4 validation

```text
Release production/reference/tools rebuild                 passed
NASM worker-handle probe                                   1/1 passed; 0.05 s
full regression suite                                      71/71 passed; 104.79 s
production CreateThread/wait/close calls                   NASM x64
startup/rollback and join ordering                         C++ transitional owner
producer/WASAPI playback                                   fully green
```

This is a **GO** for the next worker slice. The remaining risk is moving the
startup/rollback choreography itself, including prebuffer failure, worker
early-exit detection, stop-state publication, and guaranteed join ordering.

## Phase 3B.6.7B.9.5 startup, rollback, and join choreography

This slice moves the remaining worker-lifecycle control flow from
`audio_asm.cpp` into `audio_workers.asm` while preserving the existing
fixed-layout `AudioWorkerLifecycleArgs` boundary.  The assembly routine now
owns producer creation, 8192-frame prebuffer polling, producer-failure
detection, controller creation, the 250 ms early-exit check, status-coded
rollback, stop-state publication, worker-before-producer join ordering, and
handle-slot cleanup.  C++ retains only the record construction, diagnostic
messages, and the synchronization records themselves.

The production failure branches remain intentionally reversible: a producer
creation/prebuffer failure returns status 1, controller creation failure
returns status 2 with the producer handle available for the caller's shutdown
path, and an early controller exit returns status 3 with both handles
available for rollback.  This keeps the reference target and the C++
behavioral oracle unchanged while the shipped target crosses the higher-risk
thread-lifecycle boundary.

`audio_workers_probe` now covers normal startup, a live worker, early worker
exit, controller-creation failure, producer-creation failure, idempotent
rollback, stop-state publication, join ordering, and handle-slot clearing.
The canonical Release suite remains the gate for live WASAPI lifecycle,
seek/stress, device-failure cleanup, and full P1/pause/close playback.

### Phase 3B.6.7B.9.5 validation

```text
Release production/reference/tools rebuild                 passed
NASM worker lifecycle probe                                passed
full regression suite                                      71/71 passed; 105.15 s
startup/prebuffer/rollback/join choreography               NASM x64
producer/WASAPI playback                                   fully green
reference behavioral oracle                                retained
```

This is a **GO**.  The production audio path has now crossed the worker
creation and teardown gate without changing the soundtrack contract.  The
next risk is seek-time quiescence and ring flushing, where producer and WASAPI
threads must observe a precise pause boundary before the controller rewrites
ring ownership state.

## Phase 3B.6.7B.9.6 seek quiescence and ring transaction

This slice moves the remaining controller-side seek choreography from
`audio_asm.cpp` into `audio_seek.asm`.  The fixed `AudioSeekTransactionArgs`
ABI now makes assembly responsible for pause acknowledgement, consumed-frame
capture, target/sequence publication, producer acknowledgement polling, PCM
and marker cursor flushing, commit publication, 8192-frame prebuffer polling,
and resume acknowledgement.  The existing producer-side tracker rebuild and
the WASAPI worker's audio-boundary acknowledgement remain assembly-owned and
are joined through the same `AudioLiveControl` record.

The transaction returns status 0 for failure before resume, 1 for complete
success, and 2 when commit/prebuffer completed but resume acknowledgement
failed.  That preserves the former C++ metadata behavior for the latter case
while keeping all cross-thread ownership operations in assembly.  The real
`audio_seek_probe` uses separate Win32 producer and consumer helper threads to
verify the complete pause/seek/flush/refill/resume sequence, while the live
WASAPI seek/stress tests validate the production path.

### Phase 3B.6.7B.9.6 validation

```text
Release production/reference/tools rebuild                 passed
NASM seek transaction probe                                 1/1 passed
seek/stress/P1/pause/close focused gates                    6/6 passed
full regression suite                                      72/72 passed; 106.54 s
PCM/marker flush and resume ownership                      NASM x64
soundtrack/A-V lifecycle                                   fully green
```

This is a **GO**.  The highest-risk audio synchronization boundary now has a
native assembly implementation with real-worker and production validation.

## Phase 3B.6.7B.9.7 audio controller metadata and query wrapper

This slice moves the remaining steady-state controller surface from
`audio_asm.cpp` into `audio_controller.asm` while keeping initialization,
shutdown, playback, and the already-migrated seek transaction as explicit
assembly/C++ ABI boundaries. NASM now owns `audioAsmModPos`,
`audioAsmModLength`, `audioAsmElapsedSec`, `audioAsmPump`, and
`audioAsmSelfCheck`. The controller ABI has a compile-time layout witness for
the 600-byte runtime view, and the focused probe verifies uninitialized
defaults, ModPos/order queries, elapsed time across a seek base, pause/resume
state publication, helper-thread acknowledgements, self-check logging, and
failure reporting.

The migration also removed the obsolete C++ `issueState` wrapper and corrected
the Win64 boolean boundary to test MSVC's `AL` return value. Elapsed-frame
conversion uses a zero-extended 64-bit integer before SSE2 conversion, so the
query remains correct across the full unsigned 32-bit frame range. The
reference executable and host probes remain the behavioral oracle.

### Phase 3B.6.7B.9.7 validation

```text
Release production/reference/tools rebuild                 passed
NASM controller/query/self-check probe                      1/1 passed
full regression suite                                      73/73 passed; 109.09 s
live WASAPI control/seek/stress/long-run                    passed
full assembly P1/pause/close playback                      passed
visual/audio/A-V differential gates                         passed
```

This is a **GO**. The controller query and reporting boundary is now native
x64 assembly without regressions in rendering, soundtrack output, A/V timing,
or lifecycle stability.

## Phase 3B.6.7B.9.8.1 audio lifecycle orchestration

This slice moves the dedicated player's remaining initialization, startup
record construction, failure rollback, shutdown, and play/stop state
publication from `audio_asm.cpp` into `audio_lifecycle.asm`. NASM now builds the
fixed producer/worker/lifecycle records, invokes the existing assembly storage,
ring, and worker services, preserves the former failure-status logging and
worker-before-producer teardown order, closes the ring, clears the runtime, and
publishes the play state atomically. The C++ audio runtime file no longer
includes Windows headers or owns lifecycle code; it retains only seek-index
selection and seek metadata commit for the next gate.

The focused lifecycle witness uses controlled storage/ring/worker stubs to
verify exact pointer offsets and Win64 argument records, null-path and forced
device-failure rejection before storage, successful startup, play/stop, and
shutdown cleanup. The production suite then exercises the real native module,
producer, WASAPI worker, failure injection, full soundtrack, and reference
oracle paths.

### Phase 3B.6.7B.9.8.1 validation

```text
Release production/reference/tools rebuild                 passed
NASM lifecycle record/startup/teardown probe                 1/1 passed
full regression suite                                      74/74 passed; 111.92 s
live WASAPI control/seek/stress/long-run                    passed
full assembly P1/pause/close playback                      passed
failure-injection/reference/lifecycle gates                 passed
```

This is a **GO**. The dedicated audio lifecycle is now native x64 assembly
without regressions in PCM delivery, soundtrack timing, A/V synchronization,
rendering, or teardown stability.

## Phase 3B.6.7B.9.8.2 final audio seek wrapper

This slice moves the last production C++ audio surface out of `audio_asm.cpp`.
`audio_seek_controller.asm` now owns the public ModPos, millisecond, and order
seek wrappers, calls the native lower-bound and cross-thread transaction
primitives, and commits the seek-relative frame/source/time metadata. It
preserves the former status contract: status 0 leaves metadata unchanged,
status 1 returns the selected ModPos, and status 2 commits metadata but returns
failure to the caller. Negative millisecond/order inputs remain rejected and
duplicate lower-bound behavior is unchanged.

The obsolete `audio_asm.cpp` translation unit is removed from both production
and reference target source lists. The dedicated player is now entirely NASM
at the implementation layer; C++ remains only in the separate reference
`audio.cpp` and in host/tool probes used for differential validation.

### Phase 3B.6.7B.9.8.2 validation

```text
Release production/reference/tools rebuild                 passed
NASM public seek-controller probe                            1/1 passed
full regression suite                                      75/75 passed; 106.63 s
live WASAPI seek/stress/long-run                             passed
full assembly P1/pause/close playback                       passed
audio C++ orchestration source in VOODKA build              removed
visual/audio/A-V/reference differential gates                passed
```

This is a **GO**. The shipped dedicated audio player is now fully native x64
assembly, including tracker/mixer, storage, WASAPI worker, synchronization,
controller, lifecycle, and public seek ABI.

## Next gate: Phase 3B.6.7C production platform C++ inventory

With audio complete, the next risk-first gate is an import/symbol/source audit
of the remaining shipped platform objects: `input.cpp`, `timer.cpp`,
`progress.cpp`, `pause.cpp`, `bridge.cpp`, and the CRT `production_entry.cpp`
handoff. Classify each remaining boundary by actual production references,
Win32 API/COM dependency, and no-CRT impact before converting code. The
reference target and all existing visual/audio/lifecycle gates remain
mandatory; custom `/ENTRY` is still deferred until the remaining C++ startup
and host contracts are understood.
