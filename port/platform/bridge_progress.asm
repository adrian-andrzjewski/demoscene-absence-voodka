; bridge_progress.asm - production vk::progress namespace ABI.
;
; This is the shipped scene-boundary state machine. It preserves the C++
; progress contract while keeping scene tables, elapsed formatting, title
; updates, timeline emission, and transition logging in native x64 assembly.

BITS 64
DEFAULT REL

%include "win64_abi.inc"
%include "window_title.inc"

extern ?getModPos@vk@@YAIXZ
extern ?getFrameCounter@vk@@YA_KXZ
extern ?getQpcUs@vk@@YA_KXZ
extern ?timelineFrame@vk@@YAX_K0I@Z
extern ?audioElapsedSec@vk@@YANXZ
extern asm_log_vformat
extern vk_log_printf
%if VOODKA_DEBUG_TITLE
extern SetWindowTextA
%else
extern SetWindowTextW
%endif

global ?progressInit@vk@@YAXPEAX@Z
global ?progressUpdate@vk@@YAXXZ

%define PROG_TBUF       0x40
%define PROG_TITLE      0x80
%define PROG_SCENE_PTR  0x1A0
%define PROG_EFFECT_PTR 0x1A8
%define PROG_SCENE_ID   0x1B0
%define PROG_MM         0x1B4
%define PROG_SS         0x1B8
%define PROG_TT         0x1BC
%define PROG_ELAPSED_VA 0x1C0
%define PROG_TITLE_VA   0x1E0

section .bss
align 8
progress_hwnd:              resq 1
progress_last_scene:        resd 1
progress_transition_count:  resd 1

section .rdata
align 8
progress_sixty: dq 60.0
progress_ten:   dq 10.0

progress_elapsed_format: db "%02d:%02d.%d", 0
progress_production_title:
        VOODKA_EMIT_WINDOW_TITLE_W
%if VOODKA_DEBUG_TITLE
progress_title_format: db 'VOODKA (Absence) - Scene %d/8  %s  [%s]  t=%s  scene#%ld', 0
%endif
progress_log_format: db '[scene] part=%d/8 scene="%s" effect="%s" elapsed=%s modpos=0x%x scene_index=%ld', 10, 0

scene_modpos: dd 0x0000, 0x0100, 0x0200, 0x0300
              dd 0x0400, 0x0730, 0x0B40, 0x1400
              dd 0x1B40, 0x1C40, 0x2040
scene_ids: db 1, 1, 1, 1, 2, 2, 3, 5, 6, 7, 8

scene_names:
        dq scene_oko
        dq scene_oko
        dq scene_oko
        dq scene_oko
        dq scene_swiatynia
        dq scene_swiatynia
        dq scene_tunel
        dq scene_torus
        dq scene_gratki
        dq scene_gratki_woda
        dq scene_lampa

scene_effects:
        dq effect_znik
        dq effect_head
        dq effect_logo
        dq effect_fade
        dq effect_camera
        dq effect_reflective
        dq effect_twisted
        dq effect_torus
        dq effect_bump
        dq effect_water
        dq effect_object

scene_oko:          db 'oko + szklo', 0
scene_swiatynia:    db 'swiatynia city', 0
scene_tunel:       db 'tunel + wygibasy', 0
scene_torus:       db 'torus ustep village', 0
scene_gratki:      db 'gratki', 0
scene_gratki_woda: db 'gratki + woda', 0
scene_lampa:       db 'nad czerwonym lampa', 0

effect_znik:       db 'Znik fade-in', 0
effect_head:       db 'Texture-mapped head', 0
effect_logo:       db 'Logo overlay', 0
effect_fade:       db 'Palette fade', 0
effect_camera:     db 'Camera fly-through', 0
effect_reflective: db 'Reflective water', 0
effect_twisted:    db 'Twisted landscape', 0
effect_torus:      db 'Torus over water', 0
effect_bump:       db '2D bump mapping', 0
effect_water:      db '7-phase water', 0
effect_object:     db 'Rotating object view', 0

section .text

; void vk::progressInit(void* hwnd)
?progressInit@vk@@YAXPEAX@Z:
        mov     [rel progress_hwnd], rcx
        mov     dword [rel progress_last_scene], -1
        mov     dword [rel progress_transition_count], 0
%if !VOODKA_DEBUG_TITLE
        test    rcx, rcx
        jz      .init_done
        sub     rsp, 0x28
        lea     rdx, [rel progress_production_title]
        call    SetWindowTextW
        add     rsp, 0x28
.init_done:
%endif
        ret

