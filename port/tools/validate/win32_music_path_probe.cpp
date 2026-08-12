// win32_music_path_probe.cpp - production NASM soundtrack path witness.

#include <cstring>

extern "C" const char* asm_voodka_resolve_music_path(const char* overridePath,
                                                       const char* repositoryRoot);

int main() {
    const char overridePath[] = "C:\\voodka\\override.mod";
    if (asm_voodka_resolve_music_path(overridePath, nullptr) != overridePath)
        return 1;

    const char* path = asm_voodka_resolve_music_path(nullptr, VOODKA_REPO_ROOT);
    if (!path || std::strcmp(path, "embedded:amnezja2.mod") != 0) return 2;

    const char emptyOverride[] = "";
    const char* emptyFallback =
        asm_voodka_resolve_music_path(emptyOverride, VOODKA_REPO_ROOT);
    if (!emptyFallback || std::strcmp(emptyFallback, "embedded:amnezja2.mod") != 0)
        return 3;
    return 0;
}
