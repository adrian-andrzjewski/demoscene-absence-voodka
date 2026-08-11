# Building & running the VOODKA Windows port

## Prerequisites

| Requirement | Notes |
|---|---|
| Windows 10/11 x64 | the only supported target |
| Visual Studio 2022 (Build Tools suffice) | 2026 also accepted; `build.ps1` prefers 2022 |
| CMake >= 3.24 | on PATH |
| PowerShell 7+ | for `build.ps1` |
| NASM + libxmp | **vendored** in `modules/` - nothing to install; libxmp is reference/tooling-only for the shipped demo |

No package manager, no DOS toolchain, no external SDK.

## Build

```powershell
cd port
.\build.ps1 -Config Release          # configure + build
.\build.ps1 -Config Release -Test    # build + run the CTest suite (88 tests)
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
VOODKA.exe          the demo (assembly audio; no libxmp dependency)
VOODKA_REFERENCE.exe non-shipped C++/libxmp behavioral-oracle build
win32_runtime_probe.exe no-CRT assembly Win32/thread lifecycle feasibility gate
VIRTUAL.exe         the standalone VR-engine test viewer (Esc quits; --check loads+exits)
asset_viewer.exe   the V3D/V3M asset viewer (loads all 9 3D models from data/vodka.dat)
asset_viewer_selftest.exe  parse-only validation (CTest v3d.viewer_parse)
data/vodka.dat      packed assets, byte-identical to the 1996 release archive
data/world          VIRTUAL viewer object archive (byte-identical to the original)
music/amnezja2.mod  the 14-channel module the demo plays
*_selftest.exe      cross-check test binaries + tools
audio_oracle.exe    libxmp module/timing/PCM oracle for Phase 2 validation
audio_mod_parse_probe.exe  NASM-vs-libxmp module parser cross-check
audio_mod_trace_probe.exe  NASM-vs-libxmp tracker timing cross-check
audio_mod_event_probe.exe  NASM-vs-libxmp packed event cross-check
audio_mod_voice_probe.exe  NASM-vs-libxmp row voice identity cross-check
audio_mod_tick_probe.exe   NASM-vs-libxmp per-tick effect/state cross-check
audio_mod_mixer_probe.exe  native assembly PCM mixer vs libxmp tick-stream cross-check
audio_mod_stream_probe.exe  continuous bounded assembly mixer history gate
audio_live_tracker_probe.exe  persistent assembly tracker state equivalence gate
audio_live_ring_probe.exe  concurrent bounded live PCM/ModPos ring gate
audio_wasapi_asm_probe.exe assembly-owned COM/WASAPI endpoint and buffer gate
audio_thread_asm_probe.exe assembly-owned WASAPI worker-thread lifecycle gate
audio_pcm_thread_probe.exe native PCM handoff into the assembly worker
audio_live_wasapi_probe.exe live ring-to-assembly-WASAPI handoff gate
audio_live_wasapi_probe.exe --control pause/resume command-protocol gate
audio_live_wasapi_probe.exe --seek coordinated tracker/mixer seek gate
audio_live_wasapi_probe.exe --stress repeated live-seek/teardown stress gate
audio_live_wasapi_probe.exe --longrun sustained 15-second live handoff gate
```

`bin/<Config>` is self-contained: `VOODKA.exe` finds `data\vodka.dat` and
`music\amnezja2.mod` next to itself (dev-tree fallbacks exist for running
from elsewhere). To distribute, zip those three files (add `VIRTUAL.exe` +
`data\world` for the viewer).

For a release audit on the build host or on a Windows 11 validation machine,
run the PE/source/import checks and the live P4 smoke with:

```powershell
.\port\verify_production.ps1 -Config Release
.\port\verify_production.ps1 -Config Release -RunTests -PackageRun -FullRun
```

The second command runs the CTest matrix, the live P4 gate, and the complete
production playback from an isolated package containing only `VOODKA.exe`,
`data\vodka.dat`, and `music\amnezja2.mod`; it records an A/V timeline under
`port/build/` before cleaning up the temporary package.

