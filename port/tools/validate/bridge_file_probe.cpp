// bridge_file_probe.cpp - C ABI witness for the production file adapter.

#include <cstdint>
#include <cstdio>

extern "C" {
uint32_t vk_load_internal_file(const char* name);
}

namespace {
const char* g_lastName = nullptr;
uint32_t g_logCalls = 0;
}

extern "C" uint32_t asm_arena_load_internal_file(const char* name) {
    g_lastName = name;
    return name && name[0] == 'v' ? 0x00040000u : 0;
}

extern "C" uint8_t* asm_input_key_map() {
    static uint8_t unused[128]{};
    return unused;
}

extern "C" void vk_log_printf(const char*, ...) {
    ++g_logCalls;
}

static bool check(bool condition, const char* message) {
    if (!condition) std::fprintf(stderr, "bridge file: %s\n", message);
    return condition;
}

int main() {
    bool ok = true;
    const char valid[] = "voodka.dat";
    const char invalid[] = "missing.dat";

    ok &= check(vk_load_internal_file(valid) == 0x00040000u,
                "file offset forwards unchanged");
    ok &= check(g_lastName == valid,
                "file name pointer forwards unchanged");
    ok &= check(vk_load_internal_file(invalid) == 0,
                "failed file load forwards unchanged");
    ok &= check(g_lastName == invalid,
                "failed file name still reaches arena service");
    ok &= check(vk_load_internal_file(nullptr) == 0 && g_logCalls == 2,
                "unknown and null files retain diagnostic logging");
    return ok ? 0 : 1;
}
