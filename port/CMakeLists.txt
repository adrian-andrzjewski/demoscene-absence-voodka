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

# Tests are registered throughout this file; enable before the first add_test.
enable_testing()

# Repo root at configure time: used only for dev-tree fallbacks (music path,
# reference data for cross-check tests). The staged bin/ output is
# self-contained and never needs it at runtime on another machine.
get_filename_component(VOODKA_REPO_ROOT "${CMAKE_SOURCE_DIR}/.." ABSOLUTE)
add_compile_definitions(VOODKA_REPO_ROOT="${VOODKA_REPO_ROOT}")

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
add_executable(world_pack tools/world_pack/world_pack.cpp)
add_executable(d3d11_shader_compile tools/validate/d3d11_shader_compile.cpp)
if(MSVC)
    target_compile_options(vodka_pack PRIVATE /W4)
    target_compile_options(tabl2nasm  PRIVATE /W4)
    target_compile_options(frames2img PRIVATE /W4)
    target_compile_options(sin_tables PRIVATE /W4)
    target_compile_options(world_pack PRIVATE /W4)
    target_compile_options(d3d11_shader_compile PRIVATE /W4)
endif()
target_link_libraries(d3d11_shader_compile PRIVATE d3dcompiler)

set(VOODKA_GENERATED_DIR "${CMAKE_BINARY_DIR}/generated")
set(VOODKA_D3D11_VS_CSO "${VOODKA_GENERATED_DIR}/voodka_present_vs.cso")
set(VOODKA_D3D11_PS_CSO "${VOODKA_GENERATED_DIR}/voodka_present_ps.cso")
file(MAKE_DIRECTORY "${VOODKA_GENERATED_DIR}")
configure_file(
    "${CMAKE_SOURCE_DIR}/core/eos_replace/d3d11_shader_paths.inc.in"
    "${VOODKA_GENERATED_DIR}/d3d11_shader_paths.inc" @ONLY)
add_custom_command(
    OUTPUT "${VOODKA_D3D11_VS_CSO}" "${VOODKA_D3D11_PS_CSO}"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${VOODKA_GENERATED_DIR}"
    COMMAND $<TARGET_FILE:d3d11_shader_compile>
            "${VOODKA_D3D11_VS_CSO}" "${VOODKA_D3D11_PS_CSO}"
    DEPENDS d3d11_shader_compile
    COMMENT "Compiling embedded D3D11 presenter shaders"
    VERBATIM)
add_custom_target(voodka_shaders DEPENDS
    "${VOODKA_D3D11_VS_CSO}" "${VOODKA_D3D11_PS_CSO}")

add_custom_command(
    OUTPUT "${VOODKA_DAT}"
    COMMAND vodka_pack "${VOODKA_MANIFEST}" "${VOODKA_DANE}" "${VOODKA_DAT}"
    DEPENDS vodka_pack "${VOODKA_MANIFEST}"
    COMMENT "Packing vodka.dat from reference DANE/ (LINKER.PAS semantics)"
)
add_custom_target(voodka_data ALL DEPENDS "${VOODKA_DAT}")

# ---- VIRTUAL viewer object archive (WORLD.PAS semantics) --------------------
set(VOODKA_WORLD_MANIFEST
    "${CMAKE_SOURCE_DIR}/../demoscene-absence-voodka-master/VIRTUAL/OBJECTS/WORLD.TXT")
set(VOODKA_WORLD "${CMAKE_SOURCE_DIR}/data/world")
add_custom_command(
    OUTPUT "${VOODKA_WORLD}"
    COMMAND world_pack "${VOODKA_WORLD_MANIFEST}" "${VOODKA_WORLD}"
    DEPENDS world_pack "${VOODKA_WORLD_MANIFEST}"
    COMMENT "Packing VIRTUAL objects/world (WORLD.PAS semantics)"
)
add_custom_target(voodka_world ALL DEPENDS "${VOODKA_WORLD}")
# golden: the repacked archive must be byte-identical to the shipped one
add_test(NAME virtual.world_golden
         COMMAND "${CMAKE_COMMAND}" -E compare_files "${VOODKA_WORLD}"
 "${CMAKE_SOURCE_DIR}/../reference/source/demoscene-absence-voodka-master/VIRTUAL/OBJECTS/WORLD")

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

