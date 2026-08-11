; win32_app_window.asm - production VOODKA window bootstrap in x64 assembly.
;
; The shipped target owns Win32 class/window registration, geometry, focus,
; and teardown here. The C++ reference executable retains its original path
; solely as a differential oracle.

BITS 64
DEFAULT REL

%include "win64_abi.inc"
%include "window_title.inc"

%define CS_HREDRAW                  0x0002
%define CS_VREDRAW                  0x0001
%define IDC_ARROW                   0x00007F00
%define BLACK_BRUSH                 4
%define WS_OVERLAPPEDWINDOW         0x00CF0000
%define WS_EX_TOPMOST               0x00000008
%define SW_SHOW                     5
%define HWND_TOPMOST                -1
%define SWP_NOSIZE                  0x0001
%define SWP_NOMOVE                  0x0002
%define SWP_NOACTIVATE              0x0010
%define MONITOR_DEFAULTTOPRIMARY    2
%define SM_CXSCREEN                 0
%define SM_CYSCREEN                 1

; WNDCLASSW field offsets (x64 Windows SDK layout).
%define WC_STYLE                    0
%define WC_WNDPROC                  8
%define WC_HINSTANCE                24
%define WC_HCURSOR                  40
%define WC_HBRBACKGROUND            48
%define WC_CLASSNAME                64
%define WC_BYTES                    72

; MONITORINFO and RECT layouts are fixed-width Win32 structures.
%define MI_CBSIZE                   0
%define MI_RCWORK                   20             ; rcWork.left

extern asm_voodka_wndproc
extern RegisterClassW
extern UnregisterClassW
extern LoadCursorW
extern GetStockObject
extern AdjustWindowRectEx
extern MonitorFromPoint
extern GetMonitorInfoW
extern GetSystemMetrics
extern CreateWindowExW
extern ShowWindow
extern UpdateWindow
extern SetWindowPos
extern SetForegroundWindow
extern SetActiveWindow
extern SetFocus
extern IsWindow
extern DestroyWindow

global asm_create_voodka_window
global asm_destroy_voodka_window

section .bss
align 8
app_wndclass:       resb WC_BYTES
app_client_rect:    resb 16
app_work_rect:      resb 16
app_monitor_info:   resb 40

section .data
align 2
app_class_name:     dw 'V','O','O','D','K','A',0
app_window_title:
        VOODKA_EMIT_WINDOW_TITLE_W

section .text

; HWND asm_create_voodka_window(HINSTANCE hInst)
;
; The local frame supplies CreateWindowExW's eight stack arguments and keeps
; the Win64 call-site aligned. The work-area calculation intentionally mirrors
; app.cpp: primary monitor work area, fallback to primary screen, centered and
; clamped, with the taskbar left visible.
asm_create_voodka_window:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0xA8                    ; RSP%16 == 0 at every CALL

        mov     r12, rcx                     ; HINSTANCE

        ; Rebuild the WNDCLASSW value on every call; this makes a failed
        ; bootstrap retryable and keeps all unused fields explicitly zero.
        lea     rdi, [rel app_wndclass]
        xor     eax, eax
        mov     ecx, WC_BYTES / 8
        rep stosq
        mov     dword [rel app_wndclass + WC_STYLE], CS_HREDRAW | CS_VREDRAW
        lea     rax, [rel asm_voodka_wndproc]
        mov     [rel app_wndclass + WC_WNDPROC], rax
        mov     [rel app_wndclass + WC_HINSTANCE], r12
        xor     ecx, ecx                    ; LoadCursorW(NULL, IDC_ARROW)
        mov     edx, IDC_ARROW
        call    LoadCursorW
        mov     [rel app_wndclass + WC_HCURSOR], rax
        mov     ecx, BLACK_BRUSH
        call    GetStockObject
        mov     [rel app_wndclass + WC_HBRBACKGROUND], rax
        lea     rax, [rel app_class_name]
        mov     [rel app_wndclass + WC_CLASSNAME], rax
        lea     rcx, [rel app_wndclass]
        call    RegisterClassW
        test    eax, eax
        jz      .fail

        ; RECT client dimensions: 320x200 logic upscaled exactly 4x.
        mov     dword [rel app_client_rect + 0], 0
        mov     dword [rel app_client_rect + 4], 0
        mov     dword [rel app_client_rect + 8], 1280
        mov     dword [rel app_client_rect + 12], 800
        lea     rcx, [rel app_client_rect]
        mov     edx, WS_OVERLAPPEDWINDOW
        xor     r8d, r8d                    ; no menu
        mov     r9d, WS_EX_TOPMOST
        call    AdjustWindowRectEx
        test    eax, eax
        jz      .fail_unregister

        mov     eax, [rel app_client_rect + 8]
        sub     eax, [rel app_client_rect + 0]
        mov     r14d, eax                   ; outer window width
        mov     eax, [rel app_client_rect + 12]
        sub     eax, [rel app_client_rect + 4]
        mov     r15d, eax                   ; outer window height

        ; Primary monitor work area, with the same full-screen fallback.
        xor     ecx, ecx                    ; POINT {0,0}
        mov     edx, MONITOR_DEFAULTTOPRIMARY
        call    MonitorFromPoint
        mov     rbx, rax
        test    rbx, rbx
        jz      .fallback_work_area
        mov     dword [rel app_monitor_info + MI_CBSIZE], 40
        mov     rcx, rbx
        lea     rdx, [rel app_monitor_info]
        call    GetMonitorInfoW
        test    eax, eax
        jz      .fallback_work_area
        lea     rsi, [rel app_monitor_info + MI_RCWORK]
        jmp     .have_work_area

