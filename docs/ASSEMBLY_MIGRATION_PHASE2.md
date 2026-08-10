# Phase 2 progress: dedicated assembly audio gate

Status: **Phase 2A through Phase 2V passed; default production swap remains**
Snapshot date: **2026-08-10**

Phase 2 is the next feasibility gate after the D3D11 presenter. The production
application still uses the C++ `audio.cpp` implementation and links the
vendored `libxmp`. Nothing in Phase 2A through 2L changes production playback.

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

1. Add seek/reposition commands with a coordinated ring flush and tracker/
   mixer reset, then compare every reached ModPos against the C++/libxmp path.
2. Add full-demo synchronization, long-run starvation, and teardown stress
   gates around the controlled assembly audio path.
3. Remove libxmp from the production target only after those gates pass; retain
   it in host-only oracle tools until release signoff.

## Phase 2I go/no-go

**GO through the native PCM-to-device handoff.** Native NASM-generated PCM is
accepted by the assembly-owned worker, real WASAPI buffers receive it, and the
assembly worker publishes a matching post-copy ModPos snapshot with clean
repeatable teardown.
**NO-GO to live production audio or libxmp removal yet:** the current gate is
an immutable pre-rendered stream. A live ring-buffer mixer, pause/seek contract,
full-demo A/V synchronization, and long-run underrun evidence remain required.

## Phase 2J result: bounded mixer continuity

Phase 2J removes a hidden obstacle to live production: the native mixer’s
anti-click and ramp history is no longer forced to reset at every API call.

- [`audio_pcm.asm`](../port/core/eos_replace/audio_pcm.asm) retains the
  original isolated entry point and adds
  `asm_audio_mix_tick_states_continuous`, whose seventh argument points to a
  caller-owned 224-byte history block containing four 14-channel int32 arrays.
- [`audio_mix_abi.h`](../port/tools/validate/audio_mix_abi.h) documents the
  history layout and the continuous-call ABI.
- [`audio_mod_stream_probe.cpp`](../port/tools/validate/audio_mod_stream_probe.cpp)
  feeds all native tracker states through deliberately irregular bounded
  chunks and verifies the complete output against the established PCM hash.
- CTest name: `audio.mod_stream`.

The complete stream passes through 78 chunks with boundaries ranging from one
tick to 1,024 ticks:

```text
tracker states                                  13,440
bounded chunks                                  78
output                                          11,613,525 stereo frames
PCM FNV-1a                                      18C7451650A7C772
sample mismatches                               0
production audio self-check                    PASS
```

This is a **GO** for stateful bounded assembly mixing and preservation of
anti-click/ramp continuity across chunk boundaries. It remains a **NO-GO** for
the live production switch: tracker order/row/tick state is still generated by
the offline trace entry, and no producer/consumer ring, pause/seek control, or
full-demo `--asm-audio` path exists yet. Production remains C++/libxmp.

## Phase 2J go/no-go

**GO through bounded stateful assembly mixing.** The complete native soundtrack
is sample-identical when rendered through irregular chunk boundaries, with the
caller-owned anti-click/ramp history carried between calls.
**NO-GO to a live assembly player or libxmp removal yet:** the tracker itself
still runs as an offline whole-stream trace and the WASAPI worker is not fed by
a live producer/ring.

## Phase 2K result: persistent live tracker context

Phase 2K turns the native effect/state machine into a resumable assembly API:

- [`audio_effects.asm`](../port/core/eos_replace/audio_effects.asm) exports
  `asm_audio_live_init` and `asm_audio_live_next`. Initialization validates the
  module and stores the 14 internal 80-byte channel states in a caller-owned
  context. Each `next` call resumes at the saved order, row, tick, speed, and
  BPM, emits exactly one `AudioTickState` frame, then advances the context.
- [`audio_tick_abi.h`](../port/tools/validate/audio_tick_abi.h) fixes the
  1,184-byte context layout and the live entry-point ABI.
