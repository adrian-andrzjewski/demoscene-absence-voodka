; video.inc - NASM port of CODE/INC/VIDEO.PM helpers.
;
; Screen model (unchanged semantics, flat pointers):
;   _screen      : dword arena OFFSET of the offscreen render target
;   framebuffer  : dword arena OFFSET of the presented frame (old 0xA0000)
;   Ekran        : backbuffer -> framebuffer (was  rep movsw to VGA)
;   Screen0      : VSynch + clear backbuffer (16000 dwords)
;   ShowPicture  : row-blit from _[skad]
;   SetPal       : upload 768-byte VGA palette (in esi) to the platform
;   VSynch       : no-op spin hole; pacing is done by waitVbl elsewhere

%ifndef VIDEO_INC
%define VIDEO_INC

%include "eos.inc"

extern Code32_addr
extern _screen
extern framebuffer_off

section .text

; helpers to resolve an arena offset -> real 64-bit pointer (in rdi)
resolve_offset_macro_rdi:
        mov     edi, [rel .off]
        add     rdi, qword [rel Code32_addr]
        ret
.off:   dd 0

%macro Ekran 0
        ; backbuffer(_screen) -> framebuffer, 320x200 bytes
        push    rax
        push    rcx
        push    rsi
        push    rdi
        mov     esi, [rel _screen]
        add     rsi, qword [rel Code32_addr]
        mov     edi, [rel framebuffer_off]
        add     rdi, qword [rel Code32_addr]
        mov     ecx, 8000
        rep movsq                 ; 64000 bytes
        pop     rdi
        pop     rsi
        pop     rcx
        pop     rax
        ; present the just-blitted frame (mirrors writing to VGA memory).
        ; NOTE: this block is INLINED into a body with RSP%16==0; push rbp
        ; makes it 8, so we subtract 0x28 (40) -> 8+40=48 ≡ 0 at the call.
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x28
        extern vk_present_frame
        call    vk_present_frame
        add     rsp, 0x28
        mov     rsp, rbp
        pop     rbp
%endmacro

%macro Screen0 0
        push    rax
        push    rdi
        push    rcx
        mov     edi, [rel _screen]
        add     rdi, qword [rel Code32_addr]
        xor     eax, eax
        mov     ecx, 8000
        rep stosq
        pop     rcx
        pop     rdi
        pop     rax
%endmacro

; ShowPicture <width>, <height>, <srcOffsetVar>
%macro ShowPicture 3
        push    rax
        push    rcx
        push    rdx
        push    rsi
        push    rdi
        mov     esi, [%3]
        add     rsi, qword [rel Code32_addr]
        mov     edi, [rel _screen]
        add     rdi, qword [rel Code32_addr]
        mov     edx, %2
%%row:
        mov     ecx, %1
        rep movsb
        add     edi, 320 - (%1)
        dec     edx
        jnz     %%row
        pop     rdi
        pop     rsi
        pop     rdx
        pop     rcx
        pop     rax
%endmacro

%macro Set13h 0          ; mode 13h is implicit in our flat model
%endmacro
%macro Set3h 0          ; back to text - no-op (app exits on quit)
%endmacro

section .text
; SetPal: esi = pointer to 768-byte palette (REAL pointer, already resolved)
;   -> forward to platform palette upload
SetPal:
        ; vk_set_palette is extern-C; call with rcx = esi
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20
        mov     rcx, rsi
        extern vk_set_palette
        call    vk_set_palette
        add     rsp, 0x20
        pop     rbp
        ret

; VSynch: the original polled the VGA retrace; we only need a cheap marker.
VSynch:
        ret

; v_sync - port of the external-EOS `v_sync` macro: wait for a frame boundary.
; Original polled the VGA retrace; here it forwards to EOS wait_vbl (QPC-paced
; ~70Hz). Must be used from a body with RSP%16==0; frames its own stack so the
; eos_dispatch call is 16-aligned.
%macro v_sync 0
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x28
        extern eos_dispatch
        mov     eax, EOS_WAIT_VBL
        call    eos_dispatch
        add     rsp, 0x28
        mov     rsp, rbp
        pop     rbp
%endmacro

%endif ; VIDEO_INC
