// production_entry.cpp - minimal CRT-owned WinMain handoff.
//
// The shipped host itself is native x64 assembly in win32_app_host.asm. This
// shim remains only because the current target still uses the CRT entrypoint
// while other platform services are being migrated; the reference executable
// keeps the full C++ app.cpp lifecycle as its behavioral oracle.

#include <windows.h>

extern "C" int asm_voodka_winmain(HINSTANCE, HINSTANCE, LPSTR, int);

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR lpCmd, int nCmdShow) {
    return asm_voodka_winmain(hInst, hPrev, lpCmd, nCmdShow);
}