- [`audio_live_tracker_probe.cpp`](../port/tools/validate/audio_live_tracker_probe.cpp)
  compares every byte of all 13,440 live frames against the offline oracle,
  verifies the completion sentinel, and runs the live states through the
  continuous mixer.
- CTest name: `audio.live_tracker`.

The gate reports:

```text
live tracker ticks                             13,440
state-byte mismatches                          0
completion sentinel                            correct
continuous mixer chunks                       78
PCM frames                                    11,613,525
PCM FNV-1a                                    18C7451650A7C772
```

This is a **GO** for persistent assembly tracker state and one-tick emission
equivalence. It remains a **NO-GO** for production audio: there is no bounded
SPSC ring, producer backpressure policy, pause/seek command protocol, or
assembly worker integration behind `--asm-audio` yet. Production remains
C++/libxmp.

## Phase 2K go/no-go

**GO through the persistent live tracker context.** The assembly state machine
can run incrementally for the complete module and preserve exact state and PCM
behavior across continuous mixer chunks.
**NO-GO to live WASAPI playback or libxmp removal yet:** the next feasibility
gate is feeding that ring from the assembly WASAPI worker and proving its
shutdown, underrun, pause/seek, and full-demo synchronization behavior.

## Phase 2L result: concurrent live PCM/timeline ring

Phase 2L adds the bounded handoff needed between the live tracker/mixer and the
assembly-owned device worker:

- [`audio_ring.asm`](../port/core/eos_replace/audio_ring.asm) implements a
  context-based lock-free SPSC ring for interleaved stereo PCM. It publishes
  payload bytes before its producer index, never overwrites unread frames, and
  exposes explicit close and backpressure-event counters.
- The same ABI carries a bounded timeline-marker queue containing absolute
  output-frame positions and original `(order << 8) | row` ModPos values.
- [`audio_live_ring_probe.cpp`](../port/tools/validate/audio_live_ring_probe.cpp)
  runs the persistent assembly tracker and continuous mixer in a producer
  thread, consumes the ring concurrently, verifies wrap/backpressure/close
  behavior, and checks every timeline marker.
- CTest name: `audio.live_ring`.

The gate reports:

```text
live tracker states                            13,440
PCM frames                                    11,613,525
PCM FNV-1a                                    18C7451650A7C772
timeline markers                               13,440
marker mismatches                              0
producer/consumer failures                     0
underrun events                                 0
marker overflow events                          0
repeat runs                                    10/10
```

This is a **GO** for the bounded concurrent live tracker-to-PCM/timeline
contract, including wrap-around, producer backpressure, marker ordering, and
clean closure. It remains a **NO-GO** for the production switch: the ring is
not yet the source for the assembly WASAPI worker, and pause/seek plus full-demo
A/V synchronization remain unproven. Production remains C++/libxmp.

## Phase 2M result: live ring into assembly WASAPI

Phase 2M connects the previously independent live ring and assembly worker in
a host-only feasibility target:

- `audio_thread_probe.asm` now has a ring mode. The worker calls the assembly
  ring pop/marker APIs while a WASAPI render buffer is owned, publishes the
  consumed source-frame position and latest `(order << 8) | row` marker, and
  records ring errors plus an assembly-side FNV-1a witness of the bytes copied
  into the device buffer.
- [`audio_live_wasapi_probe.cpp`](../port/tools/validate/audio_live_wasapi_probe.cpp)
  runs the persistent assembly tracker and continuous mixer in a producer
  thread, prebuffers the ring, then starts the assembly-owned COM/WASAPI worker
  under the real device clock. The producer is stopped and joined before ring
  closure.
- CTest name: `audio.live_wasapi_probe`.

The Release gate reports, across 10 direct repeats:

```text
device frames                               45,864 to 46,305
render wakeups                               99 to 100
consumed ring frames                         equal to device frames
consumed PCM FNV                             equals independent expected prefix
ModPos snapshots                             53
ring underrun events                         0
marker overflow events                       0
producer failures                             0
worker timeouts                               0
Stop/Reset/join                              clean
```

