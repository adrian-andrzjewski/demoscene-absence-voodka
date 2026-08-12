; win32_lifecycle.asm - production lifecycle automation worker.
;
; The worker injects the same Win32 Space and close messages used by the C++
; reference host.  It is deliberately independent of the demo/audio state:
; the message handler and the normal shutdown path remain the authorities for
; pause, quit, and resource cleanup.

BITS 64
DEFAULT REL

%include "win64_abi.inc"

%define VK_SPACE                   0x20
%define WM_KEYDOWN                 0x0100
%define WM_KEYUP                   0x0101
%define WM_CLOSE                   0x0010
%define WAIT_OBJECT_0              0
%define INFINITE                   0xFFFFFFFF

extern CreateEventW
extern CreateThread
extern WaitForSingleObject
extern SetEvent
extern CloseHandle
extern GetTickCount64
extern PostMessageW

global asm_lifecycle_start
global asm_lifecycle_stop
global asm_lifecycle_worker

section .bss
align 8
asm_lifecycle_window:      resq 1
asm_lifecycle_stop_event:  resq 1
asm_lifecycle_thread:      resq 1
asm_lifecycle_pause_ms:    resd 1
asm_lifecycle_close_ms:    resd 1

section .text

; DWORD WINAPI asm_lifecycle_worker(LPVOID unused)
asm_lifecycle_worker:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        sub     rsp, 0x40                    ; shadow + two persistent locals
        call    GetTickCount64
        mov     r12, rax                     ; start tick
        xor     r13d, r13d                   ; bit 0 = paused, bit 1 = resumed

.loop:
        mov     rcx, [rel asm_lifecycle_stop_event]
        test    rcx, rcx
        jz      .done
        mov     edx, 5
        call    WaitForSingleObject
        cmp     eax, WAIT_OBJECT_0
        je      .done

        call    GetTickCount64
        sub     rax, r12
        mov     [rsp + 0x30], rax            ; elapsed, above call shadow space

        ; Post the first Space pair once the pause threshold is reached.
        mov     ecx, [rel asm_lifecycle_pause_ms]
        cmp     ecx, -1
        je      .check_resume
        test    r13d, 1
        jnz     .check_resume
        mov     r8d, ecx
        cmp     [rsp + 0x30], r8
        jb      .check_resume
        mov     rcx, [rel asm_lifecycle_window]
        mov     edx, WM_KEYDOWN
        mov     r8d, VK_SPACE
        mov     r9, 0x00390000
        call    PostMessageW
        mov     rcx, [rel asm_lifecycle_window]
        mov     edx, WM_KEYUP
        mov     r8d, VK_SPACE
        mov     r9, 0xC0390000
        call    PostMessageW
        or      r13d, 1

.check_resume:
        ; Resume one second after the pause injection, matching the C++ oracle.
        test    r13d, 1
        jz      .check_close
        test    r13d, 2
        jnz     .check_close
        mov     eax, [rel asm_lifecycle_pause_ms]
        add     eax, 1000
        mov     [rsp + 0x38], eax
        call    GetTickCount64
        sub     rax, r12
        mov     [rsp + 0x30], rax
        xor     edx, edx
        mov     edx, [rsp + 0x38]
        cmp     rax, rdx
        jb      .check_close
        mov     rcx, [rel asm_lifecycle_window]
        mov     edx, WM_KEYDOWN
        mov     r8d, VK_SPACE
        mov     r9, 0x00390000
        call    PostMessageW
        mov     rcx, [rel asm_lifecycle_window]
        mov     edx, WM_KEYUP
        mov     r8d, VK_SPACE
        mov     r9, 0xC0390000
        call    PostMessageW
        or      r13d, 2

.check_close:
        mov     ecx, [rel asm_lifecycle_close_ms]
        cmp     ecx, -1
        je      .loop
        mov     r8d, ecx
        cmp     [rsp + 0x30], r8
        jb      .loop
        mov     rcx, [rel asm_lifecycle_window]
        mov     edx, WM_CLOSE
        xor     r8d, r8d
        xor     r9d, r9d
        call    PostMessageW
        jmp     .done

.done:
        xor     eax, eax
        add     rsp, 0x40
        pop     r13
        pop     r12
        pop     rbp
        ret

; int asm_lifecycle_start(HWND hwnd, int32_t pauseMs, int32_t closeMs)
asm_lifecycle_start:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x30                    ; CreateThread has two stack args
        cmp     qword [rel asm_lifecycle_thread], 0
        jne     .already_running
        cmp     edx, -1
        jne     .enabled
        cmp     r8d, -1
        je      .success
.enabled:
        mov     [rel asm_lifecycle_window], rcx
        mov     [rel asm_lifecycle_pause_ms], edx
        mov     [rel asm_lifecycle_close_ms], r8d

        xor     ecx, ecx                    ; manual-reset, initially nonsignaled
        mov     edx, 1
        xor     r8d, r8d
        xor     r9d, r9d
        call    CreateEventW
        test    rax, rax
        jz      .fail
        mov     [rel asm_lifecycle_stop_event], rax

        xor     ecx, ecx
        xor     edx, edx
        lea     r8, [rel asm_lifecycle_worker]
        xor     r9d, r9d
        mov     qword [rsp + 0x20], 0         ; creation flags
        mov     qword [rsp + 0x28], 0         ; thread id
        call    CreateThread
        test    rax, rax
        jz      .fail_close_event
        mov     [rel asm_lifecycle_thread], rax
        mov     eax, 1
        jmp     .return

.already_running:
.success:
        mov     eax, 1
        jmp     .return

.fail_close_event:
        mov     rcx, [rel asm_lifecycle_stop_event]
        call    CloseHandle
        mov     qword [rel asm_lifecycle_stop_event], 0
.fail:
        mov     qword [rel asm_lifecycle_window], 0
        mov     dword [rel asm_lifecycle_pause_ms], -1
        mov     dword [rel asm_lifecycle_close_ms], -1
        xor     eax, eax
.return:
        add     rsp, 0x30
        pop     rbp
        ret

; void asm_lifecycle_stop(void)
asm_lifecycle_stop:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20
        mov     rcx, [rel asm_lifecycle_stop_event]
        test    rcx, rcx
        jz      .wait_thread
        call    SetEvent
.wait_thread:
        mov     rcx, [rel asm_lifecycle_thread]
        test    rcx, rcx
        jz      .close_event
        mov     edx, INFINITE
        call    WaitForSingleObject
        mov     rcx, [rel asm_lifecycle_thread]
        call    CloseHandle
        mov     qword [rel asm_lifecycle_thread], 0
.close_event:
        mov     rcx, [rel asm_lifecycle_stop_event]
        test    rcx, rcx
        jz      .clear
        call    CloseHandle
        mov     qword [rel asm_lifecycle_stop_event], 0
.clear:
        mov     qword [rel asm_lifecycle_window], 0
        mov     dword [rel asm_lifecycle_pause_ms], -1
        mov     dword [rel asm_lifecycle_close_ms], -1
        add     rsp, 0x20
        pop     rbp
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
