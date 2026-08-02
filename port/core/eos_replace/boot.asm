; boot.asm - assembly demo entry.  Replaces the phase-1b smoke loop.
;
; DemoStart32 (Microsoft x64 ABI):
;       int DemoStart32(void* arenaBase, uint64_t arenaSize)
;
; Flow (mirrors DEMO.AS^ start32):
;   - Code32_addr = arenaBase
;   - _file_addr = LoadFile "voodka.dat"   (packed archive arena offset)
;   - _scr_Addr  = backbuffer arena offset (== platform kBackbufferOffset)
;   - framebuffer_off = platform framebuffer offset
;   - run part sequence (today: part6 bump map, then part7 water)
;   - return 0
;
; Framebuffer/backbuffer offsets come from the platform via the bridge.

BITS 64
DEFAULT REL

%include "eos.inc"
%include "video.inc"
%include "vodka.inc"

section .text

extern vk_load_internal_file
extern vk_framebuffer_offset
extern vk_backbuffer_offset
extern Code32_addr
extern eos_dispatch

extern _scr_Addr
extern _file_addr
extern _screen
extern GetModPos
extern ModPos

extern part6
extern part7

global DemoStart32
DemoStart32:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        ; 5 pushes (40): entry RSP%16==8 -> after pushes ==0; sub 0x20 keeps 0.
        sub     rsp, 0x20

        ; preserve arenaBase (rcx = first arg) in r12 across all calls
        mov     r12, rcx
        mov     [rel Code32_addr], r12

        ; framebuffer_off = platform offset
        call    vk_framebuffer_offset
        mov     [rel framebuffer_off], eax

        ; load the packed archive (name passed via dispatch)
        lea     rdx, [rel archive_name]
        mov     eax, EOS_LOAD_INTERNAL_FILE
        call    eos_dispatch
        mov     [rel _file_addr], eax

        ; _scr_Addr = kBackbufferOffset
        call    vk_backbuffer_offset
        mov     [rel _scr_Addr], eax

        ; run the parts
        call    part6
        call    part7

        xor     eax, eax
        add     rsp, 0x20
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

section .data
archive_name: db "voodka.dat", 0

section .note.GNU-stack noalloc noexec nowrite progbits
