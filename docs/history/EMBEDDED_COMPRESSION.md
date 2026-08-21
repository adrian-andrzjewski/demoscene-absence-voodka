# Embedded runtime compression

The Release image stores the canonical `vodka.dat` archive and
`amnezja2.mod` soundtrack in one deterministic `VPK1` container. Each entry is
an independent XZ stream using LZMA2 at Python `lzma.PRESET_EXTREME` (preset 9)
with the CRC32 stream check. Both entries use the same freestanding XZ
Embedded decoder; there is no raw archive/module copy in the PE.

## Measured payloads

Measurements were taken from the Release inputs on 2026-08-12:

| Asset | Original | XZ/LZMA2 extreme | Ratio | Reduction |
|---|---:|---:|---:|---:|
| `vodka.dat` | 2,731,687 B | 363,028 B | 7.525:1 | 86.71% |
| `amnezja2.mod` | 381,890 B | 160,752 B | 2.376:1 | 57.89% |
| Payload streams | 3,113,577 B | 523,780 B | 5.944:1 | 83.18% |
| VPK1 container | 3,113,577 B | 523,828 B | 5.942:1 | 83.17% |

The 48-byte container header and two 16-byte entry records carry the exact
uncompressed sizes and bounded stream offsets. A single combined XZ stream is
64 bytes smaller than the two streams, but would require either a temporary
combined output buffer or a multi-call decoder with a separate dictionary. The
two-stream layout is the smaller practical runtime design because it writes
directly into the final archive and module destinations.

The build-time codec comparison used the strongest available settings:

| Candidate | Container payload | Difference from XZ |
|---|---:|---:|
| XZ/LZMA2 preset 9 extreme | 523,828 B | baseline |
| Brotli quality 11 | 534,863 B | +11,035 B |
| Zstandard level 22 | 577,039 B | +53,211 B |

Brotli and Zstandard were not added as dependencies or runtime alternatives:
their payloads are already larger before a decoder is counted, while the
selected XZ Embedded decoder is available in-tree and can be built without
the CRT, libxmp, or a second codec implementation.

## Runtime cost

The Release executable measured 897,536 B. Its file-size budget is:

| PE contribution | Raw bytes |
|---|---:|
| PE/DOS headers | 1,024 B |
| `.text` | 95,744 B |
| `.rodata` | 512 B |
| `.rdata` (compressed payload plus constants) | 530,432 B |
| `.data` raw image data | 268,288 B |
| `.pdata`, resources, relocations | 1,536 B |
| **Total** | **897,536 B** |

The standalone `voodka_xz_decoder.lib` is 24,888 B on disk. In the linked
image, the added native decoder/platform code is reflected by the `.text`
increase from 87,552 B in the raw-payload baseline to 95,744 B, plus the
512-byte `.pdata` section required by the C decoder. The compressed payload is
one PE occurrence and the raw canonical assets occur zero times.

At startup, the decoder uses a fixed 128 KiB no-CRT workspace. `vodka.dat` is
decoded directly into its existing 64 MiB arena allocation and the module is
decoded directly into its persistent 381,890-byte soundtrack buffer. There is
no uncompressed staging copy and no temporary combined asset buffer. The
additional committed image BSS is approximately 509 KiB (decoder workspace
plus module destination); the archive destination is within the pre-existing
arena.

The exactness validator measured, on the same Release machine:

| Decode | Output | Wall time |
|---|---:|---:|
| `vodka.dat` | 2,731,687 B | 57.383 ms |
| `amnezja2.mod` | 381,890 B | 16.908 ms |

These measurements are startup-only. The decoded bytes are then consumed by
the unchanged archive loaders and dedicated soundtrack player, so compression
does not alter rendering inputs, audio samples, tracker timing, A/V clocks, or
scene scheduling. `embedded.payload` proves both outputs byte-for-byte; the
arena probe proves the production loader path and teardown; the existing unit,
integration, packaged-smoke, and full-playback gates remain the behavioral
checks.

## Reduction opportunities

The implemented reduction is safe and behavior-preserving:

* Replacing the raw payload in the previous 3,478,016-byte single-file port
  with the VPK1 payload reduces the executable to 897,536 B, saving 2,580,480
  B (74.19%).
* Compared with the 3,099,592-byte original DOS executable, the modern native
  executable is 2,202,056 B smaller. This is a PE/native-runtime comparison,
  not a claim that the two formats have identical section budgets.

Further savings would require significant architectural work rather than a
safe compression switch: a raw-LZMA2 container could remove XZ framing but
would require a new bounded parser/decoder contract; a combined stream could
save roughly 40 bytes in the current container but would require changing the
direct-destination layout. Removing the decoder's exception metadata or
shrinking its workspace would need a separate toolchain/runtime audit. None of
those changes is justified by their small expected savings relative to the
fidelity and startup-risk surface.
