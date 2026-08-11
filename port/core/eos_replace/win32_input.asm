; win32_input.asm - production assembly global Escape watcher.
;
; The main-thread key map and message pump stay in input.cpp for this gate.
; This file owns the asynchronous watcher, its event/thread handles, and the
; deterministic start/stop protocol used during loading and teardown.

BITS 64
DEFAULT REL

%include "win64_abi.inc"

%define VK_ESCAPE                   0x1B
%define WM_CLOSE                    0x0010
%define WAIT_OBJECT_0               0
%define TRUE_VALUE                  1

extern CreateEventW
extern CreateThread
extern WaitForSingleObject
extern SetEvent
extern CloseHandle
extern GetAsyncKeyState
extern PostMessageW
extern PeekMessageW
extern TranslateMessage
extern DispatchMessageW
extern vk_request_quit

global asm_input_init
global asm_input_shutdown
global asm_input_worker
global asm_input_key_map
global asm_input_key_down
global asm_input_key_up
global asm_input_key_reset
global asm_input_key_is_down
global asm_input_clear_escape
global asm_input_escape_queued
global asm_input_update

section .bss
align 8
asm_input_window:    resq 1
asm_input_stop:      resq 1
asm_input_thread:    resq 1
asm_input_keys:      resb 128
asm_input_escape:    resb 1
align 8
asm_input_message:   resb 48

section .text

; DWORD WINAPI asm_input_worker(LPVOID unused)
asm_input_worker:
        push    rbp
        mov     rbp, rsp
        push    r12
        sub     rsp, 0x28                    ; RSP%16 == 0 at CALL sites
        xor     r12d, r12d                   ; wasDown = false

.loop:
        mov     rcx, [rel asm_input_stop]
        test    rcx, rcx
        jz      .done
        mov     edx, 8
        call    WaitForSingleObject
        cmp     eax, WAIT_OBJECT_0
        je      .done

        mov     ecx, VK_ESCAPE
        call    GetAsyncKeyState
        test    eax, 0x8000
        jz      .released
        test    r12d, r12d
        jnz     .loop
        mov     r12d, TRUE_VALUE
        call    vk_request_quit
        mov     rcx, [rel asm_input_window]
        test    rcx, rcx
        jz      .loop
        mov     edx, WM_CLOSE
        xor     r8d, r8d
        xor     r9d, r9d
        call    PostMessageW
        jmp     .loop

.released:
        xor     r12d, r12d
        jmp     .loop

.done:
        xor     eax, eax
        add     rsp, 0x28
        pop     r12
        pop     rbp
        ret

; int asm_input_init(HWND hwnd)
asm_input_init:
        push    rbp
        mov     rbp, rsp
        push    r12
        sub     rsp, 0x38                    ; RSP%16 == 0; two stack args
        mov     r12, rcx
        cmp     qword [rel asm_input_thread], 0
        jne     .already_running
        mov     [rel asm_input_window], r12

        xor     ecx, ecx                    ; manual reset, initially off
        mov     edx, 1
        xor     r8d, r8d
        xor     r9d, r9d
        call    CreateEventW
        test    rax, rax
        jz      .fail
        mov     [rel asm_input_stop], rax

        xor     ecx, ecx
        xor     edx, edx
        lea     r8, [rel asm_input_worker]
        xor     r9d, r9d
        mov     qword [rsp + 0x20], 0         ; creation flags
        mov     qword [rsp + 0x28], 0         ; thread id
        call    CreateThread
        test    rax, rax
        jz      .fail_close_event
        mov     [rel asm_input_thread], rax
        mov     eax, TRUE_VALUE
        jmp     .return

.already_running:
        mov     eax, TRUE_VALUE
        jmp     .return

.fail_close_event:
        mov     rcx, [rel asm_input_stop]
        call    CloseHandle
        mov     qword [rel asm_input_stop], 0
.fail:
        mov     qword [rel asm_input_window], 0
        xor     eax, eax
.return:
        add     rsp, 0x38
        pop     r12
        pop     rbp
        ret

; void asm_input_shutdown(void)
asm_input_shutdown:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20                    ; RSP%16 == 0 at CALL sites
        mov     rcx, [rel asm_input_stop]
        test    rcx, rcx
        jz      .wait_thread
        call    SetEvent
.wait_thread:
        mov     rcx, [rel asm_input_thread]
        test    rcx, rcx
        jz      .close_stop
        mov     edx, 0xFFFFFFFF
        call    WaitForSingleObject
        mov     rcx, [rel asm_input_thread]
        call    CloseHandle
        mov     qword [rel asm_input_thread], 0
.close_stop:
        mov     rcx, [rel asm_input_stop]
        test    rcx, rcx
        jz      .clear
        call    CloseHandle
        mov     qword [rel asm_input_stop], 0
.clear:
        mov     qword [rel asm_input_window], 0
        add     rsp, 0x20
        pop     rbp
        ret

; uint8_t* asm_input_key_map(void)
asm_input_key_map:
        lea     rax, [rel asm_input_keys]
        ret

; void asm_input_key_down(uint32_t scancode)
asm_input_key_down:
        cmp     ecx, 128
        jae     .key_down_done
        lea     rax, [rel asm_input_keys]
        mov     byte [rax + rcx], 1
        cmp     ecx, 1
        jne     .key_down_done
        mov     byte [rel asm_input_escape], 1
        call    vk_request_quit
.key_down_done:
        ret

; void asm_input_key_up(uint32_t scancode)
asm_input_key_up:
        cmp     ecx, 128
        jae     .key_up_done
        lea     rax, [rel asm_input_keys]
        mov     byte [rax + rcx], 0
.key_up_done:
        ret

; void asm_input_key_reset(void)
asm_input_key_reset:
        lea     rax, [rel asm_input_keys]
        xor     ecx, ecx
.reset_loop:
        mov     byte [rax + rcx], 0
        inc     ecx
        cmp     ecx, 128
        jb      .reset_loop
        ret

; int asm_input_key_is_down(int scancode)
asm_input_key_is_down:
        cmp     ecx, 0
        jl      .key_not_down
        cmp     ecx, 128
        jae     .key_not_down
        lea     rax, [rel asm_input_keys]
        movzx   eax, byte [rax + rcx]
        ret
.key_not_down:
        xor     eax, eax
        ret

; void asm_input_clear_escape(void)
asm_input_clear_escape:
        mov     byte [rel asm_input_escape], 0
        ret

; int asm_input_escape_queued(void)
asm_input_escape_queued:
        movzx   eax, byte [rel asm_input_escape]
        ret

; void asm_input_update(void)
;
; PeekMessageW uses one stack argument (PM_REMOVE), so the 0x20-byte frame is
; the mandatory home area and the call-site remains 16-byte aligned.
asm_input_update:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x30
.message_loop:
        lea     rcx, [rel asm_input_message]
        xor     edx, edx
        xor     r8d, r8d
        xor     r9d, r9d
        mov     qword [rsp + 0x20], 1         ; PM_REMOVE
        call    PeekMessageW
        test    eax, eax
        jz      .message_done
        cmp     dword [rel asm_input_message + 8], 0x0012 ; WM_QUIT
        jne     .dispatch
        call    vk_request_quit
        jmp     .message_loop
.dispatch:
        lea     rcx, [rel asm_input_message]
        call    TranslateMessage
        lea     rcx, [rel asm_input_message]
        call    DispatchMessageW
        jmp     .message_loop
.message_done:
        add     rsp, 0x30
        pop     rbp
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
