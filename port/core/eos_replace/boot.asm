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
extern _scrSel
extern _file_addr
extern _screen
extern GetModPos
extern ModPos

; shared tunnel tables (DEMO.AS^): _tableToonel arena offset, filled by the
; standalone vk_make_toonel (toonel.asm) at Start32 time.
global _tableToonel
section .bss
_tableToonel: resd 1
section .text
extern vk_make_toonel

extern part1
extern part2
extern part3
extern part5
extern part6
extern part7
extern part8

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

        ; _scrSel = selector over the backbuffer (DEMO.AS^ allocates the
        ; screen selector at Start32; P1/P5/P8 read _scrSel for gs_sel).
        ; Without this, standalone parts (--part N) inherit gs_sel=0 and
        ; tm_face writes to a null screen base.
        mov     eax, EOS_ALLOCATE_SELECTOR
        mov     esi, [rel _scr_Addr]
        add     rsi, qword [rel Code32_addr]
        mov     edi, 320*200
        call    eos_dispatch
        mov     [rel _scrSel], ax

        ; shared tunnel tables (built once in Start32, used by the tunnel parts)
        ; _tableToonel = 128000-byte arena table: u/v coordinates for 320x200.
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, 128000
        call    eos_dispatch
        mov     [rel _tableToonel], edx
        mov     rcx, rdx
        add     rcx, qword [rel Code32_addr]   ; real 128000-byte arena buffer
        call    vk_make_toonel

        ; ---- run the selected scene ----------------------------------------
        ; vk_get_entry_part(): 0 = full part1..part8 sequence (default),
        ; 1..8 = run only that part. Parts present are driven by the audio
        ; timeline (GetModPos), which the app has already seeked to the part's
        ; start via --part / --modpos / --ms / --order.
        extern vk_get_entry_part
        call    vk_get_entry_part

        cmp     eax, 0
        je      .full_sequence
        cmp     eax, 1
        je      .single_p1
        cmp     eax, 2
        je      .single_p2
        cmp     eax, 3
        je      .single_p3
        cmp     eax, 5
        je      .single_p5
        cmp     eax, 6
        je      .single_p6
        cmp     eax, 7
        je      .single_p7
        cmp     eax, 8
        je      .single_p8
        ; unknown single part: default to the full slice
        jmp     .full_sequence

.single_p1:
        call    part1
        jmp     .done
.single_p2:
        call    part2
        jmp     .done
.single_p3:
        call    part3
        jmp     .done
.single_p5:
        call    part5
        jmp     .done
.single_p6:
        call    part6
        jmp     .done
.single_p7:
        call    part7
        jmp     .done
.single_p8:
        call    part8
        jmp     .done

.full_sequence:
        ; current implemented slice: P1 then P2 then P3 (hold to 0x1400),
        ; then P5 then P6 then P7 then P8. P4 was removed 2026-08-06.
        ; (run progress is reported centrally by the platform via the ModPos
        ; timeline; see port/platform/progress.cpp)
        call    part1
        call    part2
        call    part3
        ; P4 was removed from the modernized build (2026-08-06). Its audio
        ; window (0x0D40..0x1400) still plays; hold the last frame until P5's
        ; calibrated start so the remaining parts keep their ModPos timeline.
.p4_hold:
        ; Must keep pumping EOS_WAIT_VBL: it services the main-thread audio
        ; engine, so ModPos only advances here (P4's own loop used to do this).
        mov     eax, EOS_WAIT_VBL
        call    eos_dispatch
        call    GetModPos
        movzx   eax, word [rel ModPos]
        cmp     eax, 0x1400
        jb      .p4_hold
        call    part5
        call    part6
        call    part7
        call    part8

.done:
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
