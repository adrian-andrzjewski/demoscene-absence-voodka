// log.cpp - minimal logging: OutputDebugStringA + optional file (VOODKA.log).

#include "platform_abi.h"
#include <windows.h>
#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <cwchar>
#include <ctime>

#if defined(VOODKA_ASSEMBLY_PLATFORM)
extern "C" int asm_log_init(void);
extern "C" void asm_log_write(const char*, unsigned);
extern "C" void asm_log_flush(void);
extern "C" void asm_log_shutdown(void);
extern "C" int asm_log_format_supported(const char*);
extern "C" int asm_log_vformat(char*, unsigned, const char*, const char*);
#endif

namespace vk {

#if !defined(VOODKA_ASSEMBLY_PLATFORM)
namespace {
HANDLE g_log = INVALID_HANDLE_VALUE;
CRITICAL_SECTION g_logCs;
bool g_logInit = false;
}
#endif

void logInit() {
#if !defined(VOODKA_ASSEMBLY_PLATFORM)
    InitializeCriticalSection(&g_logCs);
    wchar_t path[MAX_PATH] = {};
    GetModuleFileNameW(nullptr, path, MAX_PATH);
    wcscpy(wcsrchr(path, L'\\') + 1, L"voodka.log");
    g_log = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                        CREATE_ALWAYS, 0, nullptr);
    g_logInit = true;
#else
    asm_log_init();
#endif
    logPrint("---- VOODKA x64 port session ----\n");
}

void logPrint(const char* fmt, ...) {
#if !defined(VOODKA_ASSEMBLY_PLATFORM)
    if (!g_logInit) return;
#endif
    char buf[2048];
    va_list ap;
    va_start(ap, fmt);
#if defined(VOODKA_ASSEMBLY_PLATFORM)
    if (asm_log_format_supported(fmt)) {
        const int length = asm_log_vformat(buf, sizeof buf, fmt, ap);
        va_end(ap);
        if (length >= 0) {
            asm_log_write(buf, static_cast<unsigned>(length));
            return;
        }
        va_start(ap, fmt);
    }
#endif
    std::vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
#if !defined(VOODKA_ASSEMBLY_PLATFORM)
    if (g_log != INVALID_HANDLE_VALUE) {
        EnterCriticalSection(&g_logCs);
        DWORD wr = 0;
        WriteFile(g_log, buf, (DWORD)std::strlen(buf), &wr, nullptr);
        LeaveCriticalSection(&g_logCs);
    }
#else
    asm_log_write(buf, static_cast<unsigned>(std::strlen(buf)));
#endif
}

void logFlush() {
#if !defined(VOODKA_ASSEMBLY_PLATFORM)
    if (g_log != INVALID_HANDLE_VALUE) {
        FlushFileBuffers(g_log);
    }
#else
    asm_log_flush();
#endif
}

void logShutdown() {
#if !defined(VOODKA_ASSEMBLY_PLATFORM)
    if (!g_logInit) return;
    logFlush();
    if (g_log != INVALID_HANDLE_VALUE) CloseHandle(g_log);
    g_log = INVALID_HANDLE_VALUE;
    g_logInit = false;
    DeleteCriticalSection(&g_logCs);
#else
    asm_log_shutdown();
#endif
}

}  // namespace vk
