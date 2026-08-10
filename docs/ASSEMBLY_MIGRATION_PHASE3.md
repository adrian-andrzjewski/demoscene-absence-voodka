# Phase 3 progress: pure Win32/thread runtime and callback integration

Status: **Phase 3A passed; Phase 3B callback integration passed.**

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

## Next gate: Phase 3B.2

Phase 3B.2 must move window bootstrap and the application lifecycle handoff
behind a stable assembly adapter without changing behavior. It should cover
class registration, geometry, window creation/show/focus, input watcher
startup, and the transition into `DemoStart32`. The C++ reference executable
remains mandatory until those paths pass the same full-demo visual, audio,
timing, and stability witnesses.
