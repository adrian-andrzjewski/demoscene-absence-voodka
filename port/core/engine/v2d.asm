; v2d.asm - native x64 port of VISIBLE.PM (isVisible) + PIXEL2D.PM (Pixel2d),
; exposed as a clean Win64 C ABI:
;
;     int  vk_is_visible(int x1,int y1,int x2,int y2,int x3,int y3)  ; 1/0
;     void vk_pixel2d(uint8_t* screen, const int32_t* pts, int count,
;                     uint8_t color)                                 ; clipped plot

BITS 64
DEFAULT REL

section .bss align=1
vis_x1: resw 1
vis_y1: resw 1
vis_x2: resw 1
vis_y2: resw 1
vis_x3: resw 1
vis_y3: resw 1
global vis_visible
vis_visible: resb 1

section .data align=16
pom_tab:
%assign t 0
%rep 200
        dd t
        %assign t t+320
%endrep

section .text

; isVisible - 2D backface test on the 16-bit corner globals; sets vis_visible.
isVisible:
        mov     byte [vis_visible], 0
        mov     ax, [vis_y2]
        sub     ax, [vis_y1]
        mov     bx, [vis_x3]
        sub     bx, [vis_x1]
        imul    ax, bx
        mov     cx, ax
        mov     ax, [vis_y3]
        sub     ax, [vis_y1]
        mov     bx, [vis_x2]
        sub     bx, [vis_x1]
        imul    ax, bx
        sub     cx, ax
        neg     cx
        js      .noVis
        mov     byte [vis_visible], 1
.noVis:
        ret

; Pixel2d - plot colored bytes into a 320x200 screen buffer (rdi) with clipping.
;   rsi = 2D points (2*count int32), ecx = count, al = color, r10 = pom_tab
Pixel2d:
        lea     r10, [rel pom_tab]
.pLoop:
        mov     ebx, [rsi]            ; x
        mov     edx, [rsi + 4]        ; y
        cmp     ebx, 0
        jl      .skip
        cmp     ebx, 319
        jg      .skip
        cmp     edx, 0
        jl      .skip
        cmp     edx, 199
        jg      .skip
        mov     r11d, [r10 + rdx*4]   ; row offset (y*320)
        add     r11d, ebx
        mov     byte [rdi + r11], al
.skip:
        add     rsi, 8
        dec     ecx
        jnz     .pLoop
        ret

global vk_is_visible
; int vk_is_visible(int x1, int y1, int x2, int y2, int x3, int y3)
;   rcx,rdx,r8d,r9d,[rsp+0x28],[rsp+0x30]
vk_is_visible:
        mov     [vis_x1], cx
        mov     [vis_y1], dx
        mov     [vis_x2], r8w
        mov     [vis_y2], r9w
        mov     ax, word [rsp + 0x28]
        mov     [vis_x3], ax
        mov     ax, word [rsp + 0x30]
        mov     [vis_y3], ax
        push    rbx
        call    isVisible
        pop     rbx
        movzx   eax, byte [vis_visible]
        ret

global vk_pixel2d
; void vk_pixel2d(uint8_t* screen, const int32_t* pts, int count, uint8_t color)
vk_pixel2d:
        push    rbx
        push    rsi
        push    rdi
        mov     rdi, rcx
        mov     rsi, rdx
        mov     ecx, r8d
        mov     al, r9b
        call    Pixel2d
        pop     rdi
        pop     rsi
        pop     rbx
        ret
