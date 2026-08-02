; txtr.asm - NASM x64 port of CODE/INC/TXTR.ASM  (texture-mapped triangle).
;
; Translation notes:
;   - Original is flat 32-bit (no selectors); math kept 32-bit operand width.
;   - fs:/gs: "selectors" are emulated: the caller stores *selector handles*
;     into fs_sel/gs_sel (dword), and tm_face resolves the real 64-bit base
;     from sel_base_table[handle*8] (bridge.cpp) up front instead of fs:[...].
;   - Raster walk uses the same signed 16-bit fixed-point math and clipping
;     as the original; nothing is re-factored.
;   - Callee-saved regs: rbx/rsi/rdi (used) + r14/r15 (bases) are pushed.

BITS 64
DEFAULT REL

%include "eos.inc"

extern Code32_addr
extern sel_base_table

section .bss
; per-face inputs (dword coords / dword texel packed 16.16)
global x_1
global y_1
global x_2
global y_2
global x_3
global y_3
global p_1
global p_2
global p_3
x_1:  resd 1
x_s:  resd 1
y_1:  resd 1
p_1:  resw 2
x_2:  resd 1
y_2:  resd 1
p_2:  resw 2
x_3:  resd 1
y_3:  resd 1
p_3:  resw 2

dx_1: resd 1
dy_1: resd 1
dx_2: resd 1
dy_2: resd 1
dy_3: resd 1
pd_1: resw 2
pd_2: resw 2

pom:  resw 1
mem:  resw 2

; selector handles the caller sets before calling tm_face (fitch "mov fs,sel").
global fs_sel
global gs_sel
fs_sel: resd 1
gs_sel: resd 1

x_min EQU 0
y_min EQU 0
x_max EQU 320
y_max EQU 200

section .text

; tm_face - texture-mapped face (triangle)
; in (globals): x_1/y_1/p_1, x_2/y_2/p_2, x_3/y_3/p_3  (p = texel 16.16)
;               fs_sel = texture selector, gs_sel = screen selector
global tm_face
tm_face:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r14
        push    r15
        sub     rsp, 0x20

        ; resolve selector bases once (fs = texture, gs = screen)
        lea     rbx, [rel sel_base_table]
        mov     eax, [rel fs_sel]
        and     eax, 0x1ff
        mov     r14, [rbx + rax*8]                  ; texture base
        mov     eax, [rel gs_sel]
        and     eax, 0x1ff
        mov     r15, [rbx + rax*8]                  ; screen base

        ; the original kept EDI/ESI high words zero across the raster (caller
        ; zero-extended them); reproduce that so partial-word fills are safe.
        xor     edi, edi
        xor     esi, esi
        xor     ebx, ebx

        mov     word [rel pom], 0

        mov     eax, [rel y_1]
        cmp     eax, [rel y_2]
        jle     .pr_1

        mov     eax, [rel x_1]
        xchg    [rel x_2], eax
        mov     [rel x_1], eax
        mov     eax, [rel y_1]
        xchg    [rel y_2], eax
        mov     [rel y_1], eax
        mov     eax, [rel p_1]
        xchg    [rel p_2], eax
        mov     [rel p_1], eax

.pr_1:  mov     eax, [rel y_1]
        cmp     eax, [rel y_3]
        jle     .pr_2

        mov     eax, [rel x_1]
        xchg    [rel x_3], eax
        mov     [rel x_1], eax
        mov     eax, [rel y_1]
        xchg    [rel y_3], eax
        mov     [rel y_1], eax
        mov     eax, [rel p_1]
        xchg    [rel p_3], eax
        mov     [rel p_1], eax

.pr_2:  mov     eax, [rel y_2]
        cmp     eax, [rel y_3]
        jle     .pr_3

        mov     eax, [rel x_2]
        xchg    [rel x_3], eax
        mov     [rel x_2], eax
        mov     eax, [rel y_2]
        xchg    [rel y_3], eax
        mov     [rel y_2], eax
        mov     eax, [rel p_2]
        xchg    [rel p_3], eax
        mov     [rel p_2], eax

