; win32_log.asm - production low-level file logging sink.
;
; NASM owns formatting, the Windows file/critical-section lifecycle, and byte
; writes used by VOODKA.exe. The reference target retains its C++ logger as an
; independent formatting oracle.

BITS 64
DEFAULT REL

%include "win64_abi.inc"

%define GENERIC_WRITE               0x40000000
%define FILE_SHARE_READ             0x00000001
%define CREATE_ALWAYS               2
%define FILE_ATTRIBUTE_NORMAL       0x00000080
%define INVALID_HANDLE_VALUE        0xFFFFFFFFFFFFFFFF
%define LOG_PATH_WORDS              260
%define CRITICAL_SECTION_BYTES      40

extern InitializeCriticalSection
extern DeleteCriticalSection
extern EnterCriticalSection
extern LeaveCriticalSection
extern GetModuleFileNameW
extern CreateFileW
extern WriteFile
extern FlushFileBuffers
extern CloseHandle

global asm_log_init
global asm_log_write
global asm_log_flush
global asm_log_shutdown

section .bss
align 8
asm_log_handle:       resq 1
asm_log_cs:           resb CRITICAL_SECTION_BYTES
asm_log_path:         resw LOG_PATH_WORDS
asm_log_initialized:  resd 1

section .data
align 2
asm_log_filename:     dw 'v','o','o','d','k','a','.','l','o','g',0

section .text

; int asm_log_init(void)
asm_log_init:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x40                    ; CreateFileW has 3 stack args
        cmp     dword [rel asm_log_initialized], 0
        jne     .already_initialized

        lea     rcx, [rel asm_log_cs]
        call    InitializeCriticalSection
        mov     dword [rel asm_log_initialized], 1

        xor     ecx, ecx                    ; current module
        lea     rdx, [rel asm_log_path]
        mov     r8d, LOG_PATH_WORDS
        call    GetModuleFileNameW
        test    eax, eax
        jz      .open_file

        ; Replace the executable filename while preserving its directory.
        mov     r10d, eax
        lea     r11, [rel asm_log_path]
        lea     rdi, [r11 + r10 * 2]
.find_slash:
        cmp     rdi, r11
        je      .at_path_start
        sub     rdi, 2
        mov     ax, [rdi]
        cmp     ax, 0x005C
        je      .after_slash
        cmp     ax, '/'
        jne     .find_slash
.after_slash:
        add     rdi, 2
        jmp     .copy_filename
.at_path_start:
        mov     rdi, r11
.copy_filename:
        lea     rsi, [rel asm_log_filename]
        mov     ecx, 11
        rep     movsw

.open_file:
        lea     rcx, [rel asm_log_path]
        mov     edx, GENERIC_WRITE
        mov     r8d, FILE_SHARE_READ
        xor     r9d, r9d                    ; lpSecurityAttributes
        mov     qword [rsp + 0x20], CREATE_ALWAYS
        mov     qword [rsp + 0x28], FILE_ATTRIBUTE_NORMAL
        mov     qword [rsp + 0x30], 0       ; hTemplateFile
        call    CreateFileW
        mov     [rel asm_log_handle], rax
        mov     eax, 1
        jmp     .return

.already_initialized:
        mov     eax, 1
.return:
        add     rsp, 0x40
        pop     rbp
        ret

; void asm_log_write(const char* bytes, uint32_t length)
asm_log_write:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        sub     rsp, 0x40                    ; local DWORD + WriteFile home
        mov     r12, rcx
        mov     r13d, edx
        cmp     dword [rel asm_log_initialized], 0
        je      .done
        mov     rax, [rel asm_log_handle]
        test    rax, rax
        jz      .done
        cmp     rax, INVALID_HANDLE_VALUE
        je      .done

        lea     rcx, [rel asm_log_cs]
        call    EnterCriticalSection
        mov     rcx, [rel asm_log_handle]
        mov     rdx, r12
        mov     r8d, r13d
        lea     r9, [rsp + 0x30]             ; lpNumberOfBytesWritten
        mov     qword [rsp + 0x20], 0        ; lpOverlapped
        call    WriteFile
        lea     rcx, [rel asm_log_cs]
        call    LeaveCriticalSection
.done:
        add     rsp, 0x40
        pop     r13
        pop     r12
        pop     rbp
        ret

; void asm_log_flush(void)
asm_log_flush:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20
        cmp     dword [rel asm_log_initialized], 0
        je      .done
        mov     rcx, [rel asm_log_handle]
        test    rcx, rcx
        jz      .done
        cmp     rcx, INVALID_HANDLE_VALUE
        je      .done
        call    FlushFileBuffers
.done:
        add     rsp, 0x20
        pop     rbp
        ret

; void asm_log_shutdown(void)
asm_log_shutdown:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20
        cmp     dword [rel asm_log_initialized], 0
        je      .done
        call    asm_log_flush
        mov     rcx, [rel asm_log_handle]
        test    rcx, rcx
        jz      .delete_cs
        cmp     rcx, INVALID_HANDLE_VALUE
        je      .delete_cs
        call    CloseHandle
.delete_cs:
        mov     qword [rel asm_log_handle], INVALID_HANDLE_VALUE
        lea     rcx, [rel asm_log_cs]
        call    DeleteCriticalSection
        mov     dword [rel asm_log_initialized], 0
.done:
        add     rsp, 0x20
        pop     rbp
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
