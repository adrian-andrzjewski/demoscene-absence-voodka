# Reference captures & validation data

Methodology, results, and the curated side-by-side stills for the original
(DOSBox) vs the Windows port. See `docs/KNOWN_DIFFERENCES.md` for the full
difference log and `reference/dosbox/` for the capture tooling.

## How the reference was captured

- `reference/dosbox/capture_reference.ps1` runs the original
  `reference/release/abc_voda/VOODKA.EXE` under DOSBox 0.74-3 (SB16, cycles
  max) and screenshots every 1 s (CTRL-F5) with timestamps in `shots.csv`,
  plus a ZMBV video. Full run: 261.9 s, 251 frames (in `raw/`, gitignored).
- `reference/dosbox/modtimeline.py` parses `music/amnezja2.mod` (14-channel,
  speed 5, BPM 125/128/138) into a ModPos->wall-clock CSV; the demo's scene
  thresholds are music-driven, so this maps scenes to seconds.
- `reference/dosbox/analyze_capture.py` (needs PIL+numpy) finds the
  transition candidates; each candidate was confirmed by eye.
- Port stills come from `VOODKA.exe --record` + `frames2img`.

## Scene transition measurements (original, DOSBox, wall clock)

| Scene | Original observed (s) | Module time M (s) | Port scene ModPos |
|---|---:|---:|---|
| P1 head start | ~9 (boot+precalc) | 0.0 | 0x0000 |
| P2 stadium | 28.2-30.2 | 25.6 | 0x0400 |
| P2 water phase | ~49 (port log) | ~46.4 | 0x0730 |
| P3 tunnel | 79.6-80.6 | 75.6 | 0x0C00 |
| P4 plate | 90.7-92.7 | 88.1 | 0x0E00 |
| P5 torus | 116.8-118.9 | 113.1 | 0x1200 |
| P6 bump | 185.4-187.4 | 176.1 | 0x1C00 |
| P7 water | 191.4-196.4 | 182.3 | 0x1D00 |
| P8 viewer | 216.6-217.6 | 207.3 | 0x2100 |
| end screen | 256.9-261 | 244.7 | 0x2640 |

Least-squares fit of observed-vs-module time: `W = B + M/r` with
**B ~ 0.5-3 s** (DOSBox boot + FPU precalc before the music starts) and
**r = 0.950** (the original plays the module ~5% slower than libxmp's nominal
timeline; see KNOWN_DIFFERENCES.md). All eight transitions land within
+/-1.7 s (~18 rows) of the port's scene table — i.e. **the port's
`kPartStartModPos` matches the original at sub-pattern granularity**, and the
ModPos encoding (order<<8|row) is confirmed against the original's behavior.

## Curated stills

`orig_*.png` — DOSBox captures of the original. `port_*.png` — same scenes
from the port (`--record` + `frames2img`). Pairs to compare: p1_head,
p2_stadium, p3_tunnel, p4_plate, p5_torus, p6_bump, p7_water, p8_viewer,
outro.
