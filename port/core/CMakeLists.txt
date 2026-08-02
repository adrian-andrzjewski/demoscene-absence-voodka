# core/CMakeLists.txt - the NASM assembly core (demo logic).

set(VOODKA_CORE_ASM
    eos_replace/eos_dispatch.asm
    eos_replace/boot.asm
)

add_library(voodka_core STATIC ${VOODKA_CORE_ASM})

# NASM include path: parts pull eos.inc via %include "eos.inc"
target_include_directories(voodka_core PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/eos_replace")
