cmake_minimum_required(VERSION 3.24)

# =============================================================================
# VOODKA - native Windows x64 port of the 1990s Absence demoscene demo.
# Builds with Visual Studio 2022 (or 2026). Pure assembly core (NASM x64) +
# C++ Windows integration layer. Everything is vendored under modules/.
# =============================================================================

project(VOODKA LANGUAGES C CXX ASM_NASM)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT WIN32)
    message(FATAL_ERROR "VOODKA port currently targets Windows only (Win32 x64).")
endif()

# ---- vendored toolchain -----------------------------------------------------
set(VOODKA_NASM_BIN "${CMAKE_SOURCE_DIR}/../modules/nasm/nasm.exe")
if(EXISTS "${VOODKA_NASM_BIN}")
    set(CMAKE_ASM_NASM_COMPILER "${VOODKA_NASM_BIN}")
else()
    set(CMAKE_ASM_NASM_COMPILER "nasm" CACHE FILEPATH "NASM executable")
endif()

# ---- output layout ----------------------------------------------------------
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/bin")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/bin")
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/bin")

# ---- data asset generation (reproduces the original vodka.dat) --------------
set(VOODKA_DANE "${CMAKE_SOURCE_DIR}/../demoscene-absence-voodka-master/CODE/LINKER/DANE")
set(VOODKA_DANE_REF "${CMAKE_SOURCE_DIR}/../reference/source/demoscene-absence-voodka-master/CODE/LINKER/DANE")
set(VOODKA_MANIFEST "${CMAKE_SOURCE_DIR}/../demoscene-absence-voodka-master/CODE/LINKER/VODKA.TXT")
set(VOODKA_DAT "${CMAKE_SOURCE_DIR}/data/vodka.dat")

add_executable(vodka_pack tools/vodka_pack/vodka_pack.cpp)
add_executable(tabl2nasm  tools/vodka_pack/tabl2nasm.cpp)
if(MSVC)
    target_compile_options(vodka_pack PRIVATE /W4)
    target_compile_options(tabl2nasm  PRIVATE /W4)
endif()

add_custom_command(
    OUTPUT "${VOODKA_DAT}"
    COMMAND vodka_pack "${VOODKA_MANIFEST}" "${VOODKA_DANE}" "${VOODKA_DAT}"
    DEPENDS vodka_pack "${VOODKA_MANIFEST}"
    COMMENT "Packing vodka.dat from reference DANE/ (LINKER.PAS semantics)"
)
add_custom_target(voodka_data ALL DEPENDS "${VOODKA_DAT}")

# ---- golden test: packed archive must match release EXE archive exactly -----
enable_testing()
add_executable(golden_hash_test tools/vodka_pack/golden_hash_test.cpp)
add_test(
    NAME vodka.golden_hash
    COMMAND golden_hash_test "${VOODKA_DAT}"
)

# ---- libxmp (vendored MOD player) ------------------------------------------
add_subdirectory("${CMAKE_SOURCE_DIR}/../modules/libxmp"
                 "${CMAKE_BINARY_DIR}/libxmp")

# ---- platform layer + assembly core (phases >0) -----------------------------
add_subdirectory(core)
add_subdirectory(platform)

message(STATUS "VOODKA x64 port configured. NASM: ${CMAKE_ASM_NASM_COMPILER}")
