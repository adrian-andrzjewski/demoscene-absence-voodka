// win32_log_format_probe.cpp - differential witness for the NASM formatter.

#include <cstdarg>
#include <cstdio>
#include <cstring>

extern "C" int asm_log_format_supported(const char* fmt);
extern "C" int asm_log_vformat(char* out, unsigned capacity, const char* fmt,
                                const char* va_list_cursor);

static int formatAssembly(char* out, unsigned capacity, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    const int length = asm_log_vformat(out, capacity, fmt, ap);
    va_end(ap);
    return length;
}

int main() {
    if (!asm_log_format_supported("%d %u %ld %lu %x %08x %p %zu %llu %s\n")) {
        return 1;
    }
    if (asm_log_format_supported("%n") ||
        asm_log_format_supported("%*d") ||
        asm_log_format_supported("% d") ||
        asm_log_format_supported("%#x")) {
        return 2;
    }

    char expected[512] = {};
    char actual[512] = {};

    if (formatAssembly(actual, sizeof actual, "literal") != 7 ||
        std::strcmp(actual, "literal") != 0) {
        return 10;
    }
    if (formatAssembly(actual, sizeof actual, "%d", -17) != 3 ||
        std::strcmp(actual, "-17") != 0) {
        return 11;
    }

    std::snprintf(expected, sizeof expected,
                  "[ints] %d %u %ld %lu %x %08x %p %zu %llu %s\n",
                  -17, 42u, -123L, 456UL, 0xabc, 0x2a,
                  reinterpret_cast<void*>(0x1234), static_cast<size_t>(9876543210ull),
                  1234567890123ull, "text");
    const int n = formatAssembly(actual, sizeof actual,
                                 "[ints] %d %u %ld %lu %x %08x %p %zu %llu %s\n",
                                 -17, 42u, -123L, 456UL, 0xabc, 0x2a,
                                 reinterpret_cast<void*>(0x1234), static_cast<size_t>(9876543210ull),
                                 1234567890123ull, "text");
    if (n < 0 || std::strcmp(expected, actual) != 0 ||
        n != static_cast<int>(std::strlen(actual))) {
        return 3;
    }

    std::snprintf(expected, sizeof expected, "[text] %% %c %i %llX %S\n",
                  'Z', -9, 0xfeedbeefull, L"wide/path");
    const int m = formatAssembly(actual, sizeof actual,
                                 "[text] %% %c %i %llX %S\n",
                                 'Z', -9, 0xfeedbeefull, L"wide/path");
    if (m < 0 || std::strcmp(expected, actual) != 0 ||
        m != static_cast<int>(std::strlen(actual))) {
        return 4;
    }

    std::snprintf(expected, sizeof expected, "[flags] %+d %-8d %08d\n",
                  7, 7, -17);
    const int f = formatAssembly(actual, sizeof actual,
                                 "[flags] %+d %-8d %08d\n", 7, 7, -17);
    if (f < 0 || std::strcmp(expected, actual) != 0 ||
        f != static_cast<int>(std::strlen(actual))) {
        return 6;
    }

    if (!asm_log_format_supported("%.2f %+.0f %.3f") ||
        asm_log_format_supported("%.7f") ||
        asm_log_format_supported("%e") ||
        asm_log_format_supported("%g")) {
        return 7;
    }
    const int oneFloat = formatAssembly(actual, sizeof actual, "%.2f", 1.234);
    if (oneFloat < 0) return 70;
    std::snprintf(expected, sizeof expected, "[float] %.2f %+.0f %.3f\n",
                  1.234, -2.6, 0.9995);
    const int q = formatAssembly(actual, sizeof actual,
                                 "[float] %.2f %+.0f %.3f\n",
                                 1.234, -2.6, 0.9995);
    if (q < 0 || std::strcmp(expected, actual) != 0 ||
        q != static_cast<int>(std::strlen(actual))) {
        std::fprintf(stderr, "expected=[%s] actual=[%s] length=%d\n",
                     expected, actual, q);
        return 8;
    }

    std::snprintf(expected, sizeof expected,
                  "[pause] PAUSED  ModPos=0x%x elapsed=%.2fs toggle=%ld\n",
                  0x4u, 1.0, 1L);
    const int pause = formatAssembly(actual, sizeof actual,
                                     "[pause] PAUSED  ModPos=0x%x elapsed=%.2fs toggle=%ld\n",
                                     0x4u, 1.0, 1L);
    if (pause < 0 || std::strcmp(expected, actual) != 0 ||
        pause != static_cast<int>(std::strlen(actual))) {
        std::fprintf(stderr, "expected=[%s] actual=[%s] length=%d\n",
                     expected, actual, pause);
        return 9;
    }

    char tiny[8] = {};
    const int t = formatAssembly(tiny, sizeof tiny, "abcdefghijk");
    if (t != 7 || std::strcmp(tiny, "abcdefg") != 0) return 5;
    return 0;
}