.pr_3:  cmp     word [rel y_1], y_max-1
        jge     .sk
        cmp     word [rel y_3], y_min
        jl      .sk

        mov     eax, [rel y_2]
        sub     eax, [rel y_1]
        jne     .pr_4
        inc     eax
        mov     word [rel pom], 1
.pr_4:  mov     [rel dy_1], eax

        mov     eax, [rel y_3]
        sub     eax, [rel y_2]
        jne     .pr_5
        inc     eax
.pr_5:  mov     [rel dy_2], eax

        mov     eax, [rel y_3]
        sub     eax, [rel y_1]
        jne     .pr_6
        inc     eax
.pr_6:  mov     [rel dy_3], eax

        mov     eax, [rel x_3]
        sub     eax, [rel x_1]
        shl     eax, 16
        cdq
        idiv    dword [rel dy_3]
        mov     [rel dx_2], eax

        movzx   ebx, word [rel p_1]
        movzx   eax, word [rel p_3]
        sub     eax, ebx
        cdq
        idiv    dword [rel dy_3]
        mov     [rel pd_1], ax

        movzx   ebx, word [rel p_1+2]
        movzx   eax, word [rel p_3+2]
        sub     eax, ebx
        cdq
        idiv    dword [rel dy_3]
        mov     [rel pd_2], ax

        cmp     word [rel pom], 1
        jne     .no

        mov     eax, [rel x_1]
        mov     [rel pom], ax
        shl     eax, 16
        mov     [rel x_s], eax
        mov     eax, [rel x_2]
        shl     eax, 16
        mov     [rel x_1], eax
        mov     eax, [rel p_1]
        mov     [rel mem], eax
        jmp     .go

.no:    mov     eax, [rel x_2]
        sub     eax, [rel x_1]
        shl     eax, 16
        cdq
        idiv    dword [rel dy_1]
        mov     [rel dx_1], eax

        mov     eax, [rel dy_1]
        imul    dword [rel dx_2]
        shr     eax, 16
        add     eax, [rel x_1]
        mov     [rel pom], ax

        mov     eax, [rel dy_1]
        imul    dword [rel pd_1]
        add     ax, [rel p_1]
        mov     [rel mem], ax

        mov     eax, [rel dy_1]
        imul    dword [rel pd_2]
        add     ax, [rel p_1+2]
        mov     [rel mem+2], ax

        mov     eax, [rel x_1]
        shl     eax, 16
        mov     [rel x_1], eax
        mov     [rel x_s], eax

.go:    mov     eax, [rel y_1]
        imul    eax, 320
        mov     [rel y_1], eax
        mov     eax, [rel y_2]
        imul    eax, 320
        mov     [rel y_2], eax

        mov     ax, [rel p_1]
        xchg    word [rel p_1+2], ax
        mov     [rel p_1], ax

        cmp     dword [rel y_3], y_max-1
        jl      .no_da
        sub     dword [rel y_3], y_max-1
        mov     eax, [rel y_3]
        sub     [rel dy_3], eax

.no_da: xor     ebx, ebx

        mov     bx, [rel x_2]
        sub     bx, [rel pom]
        jnz     .okay
        inc     bx
.okay:  jg      .norm
        neg     bx

        movzx   ecx, word [rel mem]
        movzx   eax, word [rel p_2]
        sub     eax, ecx
        cdq
        idiv    ebx
        mov     si, ax

        shl     esi, 16

        movzx   ecx, word [rel mem+2]
        movzx   eax, word [rel p_2+2]
        sub     eax, ecx
        cdq
        idiv    ebx
        mov     si, ax

.draw_1:mov     ebx, [rel y_1]
        cmp     [rel y_2], ebx
        jne     .no_1

        mov     eax, [rel x_3]
        sub     eax, [rel x_2]
        shl     eax, 16
        cdq
        idiv    dword [rel dy_2]
        mov     [rel dx_1], eax

