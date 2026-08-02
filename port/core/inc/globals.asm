; globals.asm - shared runtime globals that several parts depend on.
; Mirrors the PUBLIC/EXTRN surface of DEMO.AS^ and the shared VGA helpers:
;   _screen, _scr_Addr, _scrSel, ModPos, GetModPos,
;   framebuffer_off (presented frame arena offset),
;   _file_addr     (packed archive arena offset),
;   white          (768*63 = max-brightness palette)
;
; GetModPos: original DEMO.AS^ helper
;   mov ah,Get_Info; Int_Eos; mov al,bl; mov ModPos,ax
; This one gets the platform song position and stores it into ModPos.

BITS 64
DEFAULT REL

%include "eos.inc"

section .bss
global _screen
_screen:    resd 1
global _scr_Addr
_scr_Addr:  resd 1
global _scrSel
_scrSel:    resw 1
global ModPos
ModPos:     resw 1

; presented frame arena offset (== platform kFramebufferOffset); set by boot
global framebuffer_off
framebuffer_off: resd 1

; packed archive arena offset; set by boot (LoadFile "voodka.dat")
global _file_addr
_file_addr: resd 1

section .data align=16
; max-brightness VGA palette (768 bytes of 63) - used by every fade
global white
white:      times 768 db 63

section .text
extern eos_dispatch

global GetModPos
GetModPos:
        push    rbp
        mov     rbp, rsp
        push    rbx
        sub     rsp, 0x28
        mov     eax, EOS_GET_INFO
        call    eos_dispatch
        movzx   eax, bl
        mov     [rel ModPos], ax
        add     rsp, 0x28
        pop     rbx
        pop     rbp
        ret