; void vk::progressUpdate(void)
?progressUpdate@vk@@YAXXZ:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0x2A0                   ; aligned before every CALL

        call    ?getModPos@vk@@YAIXZ
        mov     r12d, eax                    ; ModPos
        call    ?getFrameCounter@vk@@YA_KXZ
        mov     r13, rax                     ; frame
        call    ?getQpcUs@vk@@YA_KXZ
        mov     r14, rax                     ; QPC microseconds

        mov     rcx, r13
        mov     rdx, r14
        mov     r8d, r12d
        call    ?timelineFrame@vk@@YAX_K0I@Z

        ; Find the last scene boundary <= ModPos. The C++ table starts at
        ; index zero and advances only across already-reached boundaries.
        xor     r15d, r15d
        mov     r10d, 1
.find_scene:
        cmp     r10d, 11
        jae     .scene_found
        lea     r11, [rel scene_modpos]
        cmp     r12d, [r11 + r10 * 4]
        jb      .scene_found
        mov     r15d, r10d
        inc     r10d
        jmp     .find_scene

.scene_found:
        cmp     r15d, [rel progress_last_scene]
        je      .done
        mov     [rel progress_last_scene], r15d
        inc     dword [rel progress_transition_count]

        lea     r10, [rel scene_names]
        mov     rax, [r10 + r15 * 8]
        mov     [rsp + PROG_SCENE_PTR], rax
        lea     r10, [rel scene_effects]
        mov     rax, [r10 + r15 * 8]
        mov     [rsp + PROG_EFFECT_PTR], rax
        lea     r10, [rel scene_ids]
        movzx   eax, byte [r10 + r15]
        mov     [rsp + PROG_SCENE_ID], eax

        call    ?audioElapsedSec@vk@@YANXZ
        movapd  xmm1, xmm0
        divsd   xmm1, [rel progress_sixty]
        cvttsd2si eax, xmm1
        mov     [rsp + PROG_MM], eax

        cvttsd2si eax, xmm0
        cdq
        mov     ecx, 60
        idiv    ecx
        mov     [rsp + PROG_SS], edx

        mulsd   xmm0, [rel progress_ten]
        cvttsd2si eax, xmm0
        cdq
        mov     ecx, 10
        idiv    ecx
        mov     [rsp + PROG_TT], edx

        mov     eax, [rsp + PROG_MM]
        mov     [rsp + PROG_ELAPSED_VA], rax
        mov     eax, [rsp + PROG_SS]
        mov     [rsp + PROG_ELAPSED_VA + 8], rax
        mov     eax, [rsp + PROG_TT]
        mov     [rsp + PROG_ELAPSED_VA + 16], rax
        mov     byte [rsp + PROG_TBUF], 0
        lea     rcx, [rsp + PROG_TBUF]
        mov     edx, 32
        lea     r8, [rel progress_elapsed_format]
        lea     r9, [rsp + PROG_ELAPSED_VA]
        call    asm_log_vformat

%if VOODKA_DEBUG_TITLE
        mov     eax, [rsp + PROG_SCENE_ID]
        mov     [rsp + PROG_TITLE_VA], rax
        mov     rax, [rsp + PROG_SCENE_PTR]
        mov     [rsp + PROG_TITLE_VA + 8], rax
        mov     rax, [rsp + PROG_EFFECT_PTR]
        mov     [rsp + PROG_TITLE_VA + 16], rax
        lea     rax, [rsp + PROG_TBUF]
        mov     [rsp + PROG_TITLE_VA + 24], rax
        mov     eax, [rel progress_transition_count]
        mov     [rsp + PROG_TITLE_VA + 32], rax
        lea     rcx, [rsp + PROG_TITLE]
        mov     edx, 256
        lea     r8, [rel progress_title_format]
        lea     r9, [rsp + PROG_TITLE_VA]
        call    asm_log_vformat

        mov     rcx, [rel progress_hwnd]
        test    rcx, rcx
        jz      .no_title
        lea     rdx, [rsp + PROG_TITLE]
        call    SetWindowTextA
.no_title:
%endif
        ; Six log arguments: the first four use registers and the final two
        ; use the caller's Win64 stack slots.
        lea     rcx, [rel progress_log_format]
        mov     eax, [rsp + PROG_SCENE_ID]
        mov     edx, eax
        mov     r8, [rsp + PROG_SCENE_PTR]
        mov     r9, [rsp + PROG_EFFECT_PTR]
        lea     rax, [rsp + PROG_TBUF]
        mov     [rsp + 0x20], rax
        mov     eax, r12d
        mov     [rsp + 0x28], rax
        mov     eax, [rel progress_transition_count]
        mov     [rsp + 0x30], rax
        call    vk_log_printf

.done:
        add     rsp, 0x2A0
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbp
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
