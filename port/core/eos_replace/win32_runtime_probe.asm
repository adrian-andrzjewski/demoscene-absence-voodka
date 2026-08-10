; win32_runtime_probe.asm - no-CRT Win64 Win32/thread feasibility probe.
;
; Phase 3A deliberately keeps the scope small and observable.  The process
; entry point, WNDCLASSEXA registration, hidden HWND, WndProc, message pump,
; worker thread, event, interlocked counter, exception-filter installation,
; and orderly teardown are all native x64 assembly.  The probe exits through
; ExitProcess, so it does not depend on a C/C++ startup or shutdown object.

BITS 64
DEFAULT REL

%include "win64_abi.inc"

%define CS_HREDRAW                  0x0002
%define CS_VREDRAW                  0x0001
%define COLOR_WINDOW                5
%define WS_OVERLAPPEDWINDOW         0x00CF0000
%define SW_HIDE                     0
%define WM_CLOSE                    0x0010
%define WM_DESTROY                  0x0002
%define WAIT_OBJECT_0               0
%define WAIT_TIMEOUT                258
%define INFINITE                    0xFFFFFFFF

extern GetModuleHandleA
extern RegisterClassExA
extern UnregisterClassA
extern CreateWindowExA
extern ShowWindow
extern UpdateWindow
extern DestroyWindow
extern DefWindowProcA
extern SendMessageA
extern GetMessageA
extern TranslateMessage
extern DispatchMessageA
extern PostQuitMessage
extern CreateEventA
extern CreateThread
extern Sleep
extern SetEvent
extern WaitForSingleObject
extern CloseHandle
extern SetUnhandledExceptionFilter
extern ExitProcess

global asm_runtime_probe_entry
global asm_runtime_probe_wndproc
global asm_runtime_probe_worker
global asm_runtime_probe_exception_filter

section .bss
align 8
probe_class:        resb 80             ; WNDCLASSEXA
probe_message:      resb 48             ; MSG
probe_counter:      resd 1
probe_worker_result:resd 1              ; 0 = observed stop event
probe_instance:     resq 1
probe_window:       resq 1
probe_stop_event:   resq 1
probe_thread:       resq 1

section .data
align 8
probe_class_name:   db "VOODKA_ASM_RUNTIME_PROBE", 0
probe_window_title: db "VOODKA assembly runtime probe", 0

section .text

; The callback is installed as a real unhandled-exception filter.  Phase 3A
; validates registration and ABI reachability; later phases will add a
; deliberate exception and unwind-record verification.
asm_runtime_probe_exception_filter:
        xor     eax, eax                    ; EXCEPTION_CONTINUE_SEARCH
        ret

; DWORD WINAPI worker(LPVOID stopEvent)
asm_runtime_probe_worker:
        push    rbp
        mov     rbp, rsp
        push    r12
        sub     rsp, 0x28                    ; RSP%16 == 0 at every CALL

        mov     r12, rcx
        ; MSVC exposes InterlockedIncrement as an intrinsic rather than a
        ; kernel32 import on this target.  Its Win64 implementation is the
        ; same locked read-modify-write operation.
        lock    inc dword [rel probe_counter]

        ; A timeout is not success: keep waiting until the main thread's
        ; explicit event signal is observed.
.worker_wait:
        mov     rcx, r12
        mov     edx, 1000
        call    WaitForSingleObject
        cmp     eax, WAIT_OBJECT_0
        je      .worker_signaled
        cmp     eax, WAIT_TIMEOUT
        je      .worker_wait
        mov     dword [rel probe_worker_result], 1
        jmp     .worker_done

.worker_signaled:
        mov     dword [rel probe_worker_result], 0

.worker_done:
        xor     eax, eax
        add     rsp, 0x28
        pop     r12
        pop     rbp
        ret

; LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM)
asm_runtime_probe_wndproc:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20                    ; shadow space for Win32 calls

        cmp     edx, WM_CLOSE
        je      .close
        cmp     edx, WM_DESTROY
        je      .destroy

        call    DefWindowProcA
        add     rsp, 0x20
        pop     rbp
        ret

.close:
        call    DestroyWindow
        xor     eax, eax
        add     rsp, 0x20
        pop     rbp
        ret

.destroy:
        xor     ecx, ecx
        call    PostQuitMessage
        xor     eax, eax
        add     rsp, 0x20
        pop     rbp
        ret

