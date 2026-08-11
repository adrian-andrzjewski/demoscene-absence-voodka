// win32_music_path_probe.cpp - production NASM soundtrack path witness.

#include <windows.h>

#include <cstring>

extern "C" const char* asm_voodka_resolve_music_path(const char* overridePath,
                                                       const char* repositoryRoot);

int main() {
    const char overridePath[] = "C:\\voodka\\override.mod";
    if (asm_voodka_resolve_music_path(overridePath, nullptr) != overridePath)
        return 1;

    const char* path = asm_voodka_resolve_music_path(nullptr, VOODKA_REPO_ROOT);
    if (!path || !path[0]) return 2;

    const DWORD attributes = GetFileAttributesA(path);
    if (attributes == INVALID_FILE_ATTRIBUTES ||
        (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0)
        return 3;

    const size_t length = std::strlen(path);
    const char suffix[] = "music\\amnezja2.mod";
    const size_t suffixLength = sizeof(suffix) - 1;
    if (length < suffixLength ||
        std::strcmp(path + length - suffixLength, suffix) != 0)
        return 4;

    const char emptyOverride[] = "";
    const char* emptyFallback =
        asm_voodka_resolve_music_path(emptyOverride, VOODKA_REPO_ROOT);
    if (!emptyFallback || !emptyFallback[0]) return 5;
    return 0;
}
