; win32_app_wndproc.asm - production VOODKA Win32 callback in x64 assembly.
;
; Phase 3B migrates the callback that sits on the real demo window. Window
; creation and the C++ reference lifecycle remain unchanged for this gate, but
; the shipped target now handles keyboard, pause, activation, paint, close,
; and destroy messages through this native Win64 entry point.

BITS 64
DEFAULT REL

%include "win64_abi.inc"

%define WM_PAINT                    0x000F
%define WM_ACTIVATE                 0x0006
%define WM_KEYDOWN                  0x0100
%define WM_KEYUP                    0x0101
%define WM_CLOSE                    0x0010
%define WM_DESTROY                  0x0002
%define WA_INACTIVE                 0
%define HWND_TOPMOST                -1
%define SWP_NOSIZE                  0x0001
%define SWP_NOMOVE                  0x0002
%define SWP_NOACTIVATE              0x0010

extern BeginPaint
extern EndPaint
extern SetWindowPos
extern DestroyWindow
extern PostQuitMessage
extern DefWindowProcW

; C ABI wrappers in bridge.cpp. Keeping these four calls unmangled makes the
; assembly callback independent of the C++ namespace and implementation.
extern vk_key_down
extern vk_key_up
extern vk_pause_toggle
extern vk_request_quit

global asm_voodka_wndproc

section .text

; LRESULT CALLBACK asm_voodka_wndproc(HWND, UINT, WPARAM, LPARAM)
;
; The local frame contains a PAINTSTRUCT at +0x20 (72 bytes) and a saved copy
; of all incoming arguments at +0x68..+0x78. Three nonvolatile registers are
; used, so the 0x80-byte allocation leaves RSP%16==0 at every bridge/API call.
asm_voodka_wndproc:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        sub     rsp, 0x80

        mov     r12, rcx                    ; HWND
        mov     qword [rsp + 0x68], rdx      ; UINT
        mov     qword [rsp + 0x70], r8       ; WPARAM
        mov     qword [rsp + 0x78], r9       ; LPARAM

        cmp     edx, WM_KEYDOWN
        je      .key_down
        cmp     edx, WM_KEYUP
        je      .key_up
        cmp     edx, WM_PAINT
        je      .paint
        cmp     edx, WM_ACTIVATE
        je      .activate
        cmp     edx, WM_CLOSE
        je      .close
        cmp     edx, WM_DESTROY
        je      .destroy
        jmp     .default

.key_down:
        mov     rax, [rsp + 0x78]
        mov     r13d, eax
        shr     r13d, 16
        and     r13d, 0xff
        test    eax, 0x01000000
        jz      .key_down_scancode_ready
        or      r13d, 0x80
.key_down_scancode_ready:
        mov     ecx, r13d
        and     ecx, 0x7f
        call    vk_key_down

        cmp     r13d, 0x39                  ; Space make code
        jne     .key_down_done
        test    qword [rsp + 0x78], 0x40000000 ; ignore auto-repeat
        jnz     .key_down_done
        call    vk_pause_toggle

.key_down_done:
        mov     ecx, r13d
        and     ecx, 0x7f
        call    vk_key_up
        xor     eax, eax
        jmp     .return_zero

.key_up:
        mov     rax, [rsp + 0x78]
        mov     r13d, eax
        shr     r13d, 16
        and     r13d, 0xff
        test    eax, 0x01000000
        jz      .key_up_scancode_ready
        or      r13d, 0x80
.key_up_scancode_ready:
        mov     ecx, r13d
        and     ecx, 0x7f
        call    vk_key_up
        xor     eax, eax
        jmp     .return_zero

.paint:
        mov     rcx, r12
        lea     rdx, [rsp + 0x20]
        call    BeginPaint
        mov     rcx, r12
        lea     rdx, [rsp + 0x20]
        call    EndPaint
        xor     eax, eax
        jmp     .return_zero

.activate:
        cmp     qword [rsp + 0x70], WA_INACTIVE
        je      .default
        mov     rcx, r12
        mov     rdx, HWND_TOPMOST
        xor     r8d, r8d                    ; X
        xor     r9d, r9d                    ; Y
        mov     qword [rsp + 0x20], 0       ; cx
        mov     qword [rsp + 0x28], 0       ; cy
        mov     qword [rsp + 0x30], SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE
        call    SetWindowPos
        jmp     .default

.close:
        call    vk_request_quit
        mov     rcx, r12
        call    DestroyWindow
        xor     eax, eax
        jmp     .return_zero

.destroy:
        call    vk_request_quit
        xor     ecx, ecx
        call    PostQuitMessage
        xor     eax, eax
        jmp     .return_zero

.default:
        mov     rcx, r12
        mov     rdx, [rsp + 0x68]
        mov     r8,  [rsp + 0x70]
        mov     r9,  [rsp + 0x78]
        call    DefWindowProcW
        jmp     .return

.return_zero:
        xor     eax, eax
.return:
        add     rsp, 0x80
        pop     r13
        pop     r12
        pop     rbp
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
