; water.inc - NASM port of CODE/P7/WATER.PM (ripple sim + draw).
;
; Translation notes:
;   - Original patches instruction immediates at WaterX/WaterY/innerWater
;     (self-modifying code). W^X forbids that on Windows; replaced by explicit
;     word/byte state vars with identical arithmetic.
;   - DESTINY (sar dx,04h immediate) is never written in this part -> const 4.
;   - calculateWater switches two 128*128 16-bit page buffers per frame.
;   - MUL160 = REPT 100 dw (row*160) -> picture row offsets.

%ifndef WATER_INC
%define WATER_INC

%include "eos.inc"

extern Code32_addr
extern _screen
extern _bufor1
extern _bufor2
extern _obrazek
extern nPage

section .bss
; working state (replaces self-modifying immediates)
water_x:   resw 1
water_y:   resw 1
inner_water: resb 1

section .data align=16
MUL160:
        %assign uu 0
        %rep 100
        dw uu
        %assign uu uu+160
        %endrep

section .text

; ---------------------------------------------------------------- calculateWater
calculateWater:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0x28

        ; original: edi = write page, esi = read page, chosen by nPage parity.
        mov     eax, [rel nPage]
        and     eax, 1
        test    eax, eax
        jnz     .ches1
        mov     edi, [rel _bufor1]
        mov     esi, [rel _bufor2]
        jmp     .ches2
.ches1:
        mov     edi, [rel _bufor2]
        mov     esi, [rel _bufor1]
.ches2:
        add     rsi, 161*2
        add     rdi, 161*2

        mov     rbx, 98                 ; x Count (outer = rows)
.outer:
        mov     rcx, 158                ; y Count (inner = cols)
.inner:
        movzx   eax, word [rdi + 160*2]
        movzx   edx, word [rdi - 160*2]
        add     eax, edx
        movzx   edx, word [rdi + 1*2]
        add     eax, edx
        movzx   edx, word [rdi - 1*2]
        add     eax, edx
        sar     eax, 1
        movzx   edx, word [rsi]
        sub     eax, edx
        mov     edx, eax
        sar     edx, 4                  ; DESTINY (constant 4)
        sub     eax, edx
        mov     [rsi], ax
        add     rsi, 2
        add     rdi, 2
        dec     rcx
        jnz     .inner
        add     rsi, 4
        add     rdi, 4
        dec     rbx
        jnz     .outer

        add     rsp, 0x28
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ---------------------------------------------------------------- drawWater
; Original register map: esi=page, edi=screen, ebp=_obrazek, ecx loop ctrl.
; For each cell computes a picture offset driven by the water field and
; writes a 2x2 upsampled pixel to the screen.
drawWater:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0x28

        ; r13 = picture, rdi = screen
        mov     r13d, [rel _obrazek]
        add     r13, qword [rel Code32_addr]
        mov     edi, [rel _screen]
        add     rdi, qword [rel Code32_addr]

        ; rsi = page (real pointer)
        mov     eax, [rel nPage]
        and     eax, 1
        test    eax, eax
        jnz     .vamp1
        mov     esi, [rel _bufor1]
        jmp     .draw
.vamp1:
        mov     esi, [rel _bufor2]
.draw:
        add     rsi, qword [rel Code32_addr]

        ; ecx = (-99 << 16) | 160 ; WaterY = 0  (0xFF9D0000 + 160)
        mov     ecx, 0xFF9D0000 + 160
        mov     word [rel water_y], 0
.outer:
        mov     cx, 160
        mov     word [rel water_x], 0
.inner:
        ; ---- vdiff = [esi] - [esi+320] ; hdiff = [esi] - [esi+2] ----
        movzx   eax, word [rsi]
        movzx   r10d, word [rsi + 320]
        movzx   r11d, word [rsi + 2]
        mov     ecx, eax
        sub     cx, r10w               ; cx = vdiff (16-bit, wraps)
        mov     edx, eax
        sub     dx, r11w               ; dx = hdiff (16-bit, wraps)

        ; ---- innerWater = (128 - vdiff) & 0xff ----
        mov     eax, 128
        sub     ax, cx                 ; 128 - vdiff
        and     eax, 0xffff
        mov     [rel inner_water], al

        ; ---- bx = vdiff>>3 + water_y ; dx = hdiff>>3 + water_x ----
        mov     bx, cx
        sar     bx, 3
        add     bx, word [rel water_y]
        sar     dx, 3
        add     dx, word [rel water_x]

        ; ---- ax = MUL160[bx] + dx ; pixel = picture[ax] ----
        movzx   ecx, bx
        lea     r12, [rel MUL160]
        movzx   eax, word [r12 + rcx*2]
        add     ax, dx

        ; multiply by innerWater -> ah stored (2x2 upsample)
        movzx   eax, byte [r13 + rax]
        movzx   ebx, byte [rel inner_water]
        imul    ax, bx                ; ax = picture * innerWater

        mov     [rdi + 320], ah
        mov     [rdi + 321], ah
        mov     [rdi + 640], ah
        mov     [rdi + 641], ah

        inc     rdi
        inc     rdi
        add     rsi, 2
        inc     word [rel water_x]
        dec     cx
        jnz     .inner

        add     rdi, 320
        inc     word [rel water_y]
        add     ecx, 0x00010000
        js      .outer

        add     rsp, 0x28
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

%endif ; WATER_INC
