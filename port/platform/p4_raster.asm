; p4_raster.asm - native x64 replacement for the production processorek Nevosolek (P4) bridge.
;
; The processorek Nevosolek (P4) core passes a pointer to the fixed-layout ProcessorekNevosolekDrawArgs record.  This
; scan converter intentionally follows bridge.cpp's C++ oracle: sort by Y,
; interpolate the long and short edges in double precision, clamp the
; covered rectangle, and use the original 8-bit wrapped texture address.

BITS 64
DEFAULT REL

; ProcessorekNevosolekDrawArgs
%define ARG_XY       0
%define ARG_UV       24
%define ARG_TEXTURE  40
%define ARG_SCREEN   48
%define ARG_COLOR    56

; A local vertex is four doubles: x, y, u, v.
; Keep every local below the saved-register area.  The prologue stores
; rbx..r15 at rbp-08..rbp-38; the former V0/V1 offsets overlapped those
; slots (V1+24 == rbp-28), restoring a vertex double into r13 on return.
%define V0           -0x60
%define V1           -0x80
%define V2           -0xa0
%define EDGE_LONG    -0xc0
%define EDGE_SHORT   -0xe0
%define EDGE_LEFT    -0x100
%define EDGE_RIGHT   -0x120
%define TEXTURE      -0x130
%define SCREEN       -0x138
%define COLOR        -0x13c

global vk_processorek_nevosolek_draw_triangle
global vk_processorek_nevosolek_draw_triangle_asm

section .text

vk_processorek_nevosolek_draw_triangle:
vk_processorek_nevosolek_draw_triangle_asm:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0x200

        ; Save the pointer members before using the integer registers as
        ; interpolation and pixel-loop scratch.
        mov     rax, [rcx + ARG_TEXTURE]
        mov     [rbp + TEXTURE], rax
        mov     rax, [rcx + ARG_SCREEN]
        mov     [rbp + SCREEN], rax
        mov     eax, [rcx + ARG_COLOR]
        mov     [rbp + COLOR], eax

        ; Load the three integer screen vertices as exact doubles.
        movsxd  rax, dword [rcx + 0]
        cvtsi2sd xmm0, rax
        movsd   [rbp + V0 + 0], xmm0
        movsxd  rax, dword [rcx + 4]
        cvtsi2sd xmm0, rax
        movsd   [rbp + V0 + 8], xmm0
        movsxd  rax, dword [rcx + 8]
        cvtsi2sd xmm0, rax
        movsd   [rbp + V1 + 0], xmm0
        movsxd  rax, dword [rcx + 12]
        cvtsi2sd xmm0, rax
        movsd   [rbp + V1 + 8], xmm0
        movsxd  rax, dword [rcx + 16]
        cvtsi2sd xmm0, rax
        movsd   [rbp + V2 + 0], xmm0
        movsxd  rax, dword [rcx + 20]
        cvtsi2sd xmm0, rax
        movsd   [rbp + V2 + 8], xmm0

        ; Decode the three packed 8.8 UV words exactly as the C++ oracle.
        mov     eax, [rcx + ARG_UV + 0]
        shr     eax, 8
        and     eax, 0xff
        cvtsi2sd xmm0, rax
        movsd   [rbp + V0 + 16], xmm0
        mov     eax, [rcx + ARG_UV + 0]
        shr     eax, 24
        cvtsi2sd xmm0, rax
        movsd   [rbp + V0 + 24], xmm0

        mov     eax, [rcx + ARG_UV + 4]
        shr     eax, 8
        and     eax, 0xff
        cvtsi2sd xmm0, rax
        movsd   [rbp + V1 + 16], xmm0
        mov     eax, [rcx + ARG_UV + 4]
        shr     eax, 24
        cvtsi2sd xmm0, rax
        movsd   [rbp + V1 + 24], xmm0

        mov     eax, [rcx + ARG_UV + 8]
        shr     eax, 8
        and     eax, 0xff
        cvtsi2sd xmm0, rax
        movsd   [rbp + V2 + 16], xmm0
        mov     eax, [rcx + ARG_UV + 8]
        shr     eax, 24
        cvtsi2sd xmm0, rax
        movsd   [rbp + V2 + 24], xmm0

        ; Stable Y ordering: v0 <= v1 <= v2.
        movsd   xmm0, [rbp + V1 + 8]
        comisd  xmm0, [rbp + V0 + 8]
        jae     .sort_02
        mov     rax, [rbp + V0 + 0]
        xchg    rax, [rbp + V1 + 0]
        mov     [rbp + V0 + 0], rax
        mov     rax, [rbp + V0 + 8]
        xchg    rax, [rbp + V1 + 8]
        mov     [rbp + V0 + 8], rax
        mov     rax, [rbp + V0 + 16]
        xchg    rax, [rbp + V1 + 16]
        mov     [rbp + V0 + 16], rax
        mov     rax, [rbp + V0 + 24]
        xchg    rax, [rbp + V1 + 24]
        mov     [rbp + V0 + 24], rax

