// win32_crash_probe.cpp - synthetic witness for the production NASM crash ABI.

#include <windows.h>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <string>

extern "C" LONG WINAPI asm_voodka_crash_filter(EXCEPTION_POINTERS* ep);

namespace {
std::string g_log;

bool fail(const char* message) {
    std::fprintf(stderr, "win32 crash probe: %s\n", message);
    if (!g_log.empty()) std::fprintf(stderr, "%s", g_log.c_str());
    return false;
}
}

extern "C" void vk_log_printf(const char* fmt, ...) {
    char line[512] = {};
    va_list ap;
    va_start(ap, fmt);
    std::vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    g_log += line;
}

extern "C" void vk_shutdown_log_flush() {}

int main() {
    EXCEPTION_RECORD record{};
    CONTEXT context{};
    EXCEPTION_POINTERS pointers{&record, &context};

    record.ExceptionCode = EXCEPTION_ACCESS_VIOLATION;
    record.ExceptionAddress = reinterpret_cast<PVOID>(0x123456789ABCDEF0ull);
    context.Rax = 0x1111111111111111ull;
    context.Rbx = 0x2222222222222222ull;
    context.Rcx = 0x3333333333333333ull;
    context.Rdx = 0x4444444444444444ull;
    context.Rsi = 0x5555555555555555ull;
    context.Rdi = 0x6666666666666666ull;
    context.Rbp = 0x7777777777777777ull;
    context.Rsp = 0x8888888888888888ull;
    context.Rip = 0x9999999999999999ull;

    if (asm_voodka_crash_filter(&pointers) != EXCEPTION_CONTINUE_SEARCH)
        return fail("filter did not continue the search") ? 0 : 1;

    char expected[1024] = {};
    std::snprintf(expected, sizeof expected,
                  "[CRASH] code=0x%08x at %p\n"
                  "[CRASH] rax=%p rbx=%p rcx=%p rdx=%p\n"
                  "[CRASH] rsi=%p rdi=%p rbp=%p rsp=%p rip=%p\n",
                  record.ExceptionCode, record.ExceptionAddress,
                  reinterpret_cast<void*>(context.Rax),
                  reinterpret_cast<void*>(context.Rbx),
                  reinterpret_cast<void*>(context.Rcx),
                  reinterpret_cast<void*>(context.Rdx),
                  reinterpret_cast<void*>(context.Rsi),
                  reinterpret_cast<void*>(context.Rdi),
                  reinterpret_cast<void*>(context.Rbp),
                  reinterpret_cast<void*>(context.Rsp),
                  reinterpret_cast<void*>(context.Rip));

    if (g_log != expected) return fail("formatted output mismatch") ? 0 : 1;
    return 0;
}
