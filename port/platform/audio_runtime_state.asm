; audio_runtime_state.asm - fixed storage for the dedicated-player Runtime.
;
; audio_asm.cpp continues to provide the transitional POD layout and state
; machine, but the backing bytes are owned by the assembly image.  The loader
; zeroes this block before either target enters its platform code.

BITS 64
DEFAULT REL

global asm_audio_runtime_state

section .bss align=64
asm_audio_runtime_state: resb 0x2000

section .note.GNU-stack noalloc noexec nowrite progbits
