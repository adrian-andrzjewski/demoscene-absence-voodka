; win32_crash.asm - production assembly exception-filter registration/report.
;
; The formatter preserves the existing three diagnostic lines and delegates
; only the printf-style sink to the narrow platform logger ABI.

BITS 64
DEFAULT REL

%include "win64_abi.inc"

extern SetUnhandledExceptionFilter
extern vk_log_printf
extern vk_shutdown_log_flush

; EXCEPTION_POINTERS: ExceptionRecord at +0, ContextRecord at +8.
%define ER_EXCEPTION_CODE         0
%define ER_EXCEPTION_ADDRESS      16

; x64 CONTEXT register offsets from WinNT.h's AMD64 layout.
%define CX_RAX                     120
%define CX_RCX                     128
%define CX_RDX                     136
%define CX_RBX                     144
%define CX_RSP                     152
%define CX_RBP                     160
%define CX_RSI                     168
%define CX_RDI                     176
%define CX_RIP                     248

global asm_install_crash_filter
global asm_voodka_crash_filter

section .text

section .data
crash_line_code: db "[CRASH] code=0x%08x at %p", 10, 0
crash_line_low:  db "[CRASH] rax=%p rbx=%p rcx=%p rdx=%p", 10, 0
crash_line_high: db "[CRASH] rsi=%p rdi=%p rbp=%p rsp=%p rip=%p", 10, 0

section .text

; void asm_install_crash_filter(void)
asm_install_crash_filter:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20                    ; RSP%16 == 0 at CALL
        lea     rcx, [rel asm_voodka_crash_filter]
        call    SetUnhandledExceptionFilter
        add     rsp, 0x20
        pop     rbp
        ret

; LONG WINAPI asm_voodka_crash_filter(EXCEPTION_POINTERS* ep)
asm_voodka_crash_filter:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        push    r14
        sub     rsp, 0x28                    ; two possible stack arguments
        mov     r12, rcx                     ; EXCEPTION_POINTERS*
        test    r12, r12
        jz      .return_search
        mov     r13, [r12 + 0]               ; EXCEPTION_RECORD*
        mov     r14, [r12 + 8]               ; CONTEXT*
        test    r13, r13
        jz      .return_search
        test    r14, r14
        jz      .return_search

        lea     rcx, [rel crash_line_code]
        mov     edx, [r13 + ER_EXCEPTION_CODE]
        mov     r8,  [r13 + ER_EXCEPTION_ADDRESS]
        call    vk_log_printf

        lea     rcx, [rel crash_line_low]
        mov     rdx, [r14 + CX_RAX]
        mov     r8,  [r14 + CX_RBX]
        mov     r9,  [r14 + CX_RCX]
        mov     rax, [r14 + CX_RDX]
        mov     [rsp + 0x20], rax
        call    vk_log_printf

        lea     rcx, [rel crash_line_high]
        mov     rdx, [r14 + CX_RSI]
        mov     r8,  [r14 + CX_RDI]
        mov     r9,  [r14 + CX_RBP]
        mov     rax, [r14 + CX_RSP]
        mov     [rsp + 0x20], rax
        mov     rax, [r14 + CX_RIP]
        mov     [rsp + 0x28], rax
        call    vk_log_printf
        call    vk_shutdown_log_flush
.return_search:
        xor     eax, eax                    ; EXCEPTION_CONTINUE_SEARCH
        add     rsp, 0x28
        pop     r14
        pop     r13
        pop     r12
        pop     rbp
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