.sort_02:
        movsd   xmm0, [rbp + V2 + 8]
        comisd  xmm0, [rbp + V0 + 8]
        jae     .sort_12
        mov     rax, [rbp + V0 + 0]
        xchg    rax, [rbp + V2 + 0]
        mov     [rbp + V0 + 0], rax
        mov     rax, [rbp + V0 + 8]
        xchg    rax, [rbp + V2 + 8]
        mov     [rbp + V0 + 8], rax
        mov     rax, [rbp + V0 + 16]
        xchg    rax, [rbp + V2 + 16]
        mov     [rbp + V0 + 16], rax
        mov     rax, [rbp + V0 + 24]
        xchg    rax, [rbp + V2 + 24]
        mov     [rbp + V0 + 24], rax

.sort_12:
        movsd   xmm0, [rbp + V2 + 8]
        comisd  xmm0, [rbp + V1 + 8]
        jae     .sorted
        mov     rax, [rbp + V1 + 0]
        xchg    rax, [rbp + V2 + 0]
        mov     [rbp + V1 + 0], rax
        mov     rax, [rbp + V1 + 8]
        xchg    rax, [rbp + V2 + 8]
        mov     [rbp + V1 + 8], rax
        mov     rax, [rbp + V1 + 16]
        xchg    rax, [rbp + V2 + 16]
        mov     [rbp + V1 + 16], rax
        mov     rax, [rbp + V1 + 24]
        xchg    rax, [rbp + V2 + 24]
        mov     [rbp + V1 + 24], rax

.sorted:
        ; y0 = max(0, ceil(v0.y)).  cvttsd2si is truncation toward zero;
        ; compare with the truncated double to synthesize ceil without CRT.
        movsd   xmm0, [rbp + V0 + 8]
        cvttsd2si r12d, xmm0
        cvtsi2sd xmm1, r12d
        comisd  xmm0, xmm1
        jbe     .y0_rounded
        inc     r12d
.y0_rounded:
        test    r12d, r12d
        jns     .y0_clamped
        xor     r12d, r12d
.y0_clamped:

        ; y1 = min(199, floor(v2.y)).
        movsd   xmm0, [rbp + V2 + 8]
        cvttsd2si r13d, xmm0
        cvtsi2sd xmm1, r13d
        comisd  xmm0, xmm1
        jae     .y1_rounded
        dec     r13d
.y1_rounded:
        cmp     r13d, 199
        jle     .y1_clamped
        mov     r13d, 199
.y1_clamped:
        cmp     r12d, r13d
        jg      .done

        ; Reject a degenerate triangle using the same double area expression.
        movsd   xmm0, [rbp + V2 + 0]
        subsd   xmm0, [rbp + V0 + 0]
        movsd   xmm1, [rbp + V1 + 8]
        subsd   xmm1, [rbp + V0 + 8]
        mulsd   xmm0, xmm1
        movsd   xmm2, [rbp + V2 + 8]
        subsd   xmm2, [rbp + V0 + 8]
        movsd   xmm3, [rbp + V1 + 0]
        subsd   xmm3, [rbp + V0 + 0]
        mulsd   xmm2, xmm3
        subsd   xmm0, xmm2
        xorpd   xmm1, xmm1
        comisd  xmm0, xmm1
        je      .done

        mov     r14d, r12d
.y_loop:
        cmp     r14d, r13d
        jg      .done
        cvtsi2sd xmm15, r14d

        ; Long edge: v0 -> v2.  rbx/rsi carry endpoints; rdi is output.
        lea     rbx, [rbp + V0]
        lea     rsi, [rbp + V2]
        lea     rdi, [rbp + EDGE_LONG]
        call    .edge_interpolate

        ; Short edge: v0 -> v1 above the middle vertex, otherwise v1 -> v2.
        comisd  xmm15, [rbp + V1 + 8]
        jb      .short_top
        lea     rbx, [rbp + V1]
        lea     rsi, [rbp + V2]
        jmp     .short_edge
.short_top:
        lea     rbx, [rbp + V0]
        lea     rsi, [rbp + V1]
.short_edge:
        lea     rdi, [rbp + EDGE_SHORT]
        call    .edge_interpolate

        ; Start with long/short as left/right, then swap the complete edge if
        ; their X order is reversed.
        mov     rax, [rbp + EDGE_LONG + 0]
        mov     [rbp + EDGE_LEFT + 0], rax
        mov     rax, [rbp + EDGE_LONG + 8]
        mov     [rbp + EDGE_LEFT + 8], rax
        mov     rax, [rbp + EDGE_LONG + 16]
        mov     [rbp + EDGE_LEFT + 16], rax
        mov     rax, [rbp + EDGE_SHORT + 0]
        mov     [rbp + EDGE_RIGHT + 0], rax
        mov     rax, [rbp + EDGE_SHORT + 8]
        mov     [rbp + EDGE_RIGHT + 8], rax
        mov     rax, [rbp + EDGE_SHORT + 16]
        mov     [rbp + EDGE_RIGHT + 16], rax

        movsd   xmm0, [rbp + EDGE_LEFT + 0]
        comisd  xmm0, [rbp + EDGE_RIGHT + 0]
        jbe     .edges_ordered
        mov     rax, [rbp + EDGE_LEFT + 0]
        xchg    rax, [rbp + EDGE_RIGHT + 0]
        mov     [rbp + EDGE_LEFT + 0], rax
        mov     rax, [rbp + EDGE_LEFT + 8]
        xchg    rax, [rbp + EDGE_RIGHT + 8]
        mov     [rbp + EDGE_LEFT + 8], rax
        mov     rax, [rbp + EDGE_LEFT + 16]
        xchg    rax, [rbp + EDGE_RIGHT + 16]
        mov     [rbp + EDGE_LEFT + 16], rax

