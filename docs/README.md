# Documentation index

VOODKA is a preservation/reconstruction project: the 1996 MS-DOS demoscene
production and its 30th Anniversary native Windows x64 port. This directory
holds the reconstruction and validation notes for the active port.

## Active reference

| Document | Topic |
| --- | --- |
| [`BUILDING.md`](BUILDING.md) | Build, run, test, and tool reference for `port/` |
| [`PORTING_NOTES.md`](PORTING_NOTES.md) | Architecture, ABI, memory model, and hard-won invariants |
| [`ASSET_FORMATS.md`](ASSET_FORMATS.md) | reconstructed binary formats and color pipeline |
| [`ASSETS.md`](ASSETS.md) | the 76-entry archive inventory |
| [`WORLD_ARCHITECTURE.md`](WORLD_ARCHITECTURE.md) | swiatynia city and torus ustep village worlds |
| [`P4_P8_SCENES.md`](P4_P8_SCENES.md) | processorek Nevosolek and nad czerwonym lampa scene reconstruction |
| [`KNOWN_DIFFERENCES.md`](KNOWN_DIFFERENCES.md) | measured port differences and validation notes |
| [`FLASH_EFFECTS.md`](FLASH_EFFECTS.md) | palette/DAC flash timing |
| [`ASSEMBLY_MIGRATION_PHASE3.md`](ASSEMBLY_MIGRATION_PHASE3.md) | migration record |
| [`RECONSTRUCTION_PLAN.md`](RECONSTRUCTION_PLAN.md) | audit conclusions, decisions, and work ledger |

## Historical records

[`history/`](history/) holds superseded migration phases and planning records
kept for provenance. They document how the current port was reached but are
not active references; the authoritative state lives in the active documents
above and the release notes in the repository root.

- `history/ASSEMBLY_MIGRATION_BASELINE.md` — Phase 0 baseline
- `history/ASSEMBLY_MIGRATION_PHASE1.md` — Phase 1 (D3D11/COM)
- `history/ASSEMBLY_MIGRATION_PHASE2.md` — Phase 2 (audio/tracker)
- `history/ASSEMBLY_MIGRATION_PLAN.md` — the migration plan and risk ledger
- `history/RELEASE_COMPLETION.md` — migration completion record
- `history/EMBEDDED_COMPRESSION.md` — VPK1/XZ runtime payload design

## Release notes

The Windows port, its visual showcase, build instructions, and changelog live
in the root [`README.md`](../README.md).