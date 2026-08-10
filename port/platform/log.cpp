// log.cpp - minimal logging: OutputDebugStringA + optional file (VOODKA.log).

#include "platform_abi.h"
#include <windows.h>
#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <cwchar>
#include <ctime>

namespace vk {

namespace {
HANDLE g_log = INVALID_HANDLE_VALUE;
CRITICAL_SECTION g_logCs;
bool g_logInit = false;
}

void logInit() {
    InitializeCriticalSection(&g_logCs);
    wchar_t path[MAX_PATH] = {};
    GetModuleFileNameW(nullptr, path, MAX_PATH);
    wcscpy(wcsrchr(path, L'\\') + 1, L"voodka.log");
    g_log = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                        CREATE_ALWAYS, 0, nullptr);
    g_logInit = true;
    logPrint("---- VOODKA x64 port session ----\n");
}

void logPrint(const char* fmt, ...) {
    if (!g_logInit) return;
    char buf[2048];
    va_list ap;
    va_start(ap, fmt);
    std::vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (g_log != INVALID_HANDLE_VALUE) {
        EnterCriticalSection(&g_logCs);
        DWORD wr = 0;
        WriteFile(g_log, buf, (DWORD)std::strlen(buf), &wr, nullptr);
        LeaveCriticalSection(&g_logCs);
    }
}

void logFlush() {
    if (g_log != INVALID_HANDLE_VALUE) {
        FlushFileBuffers(g_log);
    }
}

void logShutdown() {
    if (!g_logInit) return;
    logFlush();
    if (g_log != INVALID_HANDLE_VALUE) CloseHandle(g_log);
    g_log = INVALID_HANDLE_VALUE;
    g_logInit = false;
    DeleteCriticalSection(&g_logCs);
}

}  // namespace vk
