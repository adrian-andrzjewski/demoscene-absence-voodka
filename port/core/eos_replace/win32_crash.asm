; win32_crash.asm - production assembly exception-filter registration.
;
; The callback is native x64 assembly; crash formatting remains in the C++
; logger until logging is migrated, preserving the existing diagnostic output.

BITS 64
DEFAULT REL

%include "win64_abi.inc"

extern SetUnhandledExceptionFilter
extern vk_crash_report

global asm_install_crash_filter
global asm_voodka_crash_filter

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
        sub     rsp, 0x20                    ; RSP%16 == 0 at CALL
        call    vk_crash_report
        add     rsp, 0x20
        pop     rbp
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