The variable ring overrun counter records bounded producer backpressure
attempts (typically about 127-128 with the one-millisecond retry policy); the
producer retries every short push and the transfer witness remains exact.
This is a **GO** for the live assembly tracker/mixer-to-assembly-WASAPI data
path and its one-second teardown boundary. It is still a **NO-GO** for the
production switch or libxmp removal: the current application has no assembly
audio command protocol, pause/seek equivalence, full-demo A/V comparison, or
long-run starvation and shutdown stress result.

## Phase 2N result: ordered pause/resume control

Phase 2N adds the first live command boundary without changing the production
audio path:

- `AudioLiveControl` is a fixed-width shared ABI containing requested state,
  request sequence, acknowledged state, and acknowledged sequence.
- `audio_thread_probe.asm` observes and acknowledges commands at an audio
  render boundary. While paused it releases silent WASAPI buffers, does not
  consume PCM or timeline markers, and resumes from the exact same ring read
  position.
- `audio_live_wasapi_probe --control` runs the producer and assembly worker on
  separate host threads so the controller can issue real pause/resume commands
  while WASAPI is active. It checks command ordering, ring-read stability,
  consumed PCM-prefix identity, ModPos publication, and clean join/teardown.
- CTest name: `audio.live_wasapi_control`.

The Release control gate passed 10/10 direct repeats:

```text
commands acknowledged                            pause=1, resume=1
pause transitions                                 2
paused device frames                              11,907 to 12,348
ring read position during pause                  stable
consumed PCM FNV                                  equals expected prefix
ring underrun / marker overflow                   0 / 0
worker timeouts / producer failures               0 / 0
final paused state                                0
clean probe and producer joins                    10/10
```

This is a **GO** for the ordered pause/resume control and its no-consumption
pause semantics. At this point it was still a **NO-GO** for seek, production
selection, and libxmp removal; Phase 2O records the subsequent seek gate.

## Phase 2O result: coordinated live seek/reposition

Phase 2O proves the first complete reposition transaction while retaining the
same assembly-owned WASAPI worker and bounded SPSC ring:

- `AudioLiveControl` now carries a requested target tick, producer
  acknowledgement, commit sequence, logical post-seek ring base, and a live
  worker-consumed-frame counter. The latter is published at each assembly ring
  pop so the controller can capture the exact pre-seek PCM boundary after the
  pause acknowledgement.
- `audio_live_wasapi_probe --seek` pauses the worker at an audio boundary,
  waits until the producer has stopped writing, flushes both PCM and marker
  cursors, commits a fresh assembly tracker and zeroed mixer history at tick
  1,024, refills the ring, and resumes the worker.
- The gate hashes the consumed stream as two exact regions: the original
  prefix before the seek and a freshly mixed native-assembly suffix beginning
  at the requested tick. It also validates post-seek ModPos markers, worker
  pause accounting, zero underruns/marker overflows, and clean joins.
- CTest name: `audio.live_wasapi_seek`.

The Release seek gate passed 10/10 direct repeats:

```text
seek target tick                                  1,024
device frames                                     143,325 to 143,766
post-seek PCM FNV                                 equals expected prefix+suffix
post-seek ModPos                                  matches native tick timeline
ring underrun / marker overflow                   0 / 0
worker timeouts / producer failures               0 / 0
pause transitions / final state                   2 / resumed
clean probe and producer joins                    10/10
```

This is a **GO** for the bounded pause, flush, tracker/mixer reposition, and
assembly-WASAPI resume transaction. It is still a **NO-GO** for production
selection and libxmp removal: full-demo scene-driven seeks, soundtrack/A/V
comparison, long-run starvation, repeated seek stress, and shutdown stress
remain to be proven.

## Phase 2P result: repeated live-seek and teardown stress

