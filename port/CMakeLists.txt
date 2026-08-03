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

# cammat_selftest: C++ reference vs the ported camera-matrix builder
# (VIRTUAL.INC MakeCameraMatrix -> cammat.asm). Byte-for-byte over random eye
# angles; unused (zeroed) matrix entries verified too.
add_library(cammat_core_objects STATIC
    core/engine/cammat.asm
    core/inc/sin_tables.asm
)
add_dependencies(cammat_core_objects voodka_sin)
target_include_directories(cammat_core_objects PRIVATE "${CMAKE_SOURCE_DIR}/core/inc" "${CMAKE_SOURCE_DIR}/core/eos_replace")
add_executable(cammat_selftest tools/validate/cammat_selftest.cpp)
target_compile_definitions(cammat_selftest PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(cammat_selftest PRIVATE "${CMAKE_SOURCE_DIR}/platform")
target_link_libraries(cammat_selftest PRIVATE cammat_core_objects)
add_test(NAME cammat.crosscheck COMMAND cammat_selftest)

# persp_selftest: C++ reference vs the ported 3D->2D perspective projection
# (PERSP.PM -> persp.asm). Byte-for-byte over random vertices.
add_library(persp_core_objects STATIC
    core/engine/persp.asm
)
add_executable(persp_selftest tools/validate/persp_selftest.cpp)
target_compile_definitions(persp_selftest PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(persp_selftest PRIVATE "${CMAKE_SOURCE_DIR}/platform")
target_link_libraries(persp_selftest PRIVATE persp_core_objects)
add_test(NAME persp.crosscheck COMMAND persp_selftest)

# v2d_selftest: C++ reference vs the 2D primitives (VISIBLE.PM isVisible,
# PIXEL2D.PM Pixel2d -> v2d.asm). Byte-for-byte over random triangles/points.
add_library(v2d_core_objects STATIC
    core/engine/v2d.asm
)
add_executable(v2d_selftest tools/validate/v2d_selftest.cpp)
target_compile_definitions(v2d_selftest PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(v2d_selftest PRIVATE "${CMAKE_SOURCE_DIR}/platform")
target_link_libraries(v2d_selftest PRIVATE v2d_core_objects)
add_test(NAME v2d.crosscheck COMMAND v2d_selftest)

# normals_selftest: C++ reference vs the Phong normal generator
# (NORMALS.PM calcNormals -> normals.asm). Per-vertex normals within
# FPU tolerance; per-vertex counts exact.
add_library(normals_core_objects STATIC
    core/engine/normals.asm
)
add_executable(normals_selftest tools/validate/normals_selftest.cpp)
target_compile_definitions(normals_selftest PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(normals_selftest PRIVATE "${CMAKE_SOURCE_DIR}/platform")
target_link_libraries(normals_selftest PRIVATE normals_core_objects)
add_test(NAME normals.crosscheck COMMAND normals_selftest)

# loader_selftest: object-file parser/build (OBJECTS.PM Load_Object ->
# loader.asm) + unit-5 normals for PHONG. Links loader + normals.
add_library(loader_core_objects STATIC
    core/engine/loader.asm
    core/engine/normals.asm
)
add_executable(loader_selftest tools/validate/loader_selftest.cpp)
target_compile_definitions(loader_selftest PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(loader_selftest PRIVATE "${CMAKE_SOURCE_DIR}/platform")
target_link_libraries(loader_selftest PRIVATE loader_core_objects)
add_test(NAME loader.crosscheck COMMAND loader_selftest)

# vrot_selftest: rotation/transform glue (vr-PLE2 Transform + RotateObj ->
# vrot.asm) reusing units 1 (mrotate) + 2 (camera matrix). Transform verified
# byte-exact vs a matrix-multiply reference; RotateObj vs unit-1 directly.
add_library(vrot_core_objects STATIC
    core/engine/vrot.asm
    core/engine/mrotate.asm
    core/engine/cammat.asm
    core/inc/sin_tables.asm
)
add_dependencies(vrot_core_objects voodka_sin)
target_include_directories(vrot_core_objects PRIVATE "${CMAKE_SOURCE_DIR}/core/inc" "${CMAKE_SOURCE_DIR}/core/eos_replace")
add_executable(vrot_selftest tools/validate/vrot_selftest.cpp)
target_compile_definitions(vrot_selftest PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(vrot_selftest PRIVATE "${CMAKE_SOURCE_DIR}/platform")
target_link_libraries(vrot_selftest PRIVATE vrot_core_objects)
add_test(NAME vrot.crosscheck COMMAND vrot_selftest)

# vvis_selftest: visibility (CalculateVisiblating) + painter sort (VirSort)
# -> vvis.asm, reusing unit 2 (camera matrix/globals). Visibility exact;
# sort checked for valid permutation + ascending zet.
add_library(vvis_core_objects STATIC
    core/engine/vvis.asm
    core/engine/cammat.asm
    core/inc/sin_tables.asm
)
add_dependencies(vvis_core_objects voodka_sin)
target_include_directories(vvis_core_objects PRIVATE "${CMAKE_SOURCE_DIR}/core/inc" "${CMAKE_SOURCE_DIR}/core/eos_replace")
add_executable(vvis_selftest tools/validate/vvis_selftest.cpp)
target_compile_definitions(vvis_selftest PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(vvis_selftest PRIVATE "${CMAKE_SOURCE_DIR}/platform")
target_link_libraries(vvis_selftest PRIVATE vvis_core_objects)
add_test(NAME vvis.crosscheck COMMAND vvis_selftest)

# vprep_selftest: VR object-prepare pipeline (PrepareObjectVirtual ->
# vprep.asm) over the verified rotate/transform primitives. Verifies copy,
# angle setup, rotation, world/camera offset, transform sequencing.
add_library(vprep_core_objects STATIC
    core/engine/vprep.asm
    core/engine/vrot.asm
    core/engine/mrotate.asm
    core/engine/cammat.asm
    core/inc/sin_tables.asm
)
add_dependencies(vprep_core_objects voodka_sin)
target_include_directories(vprep_core_objects PRIVATE "${CMAKE_SOURCE_DIR}/core/inc" "${CMAKE_SOURCE_DIR}/core/eos_replace")
add_executable(vprep_selftest tools/validate/vprep_selftest.cpp)
target_compile_definitions(vprep_selftest PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(vprep_selftest PRIVATE "${CMAKE_SOURCE_DIR}/platform")
target_link_libraries(vprep_selftest PRIVATE vprep_core_objects)
add_test(NAME vprep.crosscheck COMMAND vprep_selftest)

# p2path_selftest: P2 camera-path data (TRASA!/WIDOKI) + selection logic. Parses
# the reference text tables and cross-checks the NASM data byte-exact + the
# vk_p2_camera selection over many ModPos / trasa_ruch samples.
add_library(p2path_core_objects STATIC
    core/engine/p2path.asm
)
target_include_directories(p2path_core_objects PRIVATE "${CMAKE_SOURCE_DIR}/core/data")
add_executable(p2path_selftest tools/validate/p2path_selftest.cpp)
target_compile_definitions(p2path_selftest PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(p2path_selftest PRIVATE "${CMAKE_SOURCE_DIR}/platform")
target_link_libraries(p2path_selftest PRIVATE p2path_core_objects)
add_test(NAME p2path.crosscheck COMMAND p2path_selftest)

# p2world_selftest: P2 World domain (INC/WORLD data + camera globals).
# Cross-checks the World data byte-exact and drives records through unit-8
# CalculateVisiblating against a reference (integration).
add_library(p2world_core_objects STATIC
    core/engine/p2world.asm
    core/engine/vvis.asm
    core/engine/cammat.asm
    core/inc/sin_tables.asm
)
add_dependencies(p2world_core_objects voodka_sin)
target_include_directories(p2world_core_objects PRIVATE "${CMAKE_SOURCE_DIR}/core/data" "${CMAKE_SOURCE_DIR}/core/inc" "${CMAKE_SOURCE_DIR}/core/eos_replace")
add_executable(p2world_selftest tools/validate/p2world_selftest.cpp)
target_compile_definitions(p2world_selftest PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(p2world_selftest PRIVATE "${CMAKE_SOURCE_DIR}/platform")
target_link_libraries(p2world_selftest PRIVATE p2world_core_objects)
add_test(NAME p2world.crosscheck COMMAND p2world_selftest)


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
