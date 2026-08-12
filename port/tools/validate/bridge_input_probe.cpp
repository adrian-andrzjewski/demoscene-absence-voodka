// bridge_input_probe.cpp - C ABI witness for the production key-map adapter.

#include <cstdint>
#include <cstdio>

extern "C" {
void vk_key_map_copy(uint8_t* destination);
}

namespace {
uint8_t g_source[128]{};
}

extern "C" uint8_t* asm_input_key_map() {
    return g_source;
}

extern "C" uint32_t asm_arena_load_internal_file(const char*) {
    return 0;
}

extern "C" void vk_log_printf(const char*, ...) {
}

static bool check(bool condition, const char* message) {
    if (!condition) std::fprintf(stderr, "bridge input: %s\n", message);
    return condition;
}

int main() {
    for (uint32_t i = 0; i < 128; ++i)
        g_source[i] = (i % 5 == 0) ? 0 : ((i % 3 == 0) ? 0x80 : 1);

    uint8_t destination[130]{};
    destination[0] = 0xa5;
    destination[129] = 0x5a;
    vk_key_map_copy(destination + 1);

    bool ok = true;
    for (uint32_t i = 0; i < 128; ++i) {
        const uint8_t expected = g_source[i] ? 1 : 0;
        if (destination[i + 1] != expected) {
            ok &= check(false, "nonzero key state normalizes to one");
            break;
        }
    }
    ok &= check(destination[0] == 0xa5 && destination[129] == 0x5a,
                "copy remains bounded to 128 entries");
    return ok ? 0 : 1;
}
