# Phase 3 progress: pure Win32/thread runtime and callback integration

Status: **Phase 3A passed; Phase 3B.1/3B.2 and the 3B.3 host handoff passed.**

Snapshot date: **2026-08-10**

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

The focused gates covered production P1 playback, production pause/resume,
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

The production tests exercised raw command-line acquisition, P1 startup,
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
still contains C++ subsystem implementations, formatted logging, crash
formatting, path resolution, and startup orchestration.

## Next gate: Phase 3B.6.2

Phase 3B.6.2 should migrate the production logging/crash-reporting boundary or
the remaining startup orchestration, whichever can be isolated with a stable
C ABI and differential evidence. It must preserve diagnostics, failure-path
behavior, and the same normal/ESC/close teardown witnesses.
