// arena.cpp - the single EOS-replacement memory arena + packaged archive
// loader (Load_internal_file). Everything the NASM core allocates lives on
// the "linear addresses" of this flat block; Code32_addr (a 64-bit base
// exposed to NASM) maps offset->real pointer, mirroring EOS semantics.

#include "platform_abi.h"

#if defined(VOODKA_ASSEMBLY_PLATFORM)

#include <cstddef>
#include <cstdint>

extern "C" int asm_arena_platform_init(const char* repositoryRoot);
extern "C" void asm_arena_platform_shutdown(void);
extern "C" uint8_t* asm_arena_base(void);
extern "C" uint32_t asm_arena_alloc(uint32_t bytes);
extern "C" void asm_arena_free(uint32_t offset);
extern "C" uint32_t asm_arena_load_internal_file(const char* name);
extern "C" const void* asm_arena_archive_base(void);
extern "C" uint32_t asm_arena_archive_size(void);
extern "C" const char* asm_arena_archive_path(void);

namespace vk {

const uint32_t kBackbufferOffset = 0x00010000;
const uint32_t kFramebufferOffset = 0x00020000;

uint8_t* arena() {
    return asm_arena_base();
}

bool platformInit() {
    if (!asm_arena_platform_init(VOODKA_REPO_ROOT)) return false;
    const uint32_t size = asm_arena_archive_size();
    if (size != 0) {
        logPrint("[arena] loaded archive %s (%u bytes)\n",
                 asm_arena_archive_path(), size);
        logPrint("[arena] arena ready, 64 MB, base=%p\n",
                 static_cast<void*>(arena()));
    } else {
        logPrint("[arena] warning: archive not found\n");
    }
    return true;
}

void platformShutdown() {
    asm_arena_platform_shutdown();
}

uint32_t arenaAlloc(uint32_t bytes) {
    return asm_arena_alloc(bytes);
}

void arenaFree(uint32_t offset) {
    asm_arena_free(offset);
}

uint32_t loadInternalFile(const char* name) {
    const uint32_t offset = asm_arena_load_internal_file(name);
    if (offset == 0) {
        logPrint("[arena] loadInternalFile: unknown internal file '%s'\n",
                 name ? name : "(null)");
    }
    return offset;
}

const void* archiveBytes() {
    return asm_arena_archive_base();
}

size_t archiveSize() {
    return asm_arena_archive_size();
}

}  // namespace vk

#else

#include <windows.h>
#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <string>
#include <vector>

