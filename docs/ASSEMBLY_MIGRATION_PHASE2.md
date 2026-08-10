# Phase 2 progress: dedicated assembly audio gate

Status: **Phase 2A passed; assembly player not yet started**
Snapshot date: **2026-08-10**

Phase 2 is the next feasibility gate after the D3D11 presenter. The production
application still uses the C++ `audio.cpp` implementation and links the
vendored `libxmp`. Nothing in Phase 2A changes production playback.

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

1. Review the generated inventory and classify every effect actually used by
   this module.
2. Implement a NASM module parser and immutable sample/pattern data layout;
   cross-check it against the oracle inventory before mixing audio.
3. Implement a software tracker tick engine and offline PCM mixer, initially
   without WASAPI.
4. Compare complete PCM and row-transition hashes against the oracle.
5. Add a separate NASM WASAPI/COM probe, then connect the proven mixer to an
   event-driven render thread behind an `--asm-audio` switch.

## Phase 2A go/no-go

**GO to Phase 2B.** The oracle loads the exact module, emits stable
inventory/timing/PCM evidence, and remains independent of the production
target. **NO-GO to a production assembly-audio switch yet:** the actual NASM
player, WASAPI backend, audio thread, and full-demo equivalence remain
unproven.