.fallback_work_area:
        mov     dword [rel app_work_rect + 0], 0
        mov     dword [rel app_work_rect + 4], 0
        mov     ecx, SM_CXSCREEN
        call    GetSystemMetrics
        mov     [rel app_work_rect + 8], eax
        mov     ecx, SM_CYSCREEN
        call    GetSystemMetrics
        mov     [rel app_work_rect + 12], eax
        lea     rsi, [rel app_work_rect]

.have_work_area:
        mov     eax, [rsi + 8]
        sub     eax, [rsi + 0]
        sub     eax, r14d
        sar     eax, 1
        add     eax, [rsi + 0]
        mov     [rel app_client_rect + 0], eax
        cmp     eax, [rsi + 0]
        jge     .x_clamped
        mov     eax, [rsi + 0]
        mov     [rel app_client_rect + 0], eax
.x_clamped:

        mov     eax, [rsi + 12]
        sub     eax, [rsi + 4]
        sub     eax, r15d
        sar     eax, 1
        add     eax, [rsi + 4]
        mov     [rel app_client_rect + 4], eax
        cmp     eax, [rsi + 4]
        jge     .y_clamped
        mov     eax, [rsi + 4]
        mov     [rel app_client_rect + 4], eax
.y_clamped:

        mov     eax, [rel app_client_rect + 0]
        add     eax, r14d
        mov     [rel app_client_rect + 8], eax
        mov     eax, [rel app_client_rect + 4]
        add     eax, r15d
        mov     [rel app_client_rect + 12], eax

        ; CreateWindowExW has eight stack arguments after the first four.
        mov     ecx, WS_EX_TOPMOST
        lea     rdx, [rel app_class_name]
        lea     r8,  [rel app_window_title]
        mov     r9d, WS_OVERLAPPEDWINDOW
        mov     eax, [rel app_client_rect + 0]
        mov     [rsp + 0x20], rax             ; x
        mov     eax, [rel app_client_rect + 4]
        mov     [rsp + 0x28], rax             ; y
        mov     eax, r14d
        mov     [rsp + 0x30], rax             ; width
        mov     eax, r15d
        mov     [rsp + 0x38], rax             ; height
        mov     qword [rsp + 0x40], 0         ; parent
        mov     qword [rsp + 0x48], 0         ; menu
        mov     [rsp + 0x50], r12             ; instance
        mov     qword [rsp + 0x58], 0         ; lpParam
        call    CreateWindowExW
        test    rax, rax
        jz      .fail_unregister
        mov     r13, rax

        mov     rcx, r13
        mov     edx, SW_SHOW
        call    ShowWindow
        mov     rcx, r13
        call    UpdateWindow
        mov     rcx, r13
        mov     rdx, HWND_TOPMOST
        xor     r8d, r8d
        xor     r9d, r9d
        mov     qword [rsp + 0x20], 0
        mov     qword [rsp + 0x28], 0
        mov     qword [rsp + 0x30], SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE
        call    SetWindowPos
        mov     rcx, r13
        call    SetForegroundWindow
        mov     rcx, r13
        call    SetActiveWindow
        mov     rcx, r13
        call    SetFocus

        mov     rax, r13
        jmp     .return

.fail_unregister:
        lea     rcx, [rel app_class_name]
        mov     rdx, r12
        call    UnregisterClassW
.fail:
        xor     eax, eax

.return:
        add     rsp, 0xA8
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; void asm_destroy_voodka_window(HWND hwnd, HINSTANCE hInst)
asm_destroy_voodka_window:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        sub     rsp, 0x20
        mov     r12, rcx                     ; HWND
        mov     r13, rdx                     ; HINSTANCE
        test    r12, r12
        jz      .unregister
        mov     rcx, r12
        call    IsWindow
        test    eax, eax
        jz      .unregister
        mov     rcx, r12
        call    DestroyWindow
.unregister:
        test    r13, r13
        jz      .done
        lea     rcx, [rel app_class_name]
        mov     rdx, r13
        call    UnregisterClassW
.done:
        add     rsp, 0x20
        pop     r13
        pop     r12
        pop     rbp
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
