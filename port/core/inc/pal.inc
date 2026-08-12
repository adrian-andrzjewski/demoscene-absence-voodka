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
extern vk_set_palette_range
extern vk_present_frame

section .bss
; per-part palette working buffer (each part includes pal.inc once; local)
pal_pom: resb 768
; Saved palette for a retrace-visible flash.  The VGA original changes only
; the DAC; the indexed framebuffer remains the already displayed frame.
pal_flash_restore: resb 768
pal_flash_work:    resb 768

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

; pal_flash - show one palette over the currently presented indexed frame,
; hold it for EBX retraces, then restore the supplied palette and present it.
; Inputs: RSI = flash palette, RDI = restore palette, EBX = white-retrace count.
; This is the port equivalent of consecutive original pal_set calls: each
; original pal_set waits for VGA retrace before changing the DAC.  Presenting
; at both palette states is essential because the Windows renderer has a
; separate framebuffer and palette texture.
pal_flash:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        sub     rsp, 0x20

        mov     r12, rsi
        mov     r13, rdi
        mov     r14d, ebx

        mov     rcx, r12
        call    vk_set_palette
        call    vk_present_frame

.flash_wait:
        test    r14d, r14d
        jz      .flash_restore
        mov     eax, EOS_WAIT_VBL
        call    eos_dispatch
        dec     r14d
        jmp     .flash_wait

.flash_restore:
        mov     rcx, r13
        call    vk_set_palette
        call    vk_present_frame

        add     rsp, 0x20
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; pal_flash_current - flash over the current palette and restore that exact
; palette. Inputs: RSI = flash palette, EBX = white-retrace count.
pal_flash_current:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        sub     rsp, 0x28

        mov     r12, rsi
        mov     r13d, ebx
        lea     rdi, [rel pal_flash_restore]
        mov     rcx, rdi
        call    vk_get_palette

        mov     rsi, r12
        lea     rdi, [rel pal_flash_restore]
        mov     ebx, r13d
        call    pal_flash

        add     rsp, 0x28
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; pal_flash_brighten - build the exact pal_fadein10-to-white palette, show it
; for EBX retraces, and restore the palette that was current on entry.
; Inputs: EBX = per-channel brightening delta, ECX = white-retrace count.
; The P1/P5 callers then add any extra restore-only pal_set retraces required
; by their original assembly loops.
pal_flash_brighten:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        sub     rsp, 0x20

        movzx   r14d, bl
        mov     r13d, ecx
        lea     rdi, [rel pal_flash_restore]
        mov     rcx, rdi
        call    vk_get_palette

        lea     rsi, [rel pal_flash_restore]
        lea     rdi, [rel pal_flash_work]
        mov     ecx, 768
.brighten_loop:
        movzx   eax, byte [rsi]
        add     eax, r14d
        cmp     eax, 63
        jle     .brighten_store
        mov     eax, 63
.brighten_store:
        stosb
        inc     rsi
        dec     ecx
        jnz     .brighten_loop

        lea     rsi, [rel pal_flash_work]
        lea     rdi, [rel pal_flash_restore]
        mov     ebx, r13d
        call    pal_flash

        add     rsp, 0x20
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; set_pal <src>, <start>, <count> - set only palette entries [start,start+count)
; from source label <src> (3 bytes/entry), preserving every other entry. Port
; of the external-EOS `set_pal` macro. Must be used from a body with RSP%16==0
; (standard for the other inline macros); it frames its own stack region so the
; two C calls are 16-aligned.
%macro set_pal 3
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x28        ; entry%16==0 + rbp(8)=8 +0x28(40)=48 -> 0
        lea     rcx, [rel %1]
        mov     edx, %2
        mov     r8d, %3
        call    vk_set_palette_range
        add     rsp, 0x28
        mov     rsp, rbp
        pop     rbp
%endmacro

%endif ; PAL_INC
