; p6.asm - NASM x64 port of CODE/P6/P6.AS^  (2D bump-mapped face, part 6).
;
; Translation notes:
;   - Original is flat 32-bit (no selectors); math kept 32-bit operand width.
;   - The original used SELF-MODIFYING code: it patched the immediates of
;     "mov [bump_x],00010001h" via labels BUMPXXX/BUMPYYY.  W^X (DEP) forbids
;     that on modern Windows, so patching is replaced by writing the dword
;     variables bump_x/bump_y directly.  Arithmetic/clipping is identical.
;   - tablica3 loads per-frame X/Y offsets into bump_x/bump_y.
;   - white = 768 bytes of 63 (max VGA 6-bit brightness).

BITS 64
DEFAULT REL

%include "eos.inc"
%include "video.inc"
%include "pal.inc"
%include "vodka.inc"

extern _screen
extern _scr_Addr
extern ModPos
extern GetModPos
extern Code32_addr
extern eos_dispatch
extern white

section .bss
; per-frame scratch
global part6

section .data
ramki:       dd 0
_pic:        dd 0
_pal:        dd 0
_bump:       dd 0
_jaszczur:   dd 0
plee:        dd 0
licznik:     dd 40
znika:       dd 0
bump_x:      dd 0
bump_y:      dd 0
bump_x_base: dd 0
bump_y_base: dd 0

; resolve stored dword offset (in [mem]) -> real 64-bit pointer in rax
; (unused helper kept for reference)

section .text

; ---------------------------------------------------------------- part6 ----
global part6
part6:
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

        ; _screen = _scr_Addr  (arena offset of the backbuffer)
        extern _scr_Addr
        mov     eax, dword [rel _scr_Addr]
        mov     [rel _screen], eax

        vodka   52, _bump
        vodka   50, _pic
        vodka   51, _pal
        vodka   53, _jaszczur

        ; palette = white, set once
        lea     rsi, [rel white]
        call    SetPal

        WaitVbl

.keye:
        cmp     dword [rel znika], 63
        jg      .ssss
        inc     dword [rel znika]
        mov     eax, [rel znika]
        movzx   ebx, al
        ; edi = real pointer to the target palette (from archive)
        mov     edi, [rel _pal]
        add     rdi, qword [rel Code32_addr]
        call    pal_fadein10
.ssss:

        Screen0

        inc     dword [rel plee]
        mov     eax, [rel ramki]
        cmp     eax, 4
        jg      .sarrr
        inc     dword [rel licznik]
        jmp     .ooss
.sarrr:
        shr     eax, 2
        add     [rel licznik], eax
.ooss:
        mov     ebx, [rel licznik]
        and     ebx, 127
        extern tablica3
        lea     rsi, [rel tablica3]
        mov     eax, [rsi + rbx*8]
        mov     [rel bump_x_base], eax
        mov     [rel bump_y], eax
        mov     eax, [rsi + rbx*8 + 4]
        mov     [rel bump_y_base], eax

        call    CalculateBump

        WaitVbl
        mov     [rel ramki], eax        ; wait_vbl returns counter in eax
        Ekran

        call    GetModPos
        cmp     word [rel ModPos], 0x1c3f   ; word var (a dword cmp reads the
        jle     .keye                       ; low half of framebuffer_off too)

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

; --------------------------------------------------------- CalculateBump ---
CalculateBump:
        ; resolve all stored offsets to real pointers once.
        ; NOTE: stored offsets are dwords; load 32-bit (zero-extends) so the
        ; high 32 bits of the 64-bit pointer are clean before adding base.
        mov     edi, [rel _screen]
        add     rdi, qword [rel Code32_addr]   ; rdi = screen real ptr
        mov     r13, rdi

        xor     esi, esi               ; esi = linear index (0..)
        mov     r14d, [rel _bump]
        add     r14, qword [rel Code32_addr]   ; r14 = bump map (128*128)
        mov     r15d, [rel _pic]
        add     r15, qword [rel Code32_addr]   ; r15 = pic (320*200)
        mov     r12d, [rel _jaszczur]
        add     r12, qword [rel Code32_addr]   ; r12 = jaszczur mask

        add     rdi, 321
        add     rsi, 321

        ; bump_y starts at bump_y_base each CalculateBump call; bump_x is
        ; re-initialized to bump_x_base at each row (mirrors the original's
        ; per-row immediate reset); both then increment as in the original.
        mov     eax, [rel bump_y_base]
        mov     [rel bump_y], eax
        mov     ecx, 197
.yloop:
        push    rcx
        mov     eax, [rel bump_x_base]
        mov     [rel bump_x], eax
        mov     ecx, 318
.xloop:
        push    rcx

        ; clipping
        cmp     dword [rel bump_x], -128
        jl      .nbump
        cmp     dword [rel bump_x], +128
        jg      .nbump
        cmp     dword [rel bump_y], -128
        jl      .nbump
        cmp     dword [rel bump_y], +128
        jg      .nbump

        xor     ebx, ebx
        xor     ecx, ecx
        ; eax = pic[i+1]-pic[i-1]; ecx = pic[i+320]-pic[i-320]
        movzx   eax, byte [r15 + rsi + 1]
        movzx   ebx, byte [r15 + rsi - 1]
        movzx   ecx, byte [r15 + rsi + 320]
        movzx   edx, byte [r15 + rsi - 320]
        sub     eax, ebx
        sub     ecx, edx
        sub     eax, [rel bump_x]
        jge     .oke1
        neg     eax
.oke1:
        sub     ecx, [rel bump_y]
        jge     .oke2
        neg     ecx
.oke2:
        mov     ebx, 120
        mov     edx, 120
        sub     ebx, eax
        jge     .oke3
        xor     ebx, ebx
.oke3:
        sub     edx, ecx
        jge     .oke4
        xor     edx, edx
.oke4:
        shl     ebx, 7
        add     ebx, edx
        movzx   eax, byte [r14 + rbx]
        movzx   ebx, byte [r12 + rsi]
        or      ebx, ebx
        jz      .ddd
        add     eax, 128
.ddd:
        mov     [r13 + rsi], al
.nbump:
        inc     rdi
        inc     rsi
        inc     dword [rel bump_x]
        pop     rcx
        dec     ecx
        jnz     .xloop

        inc     dword [rel bump_y]
        pop     rcx
        add     rdi, 2
        add     rsi, 2
        dec     ecx
        jnz     .yloop
        ret

section .data
%include "p6_tablica3.asm"   ; global 'tablica3' (129 x two dwords)
