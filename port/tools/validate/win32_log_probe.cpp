// win32_log_probe.cpp - direct witness for the production NASM log sink.

#include <windows.h>
#include <cstdio>
#include <string>

extern "C" int asm_log_init(void);
extern "C" void asm_log_write(const char* bytes, unsigned length);
extern "C" void asm_log_flush(void);
extern "C" void asm_log_shutdown(void);

int main() {
    if (!asm_log_init()) return 1;
    static constexpr char marker[] = "[win32_log_probe] assembly sink\n";
    asm_log_write(marker, static_cast<unsigned>(sizeof(marker) - 1));
    asm_log_flush();
    asm_log_shutdown();

    wchar_t module[MAX_PATH] = {};
    DWORD length = GetModuleFileNameW(nullptr, module, MAX_PATH);
    if (!length) return 2;
    std::wstring path(module, module + length);
    const size_t slash = path.find_last_of(L"\\/");
    if (slash == std::wstring::npos) path.clear();
    else path.resize(slash + 1);
    path += L"voodka.log";

    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
                              nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                              nullptr);
    if (file == INVALID_HANDLE_VALUE) return 3;
    const DWORD size = GetFileSize(file, nullptr);
    std::string contents(size, '\0');
    DWORD read = 0;
    const BOOL ok = ReadFile(file, contents.data(), size, &read, nullptr);
    CloseHandle(file);
    if (!ok || read != size) return 4;
    return contents.find(marker) == std::string::npos ? 5 : 0;
}
