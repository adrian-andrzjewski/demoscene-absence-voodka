; win32_app_entry.asm - production x64 assembly host handoff.
;
; The CRT still owns the external WinMain entry while the host uses C++ CRT
; facilities. The C++ WinMain shim immediately transfers control here. This
; keeps the migration ABI-safe and makes the eventual no-CRT process entry a
; later gate instead of calling an uninitialized C++ runtime.

BITS 64
DEFAULT REL

%include "win64_abi.inc"

%define DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 -4

extern GetModuleHandleA
extern GetCommandLineA
extern SetProcessDpiAwarenessContext
extern asm_parse_command_line
extern vk_voodka_host_main

global asm_voodka_winmain

section .bss
align 8
asm_instance_storage:       resq 1

section .text

; int asm_voodka_winmain(HINSTANCE, HINSTANCE, LPSTR, int)
;
; The CRT-supplied command-line pointer is deliberately not trusted as the
; production source. GetCommandLineA gives the host the process command line
; directly, while GetModuleHandleA supplies the process instance handle.
asm_voodka_winmain:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        push    r14
        sub     rsp, 0x28                    ; RSP%16 == 0 at every CALL

        mov     r12, rcx                     ; CRT hInstance fallback

        xor     ecx, ecx                    ; GetModuleHandleA(NULL)
        call    GetModuleHandleA
        test    rax, rax
        cmovz   rax, r12
        mov     r13, rax

        call    GetCommandLineA
        mov     r14, rax
        mov     [rel asm_instance_storage], r13
        mov     rcx, r14
        call    asm_parse_command_line

        mov     rcx, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
        call    SetProcessDpiAwarenessContext

        mov     rcx, r13                     ; HINSTANCE
        mov     rdx, r14                     ; raw command line
        xor     r8d, r8d                     ; nCmdShow is not used by host
        call    vk_voodka_host_main

        add     rsp, 0x28
        pop     r14
        pop     r13
        pop     r12
        pop     rbp
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
