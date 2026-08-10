# Phase 2 progress: dedicated assembly audio gate

Status: **Phase 2A through Phase 2I passed; live tracker-to-device swap remains**
Snapshot date: **2026-08-10**

Phase 2 is the next feasibility gate after the D3D11 presenter. The production
application still uses the C++ `audio.cpp` implementation and links the
vendored `libxmp`. Nothing in Phase 2A through 2I changes production playback.

## Phase 2A scope

The new host-only validation target is:

- [`audio_oracle.cpp`](../port/tools/validate/audio_oracle.cpp)
- CTest name: `audio.oracle`
- Generated report: `port/build/Release/audio_oracle_report.txt`

The oracle loads `music/amnezja2.mod` through the same libxmp API used by the
application and records:

- module identity, format, byte size, and libxmp MD5;
- order table, pattern lengths, rows per order-loop, and ModPos loop span;
- event population and primary/secondary effect frequencies and parameter
  ranges;
- sample lengths, loop boundaries, and flags;
- complete 44.1 kHz stereo signed-16 PCM pass hashes;
- first-second and first-ten-second PCM hashes, sample peak, nonzero count,
  and absolute-sample sum;
- replay-frame row/order/pattern transitions with timing, speed, BPM, and
  frame duration;
- a deterministic hash of the row-transition trace.

The report is generated in the build tree so it does not become a production
dependency or a checked-in binary artifact.

## Phase 2A result

`audio.oracle` passed against the checked-in module in 0.68 seconds. The
current libxmp oracle reports:

```text
module MD5             D1A711646C81CBADF31761943F90D322
module FNV-1a           0BB3E72E25172B2A
format                  Fast Tracker 14CH
initial speed/BPM       6 / 125
rows per order loop     2688
ModPos units per loop   10752
estimated duration      263429 ms
row transitions         2688
replay frames           13440
```

The module uses these primary effect families: `0x01`, `0x03`, `0x04`,
`0x06`, `0x0A`, `0x0C`, `0x0E`, and `0x0F`. The report records exact counts
and parameter ranges for each; no unsupported-effect assumption is being made
for the assembly player.

The complete 44.1 kHz, stereo, signed-16 PCM pass produced:

```text
frames                  11617219
PCM FNV-1a               1BE9D4F5B3744B32
first 1 second           479A1C61BCF3D0D9
first 10 seconds         573E47F4AD7A6E8C
nonzero samples          22764733
absolute sample sum      81713419891
peak absolute sample    32768
row trace FNV-1a         E827FA024D5B7867
```

These values are the Phase 2 reference baseline. A NASM parser/mixer must
first reproduce the module inventory and row trace, then reproduce the PCM
hashes before any WASAPI integration or production audio switch is attempted.

## Phase 2B result: NASM module parser gate

The first irreversible runtime boundary is now implemented as a native x64
NASM parser, without Windows or C runtime calls:

- [`audio_mod.asm`](../port/core/eos_replace/audio_mod.asm) parses the checked-in
  module into an immutable summary structure.
- [`audio_mod_abi.h`](../port/tools/validate/audio_mod_abi.h) defines the packed
  NASM/C++ validation ABI.
- [`audio_mod_parse_probe.cpp`](../port/tools/validate/audio_mod_parse_probe.cpp)
  compares the NASM summary with libxmp's decoded inventory.
- CTest name: `audio.mod_parse`.

The actual file is a FastTracker-family `14CH` module with a 22-byte sample
name field. Consequently, sample length/loop fields begin at sample-header
offsets `+22`, `+26`, and `+28`; using classic 20-byte-name MOD offsets would
silently corrupt the sample inventory. The parser validates:

```text
module bytes            381890
header bytes             1084
pattern data offset      1084
sample data offset       140860
sample data bytes        241030
trailing bytes           0
channels                 14
orders                   42
patterns                 39
instruments              31
rows per order loop      2688
ModPos units per loop    10752
```

It also cross-checks all order entries, pattern row counts, all 31 sample
lengths/loop boundaries/loop flags, event population counts, note/instrument/
volume counts, and primary/secondary effect counts and parameter ranges. The
probe passes against libxmp, while production `VOODKA.exe` remains unchanged
and continues to use libxmp.

This gate proves that assembly can own the module representation. It does not
yet prove tracker execution, effect semantics, sample interpolation, mixing,
or a Windows audio device backend.

## Phase 2C result: NASM tracker timing gate

The next gate is a native NASM state machine for the module timeline:

- [`audio_tracker.asm`](../port/core/eos_replace/audio_tracker.asm) walks the
  order list and rows without C, Windows, or libxmp calls.
