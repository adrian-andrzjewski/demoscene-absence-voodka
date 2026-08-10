# Phase 2 progress: dedicated assembly audio gate

Status: **Phase 2A, Phase 2B parser, and Phase 2C timing gates passed; assembly mixer not yet started**
Snapshot date: **2026-08-10**

Phase 2 is the next feasibility gate after the D3D11 presenter. The production
application still uses the C++ `audio.cpp` implementation and links the
vendored `libxmp`. Nothing in Phase 2A, 2B, or 2C changes production playback.

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

These values are the Phase 2B acceptance baseline. A NASM parser/mixer must
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

## Next implementation slices

1. Implement native channel/note state, sample-loop handling, and a software
   tracker tick engine for offline PCM mixing, initially without WASAPI.
2. Compare complete PCM and row-transition hashes against the oracle.
3. Add a separate NASM WASAPI/COM probe, then connect the proven mixer to an
   event-driven render thread behind an `--asm-audio` switch.

## Phase 2C go/no-go

**GO to the offline mixer slice.** The oracle, NASM parser, and NASM timing
engine agree on the checked-in module and complete row-transition trace.
**NO-GO to WASAPI, libxmp removal, or a production assembly-audio switch yet:**
note/channel state, effect execution, PCM equivalence, the audio thread,
device integration, and full-demo synchronization remain unproven.
