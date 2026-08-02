; p7.asm - NASM x64 port of CODE/P7/P7.AS^  (7-phase water ripples, part 7).
;
; Translation notes:
;   - Two data blobs per phase via vodka <idxA>,<idxB>; mieszanie blends
;     _pulse over _obrazek2 into _obrazek.
;   - woda (drop injection) uses tablica3 + licznik + ramki; ported inline.
;   - The water sim (calculateWater/drawWater/MUL160) is water.inc.
;   - ModPos thresholds drive the phase ladder:
;       1d1f -> 1d3f -> 1e1f -> 1e3f -> 1f1f -> 1f3f, then a fade window
;       (each fade step = (ModPos & 3f) - 14, clamped) until 203f exits.

BITS 64
DEFAULT REL

%include "eos.inc"
%include "video.inc"
%include "pal.inc"
%include "vodka.inc"
%include "water.inc"

extern _screen
extern _scr_Addr
extern ModPos
extern GetModPos
extern Code32_addr
extern eos_dispatch
extern white

section .data
ramki:      dd 0
_obrazek:   dd 0
_paleta:    dd 0
_bufor1:    dd 0
_bufor2:    dd 0
_bufor3:    dd 0
nPage:      dd 0
_obrazek2:  dd 0
ofset:      dd 0
x_of:       dd 10
y_of:       dd 50
x_jest:     db 0
y_jest:     db 0
licznik:    dd 0
_pulse:     dd 0
_pulseW:    dd 0
znikanie:   dd 0
; per-phase exit thresholds
phase_exit: dd 0

section .text

; ------------------------------------------------------------------ woda ----
%macro woda 0
        mov     eax, [rel licznik]
        and     eax, 127
        lea     rcx, [rel tablica3]
        mov     ebx, [rcx + rax*4]
        mov     [rel ofset], ebx
        mov     esi, [rel _bufor1]
        add     rsi, qword [rel Code32_addr]
        mov     eax, ebx
        mov     byte [rsi + rax], 0xFF
        mov     eax, [rel ramki]
        add     [rel licznik], eax
%endmacro

; ----------------------------------------------------------------- mieszanie
mieszanie:
        push    rbp
        mov     rbp, rsp
        push    rsi
        push    rdi
        push    rbx
        push    r13
        mov     esi, [rel _pulseW]
        add     rsi, qword [rel Code32_addr]
        mov     edi, [rel _bufor1]
        add     rdi, qword [rel Code32_addr]
        mov     ecx, 32000/4
        rep movsd

        mov     r13d, [rel _obrazek2]
        add     r13, qword [rel Code32_addr]
        mov     edi, [rel _obrazek]
        add     rdi, qword [rel Code32_addr]
        mov     esi, [rel _pulse]
        add     rsi, qword [rel Code32_addr]
        mov     ecx, 160*100
.mm_loop:
        movzx   eax, byte [rsi]
        test    al, al
        jz      .mm_opa
        mov     [rdi], al
        jmp     .mm_kop
.mm_opa:
        movzx   ebx, byte [r13]
        mov     [rdi], bl
.mm_kop:
        inc     rsi
        inc     rdi
        inc     r13
        dec     ecx
        jnz     .mm_loop
        pop     r13
        pop     rbx
        pop     rdi
        pop     rsi
        pop     rbp
        ret

; ---------------------------------------------------- phase_body macro ----
; sets up one phase: two vodka loads, mieszanie, palette setup, then the
; frame loop (woda + drawWater + calculateWater + wait_vbl + Ekran) until
; ModPos > phase_exit.
%macro PHASE_BODY 2   ; %1 = pulse idx, %2 = pulseW idx
        vodka   %1, _pulse
        vodka   %2, _pulseW
        call    mieszanie
        lea     rsi, [rel white]
        call    pal_set
        mov     edi, [rel _paleta]
        add     rdi, qword [rel Code32_addr]
        call    pal_set
%%.frame_loop:
        woda
        call    drawWater
        call    calculateWater
        inc     dword [rel nPage]
        WaitVbl
        mov     [rel ramki], eax
        Ekran
        call    GetModPos
        movzx   eax, word [rel ModPos]
        cmp     eax, [rel phase_exit]
        jle     %%.frame_loop
%endmacro

; ------------------------------------------------------------------- part7 --
global part7
part7:
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

        mov     eax, [rel _scr_Addr]
        mov     [rel _screen], eax

        vodka   69, _paleta
        vodka   68, _obrazek2

        AllocateMemory  320*100, _bufor3
        AllocateMemory  160*100, _obrazek
        ; page buffers: pad by two extra rows worth (640 bytes) so drawWater's
        ; boundary reads ([esi+320], [esi+2]) at the last row stay in-bounds.
        ; The original tolerated these over-reads in flat DOS memory; Windows
        ; guard pages fault instead.
        AllocateMemoryFree 32000 + 640, _bufor1
        AllocateMemoryFree 32000 + 640, _bufor2

        WaitVbl

        mov     dword [rel phase_exit], 0x1d1f
        PHASE_BODY 56, 57
        mov     dword [rel phase_exit], 0x1d3f
        PHASE_BODY 58, 59
        mov     dword [rel phase_exit], 0x1e1f
        PHASE_BODY 60, 61
        mov     dword [rel phase_exit], 0x1e3f
        PHASE_BODY 62, 63
        mov     dword [rel phase_exit], 0x1f1f
        PHASE_BODY 64, 65
        mov     dword [rel phase_exit], 0x1f3f
        PHASE_BODY 66, 67

        ; ---- phase 7: fade window until 203f ----
        vodka   54, _pulse
        vodka   55, _pulseW
        call    mieszanie
        lea     rsi, [rel white]
        call    pal_set
        mov     edi, [rel _paleta]
        add     rdi, qword [rel Code32_addr]
        call    pal_set
.seven_loop:
        woda
        call    drawWater
        call    calculateWater
        inc     dword [rel nPage]
        WaitVbl
        mov     [rel ramki], eax
        Ekran
        call    GetModPos
        movzx   eax, word [rel ModPos]
        cmp     eax, 0x2014
        jl      .seven_no_fade
        ; fade step = (ModPos & 3f) - 14
        and     eax, 0x3f
        sub     eax, 14
        movzx   ebx, al
        ; edi = target palette = white (fade toward white)
        lea     rdi, [rel white]
        call    pal_fadein10
        ; then re-apply the picture palette so base stays
        mov     edi, [rel _paleta]
        add     rdi, qword [rel Code32_addr]
        call    pal_set
.seven_no_fade:
        movzx   eax, word [rel ModPos]
        cmp     eax, 0x203f
        jge     .seven_done
        jmp     .seven_loop
.seven_done:

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

section .data
%include "p7_tablica3.asm"   ; global tablica3
