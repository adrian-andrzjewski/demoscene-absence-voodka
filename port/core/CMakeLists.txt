# core/CMakeLists.txt - the NASM assembly core (demo logic).

set(VOODKA_CORE_ASM
    eos_replace/eos_dispatch.asm
    eos_replace/boot.asm
    inc/globals.asm
    inc/sin_tables.asm
    engine/engine.asm
    parts/p6.asm
    parts/p7.asm
)

add_library(voodka_core STATIC ${VOODKA_CORE_ASM})

# NASM include paths
target_include_directories(voodka_core PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/eos_replace"
    "${CMAKE_CURRENT_SOURCE_DIR}/inc"
    "${CMAKE_CURRENT_SOURCE_DIR}/parts"
    "${CMAKE_CURRENT_SOURCE_DIR}/engine"
)

# sine tables are generated at configure->build time before assembling
add_dependencies(voodka_core voodka_sin)
