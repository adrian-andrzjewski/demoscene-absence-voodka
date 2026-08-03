; persp.asm - native x64 port of CODE/INC/PERSP.PM (perspective projection),
; exposed as a clean Win64 C ABI:
;
;     void vk_persp(const int32_t* src, int32_t* dst, int count)  [rcx,rdx,r8d]
;
; Projects `count` 3-component (x,y,z) int32 source vertices to 2-component
; (x,y) int32 targets:
;     s = z + 185*16 ; if s == 0, s = 1
;     x' = (x * 185) / s + 160
;     y' = (y * 185) / s + 100
; All fixed-point / signed division exactly like the original (imul -> 64-bit
; edx:eax, then idiv ebx).

BITS 64
DEFAULT REL

section .data align=16
persp_xmove:  dd 160
persp_ymove:  dd 100
persp_zdzeta: dd 185

section .text

persp:
.pLoop:
        mov     ebx, [rsi + 8]
        add     ebx, 185 * 16
        or      ebx, ebx
        jnz     .skip
        inc     ebx
.skip:
        mov     eax, [rsi]               ; x
        imul    dword [persp_zdzeta]
        idiv    ebx
        add     eax, [persp_xmove]
        mov     [rdi], eax

        mov     eax, [rsi + 4]           ; y
        imul    dword [persp_zdzeta]
        idiv    ebx
        add     eax, [persp_ymove]
        mov     [rdi + 4], eax

        add     rsi, 12
        add     rdi, 8
        dec     ecx
        jnz     .pLoop
        ret

global vk_persp
; void vk_persp(const int32_t* src, int32_t* dst, int count)  [rcx,rdx,r8d]
vk_persp:
        push    rbx
        push    rsi
        push    rdi
        mov     rsi, rcx
        mov     rdi, rdx
        mov     ecx, r8d
        call    persp
        pop     rdi
        pop     rsi
        pop     rbx
        ret
