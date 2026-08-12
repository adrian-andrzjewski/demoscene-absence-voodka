// demo_entry.h - the boundary where the C++ app calls into the NASM core.
//
// The NASM core exposes a single C-like entry, DemoStart32(), which mirrors
// the original DEMO.AS^ start32 flow (arena setup, palette, module load,
// part1..8 sequence). The platform hands it the arena base so
// Code32_addr == arena().

#pragma once
#include <cstdint>

// Called once after the window + audio + arena are ready.
// Returns 0 on success. May run for minutes (the whole demo).
extern "C" int DemoStart32(uint8_t* arenaBase, uint64_t arenaSize);

// Progress hook the asm core may call; unused by default.
typedef void (*DemoProgressFn)(int part, uint32_t frame, uint32_t modpos);
extern "C" void DemoSetProgressHook(DemoProgressFn fn);
