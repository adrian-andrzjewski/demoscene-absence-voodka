; engine_selftest.asm - MS-x64 ABI shim over the ported engine routines so a
; C++ test can drive them (engine.asm uses the original's register-global
; calling convention, not the Win64 ABI). Also provides Code32_addr + seeds it
; to a caller-supplied arena so the engine's offset+base model works standalone.
;
; Defines (MS x64):
;   void ts_set_code32(uint64_t base)
;   int  ts_sqrt(int x)                       ; eax=src, ecx=out -> returns ecx
;   void ts_prep_sort_points(uint32_t addr_tab_off, uint32_t mem_off, uint32_t faces)
;   void ts_rotate_shape(void)                 ; uses globals
;   void ts_n_calc(void)
;   void ts_sort(uint32_t val_shift_0..)       ; sorts by global sort_addr/faces

BITS 64
DEFAULT REL

%include "eos.inc"

extern sinus

section .data
; standalone definitions for the test build (the real core provides these;
; here we make the engine linkable in isolation)
global Code32_addr
Code32_addr: dq 0
global len
len: dd 0

; eos_dispatch stub (prep_sort is not exercised by the cross-check)
section .text
global eos_dispatch
eos_dispatch:
        ret

; reuse the engine's own globals
extern shape_addr
extern srot_addr
extern n_addr
extern nrot_addr
extern inc_addr
extern con_addr
extern sort_addr
extern points
extern faces
extern r_x, r_y, r_z

section .text
extern n_calc
extern rotate_shape
extern rotate_normals
extern prep_sort
extern sort
extern sqrt

section .text

global ts_set_code32
ts_set_code32:
        mov     [rel Code32_addr], rcx
        ret

global ts_sqrt
ts_sqrt:
        mov     eax, ecx
        call    sqrt
        mov     eax, ecx
        ret

; ts_n_calc at current globals
global ts_n_calc
ts_n_calc:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x28
        call    n_calc
        mov     rsp, rbp
        pop     rbp
        ret

global ts_rotate_shape
ts_rotate_shape:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x28
        call    rotate_shape
        mov     rsp, rbp
        pop     rbp
        ret

; ts_set_globals(OFFS shape, srot, n, nrot, inc, con, sort, po, fa)
global ts_set_globals
ts_set_globals:
        mov     [rel shape_addr], ecx
        mov     [rel srot_addr], edx
        mov     [rel n_addr], r8d
        mov     [rel nrot_addr], r9d
        mov     rax, [rsp+40]     ; inc
        mov     [rel inc_addr], eax
        mov     rax, [rsp+48]     ; con
        mov     [rel con_addr], eax
        mov     rax, [rsp+56]     ; sort
        mov     [rel sort_addr], eax
        mov     rax, [rsp+64]     ; points
        mov     [rel points], eax
        mov     rax, [rsp+72]     ; faces
        mov     [rel faces], eax
        ret

; ts_set_angles(x,y,z)
global ts_set_angles
ts_set_angles:
        mov     [rel r_x], cx
        mov     [rel r_y], dx
        mov     [rel r_z], r8w
        ret

; ts_set_len(v) - normal-scale constant used by n_calc normalize step
global ts_set_len
ts_set_len:
        mov     [rel len], ecx
        ret

; ts_dbg_globals() -> prints shape/srot/points/code32 via a small handler:
; not in the test path (diagnostics via CPU/regs instead)
global ts_dbgbak
ts_dbgbak:
        ret

; ts_set_sortmem(off) - point the engine's radix scratch at an arena offset
global ts_set_sortmem
ts_set_sortmem:
        extern sort_mem
        extern addr_tab
        mov     [rel sort_mem], ecx
        ; rebuild addr_tab (16 pointers spaced drawers*4) like prep_sort
        lea     rdi, [rel addr_tab]
        mov     rax, rcx
        add     rax, qword [rel Code32_addr]
        mov     ecx, 16
.ma:
        mov     [rdi], rax
        add     rdi, 8
        add     rax, 1200*4
        dec     ecx
        jnz     .ma
        ret

; ts_sort() - sort using current sort_addr/faces (4-bit radix, 4 passes)
global ts_sort
ts_sort:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x28
        call    sort
        mov     rsp, rbp
        pop     rbp
        ret
