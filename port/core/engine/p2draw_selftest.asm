; p2draw_selftest.asm - link-only support for the p2draw CTest.
;
; p2draw.asm is exercised in TRACE mode (vk_draw_object_trace), which never
; calls tm_face / pixel2d, but those are still referenced (relocations) so the
; object must resolve them and txtr.asm's sel_base_table. This shim provides
; the standalone selector base table (the real one lives in bridge.cpp), plus
; a standalone Code32_addr and sort scratch (addr_tab buckets over a static
; sort_mem) for pz_sort, which runs inside the traced face walk.

BITS 64
DEFAULT REL

%include "eos.inc"

section .data
; standalone selector base table (bridge.cpp's is not linked into the CTest)
global sel_base_table
sel_base_table: times 512 dq 0

; bucket base pointers (built by ts_p2draw_set_base, mirroring prep_sort)
global addr_tab
addr_tab: times 16 dq 0

section .bss
global Code32_addr
Code32_addr: resq 1
pz_sort_scratch: resd 1200*16        ; engine drawers=1200 capacity

section .text
; void ts_p2draw_set_base(uint8_t* base): point Code32_addr and the sort
; buckets at the test arena. Call before every vk_draw_object_trace.
; NOTE: rdi is NON-VOLATILE in the MS x64 ABI - preserve it (the caller keeps
; the record pointer there across this call).
global ts_p2draw_set_base
ts_p2draw_set_base:
        push    rdi
        mov     [rel Code32_addr], rcx
        lea     rax, [rel pz_sort_scratch]
        lea     rdi, [rel addr_tab]
        mov     ecx, 16
.mk:
        mov     [rdi], rax
        add     rdi, 8
        add     rax, 1200*4
        dec     ecx
        jnz     .mk
        pop     rdi
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
