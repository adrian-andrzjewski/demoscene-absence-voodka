# core/CMakeLists.txt - the NASM assembly core (demo logic).

set(VOODKA_CORE_ASM
    eos_replace/eos_dispatch.asm
    eos_replace/audio_mod.asm
    eos_replace/audio_tracker.asm
    eos_replace/audio_event.asm
    eos_replace/audio_voice.asm
    eos_replace/audio_effects.asm
    eos_replace/audio_pcm.asm
    eos_replace/audio_ring.asm
    eos_replace/audio_wasapi_probe.asm
    eos_replace/audio_thread_probe.asm
    eos_replace/d3d11_asm_probe.asm
    eos_replace/d3d11_asm_present.asm
    eos_replace/boot.asm
    eos_replace/toonel.asm
    inc/globals.asm
    inc/sin_tables.asm
    engine/engine.asm
    engine/txtr.asm
    engine/persp.asm
    engine/v2d.asm
    engine/mrotate.asm
    engine/vrot.asm
    engine/cammat.asm
    engine/vvis.asm
    engine/normals.asm
    engine/loader.asm
    engine/vprep.asm
    engine/p2path.asm
    engine/p2world.asm
    engine/p2draw.asm
    engine/p2loop.asm
    parts/p1.asm
    parts/p2.asm
    parts/p3.asm
    parts/p4.asm
    parts/p5.asm
    parts/p6.asm
    parts/p7.asm
    parts/p8.asm
  )

add_library(voodka_core STATIC ${VOODKA_CORE_ASM})

# NASM does not emit dependency edges for INCBIN payloads. Keep P4's embedded
# palette inputs visible to the build graph so a palette correction is picked
# up by an incremental build as well as a clean rebuild.
set_source_files_properties(parts/p4.asm PROPERTIES
    OBJECT_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/parts/sw.pal;${CMAKE_CURRENT_SOURCE_DIR}/parts/v_txr1.pal;${CMAKE_CURRENT_SOURCE_DIR}/parts/proc.pal;${CMAKE_CURRENT_SOURCE_DIR}/parts/metal.pal")

# NASM include paths
target_include_directories(voodka_core PUBLIC
    "${VOODKA_GENERATED_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}/eos_replace"
    "${CMAKE_CURRENT_SOURCE_DIR}/inc"
    "${CMAKE_CURRENT_SOURCE_DIR}/parts"
    "${CMAKE_CURRENT_SOURCE_DIR}/engine"
    "${CMAKE_CURRENT_SOURCE_DIR}/data"
)

# sine tables are generated at configure->build time before assembling
add_dependencies(voodka_core voodka_sin)
add_dependencies(voodka_core voodka_shaders)