namespace vk {

namespace {

constexpr DWORD kArenaSize = 64 * 1024 * 1024;   // 64 MB, plenty for all parts
uint8_t* g_arena = nullptr;
uint32_t g_arenaCursor = 0;
bool     g_arenaReady = false;

// ---- packaged archive (vodka.dat) -----------------------------------------
// Format (byte-identical to the shipped release, reproduced by vodka_pack):
//   [0..7999]  1000 x (offset:u32, size:u32)
//   [8000..]   concatenated files, in VODKA.TXT order
// Access is by index elsewhere; here we only resolve the outer payload by
// loading the whole archive file once and returning its arena offset. The
// inner "vodka n" indexing is done by the NASM core against _file_addr.
std::vector<uint8_t> g_archive;

bool loadArchive() {
    // search order: exe dir data/vodka.dat, exe dir vodka.dat, dev-tree copy
    wchar_t exePath[MAX_PATH] = {};
    GetModuleFileNameW(nullptr, exePath, MAX_PATH);
    std::wstring dir(exePath);
    auto slash = dir.find_last_of(L"\\/");
    if (slash != std::wstring::npos) dir = dir.substr(0, slash + 1);

    std::vector<std::wstring> c2;
    c2.push_back(dir + L"data\\vodka.dat");
    c2.push_back(dir + L"vodka.dat");
    // dev-tree fallback (configure-time repo root; ASCII-safe widening)
    std::wstring dev(VOODKA_REPO_ROOT, VOODKA_REPO_ROOT + strlen(VOODKA_REPO_ROOT));
    c2.push_back(dev + L"/port/data/vodka.dat");

    for (auto& c : c2) {
        HANDLE h = CreateFileW(c.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                               OPEN_EXISTING, 0, nullptr);
        if (h == INVALID_HANDLE_VALUE) continue;
        LARGE_INTEGER sz{};
        GetFileSizeEx(h, &sz);
        g_archive.resize((size_t)sz.QuadPart);
        DWORD rd = 0;
        ReadFile(h, g_archive.data(), (DWORD)sz.QuadPart, &rd, nullptr);
        CloseHandle(h);
        logPrint("[arena] loaded archive %S (%zu bytes)\n", c.c_str(), g_archive.size());
        return true;
    }
    return false;
}

}  // namespace

uint8_t* arena() { return g_arena; }

// The two VGA overlay regions live at FIXED arena offsets so the NASM core
// and the D3D presenter agree without further plumbing:
//   kBackbufferOffset  : offscreen render target (old "_screen")
//   kFramebufferOffset : presented 64000 bytes (old 0xA0000 VGA memory)
// We also reserve the arena head for the palette copy the presenter reads.
const uint32_t kBackbufferOffset = 0x00010000;      // 64 KiB in
const uint32_t kFramebufferOffset = 0x00020000;     // 128 KiB in

bool platformInit() {
    if (g_arenaReady) return true;
    g_arena = (uint8_t*)VirtualAlloc(nullptr, kArenaSize, MEM_RESERVE | MEM_COMMIT,
                                     PAGE_READWRITE);
    if (!g_arena) return false;
    g_arenaReady = true;
    g_arenaCursor = 0x00040000;   // keep VGA overlays + head clear
    if (!loadArchive()) logPrint("[arena] warning: archive not found\n");
    else                     logPrint("[arena] arena ready, %d MB, base=%p\n",
                                      kArenaSize >> 20, (void*)g_arena);
    return true;
}

void platformShutdown() {
    if (g_arena) {
        VirtualFree(g_arena, 0, MEM_RELEASE);
        g_arena = nullptr;
    }
    g_arenaCursor = 0;
    g_archive.clear();
    g_archive.shrink_to_fit();
    g_arenaReady = false;
}

uint32_t arenaAlloc(uint32_t bytes) {
    // align to 16 to keep the demo's movsd loops happy
    bytes = (bytes + 15) & ~15u;
    // grow arena if needed
    if (g_arenaCursor + bytes > kArenaSize) {
        logFlush();
        MessageBoxA(nullptr, "VOODKA arena exhausted; refusing to grow.",
                    "arena", MB_ICONERROR);
        ExitProcess(1);
    }
    uint32_t off = g_arenaCursor;
    memset(g_arena + off, 0, bytes);
    g_arenaCursor += bytes;
    return off;
}

void arenaFree(uint32_t) { /* arena is a bump allocator; free is a no-op */ }

uint32_t loadInternalFile(const char* name) {
    // Only the demo's outer archive "voodka.dat" is requested by name; the
    // inner 76 files are resolved by the NASM core through the vodka macro.
    if (_stricmp(name, "voodka.dat") == 0 || _stricmp(name, "vodka.dat") == 0) {
        static uint32_t cached = 0;
        if (cached) return cached;              // idempotent - one copy
        uint32_t off = arenaAlloc((uint32_t)g_archive.size()) | uint32_t{0};
        memcpy(g_arena + off, g_archive.data(), g_archive.size());
        cached = off;
        return off;
    }
    logPrint("[arena] loadInternalFile: unknown internal file '%s'\n", name);
    return 0;
}

const void* archiveBytes() { return g_archive.data(); }
size_t archiveSize() { return g_archive.size(); }

}  // namespace vk

#endif
