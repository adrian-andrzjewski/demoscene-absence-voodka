# Phase 3 progress: pure Win32/thread runtime feasibility gate

Status: **Phase 3A passed; the no-CRT Win32/thread substrate is feasible.**

Snapshot date: **2026-08-10**

Phase 3 begins the highest-risk remaining platform work. It tests whether a
native x64 assembly process can perform the Windows startup, window, message,
thread, synchronization, exception-filter registration, and shutdown work
without relying on C/C++ startup objects. The production demo is not switched
to this substrate yet; the probe remains an isolated gate.

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

This is a **GO** for Phase 3B: moving the real application window and lifecycle
entry contract behind an assembly adapter while retaining the current C++ host
as the reference target. It is a **NO-GO** for claiming a pure assembly demo
process: the production application still owns window creation, input, timing,
logging, crash handling, and shutdown in C++.

## Next gate: Phase 3B

Phase 3B must connect the proven substrate to the existing application without
changing behavior. It should first replace the production target's window and
message-pump calls behind a stable ABI, then validate ESC/window-close teardown,
pause/resume, D3D11/audio lifetime ordering, and repeated startup/shutdown.
The C++ reference executable remains mandatory until those paths pass the same
full-demo visual, audio, timing, and stability witnesses.
