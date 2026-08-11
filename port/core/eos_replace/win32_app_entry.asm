; win32_app_entry.asm - production x64 assembly process/host entry.
;
; The shipped target enters through asm_voodka_process_entry with no CRT.
; asm_voodka_winmain remains a callable WinMain-shaped adapter for the
; reference/ABI boundary and for differential host tests.

BITS 64
DEFAULT REL

%include "win64_abi.inc"

%define DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 -4

extern GetModuleHandleA
extern GetCommandLineA
extern GetProcAddress
extern ExitProcess
extern asm_parse_command_line
extern asm_voodka_host_main

global asm_voodka_winmain
global asm_voodka_process_entry

section .bss
align 8
asm_instance_storage:       resq 1

section .rdata
user32_dll_name:            db 'user32.dll', 0
dpi_v2_proc_name:           db 'SetProcessDpiAwarenessContext', 0

section .text

; Resolve the Windows 10 1703+ DPI-V2 API at runtime. USER32 is already an
; import of the production image, but the symbol itself is not present on
; earlier Windows 10 releases. A missing module/export is a valid fallback:
; the process continues with the system's default DPI policy instead of
; failing in the PE loader before the demo can start.
asm_apply_dpi_awareness:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20                    ; RSP%16 == 0 at every CALL

        lea     rcx, [rel user32_dll_name]
        call    GetModuleHandleA
        test    rax, rax
        jz      .done

        mov     rcx, rax
        lea     rdx, [rel dpi_v2_proc_name]
        call    GetProcAddress
        test    rax, rax
        jz      .done

        mov     rcx, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
        call    rax

.done:
        add     rsp, 0x20
        pop     rbp
        ret

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

        call    asm_apply_dpi_awareness

        mov     rcx, r13                     ; HINSTANCE
        mov     rdx, r14                     ; raw command line
        xor     r8d, r8d                     ; nCmdShow is not used by host
        call    asm_voodka_host_main

        add     rsp, 0x28
        pop     r14
        pop     r13
        pop     r12
        pop     rbp
        ret

; Process entry used by the shipped /SUBSYSTEM:WINDOWS, /NODEFAULTLIB image.
; The OS does not provide WinMain arguments here, so acquire the two values
; required by the existing assembly host directly from Win32 and terminate
; through ExitProcess with the host result.  No return address is assumed.
asm_voodka_process_entry:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        and     rsp, -16
        sub     rsp, 0x20                    ; Win64 shadow space

        xor     ecx, ecx
        call    GetModuleHandleA
        mov     r12, rax

        call    GetCommandLineA
        mov     r13, rax
        mov     rcx, r13
        call    asm_parse_command_line

        call    asm_apply_dpi_awareness

        mov     rcx, r12
        mov     rdx, r13
        xor     r8d, r8d                     ; nCmdShow is not used by host
        call    asm_voodka_host_main

        mov     ecx, eax
        call    ExitProcess
        int3                                    ; ExitProcess is noreturn

section .note.GNU-stack noalloc noexec nowrite progbits
