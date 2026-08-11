; win32_timeline.asm - production timeline file sink.
;
; The C++ reference target retains stdio for differential comparison. The
; shipped target owns the timeline handle and raw Win32 write lifecycle here;
; formatting is supplied by win32_log_format.asm into a caller buffer.

BITS 64
DEFAULT REL

%include "win64_abi.inc"

%define GENERIC_WRITE               0x40000000
%define FILE_SHARE_READ             0x00000001
%define CREATE_ALWAYS               2
%define FILE_ATTRIBUTE_NORMAL       0x00000080
%define INVALID_HANDLE_VALUE        0xFFFFFFFFFFFFFFFF

extern CreateFileA
extern WriteFile
extern FlushFileBuffers
extern CloseHandle

global asm_timeline_open
global asm_timeline_write
global asm_timeline_flush
global asm_timeline_close

section .bss
align 8
asm_timeline_handle: resq 1

section .text

; int asm_timeline_open(const char* path)
asm_timeline_open:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x40
        test    rcx, rcx
        jz      .fail
        mov     edx, GENERIC_WRITE
        mov     r8d, FILE_SHARE_READ
        xor     r9d, r9d
        mov     qword [rsp + 0x20], CREATE_ALWAYS
        mov     qword [rsp + 0x28], FILE_ATTRIBUTE_NORMAL
        mov     qword [rsp + 0x30], 0
        call    CreateFileA
        mov     [rel asm_timeline_handle], rax
        cmp     rax, INVALID_HANDLE_VALUE
        sete    al
        xor     ecx, ecx
        test    al, al
        setz    cl
        mov     eax, ecx
        jmp     .return
.fail:
        mov     qword [rel asm_timeline_handle], INVALID_HANDLE_VALUE
        xor     eax, eax
.return:
        add     rsp, 0x40
        pop     rbp
        ret

; int asm_timeline_write(const char* bytes, uint32_t length)
asm_timeline_write:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x40
        mov     r10, rcx
        mov     r11d, edx
        mov     dword [rsp + 0x38], r11d
        mov     rcx, [rel asm_timeline_handle]
        cmp     rcx, INVALID_HANDLE_VALUE
        je      .fail
        test    rcx, rcx
        jz      .fail
        mov     rdx, r10
        mov     r8d, r11d
        lea     r9, [rsp + 0x30]
        mov     qword [rsp + 0x20], 0
        call    WriteFile
        test    eax, eax
        jz      .fail
        mov     eax, dword [rsp + 0x30]
        cmp     eax, dword [rsp + 0x38]
        jne     .fail
        mov     eax, 1
        jmp     .return
.fail:
        xor     eax, eax
.return:
        add     rsp, 0x40
        pop     rbp
        ret

; void asm_timeline_flush(void)
asm_timeline_flush:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20
        mov     rcx, [rel asm_timeline_handle]
        cmp     rcx, INVALID_HANDLE_VALUE
        je      .done
        test    rcx, rcx
        jz      .done
        call    FlushFileBuffers
.done:
        add     rsp, 0x20
        pop     rbp
        ret

; void asm_timeline_close(void)
asm_timeline_close:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20
        call    asm_timeline_flush
        mov     rcx, [rel asm_timeline_handle]
        cmp     rcx, INVALID_HANDLE_VALUE
        je      .clear
        test    rcx, rcx
        jz      .clear
        call    CloseHandle
.clear:
        mov     qword [rel asm_timeline_handle], INVALID_HANDLE_VALUE
        add     rsp, 0x20
        pop     rbp
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
