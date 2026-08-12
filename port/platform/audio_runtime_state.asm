; audio_runtime_state.asm - fixed storage for the dedicated-player Runtime.
;
; The public C++ ABI view is described by audio_controller_abi.h; assembly
; lifecycle/controller/seek services own the block in the shipped target. The
; loader zeroes this block before either target enters its platform code.

BITS 64
DEFAULT REL

global asm_audio_runtime_state

section .bss align=64
asm_audio_runtime_state: resb 0x2000

section .note.GNU-stack noalloc noexec nowrite progbits