# p2draw_selftest: P2 object rasterizer (p2draw.asm DrawObject /
# DrawZielonyLudek, the per-object face walk + cull + texel math). Drives
# vk_draw_object_trace over synthetic TEXTURE/PHONG objects and cross-checks
# every record {drawn,x1..y3,p1..p3} against a C++ reference.
add_library(p2draw_core_objects STATIC
    core/engine/p2draw.asm
    core/engine/p2draw_selftest.asm
    core/engine/txtr.asm
    core/engine/v2d.asm
    core/engine/persp.asm
)
target_include_directories(p2draw_core_objects PRIVATE
    "${CMAKE_SOURCE_DIR}/core/eos_replace"
    "${CMAKE_SOURCE_DIR}/core/inc"
)
add_executable(p2draw_selftest tools/validate/p2draw_selftest.cpp)
target_compile_definitions(p2draw_selftest PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(p2draw_selftest PRIVATE "${CMAKE_SOURCE_DIR}/platform")
target_link_libraries(p2draw_selftest PRIVATE p2draw_core_objects)
add_test(NAME p2draw.crosscheck COMMAND p2draw_selftest)

# p2loop_selftest: P2 per-frame render loop (p2loop.asm vk_p2_render_frame =
# CalculateVisiblating -> VirSort -> WorldKol walk -> prepare/draw dispatch).
# Drives the loop in TRACE mode over synthetic World records + synthetic
# object/type tables and cross-checks the emitted {drawn,idx,obj#} stream.
# (Real-render path links the full prepare/draw dependency set even though the
# CTest exercises only the trace branch.)
add_library(p2loop_core_objects STATIC
    core/engine/p2loop.asm
    core/engine/vvis.asm
    core/engine/cammat.asm
    core/inc/sin_tables.asm
    core/engine/mrotate.asm
    core/engine/vrot.asm
    core/engine/vprep.asm
    core/engine/p2draw.asm
    core/engine/p2draw_selftest.asm
    core/engine/txtr.asm
    core/engine/v2d.asm
    core/engine/persp.asm
)
add_dependencies(p2loop_core_objects voodka_sin)
target_include_directories(p2loop_core_objects PRIVATE
    "${CMAKE_SOURCE_DIR}/core/eos_replace"
    "${CMAKE_SOURCE_DIR}/core/inc"
)
add_executable(p2loop_selftest tools/validate/p2loop_selftest.cpp)
target_compile_definitions(p2loop_selftest PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(p2loop_selftest PRIVATE "${CMAKE_SOURCE_DIR}/platform")
target_link_libraries(p2loop_selftest PRIVATE p2loop_core_objects)
add_test(NAME p2loop.crosscheck COMMAND p2loop_selftest)


# ---- golden test: packed archive must match release EXE archive exactly -----
add_executable(golden_hash_test tools/vodka_pack/golden_hash_test.cpp)
add_test(
    NAME vodka.golden_hash
    COMMAND golden_hash_test "${VOODKA_DAT}"
)

# ---- v3d.crosscheck: real .V3D/.V3M assets decoded by the ported loader -----
add_executable(v3d_crosscheck tools/validate/v3d_crosscheck.cpp)
target_compile_definitions(v3d_crosscheck PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(v3d_crosscheck PRIVATE loader_core_objects)
add_test(NAME v3d.crosscheck COMMAND v3d_crosscheck)

# ---- tablica3.crosscheck: generated NASM tables vs original TASM tables ----
add_executable(tablica3_crosscheck tools/validate/tablica3_crosscheck.cpp)
add_test(NAME tablica3.crosscheck COMMAND tablica3_crosscheck)

# ---- pal.integrity: recovered palettes identical + 6-bit clean --------------
add_executable(pal_integrity tools/validate/pal_integrity.cpp)
add_test(NAME pal.integrity COMMAND pal_integrity)

# ---- python-based checks (skipped when no interpreter is available) ---------
find_package(Python3 COMPONENTS Interpreter QUIET)
if(Python3_Interpreter_FOUND)
    # palette recovery reproducibility (OBJ LEDATA -> committed .pal)
    add_test(NAME pal.repro
             COMMAND "${Python3_EXECUTABLE}"
                     "${CMAKE_SOURCE_DIR}/tools/validate/pal_repro_check.py")
    # P2 world-palette provenance: jjdj.pal == original CODE/P2/WORLD.P!
    # (guards the P2 palette fix: P2 must install jjdj, not vodka-37 2WORLD.PAL)
    add_test(NAME jjdj.repro
             COMMAND "${Python3_EXECUTABLE}"
                     "${CMAKE_SOURCE_DIR}/tools/validate/pal_jjdj_check.py")
    # build hygiene: 0 ADDR32 relocations in every core NASM object
    add_test(NAME build.addr32
             COMMAND "${Python3_EXECUTABLE}"
                     "${CMAKE_SOURCE_DIR}/tools/validate/audit_addr32.py"
                     "${CMAKE_BINARY_DIR}/core/voodka_core.dir/$<CONFIG>")
endif()

# ---- libxmp (vendored MOD player) ------------------------------------------
add_subdirectory("${CMAKE_SOURCE_DIR}/../modules/libxmp"
                 "${CMAKE_BINARY_DIR}/libxmp")

# Phase 2A: host-side libxmp behavioral oracle.  This remains a validation
# tool; it is deliberately not linked into the production assembly core.
add_executable(audio_oracle tools/validate/audio_oracle.cpp)
target_compile_definitions(audio_oracle PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(audio_oracle PRIVATE xmp_static)
add_test(NAME audio.oracle
         COMMAND audio_oracle
                 "${VOODKA_REPO_ROOT}/music/amnezja2.mod"
                 "${CMAKE_CURRENT_BINARY_DIR}/audio_oracle_report.txt")

add_executable(audio_mod_parse_probe tools/validate/audio_mod_parse_probe.cpp)
target_compile_definitions(audio_mod_parse_probe PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(audio_mod_parse_probe PRIVATE
    "${CMAKE_SOURCE_DIR}/tools/validate")
target_link_libraries(audio_mod_parse_probe PRIVATE xmp_static voodka_core)
add_test(NAME audio.mod_parse
         COMMAND audio_mod_parse_probe
                 "${VOODKA_REPO_ROOT}/music/amnezja2.mod")

add_executable(audio_mod_trace_probe tools/validate/audio_mod_trace_probe.cpp)
target_compile_definitions(audio_mod_trace_probe PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(audio_mod_trace_probe PRIVATE
    "${CMAKE_SOURCE_DIR}/tools/validate")
target_link_libraries(audio_mod_trace_probe PRIVATE xmp_static voodka_core)
add_test(NAME audio.mod_trace
         COMMAND audio_mod_trace_probe
                 "${VOODKA_REPO_ROOT}/music/amnezja2.mod")

add_executable(audio_mod_event_probe tools/validate/audio_mod_event_probe.cpp)
target_compile_definitions(audio_mod_event_probe PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(audio_mod_event_probe PRIVATE
    "${CMAKE_SOURCE_DIR}/tools/validate")
target_link_libraries(audio_mod_event_probe PRIVATE xmp_static voodka_core)
add_test(NAME audio.mod_events
         COMMAND audio_mod_event_probe
                 "${VOODKA_REPO_ROOT}/music/amnezja2.mod")

add_executable(audio_mod_voice_probe tools/validate/audio_mod_voice_probe.cpp)
target_compile_definitions(audio_mod_voice_probe PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(audio_mod_voice_probe PRIVATE
    "${CMAKE_SOURCE_DIR}/tools/validate")
target_link_libraries(audio_mod_voice_probe PRIVATE xmp_static voodka_core)
add_test(NAME audio.mod_voices
         COMMAND audio_mod_voice_probe
                 "${VOODKA_REPO_ROOT}/music/amnezja2.mod")

add_executable(audio_mod_tick_probe tools/validate/audio_mod_tick_probe.cpp)
target_compile_definitions(audio_mod_tick_probe PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(audio_mod_tick_probe PRIVATE
    "${CMAKE_SOURCE_DIR}/tools/validate")
target_link_libraries(audio_mod_tick_probe PRIVATE xmp_static voodka_core)
add_test(NAME audio.mod_ticks
         COMMAND audio_mod_tick_probe
                 "${VOODKA_REPO_ROOT}/music/amnezja2.mod")

add_executable(audio_mod_mixer_probe
    tools/validate/audio_mod_mixer_probe.cpp)
target_compile_definitions(audio_mod_mixer_probe PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(audio_mod_mixer_probe PRIVATE
    "${CMAKE_SOURCE_DIR}/tools/validate")
target_link_libraries(audio_mod_mixer_probe PRIVATE xmp_static voodka_core)
add_test(NAME audio.mod_pcm
         COMMAND audio_mod_mixer_probe
                 "${VOODKA_REPO_ROOT}/music/amnezja2.mod")

# Phase 2J feasibility gate: preserve the assembly mixer's anti-click/ramp
# history across deliberately irregular bounded calls. This is the continuity
# contract required before a live tracker/ring producer can replace the
# immutable Phase 2I stream.
add_executable(audio_mod_stream_probe
    tools/validate/audio_mod_stream_probe.cpp)
target_compile_definitions(audio_mod_stream_probe PRIVATE
    NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(audio_mod_stream_probe PRIVATE
    "${CMAKE_SOURCE_DIR}/tools/validate")
target_link_libraries(audio_mod_stream_probe PRIVATE voodka_core)
add_test(NAME audio.mod_stream
         COMMAND audio_mod_stream_probe
                 "${VOODKA_REPO_ROOT}/music/amnezja2.mod")

# Phase 2K feasibility gate: initialize one persistent NASM tracker context,
# emit one tick at a time, compare every internal state byte with the offline
# oracle, and pass those live states through the continuous mixer.
add_executable(audio_live_tracker_probe
    tools/validate/audio_live_tracker_probe.cpp)
target_compile_definitions(audio_live_tracker_probe PRIVATE
    NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(audio_live_tracker_probe PRIVATE
    "${CMAKE_SOURCE_DIR}/tools/validate")
target_link_libraries(audio_live_tracker_probe PRIVATE voodka_core)
add_test(NAME audio.live_tracker
         COMMAND audio_live_tracker_probe
                 "${VOODKA_REPO_ROOT}/music/amnezja2.mod")

# Phase 2L feasibility gate: run the persistent assembly tracker and
# continuous mixer in one thread, hand exact PCM plus ModPos markers through a
# bounded SPSC ring, and verify concurrent consumption without loss.
add_executable(audio_live_ring_probe
    tools/validate/audio_live_ring_probe.cpp)
target_compile_definitions(audio_live_ring_probe PRIVATE
    NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(audio_live_ring_probe PRIVATE
    "${CMAKE_SOURCE_DIR}/tools/validate")
target_link_libraries(audio_live_ring_probe PRIVATE voodka_core)
add_test(NAME audio.live_ring
         COMMAND audio_live_ring_probe
                 "${VOODKA_REPO_ROOT}/music/amnezja2.mod")

# ---- V3D asset viewer (standalone validation tool) ---------------------------
add_subdirectory(tools/asset_viewer)

# ---- platform layer + assembly core (phases >0) -----------------------------
add_subdirectory(core)
add_subdirectory(platform)

# Phase 1 feasibility gate: the host creates only a hidden HWND and COM
# apartment; the D3D11 device, COM vtable calls, GPU readback, Present, and
# Release sequence are implemented directly in NASM.
add_executable(d3d11_asm_probe tools/validate/d3d11_asm_probe.cpp)
target_compile_definitions(d3d11_asm_probe PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(d3d11_asm_probe PRIVATE
    voodka_core d3d11 dxgi ole32 user32 gdi32
)
add_test(NAME d3d11.asm_probe COMMAND d3d11_asm_probe)

add_executable(d3d11_asm_present_probe tools/validate/d3d11_asm_present_probe.cpp)
target_compile_definitions(d3d11_asm_present_probe PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(d3d11_asm_present_probe PRIVATE
    voodka_core d3d11 dxgi ole32 user32 gdi32
)
add_test(NAME d3d11.asm_present_probe COMMAND d3d11_asm_present_probe)

# Phase 2G feasibility gate: the C++ host only prints the report. NASM owns
# COM initialization, WASAPI endpoint activation, event-driven client setup,
# render-buffer acquisition/release, and ordered teardown.
add_executable(audio_wasapi_asm_probe
    tools/validate/audio_wasapi_asm_probe.cpp)
target_compile_definitions(audio_wasapi_asm_probe PRIVATE
    NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(audio_wasapi_asm_probe PRIVATE
    voodka_core ole32 kernel32)
add_test(NAME audio.wasapi_asm_probe COMMAND audio_wasapi_asm_probe)

# Phase 2H feasibility gate: the NASM worker owns its COM apartment, WASAPI
# interfaces, callback event, render loop, stop signal, and teardown. It writes
# silence until the tracker mixer is connected behind the production switch.
add_executable(audio_thread_asm_probe
    tools/validate/audio_thread_asm_probe.cpp)
target_compile_definitions(audio_thread_asm_probe PRIVATE
    NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(audio_thread_asm_probe PRIVATE
    "${CMAKE_SOURCE_DIR}/tools/validate")
target_link_libraries(audio_thread_asm_probe PRIVATE
    voodka_core ole32 kernel32)
add_test(NAME audio.thread_asm_probe COMMAND audio_thread_asm_probe)

# Phase 2I feasibility gate: the host pre-renders the exact native assembly
# tracker/mixer stream, then passes immutable PCM and tick/ModPos timing arrays
# to the assembly worker. NASM performs the signed-16 stereo device copy and
# publishes the post-copy timeline snapshot; production audio remains on the
# existing C++/libxmp path until the live handoff is proven.
add_executable(audio_pcm_thread_probe
    tools/validate/audio_pcm_thread_probe.cpp)
target_compile_definitions(audio_pcm_thread_probe PRIVATE
    NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(audio_pcm_thread_probe PRIVATE
    "${CMAKE_SOURCE_DIR}/tools/validate")
target_link_libraries(audio_pcm_thread_probe PRIVATE
    voodka_core ole32 kernel32)
add_test(NAME audio.pcm_thread_probe
         COMMAND audio_pcm_thread_probe
                 "${VOODKA_REPO_ROOT}/music/amnezja2.mod")

# Phase 2Q feasibility gate: a live NASM tracker/mixer producer feeds the
# bounded PCM/ModPos ring while the assembly-owned WASAPI worker consumes it
# under the real device clock.  The control modes additionally exercise
# ordered pause/resume and a coordinated tracker/mixer seek with a ring flush.
# Production audio remains unchanged until these gates and their long-run/
# synchronization follow-ups pass.
add_executable(audio_live_wasapi_probe
    tools/validate/audio_live_wasapi_probe.cpp)
target_compile_definitions(audio_live_wasapi_probe PRIVATE
    NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(audio_live_wasapi_probe PRIVATE
    "${CMAKE_SOURCE_DIR}/tools/validate")
target_link_libraries(audio_live_wasapi_probe PRIVATE
    voodka_core ole32 kernel32)
add_test(NAME audio.live_wasapi_probe
         COMMAND audio_live_wasapi_probe
                 "${VOODKA_REPO_ROOT}/music/amnezja2.mod")
add_test(NAME audio.live_wasapi_control
         COMMAND audio_live_wasapi_probe
                 "${VOODKA_REPO_ROOT}/music/amnezja2.mod" --control)
add_test(NAME audio.live_wasapi_seek
         COMMAND audio_live_wasapi_probe
                 "${VOODKA_REPO_ROOT}/music/amnezja2.mod" --seek)
add_test(NAME audio.live_wasapi_stress
         COMMAND audio_live_wasapi_probe
                 "${VOODKA_REPO_ROOT}/music/amnezja2.mod" --stress)
add_test(NAME audio.live_wasapi_longrun
         COMMAND audio_live_wasapi_probe
                 "${VOODKA_REPO_ROOT}/music/amnezja2.mod" --longrun)

message(STATUS "VOODKA x64 port configured. NASM: ${CMAKE_ASM_NASM_COMPILER}")
