; txtr_selftest.asm - MS-x64 shim over txtr.asm tm_face (register-global
; calling convention) so a C++ test can drive it. Also provides the two
; selector-base setters and the exported screen buffer.

BITS 64
DEFAULT REL

%include "eos.inc"

extern tm_face
extern fs_sel
extern gs_sel
extern x_1
extern y_1
extern x_2
extern y_2
extern x_3
extern y_3
extern p_1
extern p_2
extern p_3

section .data
; the test's screen buffer lives here; the shim points gs selector at it
global asmScr
asmScr: times 320*200 db 0
; standalone selector base table (the real one lives in bridge.cpp)
global sel_base_table
sel_base_table: times 512 dq 0

section .text

; ts_txtr_set_bases(tex, scr): store real 64-bit pointers into sel_base_table
; slot 1 and 2, then make fs_sel=1, gs_sel=2.
global ts_txtr_set_bases
ts_txtr_set_bases:
        lea     rdi, [rel sel_base_table]
        mov     [rdi + 1*8], rcx
        mov     [rdi + 2*8], rdx
        mov     dword [rel fs_sel], 1
        mov     dword [rel gs_sel], 2
        ret
; ts_txtr_set_face(x1,y1,p1, x2,y2,p2, x3,y3,p3)
global ts_txtr_set_face
ts_txtr_set_face:
        mov     [rel x_1], ecx
        mov     [rel y_1], edx
        mov     [rel p_1], r8d
        mov     [rel x_2], r9d
        ; remaining 5 args on stack: y2 @[rsp+40], p2 @[rsp+48],
        ; x3 @[rsp+56], y3 @[rsp+64], p3 @[rsp+72]
        mov     eax, [rsp+40]
        mov     [rel y_2], eax
        mov     eax, [rsp+48]
        mov     [rel p_2], eax
        mov     eax, [rsp+56]
        mov     [rel x_3], eax
        mov     eax, [rsp+64]
        mov     [rel y_3], eax
        mov     eax, [rsp+72]
        mov     [rel p_3], eax
        ret

; ts_txtr_face() - call tm_face with proper stack alignment
global ts_txtr_face
ts_txtr_face:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20
        call    tm_face
        mov     rsp, rbp
        pop     rbp
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
