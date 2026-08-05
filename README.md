# VOODKA (Absence, 1996) - native Windows reconstruction

A Windows 10/11 x64 reconstruction of the 1996 MS-DOS demoscene production
**VOODKA** by Absence (winner, Digital Art 1.5 democompo), built from the
original TASM sources. The demo core is a faithful NASM x64 port of the
original 32-bit assembly; a small C++ platform layer replaces DOS, the EOS
kernel, VGA, and the Sound Blaster.

## Layout

```
demoscene-absence-voodka-master/   original source tree (working mirror)
reference/source/                  byte-identical read-only mirror
reference/release/                 the shipped 1996 release (abc_voda, VOODKA.EXE)
reference/captures/                DOSBox reference captures & comparison notes
music/amnezja2.mod                 the 14-channel module the demo plays
modules/                           vendored NASM 2.16.03 + libxmp 4.6.2
port/                              the Windows x64 reconstruction
  core/      NASM demo core (eos_replace, engine, parts p1..p8)
  platform/  C++ Win32/D3D11/WASAPI layer (the EOS/DOS replacement)
  tools/     asset packer, table converters, validators, frames2img
  build.ps1  one-command VS2022 x64 build
docs/                              reconstruction documentation
```

Original and reference trees are **archival**: do not modify them. All
development happens in `port/` + `docs/`.

## Quick start

```powershell
cd port
.\build.ps1 -Config Release -Test   # build + run the 18-test suite
.\bin\Release\VOODKA.exe            # watch the demo (960x600 window, ~70 fps)
.\bin\Release\VOODKA.exe --part 5   # jump straight to a part
```

Details: **[docs/BUILDING.md](docs/BUILDING.md)**

## Documentation

- [docs/RECONSTRUCTION_PLAN.md](docs/RECONSTRUCTION_PLAN.md) - audit
  findings, decisions, phase status, open questions
- [docs/ASSETS.md](docs/ASSETS.md) - vodka.dat format, the 76-asset index
  map, recovery procedures
- [docs/PORTING_NOTES.md](docs/PORTING_NOTES.md) - architecture, ABI rules,
  memory model, case studies
- [docs/BUILDING.md](docs/BUILDING.md) - build/run/test reference
- [docs/KNOWN_DIFFERENCES.md](docs/KNOWN_DIFFERENCES.md) - port vs original
  (validation results)
- [AGENTS.md](AGENTS.md) - contributor/agent quick reference
