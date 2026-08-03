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
add_executable(frames2img  tools/validate/frames2img.cpp)
add_executable(sin_tables tools/vodka_pack/sin_tables.cpp)
if(MSVC)
    target_compile_options(vodka_pack PRIVATE /W4)
    target_compile_options(tabl2nasm  PRIVATE /W4)
    target_compile_options(frames2img PRIVATE /W4)
    target_compile_options(sin_tables PRIVATE /W4)
endif()

add_custom_command(
    OUTPUT "${VOODKA_DAT}"
    COMMAND vodka_pack "${VOODKA_MANIFEST}" "${VOODKA_DANE}" "${VOODKA_DAT}"
    DEPENDS vodka_pack "${VOODKA_MANIFEST}"
    COMMENT "Packing vodka.dat from reference DANE/ (LINKER.PAS semantics)"
)
add_custom_target(voodka_data ALL DEPENDS "${VOODKA_DAT}")

# ---- sine tables (generated; used by the engine + MROTATE) -----------------
set(VOODKA_SIN "${CMAKE_SOURCE_DIR}/core/inc/sin_tables.asm")
add_custom_command(
    OUTPUT "${VOODKA_SIN}"
    COMMAND sin_tables
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}/core/inc"
    DEPENDS sin_tables
    COMMENT "Generating sine tables (sin + sinus)"
    VERBATIM
)
add_custom_target(voodka_sin ALL DEPENDS "${VOODKA_SIN}")

# ---- engine cross-check test ------------------------------------------------
# engine_selftest: C++ reference vs the ported NASM engine (engine.asm --
# through a small MS-x64 shim that adapts the original's register-global
# calling convention). Validates sqrt / rotate_shape / n_calc / radix sort.
add_library(engine_core_objects STATIC
    core/engine/engine.asm
    core/engine/engine_selftest.asm
    core/inc/sin_tables.asm
)
target_include_directories(engine_core_objects PRIVATE
    "${CMAKE_SOURCE_DIR}/core/eos_replace"
    "${CMAKE_SOURCE_DIR}/core/inc"
    "${CMAKE_SOURCE_DIR}/core/engine"
)
add_dependencies(engine_core_objects voodka_sin)
target_include_directories(engine_core_objects PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/core/inc")

add_executable(engine_selftest tools/validate/engine_selftest.cpp)
target_compile_definitions(engine_selftest PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(engine_selftest PRIVATE "${CMAKE_SOURCE_DIR}/platform")
target_link_libraries(engine_selftest PRIVATE engine_core_objects)
add_test(NAME engine.crosscheck COMMAND engine_selftest)

# txtr_selftest: C++ reference vs the ported texture-mapped triangle rasterizer
# (txtr.asm tm_face) through a second small shim. Compares byte-for-byte.
add_library(txtr_core_objects STATIC
    core/engine/txtr.asm
    core/engine/txtr_selftest.asm
)
target_include_directories(txtr_core_objects PRIVATE
    "${CMAKE_SOURCE_DIR}/core/eos_replace"
    "${CMAKE_SOURCE_DIR}/core/inc"
    "${CMAKE_SOURCE_DIR}/core/engine"
)
target_include_directories(txtr_core_objects PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/core/inc")

add_executable(txtr_selftest tools/validate/txtr_selftest.cpp)
target_compile_definitions(txtr_selftest PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(txtr_selftest PRIVATE "${CMAKE_SOURCE_DIR}/platform")
target_link_libraries(txtr_selftest PRIVATE txtr_core_objects)
add_test(NAME txtr.crosscheck COMMAND txtr_selftest)

# palette_range: CTest validating applyPaletteRange, the logic behind the
# bridge vk_set_palette_range / the `set_pal` macro (palette-range upload).
add_executable(palette_selftest tools/validate/palette_selftest.cpp)
target_compile_definitions(palette_selftest PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(palette_selftest PRIVATE "${CMAKE_SOURCE_DIR}/platform")
add_test(NAME palette.crosscheck COMMAND palette_selftest)

# toonel_selftest: validates vk_make_toonel, the shared 128000-byte tunnel
# table filler (used by boot's Start32 + the tunnel parts). Checks determinism
# (two fills hash identically), non-triviality, and spot u/v coordinate cells.
add_library(toonel_core_objects STATIC
    core/eos_replace/toonel.asm
)
add_dependencies(toonel_core_objects voodka_sin)
add_executable(toonel_selftest tools/validate/toonel_selftest.cpp)
target_compile_definitions(toonel_selftest PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(toonel_selftest PRIVATE "${CMAKE_SOURCE_DIR}/platform")
target_link_libraries(toonel_selftest PRIVATE toonel_core_objects)
add_test(NAME toonel.crosscheck COMMAND toonel_selftest)

# mrotate_selftest: C++ reference vs the ported fixed-point 3D rotation
# (MROTATE.PM -> mrotate.asm). Compares rotation matrices + rotated vertices
# byte-for-byte over random angles/vertices.
add_library(mrotate_core_objects STATIC
    core/engine/mrotate.asm
    core/inc/sin_tables.asm
)
add_dependencies(mrotate_core_objects voodka_sin)
target_include_directories(mrotate_core_objects PRIVATE "${CMAKE_SOURCE_DIR}/core/inc" "${CMAKE_SOURCE_DIR}/core/eos_replace")
add_executable(mrotate_selftest tools/validate/mrotate_selftest.cpp)
target_compile_definitions(mrotate_selftest PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(mrotate_selftest PRIVATE "${CMAKE_SOURCE_DIR}/platform")
target_link_libraries(mrotate_selftest PRIVATE mrotate_core_objects)
add_test(NAME mrotate.crosscheck COMMAND mrotate_selftest)


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