.no_1:  cmp     ebx, y_min*320
        jl      .go_1

        mov     di, [rel x_1+2]
        mov     cx, [rel x_s+2]

        cmp     di, x_max
        jge     .go_1
        cmp     cx, x_min
        jl      .go_1

        mov     edx, [rel p_1]

        cmp     cx, x_max-1
        jl      .no_c3

.add_2: add     edx, esi
        dec     cx
        cmp     cx, x_max-1
        jg      .add_2

.no_c3: cmp     di, x_min
        jge     .no_c4
        mov     di, x_min

.no_c4: sub     cx, di
        jl      .go_1

        add     di, cx
        add     di, [rel y_1]
        inc     cx

.fo_1:  mov     bl, dh
        shld    ebx, edx, 8
        movzx   eax, bx                           ; fs:[bx] texture sample (16-bit)
        movzx   eax, byte [r14 + rax]            ; fs:[bx] texture sample (16-bit)
        mov     [r15 + rdi], al                ; gs:[di] screen write
        dec     di
        add     edx, esi
        dec     cx
        jnz     .fo_1

.go_1:  mov     eax, [rel dx_1]
        add     [rel x_1], eax
        mov     eax, [rel dx_2]
        add     [rel x_s], eax
        mov     ax, [rel pd_2]
        add     [rel p_1], ax
        mov     ax, [rel pd_1]
        add     [rel p_1+2], ax
        add     dword [rel y_1], 320

        dec     dword [rel dy_3]
        jne     .draw_1
        jmp     .sk

.norm:  movzx   ecx, word [rel mem]
        movzx   eax, word [rel p_2]
        sub     eax, ecx
        cdq
        idiv    ebx
        mov     si, ax

        shl     esi, 16

        movzx   ecx, word [rel mem+2]
        movzx   eax, word [rel p_2+2]
        sub     eax, ecx
        cdq
        idiv    ebx
        mov     si, ax

.draw_2:mov     ebx, [rel y_1]
        cmp     [rel y_2], ebx
        jne     .no_2

        mov     eax, [rel x_3]
        sub     eax, [rel x_2]
        shl     eax, 16
        cdq
        idiv    dword [rel dy_2]
        mov     [rel dx_1], eax

.no_2:  cmp     ebx, y_min*320
        jl      .go_2

        mov     di, [rel x_s+2]
        mov     cx, [rel x_1+2]

        cmp     di, x_max
        jge     .go_2
        cmp     cx, x_min
        jl      .go_2

        mov     edx, [rel p_1]

        cmp     di, x_min
        jge     .no_c1

.add_1: add     edx, esi
        inc     di
        jl      .add_1

.no_c1: cmp     cx, x_max-1
        jl      .no_c2
        mov     cx, x_max-1

.no_c2: sub     cx, di
        jl      .go_2

        add     di, [rel y_1]
        inc     cx

.fo_2:  mov     bl, dh
        shld    ebx, edx, 8
        movzx   eax, bx                           ; fs:[bx] texture sample (16-bit)
        movzx   eax, byte [r14 + rax]            ; fs:[bx] texture sample (16-bit)
        mov     [r15 + rdi], al                ; gs:[di] screen write
        inc     di
        add     edx, esi
        dec     cx
        jnz     .fo_2

.go_2:  mov     eax, [rel dx_1]
        add     [rel x_1], eax
        mov     eax, [rel dx_2]
        add     [rel x_s], eax
        mov     ax, [rel pd_2]
        add     [rel p_1], ax
        mov     ax, [rel pd_1]
        add     [rel p_1+2], ax
        add     dword [rel y_1], 320

        dec     dword [rel dy_3]
        jne     .draw_2

.sk:    add     rsp, 0x20
        pop     r15
        pop     r14
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret
