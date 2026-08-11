#pragma once

namespace vk {

// Keep the production title independent of all runtime state.  The build
// configuration selects whether progress.cpp may use the debug title path.
inline constexpr wchar_t kProductionWindowTitle[] =
    L"Voodka by Absence --[30th Anniversary Windows Port]--";
inline constexpr wchar_t kDebugWindowTitle[] =
    L"VOODKA (Absence 1996x - Windows x64 port)";

}  // namespace vk
