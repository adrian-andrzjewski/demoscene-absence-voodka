; pal.inc - NASM port of CODE/INC/PAL (VGA palette read/set/fade).
;
; Original touched VGA DAC ports (3C7h/3C8h/3C9h/3DAh). In the port these
; become an in-memory 768-byte "current palette" + platform upload:
;   pal_read      : fetch current palette from platform into pal_pom
;   pal_set       : push 768-byte palette (esi) to the platform
;   pal_fadein10  : step pal_pom toward target (edi) by bl per channel
;   synch         : retrace spin -> no-op (waitVbl handles pacing)

%ifndef PAL_INC
%define PAL_INC

%include "eos.inc"

extern vk_get_palette
extern vk_set_palette

section .bss
; per-part palette working buffer (each part includes pal.inc once; local)
pal_pom: resb 768

section .text

; synch - original: poll 3DAh until vertical retrace. Flat model -> ret.
synch:
        ret

; pal_read - platform current palette -> pal_pom (768 bytes)
pal_read:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20           ; 16-aligned (32), shadow only
        lea     rcx, [rel pal_pom]
        call    vk_get_palette
        mov     rsp, rbp
        pop     rbp
        ret

; pal_set - esi = pointer to 768-byte palette -> platform
pal_set:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20
        mov     rcx, rsi
        call    vk_set_palette
        mov     rsp, rbp
        pop     rbp
        ret

; pal_fadein10 - step the WHOLE palette toward target (edi) by bl/channel.
; Original first reads the current VGA palette into pal_pom, steps it toward
; the target, then uploads. Mirrors that exactly.
pal_fadein10:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    rcx
        ; 5 regs pushed after rbp -> rsp 16-aligned (entry%16==8, +8 rbp=0,
        ; +4*8=32 keeps %16==0); sub 0x20 keeps alignment at call sites.
        sub     rsp, 0x20
        ; pal_pom = current platform palette (like original pal_read)
        lea     rcx, [rel pal_pom]
        call    vk_get_palette
        lea     rsi, [rel pal_pom]
        mov     ecx, 768
        movzx   ebx, bl
.pf_loop:
        movzx   eax, byte [rsi]
        movzx   edx, byte [rdi]
        cmp     al, dl
        je      .pf_same
        jb      .pf_up
        ; current > target : subtract, clamp at target
        sub     eax, ebx
        js      .pf_clamp_hi
        cmp     eax, edx
        jae     .pf_store
.pf_clamp_hi:
        mov     eax, edx
        jmp     .pf_store
.pf_up:
        ; current < target : add, clamp at target
        add     eax, ebx
        cmp     eax, edx
        jbe     .pf_store
        mov     eax, edx
.pf_store:
        mov     [rsi], al
.pf_same:
        inc     rsi
        inc     rdi
        loop    .pf_loop
        ; upload the stepped palette
        lea     rcx, [rel pal_pom]
        call    vk_set_palette
        add     rsp, 0x20
        pop     rcx
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

%endif ; PAL_INC
