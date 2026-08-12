// bridge_log_probe.cpp - production variadic log bridge witness.

#include <cstdint>
#include <cstdio>
#include <cstring>

extern "C" void vk_log_printf(const char* fmt, ...);

namespace {
char g_output[512]{};
uint32_t g_writes = 0;
}

extern "C" void asm_log_write(const char* text, uint32_t length) {
    ++g_writes;
    if (length >= sizeof g_output) length = sizeof g_output - 1;
    std::memcpy(g_output, text, length);
    g_output[length] = 0;
}

static bool check(bool condition, const char* message) {
    if (!condition) std::fprintf(stderr, "bridge log: %s\n", message);
    return condition;
}

int main() {
    vk_log_printf("bridge:%d %s %08x %llu %d %d\n",
                  -17, "text", 0x2a,
                  0x123456789abcdef0ull, 41, 42);

    const char expected[] =
        "bridge:-17 text 0000002a 1311768467463790320 41 42\n";
    bool ok = check(g_writes == 1, "formatted record reaches sink once");
    ok &= check(std::strcmp(g_output, expected) == 0,
                "register and fifth/sixth stack varargs format exactly");
    return ok ? 0 : 1;
}