.edges_ordered:
        ; xa = max(0, ceil(left.x)).
        movsd   xmm0, [rbp + EDGE_LEFT + 0]
        cvttsd2si r15d, xmm0
        cvtsi2sd xmm1, r15d
        comisd  xmm0, xmm1
        jbe     .xa_rounded
        inc     r15d
.xa_rounded:
        test    r15d, r15d
        jns     .xa_clamped
        xor     r15d, r15d
.xa_clamped:

        ; xb = min(319, floor(right.x)).
        movsd   xmm0, [rbp + EDGE_RIGHT + 0]
        cvttsd2si r12d, xmm0
        cvtsi2sd xmm1, r12d
        comisd  xmm0, xmm1
        jae     .xb_rounded
        dec     r12d
.xb_rounded:
        cmp     r12d, 319
        jle     .xb_clamped
        mov     r12d, 319
.xb_clamped:
        cmp     r15d, r12d
        jg      .next_y

        mov     r10d, r15d
        mov     rbx, [rbp + TEXTURE]
        mov     rsi, [rbp + SCREEN]
.x_loop:
        cmp     r10d, r12d
        jg      .next_y

        ; t = (x-left.x)/(right.x-left.x), with t=0 for a zero-width row.
        movsd   xmm0, [rbp + EDGE_RIGHT + 0]
        subsd   xmm0, [rbp + EDGE_LEFT + 0]
        xorpd   xmm1, xmm1
        comisd  xmm0, xmm1
        je      .pixel_t_zero
        movsd   xmm1, [rbp + EDGE_LEFT + 0]
        cvtsi2sd xmm2, r10d
        subsd   xmm2, xmm1
        divsd   xmm2, xmm0
        jmp     .pixel_t_ready
.pixel_t_zero:
        xorpd   xmm2, xmm2
.pixel_t_ready:
        movsd   xmm0, [rbp + EDGE_RIGHT + 8]
        subsd   xmm0, [rbp + EDGE_LEFT + 8]
        mulsd   xmm0, xmm2
        addsd   xmm0, [rbp + EDGE_LEFT + 8]
        cvttsd2si r8d, xmm0

        movsd   xmm0, [rbp + EDGE_RIGHT + 16]
        subsd   xmm0, [rbp + EDGE_LEFT + 16]
        mulsd   xmm0, xmm2
        addsd   xmm0, [rbp + EDGE_LEFT + 16]
        cvttsd2si r9d, xmm0

        and     r8d, 0xff
        and     r9d, 0xff
        shl     r9d, 8
        or      r9d, r8d
        movzx   eax, byte [rbx + r9]
        add     eax, [rbp + COLOR]

        mov     edx, r14d
        imul    edx, 320
        add     edx, r10d
        mov     [rsi + rdx], al
        inc     r10d
        jmp     .x_loop

.next_y:
        inc     r14d
        jmp     .y_loop

; Interpolate the edge rbx -> rsi at the current scanline (xmm15), writing
; x/u/v to rdi.  This local call has no external ABI boundary; the normal
; machine stack remains valid and all state lives in the frame/XMM registers.
.edge_interpolate:
        movsd   xmm0, [rsi + 8]
        subsd   xmm0, [rbx + 8]
        xorpd   xmm1, xmm1
        comisd  xmm0, xmm1
        je      .edge_t_zero
        movsd   xmm1, xmm15
        subsd   xmm1, [rbx + 8]
        divsd   xmm1, xmm0
        jmp     .edge_t_ready
.edge_t_zero:
        xorpd   xmm1, xmm1
.edge_t_ready:
        movsd   xmm0, [rsi + 0]
        subsd   xmm0, [rbx + 0]
        mulsd   xmm0, xmm1
        addsd   xmm0, [rbx + 0]
        movsd   [rdi + 0], xmm0
        movsd   xmm0, [rsi + 16]
        subsd   xmm0, [rbx + 16]
        mulsd   xmm0, xmm1
        addsd   xmm0, [rbx + 16]
        movsd   [rdi + 8], xmm0
        movsd   xmm0, [rsi + 24]
        subsd   xmm0, [rbx + 24]
        mulsd   xmm0, xmm1
        addsd   xmm0, [rbx + 24]
        movsd   [rdi + 16], xmm0
        ret

.done:
        add     rsp, 0x200
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