- [`audio_tracker_abi.h`](../port/tools/validate/audio_tracker_abi.h) defines
  the packed row-transition record.
- [`audio_mod_trace_probe.cpp`](../port/tools/validate/audio_mod_trace_probe.cpp)
  compares every transition directly with `xmp_play_frame` and
  `xmp_get_frame_info`.
- CTest name: `audio.mod_trace`.

The engine reproduces the module-specific timing contract:

- 42 order positions, 64 rows per pattern, and five replay ticks per row;
- `Fxx < 0x20` changes speed and `Fxx >= 0x20` changes BPM;
- libxmp's order-start timestamp reset behavior;
- per-tick IEEE-754 double accumulation and integer truncation for elapsed
  milliseconds and frame time.

The complete comparison passes all 2,688 row transitions and all 13,440 replay
frames. The final transition is at 263,350 ms, matching the oracle trace. This
is a timing gate only: no note period, channel voice, effect state, sample
loop, interpolation, PCM mixer, thread, or WASAPI implementation is claimed.

## Phase 2D result: native event and row voice identity gates

Phase 2D establishes the first stateful audio boundary without starting the
mixer:

- [`audio_event.asm`](../port/core/eos_replace/audio_event.asm) decodes one
  packed MOD event into the eight-byte event ABI without calls into C, Windows,
  or libxmp.
- [`audio_mod_event_probe.cpp`](../port/tools/validate/audio_mod_event_probe.cpp)
  compares every packed event in the module with libxmp's decoded event.
- [`audio_voice.asm`](../port/core/eos_replace/audio_voice.asm) walks all
  2,688 chronological rows and tracks current zero-based note, instrument,
  selected sample, and sample-header volume for all 14 channels.
- [`audio_mod_voice_probe.cpp`](../port/tools/validate/audio_mod_voice_probe.cpp)
  compares row-start voice identity and row events against libxmp.
- CTest names: `audio.mod_events` and `audio.mod_voices`.

The gates pass:

```text
packed events checked       34944
row transitions checked      2688
voice states checked        37632
event decoding mismatches       0
voice identity mismatches       0
```

The implementation includes the verified libxmp compatibility rules for
period-to-note conversion, filtered `8xx`, zero-parameter continuation
rewrites, zero-based channel keys, and FT2 tone-portamento retention of the
previous base note/instrument. The voice gate deliberately does not claim
period slides, vibrato, final mixed volume/pan, retrigger position, sample
loop execution, PCM interpolation, or device output.

## Phase 2E result: native per-tick effect and sample-state gate

Phase 2E replaces the remaining tracker execution needed to reproduce the
module's visible per-channel state. It is still an offline validation target;
the production player and WASAPI path remain unchanged.

- [`audio_effects.asm`](../port/core/eos_replace/audio_effects.asm) executes
  the module's `1xx`, `3xx`, `4xx`, `5xx`, `6xx`, `Axx`, `Cxx`, `Exx`, and
  `Fxx` behavior in native x64 assembly.
- [`audio_tick_abi.h`](../port/tools/validate/audio_tick_abi.h) defines the
  packed per-channel snapshot, including logical sample position.
- [`audio_mod_tick_probe.cpp`](../port/tools/validate/audio_mod_tick_probe.cpp)
  compares every state against libxmp's `xmp_channel_info` and decoded row
  event.
- CTest name: `audio.mod_ticks`.

The complete trace passes:

```text
replay frames                 13440
channels                          14
channel states checked        188160
period mismatches                  0
pitch-bend mismatches              0
note/instrument/sample mismatches  0
volume/pan mismatches              0
event mismatches                   0
```

The implementation preserves the module-specific details that were not safe
to infer from generic MOD documentation: high-nibble volume-slide direction,
libxmp's `A0F` fine-volume-on-row-start behavior, the effective preallocated
PAL sample C4 rate of `8287`, and clamping one-shot sample positions at the
sample end. The probe contains no dependency on libxmp internals; libxmp is
used only through its public validation API.

This is a **GO** for the native offline effect/tick-state boundary. It is not
yet a GO for PCM equivalence, loop interpolation, audio threading, WASAPI, or
removing libxmp from the production target.

## Phase 2F result: native assembly PCM mixer gate

Phase 2F adds the module-specific software mixer in native x64 assembly and
compares its complete direct-tick PCM stream against the libxmp oracle:

- [`audio_pcm.asm`](../port/core/eos_replace/audio_pcm.asm) mixes the checked-in
  signed 8-bit mono MOD samples with forward loops, linear interpolation,
  stereo pan levels, integer downmix, volume ramps, anti-click discharge,
  one-shot guards, and `E9x` retrigger revival.
