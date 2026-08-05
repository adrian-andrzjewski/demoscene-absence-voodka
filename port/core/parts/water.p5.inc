; water.p5.inc - NASM x64 port of CODE/P5/water.pm (the 128x128 ripple sim that
; feeds the reflective 256x256 waterWorld used under P5's 3D world).
;
; Different from the P7 water (inc/water.inc) which upscales a 160x100 picture
; to the screen: this one runs the pure 128x128 page ripple (calculateWaterP5)
; and renders each cell as a 2x2 block into the 256x256 _waterWorld buffer
; (drawWaterP5) by sampling _obrazek.
;
; Self-modifying immediates (WaterX/WaterY/innerWater/DESTINY) are replaced by
; explicit state vars with identical arithmetic.

%ifndef WATER_P5_INC
%define WATER_P5_INC

%include "eos.inc"

extern Code32_addr
extern _bufor1
extern _bufor2
extern _obrazek
extern _waterWorld

section .bss
p5_water_x:  resw 1
p5_water_y:  resw 1
p5_inner:    resb 1
p5_page:     resd 1

section .text

; ----------------------------------------------------- calculateWaterP5 ----
; 128x128 16-bit page ripple. edi = write page, esi = read page (page parity).
calculateWaterP5:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        sub     rsp, 0x28

        mov     eax, [rel p5_page]
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
        add     rsi, 129*2
        add     rdi, 129*2
        inc     dword [rel p5_page]

        mov     r12d, 126                 ; outer (x Count)
.outer:
        mov     r13, 126                  ; inner (y Count)
.inner:
        movzx   eax, word [rdi + 128*2]
        movzx   edx, word [rdi - 128*2]
        add     eax, edx
        movzx   edx, word [rdi + 1*2]
        add     eax, edx
        movzx   edx, word [rdi - 1*2]
        add     eax, edx
        sar     eax, 1
        movzx   edx, word [rsi]
        sub     eax, edx
        mov     edx, eax
        sar     edx, 6                    ; DESTINY = 6
        sub     eax, edx
        mov     [rsi], ax
        add     rsi, 2
        add     rdi, 2
        dec     r13
        jnz     .inner
        add     rsi, 4
        add     rdi, 4
        dec     r12d
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

; --------------------------------------------------------- drawWaterP5 ----
; r13 = _obrazek (160x100 picture), rdi = _waterWorld (256x256).
; For each 128x128 cell writes a 2x2 block into _waterWorld.
drawWaterP5:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        sub     rsp, 0x28

        xor     ebx, ebx
        mov     r13d, [rel _obrazek]
        add     r13, qword [rel Code32_addr]
        mov     edi, [rel _waterWorld]
        add     rdi, qword [rel Code32_addr]

        ; rsi = read page
        mov     eax, [rel p5_page]
        and     eax, 1
        test    eax, eax
        jz      .vamp1
        mov     esi, [rel _bufor2]
        jmp     .drw
.vamp1:
        mov     esi, [rel _bufor1]
.drw:
        add     rsi, qword [rel Code32_addr]

        mov     dword [rel p5_water_y], 0
        mov     rcx, -128*65536
.loop0:
        ; low 16 of ecx = 128 (columns); count rows via high word sign.
        mov     cx, 128
        mov     dword [rel p5_water_x], 0
.loop1:
        movzx   eax, word [rsi]
        movzx   edx, word [rsi + 128*2]
        mov     r8w, ax
        sub     ax, dx                 ; ax = vdiff
        movzx   edx, word [rsi + 2]
        mov     r9w, r8w
        sub     dx, r9w                ; dx = hdiff (r8w held the original ax)
        ; NOTE: use preserved copies: r8w = original [esi], r9w stays orig.
        ; recompute vdiff/hdiff cleanly:
        movzx   eax, word [rsi]
        movzx   r10d, word [rsi + 128*2]
        movzx   r11d, word [rsi + 2]
        mov     r8d, eax
        sub     ax, r10w               ; ax = vdiff
        sub     r8w, r11w              ; r8w = hdiff (orig - [esi+2])

        ; inner = (128 - vdiff) & 0xff
        mov     ebx, 128
        sub     bx, ax
        and     ebx, 0xFFFF
        mov     [rel p5_inner], bl

        ; bx = (vdiff>>3) + water_y ; dx = (hdiff>>3) + water_x
        movsx   r9d, ax
        sar     r9d, 3
        movzx   r10d, word [rel p5_water_y]
        add     r9d, r10d
        movsx   r10d, r8w
        sar     r10d, 3
        movzx   r11d, word [rel p5_water_x]
        add     r10d, r11d

        ; sample = _obrazek[ row*128 + col ]  (base 0101h style: +1,+1)
        ; The original computes the index in 16-BIT (shl ax,7 / add ax,dx):
        ; out-of-range ripple cells wrap mod 65536 and read neighbouring data
        ; (harmless in DOS flat memory). In x64 a negative 32-bit index would
        ; zero-extend to +4GB and fault, so reproduce the 16-bit wrap.
        mov     eax, r9d
        shl     eax, 7
        add     eax, r10d
        and     eax, 0xffff
        movzx   eax, byte [r13 + rax]

        ; ah = (sample * inner) & 31
        movzx   ebx, byte [rel p5_inner]
        imul    ax, bx
        movzx   eax, ax
        shr     eax, 8
        and     eax, 31
        mov     [rdi+256], al
        mov     [rdi+257], al
        mov     [rdi+256+256], al
        mov     [rdi+257+256], al

        add     rdi, 2
        add     rsi, 2
        inc     word [rel p5_water_x]
        dec     cx
        jnz     .loop1

        add     rdi, 256
        inc     word [rel p5_water_y]
        add     rcx, 0x10000
        js      .loop0

        add     rsp, 0x28
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

%endif ; WATER_P5_INC