Phase 2P keeps one producer, one bounded PCM/marker ring, and one
assembly-owned WASAPI worker alive while issuing three seeks in sequence:
ticks 1,024, 4,096, and 8,192. Each transaction pauses at a render boundary,
quiesces the producer, flushes both ring cursors, resets tracker and mixer
state, refills, and resumes. The validator hashes every reached segment rather
than only the final suffix, and checks the timeline marker visible at every
pause boundary.

- Command: `audio_live_wasapi_probe --stress`.
- CTest name: `audio.live_wasapi_stress`.
- The six-second worker window exercises real device pacing, ring backpressure,
  repeated command sequencing, and orderly producer/worker teardown.

The Release stress gate passed 10/10 direct repeats:

```text
seek sequence                                      1,024 -> 4,096 -> 8,192
pause/resume transitions                           6 per run
device frames                                     284,414 to 288,855
segment PCM FNV                                   exact for every segment
segment ModPos checkpoints                         exact at every pause
ring underrun / marker overflow                   0 / 0
worker timeouts / producer failures               0 / 0
clean probe and producer joins                    10/10
```

This is a **GO** for repeated live seek sequencing, bounded ring recovery,
and the measured teardown window. It remains a **NO-GO** for the production
switch and libxmp removal until full-demo scene-driven A/V comparison,
extended starvation testing, production shutdown stress, and the final
application integration gate pass.

## Phase 2Q result: production-clock and sustained-transfer witnesses

Phase 2Q adds the evidence needed before attempting to select the assembly
player in the real demo process, without changing the production audio path:

- `VOODKA.exe --timeline <file>` records one row per rendered 70 Hz frame at
  the same `waitVbl()` choke point used by the assembly scene code. Each row
  contains the frame number, QPC time, the exact ModPos returned to the scene,
  and the current libxmp elapsed-clock value.
- `audio_live_wasapi_probe --timeline <file>` samples the assembly-owned
  WASAPI worker's consumed PCM boundary, published timeline marker, and pause
  state while the device is active. The file is a diagnostic witness only;
  it does not participate in playback.
- `audio_live_wasapi_probe --longrun` keeps the same native assembly producer,
  ring, and WASAPI worker alive for 15 seconds and validates the complete PCM
  prefix, marker transfer, no-underrun contract, and clean teardown.

The first synchronized slice passed on the Release build:

```text
production P1 timeline                          1,814 frames, clean exit
production ModPos range                         0x0000 -> 0x0400
production QPC/ModPos monotonicity              clean
assembly basic live timeline                    64 samples, 0x0009 at ~1.0 s
assembly repeated-seek timeline                 408 samples, monotonic
assembly repeated-seek underruns                0
assembly repeated-seek marker overflows         0
```

The production `audio_elapsed_us` field is deliberately informational: the
current libxmp `fi.time` value can restart at an order boundary, whereas the
monotonic ModPos and QPC fields are the synchronization contract. The first
slice therefore does not treat that legacy diagnostic field as an A/V gate.

The 15-second sustained-transfer CTest is the next repeatable starvation
baseline. This is a **GO** for adding production-clock observability and for
the sustained assembly handoff witness. It remains a **NO-GO** for selecting
assembly audio in `VOODKA.exe`: the assembly worker still needs a persistent
start/stop service ABI, the producer must be moved behind the production
audio interface, and the full eight-part run must be compared with aligned
frame/ModPos/audio evidence before libxmp can be removed.

## Phase 2R result: opt-in production assembly audio

Phase 2R moves the dedicated player behind the real application audio ABI
without changing the default libxmp path:

- `audio_thread_probe.asm` now supports an indefinite service lifetime. A
  zero-duration runtime waits for a shared stop command, while the existing
  bounded probe modes retain their original behavior.
- `audio_asm.cpp` owns the transitional host orchestration: module bytes,
  assembly tracker/mixer producer, ring storage, Win32 thread handles, and
  pause/seek commands. The PCM mixer, timeline markers, ring, WASAPI COM
  interfaces, worker lifetime, and stop path remain native assembly.