- [`audio_mix_abi.h`](../port/tools/validate/audio_mix_abi.h) defines the
  packed mixer entry point.
- [`audio_mod_mixer_probe.cpp`](../port/tools/validate/audio_mod_mixer_probe.cpp)
  renders the complete libxmp tick stream, runs the native mixer, and compares
  every signed-16 stereo sample.
- CTest name: `audio.mod_pcm`.

The gate passes with no temporary instrumentation or libxmp source changes:

```text
replay states                 13440
output frames             11613525
stereo samples             23227050
sample mismatches                 0
PCM FNV-1a       18C7451650A7C772
```

The final boundary fix uses the maintained double-precision source position
to decide when a loop has crossed its end, while retaining libxmp-compatible
fixed-point interpolation. This matters at a one-sample loop transition where
an integer-only boundary test produces a different PCM value. The packed tick
snapshot also carries a private mixer-volume byte so a retriggered voice can
remain bit-exact without changing the public channel-info volume contract.

This is a **GO** for the offline native tracker-plus-mixer boundary. The
production `VOODKA.exe` still uses the existing C++/libxmp audio path, so this
is not yet a GO for WASAPI integration, audio-thread lifecycle, or removing
libxmp. The Phase 2A `audio.oracle` report remains the separate
`xmp_play_buffer` capture baseline (`11617219` frames,
`1BE9D4F5B3744B32`); Phase 2F deliberately validates the direct
`xmp_play_frame` tick contract used by the assembly state ABI
(`11613525` frames, `18C7451650A7C772`). These capture contracts must be
reconciled before claiming device-level equivalence.

## Initial contract boundary

The eventual assembly player must expose the equivalent of:

```text
asm_audio_init(mod_path, sample_rate) -> status
asm_audio_shutdown()
asm_audio_play()
asm_audio_stop()
asm_audio_get_modpos() -> uint32
asm_audio_get_elapsed_us() -> uint64
asm_audio_seek_modpos(modpos) -> uint32
asm_audio_seek_ms(ms) -> uint32
asm_audio_seek_order(order) -> uint32
asm_audio_snapshot(snapshot_ptr)
```

The audio thread should publish a stable snapshot containing at least the
current order, row, loop base, and rendered frame count. The demo thread must
consume that snapshot instead of reading mutable tracker state directly.

## Known module boundary

The oracle currently requires the checked-in soundtrack inventory:

```text
bytes       381890
channels    14
orders      42
instruments 31
patterns    39
```

If the module changes, the oracle fails before an assembly implementation can
silently be tested against the wrong soundtrack. The expected inventory must
then be reviewed and deliberately updated.

## Phase 2G result: native WASAPI/COM device gate

Phase 2G proves the Windows audio API boundary without allowing C++ to own a
COM interface or audio resource:

- [`audio_wasapi_probe.asm`](../port/core/eos_replace/audio_wasapi_probe.asm)
  performs `CoInitializeEx`, `CoCreateInstance`, default endpoint selection,
  `IAudioClient` activation, exact 44.1 kHz stereo 16-bit negotiation,
  event-callback setup, start, wait, render-buffer acquisition/release, stop,
  reset, ordered COM release, event close, and `CoUninitialize`.
- [`audio_wasapi_asm_probe.cpp`](../port/tools/validate/audio_wasapi_asm_probe.cpp)
  only owns the fixed-width report and pass/fail assertions.
- CTest name: `audio.wasapi_asm_probe`.

The device gate passes on the current Windows endpoint:

```text
COM / endpoint / activation / format / initialize     S_OK
buffer size                                          2646 frames
event callback                                       delivered
GetBuffer / ReleaseBuffer                            S_OK / S_OK
Stop / Reset                                         S_OK / S_OK
format                                               PCM 44100 Hz stereo
silent render chunk                                  256 frames
repeat teardown runs                                 20/20 passed
```

This is a **GO** for direct assembly COM/WASAPI interoperability and a
**NO-GO** for the production audio switch. The audio thread, tracker-state
ownership, PCM-to-device streaming, pause/seek behavior, long-run underrun
margin, and full-demo A/V synchronization remain unproven. Production
`VOODKA.exe` remains on the C++/libxmp path.

## Phase 2H result: assembly-owned audio-thread substrate

Phase 2H proves the worker lifetime and event-driven render loop independently
of tracker state:

