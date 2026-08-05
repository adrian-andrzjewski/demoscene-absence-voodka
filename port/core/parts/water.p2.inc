; water.p2.inc - NASM x64 port of CODE/P2/WATER/WATER.PM (the P2 stadium's
; reflective-floor water: 320x200 16-bit ripple field, drawn as a 1:1 320x80
; strip at screen rows 61..140, sampling absence.dat).
;
; This is a DIFFERENT engine from the P7 water (inc/water.inc, 160x100 field
; 2x2-upscaled to full screen) and the P5 water (water.p5.inc, 128x128 field
; into the 256x256 waterWorld texture). An earlier revision of the port reused
; the P7 engine here; this file restores the original P2 behavior.
;
; Translation notes:
;   - Self-modifying immediates (WaterX/WaterY at `add bx/dx,0101h`, innerWater
;     at `mov ah,01h`) become explicit state vars with identical arithmetic.
;   - DESTINY (sar dx,06h immediate) is never written in this part -> const 6.
;   - The simulation keeps the original 16-bit wrapping arithmetic verbatim
;     (movzx/32-bit accumulation would differ once |sum| leaves int16 range).
;   - The original indexes MUL160 with a wrapped 16-bit bx (0..65535) past the
;     200-entry table whenever |vgrad>>3| pushes the row off-grid, reading
;     adjacent DOS memory. We clamp the row to [0,199] instead - only those
;     already-undefined edge cells differ (same policy as inc/water.inc).
;   - The final picture offset is a 16-bit wrapped value (0..65535), exactly
;     like the original; _obrazek2+19200+65535 stays inside the 64MB arena.

%ifndef WATER_P2_INC
%define WATER_P2_INC

%include "eos.inc"

extern Code32_addr
extern _screen
extern _bufor1
extern _bufor2
extern nPage
extern _obrazek2                  ; absence.dat arena offset (defined in p2.asm)

section .bss
p2_water_x:  resw 1
p2_water_y:  resw 1
p2_inner:    resb 1

section .data align=16
; MUL160 LABEL WORD / REPT 200 dw uuu (uuu += 320) - note the original's name
; lies: the stride is 320 (the 320-wide absence.dat rows), not 160.
P2MUL160:
        %assign uu 0
        %rep 200
        dw uu
        %assign uu uu+320
        %endrep

section .text

; ----------------------------------------------------- calculateWaterP2 ----
; 320x200 16-bit page ripple over the interior 318 cols x 80 rows starting at
; word 321. edi = write page, esi = read page (nPage parity), then swapped
; roles as in the original (edi is the accumulator source, [esi] the target).
calculateWaterP2:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        sub     rsp, 0x28

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
        add     rdi, qword [rel Code32_addr]
        add     rsi, qword [rel Code32_addr]
        add     rsi, 321*2
        add     rdi, 321*2

        mov     r14d, 198-98-20           ; 80 rows (original ebp)
.outer:
        mov     ecx, 318                  ; cols
.inner:
        mov     ax, [rdi + 320*2]
        add     ax, [rdi - 320*2]
        add     ax, [rdi + 1*2]
        add     ax, [rdi - 1*2]
        sar     ax, 1
        sub     ax, [rsi]
        mov     dx, ax
        sar     dx, 6                     ; DESTINY = 6
        sub     ax, dx
        mov     [rsi], ax
        add     rsi, 2
        add     rdi, 2
        dec     ecx
        jnz     .inner
        add     rsi, 4
        add     rdi, 4
        dec     r14d
        jnz     .outer

        add     rsp, 0x28
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; --------------------------------------------------------- drawWaterP2 -----
; r13 = _obrazek2 + 60*320 (absence.dat sampled from its row 60),
; rdi = _screen + 60*320. 80 rows x 320 cols, one pixel per field cell written
; at [rdi+320] (-> screen rows 61..140).
;   vgrad = h[i] - h[i+320]   (word below; 640 bytes)
;   hgrad = h[i] - h[i+1]
;   bright = (128 - vgrad) & 0xff
;   sample = pic[clamp(row,0,199)*320 + col]  with row=(vgrad>>3)+water_y,
;     col=(hgrad>>3)+water_x, final offset wrapped to 16 bits
;   out = (sample * bright) >> 8
drawWaterP2:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        sub     rsp, 0x28

        mov     r13d, [rel _obrazek2]
        add     r13, qword [rel Code32_addr]
        add     r13, 60*320
        mov     edi, [rel _screen]
        add     rdi, qword [rel Code32_addr]
        add     rdi, 60*320

        mov     eax, [rel nPage]
        and     eax, 1
        jnz     .vamp1
        mov     esi, [rel _bufor1]
        jmp     .drw
.vamp1:
        mov     esi, [rel _bufor2]
.drw:
        add     rsi, qword [rel Code32_addr]

        mov     word [rel p2_water_y], 0
        mov     r14d, 80                  ; original: ecx = -80 shl 16 sign loop
.dloop0:
        mov     ecx, 320                  ; original: cx column counter
        mov     word [rel p2_water_x], 0
.dloop1:
        movzx   eax, word [rsi]           ; h[i]
        mov     edx, eax
        movzx   r10d, word [rsi + 640]
        sub     ax, r10w                  ; ax = vgrad (16-bit wrap)
        movzx   r10d, word [rsi + 2]
        sub     dx, r10w                  ; dx = hgrad (16-bit wrap)

        ; p2_inner = (128 - vgrad) & 0xff
        mov     ebx, 128
        sub     bx, ax
        mov     [rel p2_inner], bl

        ; row = (vgrad>>3) + water_y, clamped to [0,199] (see header note)
        movsx   eax, ax
        sar     eax, 3
        movzx   r10d, word [rel p2_water_y]
        add     eax, r10d
        test    eax, eax
        jns     .row_nn
        xor     eax, eax
.row_nn:
        cmp     eax, 199
        jle     .row_ok
        mov     eax, 199
.row_ok:
        lea     r10, [rel P2MUL160]
        movzx   eax, word [r10 + rax*2]   ; row * 320

        ; col = (hgrad>>3) + water_x; 16-bit wrap of the final picture offset
        movsx   edx, dx
        sar     edx, 3
        movzx   r10d, word [rel p2_water_x]
        add     edx, r10d
        add     eax, edx
        and     eax, 0xffff
        movzx   eax, byte [r13 + rax]     ; al = picture sample

        movzx   ebx, byte [rel p2_inner]
        mul     bl                        ; ax = al * bl (unsigned, like mul ah)
        mov     [rdi + 320], ah           ; (sample*bright) >> 8

        inc     rdi
        add     rsi, 2
        inc     word [rel p2_water_x]
        dec     ecx
        jnz     .dloop1

        inc     word [rel p2_water_y]
        dec     r14d
        jnz     .dloop0

        add     rsp, 0x28
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

%endif ; WATER_P2_INC