- `VOODKA.exe --asm-audio` selects this service. The normal executable still
  selects C++/libxmp unless the flag is present, so the oracle remains
  available for every comparison.
- CTest `audio.assembly_demo_p1` exercises the real demo entry path with
  assembly audio and a complete P1/P2 boundary teardown.

The Release integration evidence is:

```text
assembly P1 entry                             exit 0, 1,160,271 device frames
assembly P5 entry                             exit 0, 2,249,100 device frames
assembly full P1-P8                            exit 0, 252.3 s
assembly full timeline                         17,584 frames, 12,820 markers
assembly full underruns                         0
assembly full scene sequence                    P1, P2, P3, P5, P6, P7, P8
libxmp full P1-P8                               exit 0, 252.2 s
libxmp full timeline                            17,582 frames
scene-boundary timing delta                     <= 0.3 s in the sampled run
```

The full run is a **GO** for assembly audio as an opt-in production path:
the actual demo renders, follows the soundtrack-driven ModPos timeline,
survives later-scene entry, and tears down the producer and assembly worker
cleanly. It is not yet a **GO** for removing libxmp or declaring the final
executable assembly-only. The orchestration shim is still C++, the default
path is still libxmp, and device-level PCM capture has not yet been compared
against the libxmp live stream over the full run. The next gate is to make the
assembly service's production ABI complete and prove audio/presentation
fidelity under pause, close, device failure, and repeated full-run stress.

## Phase 2S result: lifecycle and device-failure gate

Phase 2S exercises the failure paths that determine whether the dedicated
player can survive as a production service rather than only as a successful
playback path:

- `VOODKA_ASM_AUDIO_FAIL_DEVICE=1` forces assembly audio initialization to fail
  before the ring, producer, or WASAPI worker is created. The application must
  report the failure and execute the normal idempotent teardown path.
- `--auto-pause-ms N` posts a real Space key-down/up pair after `N` ms and
  resumes one second later. This drives the same Win32 input, pause, and audio
  control path as a user pause.
- `--auto-close-ms N` posts a real `WM_CLOSE` after `N` ms. The window-close
  path must reach `shutdownAndExit`, join the assembly worker and producer, and
  exit without leaving background audio activity.
- CTest adds `audio.assembly_audio_fail_device`,
  `audio.assembly_demo_pause`, and `audio.assembly_demo_close` as repeatable
  Release gates. The existing libxmp path is not changed.

The Phase 2S evidence is:

```text
assembly forced device failure                 passed; clean init failure and teardown
assembly pause/resume P1                       exit 0; PAUSED -> RESUMED; underruns 0
assembly window close during P1                 exit 0; device frames 106,281; underruns 0
filtered Phase 2S CTest gates                  3/3 passed; 29.90 s
```

This is a **GO** for proceeding to repeated lifecycle stress and the shim
removal design. It is not yet a **GO** for deleting libxmp or the C++ audio
orchestration: the full-run live audio stream still needs an aligned fidelity
comparison, and repeated launch/close runs must be completed before the
assembly service becomes the default.

## Phase 2T result: native assembly producer service

Phase 2T removes the highest-frequency real-time loop from the C++ audio shim.
`audio_service.asm` now owns the producer thread entry and performs:

- persistent tracker initialization and per-tick advancement;
- 14-channel tick-frame validation;
- continuous assembly mixer calls with caller-owned history;
- PCM-ring backpressure and timeline-marker publication;
- pause/stop polling and the coordinated seek transaction; and
- fixed-width producer failure reporting.

The `AudioAssemblyProducerArgs` ABI is a documented 112-byte structure with
explicit pointer and scalar offsets. C++ still owns module-file loading,
offline timing preparation, vector-backed storage, Win32 thread handles, and
the controller/report wrapper. Those responsibilities remain intentionally
reversible until the native service has passed the same full-run evidence.