- [`audio_thread_probe.asm`](../port/core/eos_replace/audio_thread_probe.asm)
  creates the worker, initializes COM inside that worker, activates the exact
  PCM WASAPI stream, waits on both stop and audio events, services real render
  wakeups with silent buffers, stops/resets the client, releases COM objects,
  and returns only after cleanup.
- [`audio_thread_asm_probe.cpp`](../port/tools/validate/audio_thread_asm_probe.cpp)
  validates the fixed-width report; it owns no thread, COM apartment, or
  WASAPI interface.
- CTest name: `audio.thread_asm_probe`.

The one-second worker gate reports:

```text
worker priority                                      above normal
WASAPI event wakeups                                 91
frames serviced                                      23296
timeouts                                             0
Stop / Reset / worker exit                           S_OK / S_OK / 0
repeat lifecycle runs                                10/10 passed
```

The harness intentionally writes silence. This is a **GO** for the assembly
thread, COM-apartment, event wait, join, and teardown substrate, but a **NO-GO**
for connecting the tracker mixer or replacing production audio. Tracker state
ownership, published ModPos snapshots, PCM-to-device equivalence, pause/seek,
long-run underrun margin, and full-demo A/V synchronization remain ahead.

## Phase 2H go/no-go

**GO through the assembly-owned audio-thread substrate.** The worker owns its
COM apartment and WASAPI resources, services real callback wakeups, and joins
after ordered stop/reset/release cleanup.
**NO-GO to libxmp removal or a production assembly-audio switch yet:** the
tracker mixer has not been connected to the worker or full-demo timeline.

## Phase 2I result: native PCM-to-device handoff and timeline snapshot

Phase 2I connects the already-proven native tracker/mixer output to the
already-proven assembly-owned WASAPI worker without putting a C++ object or
library callback in the device path:

- [`audio_pcm_thread_probe.cpp`](../port/tools/validate/audio_pcm_thread_probe.cpp)
  uses the native NASM parser, tracker state tracer, and PCM mixer to render
  the complete exact signed-16 stereo stream. It builds cumulative output-frame
  tick boundaries and `(order << 8) | row` ModPos values as immutable handoff
  arrays.
- [`audio_thread_probe.asm`](../port/core/eos_replace/audio_thread_probe.asm)
  receives that bounded handoff, copies the actual interleaved stereo PCM into
  `IAudioRenderClient` buffers, and publishes the timeline only after the
  corresponding device frames have been copied. It owns the worker, COM
  apartment, WASAPI interfaces, event waits, and teardown.
- [`audio_thread_abi.h`](../port/tools/validate/audio_thread_abi.h) defines the
  fixed x64 argument/report layouts shared by the probe and NASM. The host
  validator only prepares immutable test data and checks the report.
- CTest name: `audio.pcm_thread_probe`.

The current endpoint reports:

```text
pre-rendered native PCM                         11,613,525 frames
PCM FNV-1a                                      18C7451650A7C772
tracker states                                  13,440
one-second device frames                       45,864-46,305
event wakeups                                  99-100
WASAPI HRESULTs / timeouts                     all zero
post-copy timeline snapshots                   99-100
published ModPos                               0x000A
source wraps                                   0
worker exit / Stop / Reset                     0 / S_OK / S_OK
repeat handoff runs                            10/10 passed
```

This is a **GO** for the bounded native PCM-to-WASAPI handoff, assembly buffer
copy, and post-copy timeline publication. It is deliberately still a **NO-GO**
for the production switch: the probe pre-renders the whole soundtrack, has no
live tracker state owner, and does not exercise pause, seek, scene-driven audio
selection, full-demo synchronization, or long-run ring-buffer starvation.
The production application remains on C++/libxmp.

## Next implementation slices

1. Replace the immutable pre-render with a live assembly tracker/mixer owner
   feeding a bounded PCM ring while preserving the same timeline snapshot ABI.
2. Add a side-by-side `--asm-audio` path, then compare device timing, PCM
   counters, scene boundaries, pause/seek behavior, and shutdown against the
   C++/libxmp path.
3. Only after full-demo and long-run gates pass, remove libxmp from the
   production target; retain it in host-only oracle tools until release signoff.

## Phase 2I go/no-go

**GO through the native PCM-to-device handoff.** Native NASM-generated PCM is
accepted by the assembly-owned worker, real WASAPI buffers receive it, and the
assembly worker publishes a matching post-copy ModPos snapshot with clean
repeatable teardown.
**NO-GO to live production audio or libxmp removal yet:** the current gate is
an immutable pre-rendered stream. A live ring-buffer mixer, pause/seek contract,
full-demo A/V synchronization, and long-run underrun evidence remain required.
