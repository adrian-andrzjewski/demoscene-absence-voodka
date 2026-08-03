; p2draw_selftest.asm - link-only support for the p2draw CTest.
;
; p2draw.asm is exercised in TRACE mode (vk_draw_object_trace), which never
; calls tm_face / pixel2d, but those are still referenced (relocations) so the
; object must resolve them and txtr.asm's sel_base_table. This shim provides
; the standalone selector base table (the real one lives in bridge.cpp).

BITS 64
DEFAULT REL

%include "eos.inc"

section .data
; standalone selector base table (bridge.cpp's is not linked into the CTest)
global sel_base_table
sel_base_table: times 512 dq 0

section .note.GNU-stack noalloc noexec nowrite progbits