The Release evidence after the producer extraction is:

```text
assembly audio self-check 3 s                 exit 0; 150,822 device frames; underruns 0
assembly P1/P2 boundary                       exit 0; 1,154,097 device frames; underruns 0
assembly P5 seek/run                           exit 0; ModPos 0x1400 -> P5; underruns 0
assembly full P1-P8                            exit 0; 252.2 s; final ModPos 0x2803
assembly full scene sequence                   P1, P2, P3, P5, P6, P7, P8
assembly full device stream                    11,079,684 frames; underruns 0; 12,820 markers
full Release CTest suite                       51/51 passed; 105.83 s
```

This is a **GO** for the next shim-reduction step. It proves that moving the
real-time producer into native x64 assembly preserves the current soundtrack
clock, scene boundaries, seek behavior, and full-demo stability. It is still
a **NO-GO** for removing `audio_asm.cpp`, libxmp, or the C++ platform layer:
storage ownership, module/timeline preparation, controller lifetime, and
Windows-facing application integration remain in C++.

## Phase 2U result: assembly WASAPI worker entry

Phase 2U removes the C++ function between `CreateThread` and the assembly
WASAPI service. `asm_audio_ring_thread_entry` now adapts the one-argument
Win32 thread ABI to the existing two-record assembly probe, publishes the
fixed-width result, and returns the same status code. The C++ shim still owns
the thread handle and joins it, so this remains a reversible boundary.

The Phase 2U validation is:

```text
focused lifecycle/integration CTest               4/4 passed; 56.24 s
full Release CTest suite                          51/51 passed; 102.37 s
full P1-P8 playback                               exit 0; 252.3 s
full scene sequence                               P1, P2, P3, P5, P6, P7, P8
full device stream                                11,079,243 frames; underruns 0; 12,820 markers
full final ModPos                                 0x2803
```

This is a **GO** for moving audio storage and service-state ownership behind
the assembly ABI. It is not yet a **GO** for removing C++ handle management,
module loading, timeline preparation, or libxmp from the production build.

## Phase 2V result: assembly-owned storage and module loading

Phase 2V removes the remaining dynamic storage and file-I/O work from the
dedicated assembly-audio path. `asm_audio_service_storage_init` now runs the
complete pre-thread initialization in native x64 assembly:

- opens and reads the MOD through `CreateFileA`, `GetFileSize`, `ReadFile`, and
  `CloseHandle` using the Win64 ABI;
- validates the module with the native NASM parser;
- fills fixed assembly-owned tracker states, cumulative tick starts, ModPos and
  millisecond timelines, ring PCM/marker buffers, producer scratch, and mixer
  history; and
- publishes those buffers through the 112-byte `AudioAssemblyStorage` record.

The fixed capacities are explicit and bounded: 512 KiB for the module, 20,000
tracker frames, 4,096 row-trace entries, 16,384 PCM frames, 16,384 markers, and
65,536 producer scratch frames. C++ `audio_asm.cpp` now retains only the
descriptor, synchronization records, thread handles, and application-facing
orchestration. The default C++/libxmp path remains intact as the behavioral
oracle.

The Phase 2V validation is:

```text
focused lifecycle/integration CTest               4/4 passed; 56.17 s
full Release CTest suite                          51/51 passed; 106.49 s
full P1-P8 playback                               exit 0; 252.1 s
full scene sequence                               P1, P2, P3, P5, P6, P7, P8
full device stream                                11,079,243 frames; underruns 0; 12,820 markers
full final ModPos                                 0x2803
timeline rows                                     17,592 rendered frames
```

This is a **GO** for switching production audio selection to the dedicated
assembly player behind a reversible diagnostic/oracle option. It is also a
**GO** for removing the live path's C++ vector and module-reader ownership. It
remains a **NO-GO** for deleting libxmp or `audio.cpp` until the default-path
switch has passed the same full-run visual/audio witness and the oracle has
been retained in a reference-only validation target.