The shipped `VOODKA.exe` registers the NASM x64 callback in
`core/eos_replace/win32_app_wndproc.asm`. `VOODKA_REFERENCE.exe` intentionally
keeps the C++ callback so close, pause, input, and lifecycle behavior can be
compared against the assembly production path. Production window
class registration, monitor-aware geometry, creation, focus, and teardown are
also implemented in `core/eos_replace/win32_app_window.asm`. Production raw
command-line acquisition, module-handle acquisition, DPI setup, and direct
`/ENTRY` startup are implemented in `core/eos_replace/win32_app_entry.asm`;
the shipped image does not use CRT/STL initialization. Production raw
command-line storage, exception-filter entry,
and the global Escape watcher lifecycle are also implemented in
`core/eos_replace/win32_crash.asm`, `core/eos_replace/win32_input.asm`, and
`core/eos_replace/win32_log.asm`; crash formatting, the key map, message pump,
low-level logging sink, and formatted timeline/file sink are now assembly-owned;
production arena, archive loading, log, progress, crash-trace, fixed-point
float, timeline record formatting, application bridge adapters, and process
entry are NASM-owned. `VOODKA.exe` is linked with `/ENTRY` and
`/NODEFAULTLIB`; custom-entry startup is covered by the production-entry
smoke gate. C++ remains in the reference executable and host tools only.

## Running

