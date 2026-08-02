// demo_entry.h - the boundary where the C++ app calls into the NASM core.
//
// The NASM core exposes a single C-like entry, DemoStart(), which mirrors the
// original DEMO.AS^ start32 flow (arena setup, palette, module load, part1..8
// sequence). The platform hands it the arena base so Code32_addr == arena().
//
// Until the assembly core lands (Phases 3-4), app.cpp uses this header to
// declare the symbol; a C fallback is provided by platform/app.cpp so the
// platform layer is buildable/runable standalone first.

#pragma once
#include <cstdint>

// Called once after the window + audio + arena are ready.
// Returns 0 on success. May run for minutes (the whole demo).
extern "C" int DemoStart32(uint8_t* arenaBase, uint64_t arenaSize);

// Progress hook the asm core may call; unused by default.
typedef void (*DemoProgressFn)(int part, uint32_t frame, uint32_t modpos);
extern "C" void DemoSetProgressHook(DemoProgressFn fn);