; Process entry.  There is no CRT return address to preserve: every path ends
; in ExitProcess.  Align a private frame before making any Win64 API call.
asm_runtime_probe_entry:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15
        and     rsp, -16
        sub     rsp, 0x80                    ; CreateWindowExA stack args

        xor     eax, eax
        mov     [rel probe_counter], eax
        mov     dword [rel probe_worker_result], 0xFFFFFFFF
        mov     [rel probe_window], rax
        mov     [rel probe_stop_event], rax
        mov     [rel probe_thread], rax

        xor     ecx, ecx
        call    GetModuleHandleA
        test    rax, rax
        jz      .fail
        mov     r12, rax
        mov     [rel probe_instance], r12

        ; Zero and populate WNDCLASSEXA.  The structure is 80 bytes on Win64.
        lea     rdi, [rel probe_class]
        xor     eax, eax
        mov     ecx, 80 / 8
        rep     stosq
        mov     dword [rel probe_class + 0], 80
        mov     dword [rel probe_class + 4], CS_HREDRAW | CS_VREDRAW
        lea     rax, [rel asm_runtime_probe_wndproc]
        mov     [rel probe_class + 8], rax
        mov     [rel probe_class + 24], r12
        mov     qword [rel probe_class + 48], COLOR_WINDOW + 1
        lea     rax, [rel probe_class_name]
        mov     [rel probe_class + 64], rax
        lea     rcx, [rel probe_class]
        call    RegisterClassExA
        test    eax, eax
        jz      .fail

        ; Install a real process-wide unhandled-exception filter.
        lea     rcx, [rel asm_runtime_probe_exception_filter]
        call    SetUnhandledExceptionFilter

        ; CreateWindowExA has eight stack arguments after the first four.
        xor     ecx, ecx
        lea     rdx, [rel probe_class_name]
        lea     r8,  [rel probe_window_title]
        mov     r9d, WS_OVERLAPPEDWINDOW
        mov     qword [rsp + 0x20], 0         ; X
        mov     qword [rsp + 0x28], 0         ; Y
        mov     qword [rsp + 0x30], 32        ; width
        mov     qword [rsp + 0x38], 32        ; height
        mov     qword [rsp + 0x40], 0         ; parent
        mov     qword [rsp + 0x48], 0         ; menu
        mov     [rsp + 0x50], r12            ; instance
        mov     qword [rsp + 0x58], 0         ; lpParam
        call    CreateWindowExA
        test    rax, rax
        jz      .fail
        mov     r13, rax
        mov     [rel probe_window], r13

        mov     rcx, r13
        mov     edx, SW_HIDE
        call    ShowWindow
        mov     rcx, r13
        call    UpdateWindow

        ; Manual-reset stop event, initially nonsignaled.
        xor     ecx, ecx
        mov     edx, 1
        xor     r8d, r8d
        xor     r9d, r9d
        call    CreateEventA
        test    rax, rax
        jz      .fail
        mov     r14, rax
        mov     [rel probe_stop_event], r14

        ; CreateThread(NULL, 0, worker, stopEvent, 0, NULL).
        xor     ecx, ecx
        xor     edx, edx
        lea     r8, [rel asm_runtime_probe_worker]
        mov     r9, r14
        mov     qword [rsp + 0x20], 0         ; creation flags
        mov     qword [rsp + 0x28], 0         ; thread id
        call    CreateThread
        test    rax, rax
        jz      .fail
        mov     r15, rax
        mov     [rel probe_thread], r15

        mov     ecx, 20
        call    Sleep
        mov     rcx, r14
        call    SetEvent
        test    eax, eax
        jz      .fail

        mov     rcx, r15
        mov     edx, INFINITE
        call    WaitForSingleObject
        cmp     eax, WAIT_OBJECT_0
        jne     .fail
        mov     rcx, r15
        call    CloseHandle
        mov     rcx, r14
        call    CloseHandle
        mov     qword [rel probe_thread], 0
        mov     qword [rel probe_stop_event], 0

        cmp     dword [rel probe_counter], 1
        jb      .fail
        cmp     dword [rel probe_worker_result], 0
        jne     .fail

        ; Exercise the WndProc -> DestroyWindow -> WM_DESTROY -> WM_QUIT
        ; message-pump chain synchronously.
        mov     rcx, r13
        mov     edx, WM_CLOSE
        xor     r8d, r8d
        xor     r9d, r9d
        call    SendMessageA

.message_loop:
        lea     rcx, [rel probe_message]
        xor     edx, edx
        xor     r8d, r8d
        xor     r9d, r9d
        call    GetMessageA
        cmp     eax, 0
        je      .message_done
        js      .fail
        lea     rcx, [rel probe_message]
        call    TranslateMessage
        lea     rcx, [rel probe_message]
        call    DispatchMessageA
        jmp     .message_loop

.message_done:
        lea     rcx, [rel probe_class_name]
        mov     rdx, r12
        call    UnregisterClassA
        test    eax, eax
        jz      .fail

        xor     ecx, ecx
        call    ExitProcess
        ud2

.fail:
        mov     ecx, 1
        call    ExitProcess
        ud2
