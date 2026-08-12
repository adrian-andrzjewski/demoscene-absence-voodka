; bridge_timing_audio.asm - production timing/audio C ABI adapters.
;
; These are the second bridge slice.  They preserve the existing C ABI used by
; eos_dispatch.asm while forwarding directly to the already assembly-owned
; QPC/timer and dedicated-player namespace ABI.  The reference target keeps
; The C++ reference implementation remains the timer/libxmp oracle.

BITS 64
DEFAULT REL

extern ?waitVbl@vk@@YAXXZ
extern ?getFrameCounter@vk@@YA_KXZ
extern ?audioPump@vk@@YAXXZ
extern ?getModPos@vk@@YAIXZ
extern ?audioElapsedSec@vk@@YANXZ
extern ?audioPlay@vk@@YAHXZ
extern ?audioStop@vk@@YAHXZ
extern ?audioSeekRows@vk@@YAII@Z
extern ?audioSeekMs@vk@@YAIH@Z
extern ?audioSeekOrder@vk@@YAIH@Z

global vk_wait_vbl
global vk_get_modpos
global vk_audio_elapsed_us
global vk_audio_play
global vk_audio_stop
global vk_audio_clear
global vk_audio_set_pattern
global vk_audio_seek_rows
global vk_audio_seek_ms
global vk_audio_seek_order

section .bss align=8
bridge_wait_vbl_previous: resq 1

section .rodata align=8
bridge_one_million: dq 1000000.0

section .text

; uint64_t vk_wait_vbl(void)
;
; The EOS service returns the delta since the preceding call, not the
; absolute frame counter.  The first call therefore returns the current
; counter because the C++ static previous value was zero-initialized.
vk_wait_vbl:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20                    ; RSP%16 == 0 at every CALL
        call    ?waitVbl@vk@@YAXXZ
        call    ?getFrameCounter@vk@@YA_KXZ
        mov     rcx, [rel bridge_wait_vbl_previous]
        mov     [rel bridge_wait_vbl_previous], rax
        sub     rax, rcx
        add     rsp, 0x20
        pop     rbp
        ret

; uint32_t vk_get_modpos(void)
vk_get_modpos:
        sub     rsp, 0x28
        call    ?audioPump@vk@@YAXXZ
        call    ?getModPos@vk@@YAIXZ
        add     rsp, 0x28
        ret

; uint64_t vk_audio_elapsed_us(void)
vk_audio_elapsed_us:
        sub     rsp, 0x28
        call    ?audioElapsedSec@vk@@YANXZ
        mulsd   xmm0, [rel bridge_one_million]
        cvttsd2si rax, xmm0
        add     rsp, 0x28
        ret

; int vk_audio_play(void)
vk_audio_play:
        jmp     ?audioPlay@vk@@YAHXZ

; int vk_audio_stop(void)
vk_audio_stop:
        jmp     ?audioStop@vk@@YAHXZ

; void vk_audio_clear(void)
vk_audio_clear:
        ret

; void vk_audio_set_pattern(int pos)
vk_audio_set_pattern:
        ret

; uint32_t vk_audio_seek_rows(uint32_t modpos)
vk_audio_seek_rows:
        jmp     ?audioSeekRows@vk@@YAII@Z

; uint32_t vk_audio_seek_ms(int milliseconds)
vk_audio_seek_ms:
        jmp     ?audioSeekMs@vk@@YAIH@Z

; uint32_t vk_audio_seek_order(int order)
vk_audio_seek_order:
        jmp     ?audioSeekOrder@vk@@YAIH@Z

section .note.GNU-stack noalloc noexec nowrite progbits
