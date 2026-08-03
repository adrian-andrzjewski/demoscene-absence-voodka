; toonel.asm - pure tunnel-table filler, extracted so boot and the CTest can
; both call it. Faithful NASM x64 port of DEMO.AS^ makeTableToonel's core
; computation, presented as a clean Win64 C ABI:
;
;     void vk_make_toonel(uint8_t* dest)   ; rcx = caller-provided 128000-byte
;                                          ; buffer to fill
;
; For each 320x200 screen cell it computes (in x87 exactly like the original,
; fpatan/fsqrt/fimul/fistp):
;     u = int(atan2(x,y) * 128 / pi)             -> byte in low  half
;     v = int(zoom(3000) / sqrt(x^2 + y^2))      -> byte in high half
; then packs each u/v word pair across the two 64000-byte halves:
;     dest[0..63999]      : word i = (v_even<<8)|u_even for pairs 2k
;     dest[64000..127999] : word i = (u_odd<<8)|v_odd   for pairs 2k+1
;
; Uses no C calls; preserves all Win64 callee-saved registers.

BITS 64
DEFAULT REL

section .bss
StosF: resw 1

section .text

global vk_make_toonel
vk_make_toonel:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        ; no C calls -> alignment is not required, prologue stays balanced.
        sub     rsp, 0x20

        mov     rdx, rcx                ; rdx = real 128000-byte dest base
        lea     rsi, [rel StosF]        ; x87 scratch word
        xor     edi, edi                ; cell index 0..63999
        mov     bx, -100                ; Y
.pilujY:
        mov     cx, -160                ; X
.pilujX:
        mov     [rsi], cx
        fild    word [rsi]              ; st0 = X
        mov     [rsi], bx
        fild    word [rsi]              ; st0 = Y, st1 = X
        fpatan                           ; st0 = atan2(X,Y)
        mov     word [rsi], 128
        fimul   word [rsi]
        fldpi
        fdivp   st1, st0                ; *128/pi
        fistp   word [rsi]
        mov     ax, [rsi]
        mov     [rdx + rdi], al         ; u byte (low half)

        mov     word [rsi], 3000        ; zooming
        fild    word [rsi]
        mov     [rsi], cx
        fild    word [rsi]
        fmul    st0, st0                ; X^2
        mov     [rsi], bx
        fild    word [rsi]
        fmul    st0, st0                ; Y^2
        faddp   st1, st0                ; X^2+Y^2
        fsqrt
        fdivp   st1, st0                ; zoom/sqrt
        fistp   word [rsi]
        mov     ax, [rsi]
        mov     [rdx + rdi + 64000], al ; v byte (high half)

        inc     edi
        inc     cx
        cmp     cx, 160
        jne     .pilujX
        inc     bx
        cmp     bx, 100
        jne     .pilujY

        ; pack each u/v pair across the two halves (high byte shuffle)
        mov     ecx, 32000
        mov     rsi, rdx
.pleo:
        mov     ax, [rsi]
        mov     bx, [rsi + 64000]
        xchg    ah, bl
        mov     [rsi], ax
        mov     [rsi + 64000], bx
        add     rsi, 2
        loop    .pleo

        add     rsp, 0x20
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret
