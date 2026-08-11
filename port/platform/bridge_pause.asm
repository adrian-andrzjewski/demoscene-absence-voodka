; bridge_pause.asm - production vk::pause namespace ABI.
;
; The pause flag is read by the native timer/audio workers. Keep publication
; and the transition count in assembly so the shipped target has no C++ state
; or floating-point varargs adapter in this boundary.

BITS 64
DEFAULT REL

%include "win64_abi.inc"

extern ?getModPos@vk@@YAIXZ
extern ?audioElapsedSec@vk@@YANXZ
extern ?audioPump@vk@@YAXXZ
extern vk_log_printf

global ?isPaused@vk@@YA_NXZ
global ?pauseToggle@vk@@YAXXZ

section .bss
align 4
pause_state:        resd 1
pause_toggle_count: resd 1

section .rdata
pause_paused_format:  db "[pause] PAUSED  ModPos=0x%x elapsed=%.2fs toggle=%ld", 10, 0
pause_resumed_format: db "[pause] RESUMED ModPos=0x%x elapsed=%.2fs toggle=%ld", 10, 0

section .text

; bool vk::isPaused(void)
?isPaused@vk@@YA_NXZ:
        xor     eax, eax
        lock cmpxchg dword [rel pause_state], eax
        setne   al
        ret

; void vk::pauseToggle(void)
?pauseToggle@vk@@YAXXZ:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        push    r14
        sub     rsp, 0x28                    ; aligned before every CALL

        mov     eax, 1
        lock xadd dword [rel pause_toggle_count], eax
        inc     eax
        mov     r12d, eax                    ; transition number

        ; Exchange the state before sampling/logging, matching the C++
        ; contract that the worker sees the new clock state immediately.
        mov     eax, 1
        lock xchg dword [rel pause_state], eax
        test    eax, eax                     ; old state: 0 = pause, 1 = resume
        jnz     .resumed

        call    ?getModPos@vk@@YAIXZ
        mov     r13d, eax
        call    ?audioElapsedSec@vk@@YANXZ
        movq    r14, xmm0                    ; duplicate FP vararg in GP slot
        lea     rcx, [rel pause_paused_format]
        mov     edx, r13d
        mov     r8, r14
        mov     r9d, r12d
        call    vk_log_printf
        jmp     .pump

.resumed:
        ; The resumed state is zero, so the same exchange above implements
        ; the exact 1 -> 0 transition before the diagnostic calls.
        xor     eax, eax
        lock xchg dword [rel pause_state], eax
        call    ?getModPos@vk@@YAIXZ
        mov     r13d, eax
        call    ?audioElapsedSec@vk@@YANXZ
        movq    r14, xmm0
        lea     rcx, [rel pause_resumed_format]
        mov     edx, r13d
        mov     r8, r14
        mov     r9d, r12d
        call    vk_log_printf

.pump:
        call    ?audioPump@vk@@YAXXZ
        add     rsp, 0x28
        pop     r14
        pop     r13
        pop     r12
        pop     rbp
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