```
VOODKA.exe                     full demo, all eight scenes (~70 fps, 1280x800 window)
VOODKA.exe --scene <name>      start by canonical scene slug
VOODKA.exe --scene <slug>      canonical scene selector (for example, gratki-woda)
VOODKA.exe --part N             historical numeric scene selector alias (1..8)
VOODKA.exe --modpos N          start at ModPos N  ((order<<8)|row)
VOODKA.exe --order N           start at order N
VOODKA.exe --ms N              start N milliseconds into the module
VOODKA.exe --music <file>      override the module path
VOODKA.exe --asm-audio          explicit alias for the default assembly player
VOODKA_REFERENCE.exe --libxmp-audio  non-shipped C++/libxmp oracle path
VOODKA.exe --libxmp-audio       rejected: production has no libxmp path
VOODKA.exe --record <dir>      dump every frame (320x200 index + palette)
VOODKA.exe --diag <dir>        GPU readback diagnostics
VOODKA.exe --timeline <file>   per-frame QPC/ModPos/audio-clock witness
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

88 tests: 20 NASM-vs-C++ cross-checks (engine, txtr rasterizer, VR pipeline,
swiatynia city (P2) data, toonel, palette), `vodka.golden_hash` (repacked archive SHA-256 ==
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
player. `audio.mod_parse` verifies that the native NASM module parser matches
libxmp on the module layout, samples, orders, patterns, events, and effects.
`audio.mod_trace` compares every NASM row transition and timing field with the
libxmp replay trace. `audio.mod_events` compares all packed MOD events, and
`audio.mod_voices` compares all chronological row-start note/instrument/sample
states against libxmp.
`audio.mod_ticks` compares every per-tick period, pitch bend, voice, volume,
pan, event, and logical sample-position state against libxmp.
`audio.mod_pcm` compares every direct-tick signed-16 stereo sample from the
native x64 assembly mixer against libxmp; the complete checked-in stream is
11,613,525 frames with FNV-1a `18C7451650A7C772`.
`audio.mod_stream` sends those same native states through 78 irregular bounded
assembly mixer calls while preserving caller-owned anti-click/ramp history;
the complete stream must retain the same PCM hash.
`audio.live_tracker` advances a persistent NASM tracker context one tick at a
time, compares every internal state byte with the offline oracle, verifies
completion, and preserves the PCM hash through the continuous mixer.
`audio.live_ring` runs that live tracker/mixer concurrently against a bounded
assembly SPSC PCM/timeline ring, verifies wrap-around, backpressure, marker
ordering, clean close, and exact PCM/ModPos transfer without underruns.
`audio.controller` validates the NASM ModPos/order-length/elapsed-time queries,
pause/resume pump, Win64 boolean ABI, helper-thread acknowledgement, and
self-check/report success and failure paths.
`audio.lifecycle` validates NASM dedicated-player initialization, fixed record
construction, null/forced-failure rollback, play/stop state publication,
worker teardown ordering, ring closure, and runtime clearing.
`audio.seek_controller` validates the public NASM ModPos/millisecond/order
wrappers, duplicate lower-bound behavior, negative-input rejection, and
status-0/status-2 seek metadata contracts.
`timer.asm_probe` validates NASM QPC initialization, monotonic microseconds,
70 Hz frame pacing, pause parking/resume, and per-frame input/progress hooks.
`bridge.services` validates the NASM selector table, arena forwarders,
interleaved/planar palette ABI, bounded palette-range updates, present
forwarding, and fixed framebuffer overlay pointers.
`bridge.timing_audio` validates the NASM wait-vbl delta state, ModPos pump
ordering, elapsed-audio conversion, playback controls, and seek forwarding.
`bridge.file` validates NASM archive-name/offset forwarding and preserves
unknown/null-file diagnostic logging. `bridge.input` validates the bounded
128-entry normalized key-map copy. `win32.input_abi` validates the decorated
`vk::` input namespace ABI, worker lifecycle, key transitions, ESC queue, and
quit publication. `bridge.shutdown` validates the ten native
assembly teardown forwarders and their exact coordinator order. `bridge.log`
validates the native variadic bridge with register and stack-passed arguments
through the production formatter and sink.
`win32.pause_abi` validates the decorated `vk::` pause namespace ABI, atomic
state transitions, exact diagnostics, and audio-pump handoff.
`win32.progress_abi` validates the decorated `vk::` progress namespace ABI,
scene thresholds, timeline cadence, elapsed formatting, and transition-only
logging.
`audio.wasapi_asm_probe` performs the complete 44.1 kHz stereo PCM WASAPI
activation, event, buffer, stop/reset, and COM teardown sequence in NASM; the
C++ executable only validates its fixed-width report.
`audio.thread_asm_probe` creates an assembly-owned worker, runs the event-driven
WASAPI render loop for one second, and verifies priority, wakeups, buffer
service, stop/reset, join, and worker teardown.
`audio.pcm_thread_probe` pre-renders the exact native assembly tracker/mixer PCM,
hands it to that worker through immutable PCM/tick/ModPos arrays, verifies real
device-buffer copies and post-copy timeline snapshots, and repeats the one-
second handoff without involving libxmp.
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
| `audio_mod_parse_probe` | Phase 2B NASM module parser vs libxmp inventory cross-check (CTest `audio.mod_parse`) |
| `audio_mod_trace_probe` | Phase 2C NASM tracker timing vs libxmp row-transition cross-check (CTest `audio.mod_trace`) |
| `audio_mod_event_probe` | Phase 2D NASM MOD event decoder vs libxmp event cross-check (CTest `audio.mod_events`) |
| `audio_mod_voice_probe` | Phase 2D NASM row voice identity vs libxmp channel state cross-check (CTest `audio.mod_voices`) |
| `audio_mod_tick_probe` | Phase 2E NASM per-tick effect/state vs libxmp channel state cross-check (CTest `audio.mod_ticks`) |
| `audio_mod_stream_probe` | Phase 2J bounded continuous assembly mixer history gate (CTest `audio.mod_stream`) |
| `audio_live_tracker_probe` | Phase 2K persistent live tracker state equivalence gate (CTest `audio.live_tracker`) |
| `audio_live_ring_probe` | Phase 2L concurrent bounded PCM/ModPos ring gate (CTest `audio.live_ring`) |
| `audio_wasapi_asm_probe` | Phase 2G assembly COM/WASAPI endpoint, format, buffer, and teardown gate (CTest `audio.wasapi_asm_probe`) |
| `audio_thread_asm_probe` | Phase 2H assembly worker lifecycle and event-driven render gate (CTest `audio.thread_asm_probe`) |
| `audio_pcm_thread_probe` | Phase 2I native PCM-to-WASAPI handoff and timeline snapshot gate (CTest `audio.pcm_thread_probe`) |
| `audio_live_wasapi_probe` | Phase 2M live tracker/mixer ring into assembly-owned WASAPI with PCM-prefix and ModPos validation (CTest `audio.live_wasapi_probe`) |
| `audio_live_wasapi_probe --control` | Phase 2N ordered pause/resume acknowledgement, ring freeze, PCM-prefix, and teardown gate (CTest `audio.live_wasapi_control`) |
| `audio_live_wasapi_probe --seek` | Phase 2O pause, producer quiescence, PCM/marker ring flush, tracker/mixer reposition, post-seek refill, and A/V timeline validation (CTest `audio.live_wasapi_seek`) |
| `audio_live_wasapi_probe --stress` | Phase 2P three-seek live stress across one producer/ring/WASAPI worker, segment PCM/timeline validation, and clean teardown (CTest `audio.live_wasapi_stress`) |
| `audio_live_wasapi_probe --longrun` | Phase 2Q sustained 15-second assembly producer/ring/WASAPI transfer and teardown gate (CTest `audio.live_wasapi_longrun`) |
| `d3d11_asm_present_probe` | Phase 1B standalone NASM D3D11/COM presenter, GPU readback, Present, and Release gate (CTest `d3d11.asm_present_probe`) |
| `win32_runtime_probe` | Phase 3A no-CRT NASM process, HWND/WndProc, message pump, worker/event, exception-filter registration, and teardown gate (CTest `win32.runtime_probe`) |
| `win32_crash_probe` | Phase 3B.6.2 synthetic `EXCEPTION_POINTERS`/Win64 varargs witness for the production NASM crash formatter (CTest `win32.crash_report`) |
| `win32_log_probe` | Phase 3B.6.3 production NASM file sink, critical section, flush/close, and on-disk marker witness (CTest `win32.log_sink`) |
| `win32_log_format_probe` | Phase 3B.6.4-5 byte-level MSVC-oracle comparison for NASM integer/string/pointer/fixed-float formatting (CTest `win32.log_format`) |
| `win32_log_api_probe` | Phase 3B.6.4 real production `vk::logPrint` va_list/formatter/sink integration witness (CTest `win32.log_api`) |
| `win32_timeline_probe` | Phase 3B.6.6 byte-level production NASM timeline formatter/file-sink witness (CTest `win32.timeline_sink`) |
| `win32_arena_probe` | Phase 3B.6.7A/C.6.1 production NASM arena/archive discovery, decorated `vk::` namespace ABI, copy, alignment, and teardown witness (CTest `win32.arena_service`) |
| `win32_input_abi_probe` | Phase 3B.6.7C.6.2 production decorated `vk::` input ABI, worker, key-map, ESC, and quit-state witness (CTest `win32.input_abi`) |
| `win32_pause_abi_probe` | Phase 3B.6.7C.6.3 production decorated `vk::` pause ABI, atomic transitions, logging, and audio-pump witness (CTest `win32.pause_abi`) |
| `win32_progress_abi_probe` | Phase 3B.6.7C.6.4 production decorated `vk::` progress ABI, scene/timeline/formatting and transition-log witness (CTest `win32.progress_abi`) |
| `win32_application_abi_probe` | Phase 3B.6.7C.6.5 complete NASM application bridge, scene/seek/log/startup/WndProc/shutdown/path ABI witness (CTest `win32.application_abi`) |
| `win32_music_path_probe` | Phase 3B.6.7B.1 production NASM soundtrack-path override, executable-directory, and fallback witness (CTest `win32.music_path`) |
| `win32_app_modes_probe` | Phase 3B.6.7B.2 production NASM seek precedence, part-start, self-test, audio-check, and result ABI witness (CTest `win32.app_modes`) |
| `win32_app_startup_probe` | Phase 3B.6.7B.3 production NASM subsystem order, Win64 POD arguments, quit checkpoints, and rollback witness (CTest `win32.app_startup`) |
| `win32_app_host_probe` | Phase 3B.6.7B.4 production NASM host configuration, window/startup failure, seek/run, arena-size, and final-shutdown witness (CTest `win32.app_host`) |
| `win32_platform_abi_probe` | Phase 3B.6.7B.5 exact MSVC-decorated `vk::log*`/`vk::timeline*` assembly ABI, variadic logger forwarding, timeline formatting, audio-clock sampling, flush, and close witness (CTest `win32.platform_abi`) |
| `processorek_nevosolek_raster_probe` | Phase 3B.6.7B.6 deterministic NASM-vs-C++ processorek Nevosolek (P4) textured-triangle scan-conversion comparison across sorting, clipping, degenerate, horizontal, and wrapped-UV cases (CTest `processorek_nevosolek.raster`) |
| `VOODKA --part 4 --auto-close-ms 3000` | Phase 3B.6.7C P4 live-scene smoke gate covering the assembly face loop and rasterizer saved-register contract (CTest `render.assembly_p4_scene`) |
| `win32_d3d_dispatch_probe` | Phase 3B.6.7B.7 production NASM D3D11 service ABI, palette/frame recording, readback diagnostics, Win32 file handles, and lifecycle witness (CTest `win32.d3d_dispatch`) |
| `audio_dispatch_probe` | Phase 3B.6.7B.8 production NASM namespace-vk audio forwarding, disabled-mode defaults, log ABI, and shutdown witness (CTest `audio.dispatch`) |
| `audio_lookup_probe` | Phase 3B.6.7B.9.1 NASM lower-bound seek-index primitive vs `std::lower_bound` over duplicate and boundary tables (CTest `audio.lookup`) |
| `audio_sync_probe` | Phase 3B.6.7B.9.3 NASM state publish/increment/acknowledgement loop with a real Win32 helper thread (CTest `audio.sync`) |
| `audio_seek_probe` | Phase 3B.6.7B.9.6 NASM pause/seek/producer-ack/ring-flush/prebuffer/resume transaction with real producer and consumer helpers (CTest `audio.seek`) |
| `audio_workers_probe` | Phase 3B.6.7B.9.5 NASM worker startup, prebuffer, rollback, join, `CreateThread`/wait/close ownership, early-exit and failure paths (CTest `audio.workers`) |
| `timer_asm_probe` | Phase 3B.6.7C.1 NASM QPC initialization, 70 Hz pacing, pause parking, and per-frame hook gate (CTest `timer.asm_probe`) |
| `bridge_services_probe` | Phase 3B.6.7C.2 NASM selector, arena, palette, present, and fixed-overlay-pointer ABI gate (CTest `bridge.services`) |
| `bridge_timing_audio_probe` | Phase 3B.6.7C.3 NASM wait-vbl delta, ModPos, elapsed-audio, playback, and seek ABI gate (CTest `bridge.timing_audio`) |
| `bridge_file_probe` | Phase 3B.6.7C.4 NASM archive/file forwarding and unknown/null diagnostic gate (CTest `bridge.file`) |
| `bridge_input_probe` | Phase 3B.6.7C.4 NASM 128-byte normalized key-map copy and bounds gate (CTest `bridge.input`) |
| `bridge_shutdown_probe` | Phase 3B.6.7C.5 NASM shutdown-forwarding and teardown-order gate (CTest `bridge.shutdown`) |
| `bridge_log_probe` | Phase 3B.6.7C.5 Win64 register/stack-varargs logging bridge gate (CTest `bridge.log`) |
| `VOODKA` lifecycle gates | Phase 3B.1 production NASM WndProc with pause/close validation; the reference executable retains the C++ callback |
| `VOODKA` window bootstrap | Phase 3B.2 production NASM class registration, monitor geometry, creation/focus, and teardown; reference remains C++ |
| `VOODKA` host handoff | Phase 3B.3-4 production NASM module/command-line/DPI handoff and complete host coordination; reference retains the C++ host |
| `VOODKA` process entry | Phase 3B.6.7C.6.6 native NASM `/ENTRY`, `/NODEFAULTLIB`, direct Win32 startup, and `ExitProcess` handoff (CTest `win32.production_entry`) |
| `VOODKA` early host services | Phase 3B.4 production NASM raw-command-line storage, exception-filter entry, and Escape watcher thread/event lifecycle |
| `VOODKA` command-line/input bridge | Phase 3B.5 production NASM flag/value parsing, selector storage, 128-byte key map, and main-thread message pump; reference retains C++ behavior |
| `VOODKA` lifecycle automation | Phase 3B.6 production NASM pause/close automation worker, event/thread state, message injection, join, and handle cleanup; reference retains C++ behavior |
| `VOODKA` shutdown coordinator | Phase 3B.6.1 production NASM atomic shutdown claim, teardown ordering, window destruction, log close, and quit-to-ExitProcess handoff; reference retains C++ behavior |
| `VOODKA` crash formatter | Phase 3B.6.2 production NASM exception-record/context formatting and log-flush handoff; reference retains the C++ formatter |
| `VOODKA` log sink | Phase 3B.6.3 production NASM path/file/critical-section/write/flush/close sink; Phase 3B.6.4-6 NASM integer/string/pointer/fixed-float/timeline formatting and file output; reference/VIRTUAL retain C++ paths |
| `VOODKA` arena/archive service | Phase 3B.6.7A production NASM 64 MiB arena, Win32 archive discovery/read, aligned zeroed allocation, and cached `Load_internal_file`; reference/VIRTUAL retain C++ paths |
| `VOODKA` soundtrack path service | Phase 3B.6.7B.1 production NASM module-path resolution and stable `const char*` audio handoff; reference retains the C++ resolver |
| `VOODKA` mode/entry dispatcher | Phase 3B.6.7B.2 production NASM selector precedence, part-start ModPos table, self-test/audio-check modes, crash-filter handoff, and DemoStart32 result propagation |
| `VOODKA` startup coordinator | Phase 3B.6.7B.3 production NASM progress/input/arena/timing/audio/presenter/diagnostic/automation order and ordinary-failure rollback; reference retains C++ behavior |
| `VOODKA --scene nad-czerwonym-lampa --auto-close-ms 30000` | Phase 1C shipped production assembly presenter later-scene lifecycle witness |
| `d3d11_dispatch.cpp` | Phase 3B.6.7B.7 reference-only historical dispatch; production uses `win32_d3d_dispatch.asm` |
| `VOODKA_REFERENCE --asm-present` | Phase 1C reference-target comparison path using the NASM presenter |
| `VOODKA --asm-audio --scene oko-szklo` | Phase 2R real demo oko + szklo (P1) integration with assembly tracker/mixer/WASAPI and clean shutdown (CTest `audio.assembly_demo_oko_szklo`) |
| `VOODKA --asm-audio` | Phase 2T full eight-part assembly producer service witness: scene progression, seek/timeline behavior, and clean WASAPI teardown |
| `VOODKA --scene oko-szklo` | Phase 2W production-default assembly-audio oko + szklo (P1) integration and clean shutdown (CTest `audio.assembly_demo_oko_szklo`) |
| `VOODKA_REFERENCE --libxmp-audio --scene oko-szklo --auto-close-ms 2000` | Phase 2X non-shipped C++/libxmp reference-path initialization and teardown (CTest `audio.reference_demo_close`) |
| `VOODKA --libxmp-audio --scene oko-szklo` | Phase 2X production dependency-boundary rejection (CTest `audio.production_reference_rejected`) |
| `audio_dispatch.asm` | Phase 3B.6.7B.8 production namespace-vk audio ABI dispatch into the dedicated assembly player |
| `VOODKA_REFERENCE` | Phase 2X non-shipped host target retaining `audio.cpp` and `xmp_static` for differential validation |
| `asm_audio_ring_thread_entry` | Phase 2U assembly-owned CreateThread entry for the live WASAPI worker (exercised by the production assembly-audio CTests) |
| `asm_audio_service_storage_init` | Phase 2V assembly-owned MOD loading, fixed tracker/timeline storage, PCM ring buffers, producer scratch, and mixer history initialization |
| `VOODKA --asm-audio --scene oko-szklo --auto-pause-ms 1000` | Phase 2S real Win32 Space pause/resume injection through the assembly audio service (CTest `audio.assembly_demo_pause`) |
| `VOODKA --asm-audio --scene oko-szklo --auto-close-ms 2000` | Phase 2S real WM_CLOSE teardown during playback (CTest `audio.assembly_demo_close`) |
| `VOODKA_ASM_AUDIO_FAIL_DEVICE=1 VOODKA --asm-audio --scene oko-szklo` | Phase 2S deterministic assembly-device initialization failure and cleanup (CTest `audio.assembly_audio_fail_device`) |

## Troubleshooting

- **`voodka.log`** (next to the exe) is the first place to look: subsystem
  init, archive/module paths, scene changes, crash register dumps.
- Window is intentionally topmost; Alt+Tab works normally.
- `VOODKA_NOAUDIO=1` forces the headless (silent) timeline.
