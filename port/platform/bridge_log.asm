; bridge_log.asm - production variadic C logging bridge.
;
; MSVC x64 va_list is a cursor over eight-byte argument slots.  The wrapper
; homes register varargs and copies the caller's stack varargs into one
; contiguous cursor before invoking the proven NASM formatter and sink.

BITS 64
DEFAULT REL

extern asm_log_vformat
extern asm_log_write

global vk_log_printf

section .text

; void vk_log_printf(const char* fmt, ...)
vk_log_printf:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        push    rsi
        push    rdi
        sub     rsp, 0x2A0                   ; output + 16 va slots

        mov     r12, rcx                     ; format string
        mov     [rsp + 0x220], rdx           ; register varargs 1..3
        mov     [rsp + 0x228], r8
        mov     [rsp + 0x230], r9

        ; The first stack vararg is at the caller's home-area end:
        ; entry RSP + 0x28 == RBP + 0x30 after the frame setup above.
        lea     rsi, [rbp + 0x30]
        lea     rdi, [rsp + 0x238]
        mov     ecx, 13                      ; 3 register + 13 stack slots
        cld
        rep     movsq

        lea     rcx, [rsp + 0x20]            ; output buffer, 512 bytes
        mov     edx, 512
        mov     r8, r12
        lea     r9, [rsp + 0x220]
        call    asm_log_vformat
        test    eax, eax
        js      .done

        mov     edx, eax
        lea     rcx, [rsp + 0x20]
        call    asm_log_write
.done:
        add     rsp, 0x2A0
        pop     rdi
        pop     rsi
        pop     r13
        pop     r12
        pop     rbp
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
