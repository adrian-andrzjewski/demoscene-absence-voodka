; win32_shutdown.asm - production shutdown coordinator.
;
; The coordinator owns the one-shot claim, teardown order, production window
; handles, and quit-to-ExitProcess handoff.  Individual platform services stay
; behind narrow C ABI wrappers so their existing implementations remain the
; behavioral units under test.

BITS 64
DEFAULT REL

%include "win64_abi.inc"

extern asm_lifecycle_stop
extern asm_destroy_voodka_window
extern vk_shutdown_input
extern vk_shutdown_audio
extern vk_shutdown_recording
extern vk_shutdown_diagnostics
extern vk_shutdown_timeline
extern vk_shutdown_present
extern vk_shutdown_selectors
extern vk_shutdown_platform
extern vk_shutdown_log_flush
extern vk_shutdown_log_shutdown
extern vk_log_printf
extern ExitProcess

global asm_shutdown_set_window
global asm_shutdown_all
global asm_shutdown_and_exit

section .bss
align 8
asm_shutdown_hwnd:       resq 1
asm_shutdown_hinst:      resq 1
align 4
asm_shutdown_started:    resd 1

section .data
shutdown_all_message:     db "[app] shutting down all subsystems", 10, 0
shutdown_quit_message:    db "[app] quit requested (ESC/window close) - shutting down", 10, 0

section .text

; void asm_shutdown_set_window(HWND hwnd, HINSTANCE hInst)
asm_shutdown_set_window:
        mov     [rel asm_shutdown_hwnd], rcx
        mov     [rel asm_shutdown_hinst], rdx
        ret

; void asm_shutdown_all(void)
asm_shutdown_all:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20

        mov     eax, 1
        xchg    eax, [rel asm_shutdown_started]
        test    eax, eax
        jnz     .done

        lea     rcx, [rel shutdown_all_message]
        call    vk_log_printf

        ; Preserve the established C++ order: stop automation and input before
        ; audio, then close capture/timeline, graphics, selectors, and arena.
        call    asm_lifecycle_stop
        call    vk_shutdown_input
        call    vk_shutdown_audio
        call    vk_shutdown_recording
        call    vk_shutdown_diagnostics
        call    vk_shutdown_timeline
        call    vk_shutdown_present
        call    vk_shutdown_selectors
        call    vk_shutdown_platform

        mov     rcx, [rel asm_shutdown_hwnd]
        mov     rdx, [rel asm_shutdown_hinst]
        call    asm_destroy_voodka_window
        mov     qword [rel asm_shutdown_hwnd], 0
        mov     qword [rel asm_shutdown_hinst], 0

        call    vk_shutdown_log_flush
        call    vk_shutdown_log_shutdown
.done:
        add     rsp, 0x20
        pop     rbp
        ret

; void asm_shutdown_and_exit(void) - does not return
asm_shutdown_and_exit:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20
        lea     rcx, [rel shutdown_quit_message]
        call    vk_log_printf
        call    asm_shutdown_all
        xor     ecx, ecx
        call    ExitProcess
        int3

section .note.GNU-stack noalloc noexec nowrite progbits
