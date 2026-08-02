; boot.asm - assembly entry that initializes the flat environment and runs a
; smoke frame loop entirely from NASM, calling back into the C++ platform via
; the bridge (vk_* symbols).  Replaces the temporary demo_preview.cpp.
;
; DemoStart32 (Microsoft x64 ABI):
;       int DemoStart32(void* arenaBase, uint64_t arenaSize)
; Sets Code32_addr = arenaBase and runs the demo.  In this phase it proves
; the whole NASM<->C++ path: palette upload, waitVbl pacing, backbuffer
; writes and present.  Phase 4 replaces the loop body with the ported
; DEMO.AS^ sequence (module load + part1..8).

BITS 64
DEFAULT REL

%include "eos.inc"

section .text

extern vk_arena_get
extern vk_set_palette
extern vk_present_frame
extern vk_wait_vbl
extern vk_framebuffer_offset
extern vk_backbuffer_ptr
extern Code32_addr

global DemoStart32

section .data
; 256x3 demo palette (built programmatically is fine; here a static ramp so
; the presenter can be validated against a known pattern).
palette_rgb:
        %assign i 0
        %rep 256
        db      255 - i, i/2, (i*3)&255
        %assign i i+1
        %endrep

section .bss
pal_rgb: resb 768

section .text
DemoStart32:
        push    rbp
        mov     rbp, rsp
        ; rcx = arenaBase (== platform arena base)
        mov     [rel Code32_addr], rcx

        ; build palette in .bss and upload via bridge
        mov     ecx, 768
        lea     rsi, [rel palette_rgb]
        lea     rdi, [rel pal_rgb]
        rep movsb
        lea     rcx, [rel pal_rgb]
        call    vk_set_palette

        ; main frame loop (mirrors a part's loop: WaitVbl -> draw -> present)
.frame_loop:
        call    vk_wait_vbl                 ; eax = frame counter

        ; fill backbuffer with a running pattern (proves pointer arithmetic)
        call    vk_backbuffer_ptr           ; rax = backbuffer
        mov     rdi, rax
        mov     eax, [rel frame]
        shr     eax, 3
        mov     ecx, 64000
.fill:
        ; pixel = (frame>>3 + linear index) & 0xFF  (striped gradient)
        mov     edx, ecx
        mov     ebx, [rel frame]
        shr     ebx, 3
        add     edx, ebx
        mov     [rdi + rcx - 1], dl
        loop    .fill
        inc     dword [rel frame]

        call    vk_present_frame

        ; escape-ish: end after 2048 frames (~29 s) so we don't spin forever
        cmp     dword [rel frame], 0x800
        jne     .frame_loop

        xor     eax, eax
        pop     rbp
        ret

section .bss
frame:  resd 1

section .note.GNU-stack noalloc noexec nowrite progbits
