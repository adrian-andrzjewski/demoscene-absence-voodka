; win32_log_format.asm - the first production printf subset.
;
; The shipped target keeps the C++ logger as a thin ABI wrapper while this
; module owns the integer, pointer, character, narrow-string, wide-string,
; and literal conversions. Floating-point and otherwise unsupported formats
; deliberately remain on the C++ oracle path until their bytes are proven.

BITS 64
DEFAULT REL

%include "win64_abi.inc"

global asm_log_format_supported
global asm_log_vformat

section .text

; int asm_log_format_supported(const char* fmt)
; Return 1 only for the conversion grammar implemented below. This scan is
; intentionally independent of the va_list so the C++ wrapper can select its
; oracle path before consuming any arguments.
asm_log_format_supported:
        mov     rax, rcx
.scan:
        mov     dl, [rax]
        test    dl, dl
        jz      .yes
        inc     rax
        cmp     dl, '%'
        jne     .scan

        mov     dl, [rax]
        test    dl, dl
        jz      .no
        cmp     dl, '%'
        je      .literal_percent

.flags:
        mov     dl, [rax]
        cmp     dl, '0'
        je      .flag_advance
        cmp     dl, '-'
        je      .flag_advance
        cmp     dl, '+'
        je      .flag_advance
        jne     .width
.flag_advance:
        inc     rax
        jmp     .flags

.width:
        mov     dl, [rax]
        cmp     dl, '1'
        jb      .precision
        cmp     dl, '9'
        ja      .precision
        inc     rax
        jmp     .width

.precision:
        mov     dl, [rax]
        cmp     dl, '.'
        jne     .length
        inc     rax
        xor     r8d, r8d
        mov     dl, [rax]
        cmp     dl, '0'
        jb      .no
        cmp     dl, '9'
        ja      .no
.precision_digits:
        movzx   edx, byte [rax]
        sub     edx, '0'
        imul    r8d, r8d, 10
        add     r8d, edx
        cmp     r8d, 6
        ja      .no                         ; live path needs at most 6
        inc     rax
        mov     dl, [rax]
        cmp     dl, '0'
        jb      .length
        cmp     dl, '9'
        jbe     .precision_digits
        jmp     .length

.length:
        mov     dl, [rax]
        cmp     dl, 'z'
        je      .length_z
        cmp     dl, 'l'
        jne     .conversion
        inc     rax
        cmp     byte [rax], 'l'
        je      .length_ll
        jmp     .conversion
.length_ll:
        inc     rax
        jmp     .conversion
.length_z:
        inc     rax

.conversion:
        mov     dl, [rax]
        cmp     dl, 'd'
        je      .conversion_done
        cmp     dl, 'i'
        je      .conversion_done
        cmp     dl, 'u'
        je      .conversion_done
        cmp     dl, 'x'
        je      .conversion_done
        cmp     dl, 'X'
        je      .conversion_done
        cmp     dl, 'p'
        je      .conversion_done
        cmp     dl, 's'
        je      .conversion_done
        cmp     dl, 'S'
        je      .conversion_done
        cmp     dl, 'c'
        je      .conversion_done
        cmp     dl, 'f'
        je      .conversion_done
        jmp     .no
.conversion_done:
        inc     rax
        jmp     .scan

.literal_percent:
        inc     rax
        jmp     .scan

.yes:
        mov     eax, 1
        ret
.no:
        xor     eax, eax
        ret

; int asm_log_vformat(char* out, uint32_t capacity, const char* fmt,
;                     const char* va_list_cursor)
;
; On MSVC x64 va_list is a pointer to eight-byte argument slots. The C++
; wrapper passes the cursor after va_start; this routine advances it exactly
; once per conversion. Return value is the number of bytes written excluding
; the terminator, or -1 for a format outside the proven subset.
asm_log_vformat:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0xA8                    ; keep RSP%16==0 for the scan call
        mov     dword [rbp - 0x9C], 0        ; integer-format path by default

        mov     r12, rcx                    ; output buffer
        mov     r13d, edx                   ; capacity
        mov     r14, r8                     ; format
        mov     r15, r9                     ; va_list cursor

        test    r13d, r13d
        jz      .invalid_capacity
        mov     rcx, r14
        call    asm_log_format_supported
        test    eax, eax
        jz      .unsupported

        dec     r13d                        ; reserve the NUL byte
        xor     ebx, ebx                    ; output length
        mov     rsi, r14
        mov     rdi, r15

.format_loop:
        mov     al, [rsi]
        test    al, al
        jz      .finish
        cmp     al, '%'
        je      .conversion
        inc     rsi
        %macro EMIT_AL 0
                cmp     ebx, r13d
                jae     %%emit_done
                mov     [r12 + rbx], al
                inc     ebx
        %%emit_done:
        %endmacro
        EMIT_AL
        jmp     .format_loop

.conversion:
        inc     rsi
        mov     al, [rsi]
        cmp     al, '%'
        je      .literal_percent_out

        xor     r8d, r8d                    ; field width
        xor     r9d, r9d                    ; flags: zero=1, left=2, plus=4
.parse_flags:
        mov     al, [rsi]
        cmp     al, '0'
        je      .flag_zero
        cmp     al, '-'
        je      .flag_left
        cmp     al, '+'
        je      .flag_plus
        jne     .parse_width
.flag_zero:
        or      r9d, 1
        inc     rsi
        jmp     .parse_flags
.flag_left:
        or      r9d, 2
        inc     rsi
        jmp     .parse_flags
.flag_plus:
        or      r9d, 4
        inc     rsi
        jmp     .parse_flags
.parse_width:
        mov     al, [rsi]
        cmp     al, '1'
        jb      .parse_precision
        cmp     al, '9'
        ja      .parse_precision
        imul    r8d, r8d, 10
        movzx   eax, al
        sub     eax, '0'
        add     r8d, eax
        inc     rsi
        jmp     .parse_width

.parse_precision:
        mov     dword [rbp - 0x88], 6         ; printf default for %f
        cmp     byte [rsi], '.'
        jne     .parse_length
        inc     rsi
        xor     r10d, r10d
        mov     al, [rsi]
        cmp     al, '0'
        jb      .unsupported
        cmp     al, '9'
        ja      .unsupported
.parse_precision_digits:
        movzx   eax, byte [rsi]
        sub     eax, '0'
        imul    r10d, r10d, 10
        add     r10d, eax
        cmp     r10d, 6
        ja      .unsupported
        inc     rsi
        mov     al, [rsi]
        cmp     al, '0'
        jb      .parse_precision_done
        cmp     al, '9'
        jbe     .parse_precision_digits
.parse_precision_done:
        mov     [rbp - 0x88], r10d

.parse_length:
        mov     [rbp - 0x84], r8d             ; field width
        xor     r10d, r10d                 ; qword argument flag
        mov     al, [rsi]
        cmp     al, 'z'
        je      .length_qword
        cmp     al, 'l'
        jne     .conversion_type
        inc     rsi
        cmp     byte [rsi], 'l'
        jne     .conversion_type           ; Windows long remains 32-bit
        inc     rsi
        mov     r10d, 1
        jmp     .conversion_type
.length_qword:
        inc     rsi
        mov     r10d, 1

.conversion_type:
        movzx   eax, byte [rsi]
        inc     rsi
        cmp     al, 's'
        je      .string_narrow
        cmp     al, 'S'
        je      .string_wide
        cmp     al, 'c'
        je      .character
        cmp     al, 'p'
        je      .pointer
        cmp     al, 'd'
        je      .number_signed
        cmp     al, 'i'
        je      .number_signed
        cmp     al, 'u'
        je      .number_unsigned
        cmp     al, 'x'
        je      .number_hex_lower
        cmp     al, 'f'
        je      .number_float
        ; The scan above guarantees this is the supported uppercase hex case.
        mov     r11d, 2                    ; uppercase digit flag
        jmp     .number_unsigned_fetch

.pointer:
        mov     r10d, 1
        mov     r8d, 16
        or      r9d, 1                      ; MSVC %p is zero-padded
        xor     r11d, r11d
        jmp     .number_unsigned_fetch

.number_signed:
        mov     r11d, 1                    ; signed decimal
        jmp     .number_fetch
.number_unsigned:
        xor     r11d, r11d
        jmp     .number_fetch
.number_hex_lower:
        xor     r11d, r11d
        jmp     .number_fetch
.number_float:
        mov     rax, [rdi]
        add     rdi, 8
        mov     [rbp - 0xA8], rsi          ; preserve format cursor while appending
        mov     r10d, [rbp - 0x88]
        xor     r11d, r11d                 ; sign: 1 negative, 2 explicit plus
        test    rax, rax
        jns     .float_positive
        mov     r11d, 1
.float_positive_abs:
        mov     rcx, 0x7FFFFFFFFFFFFFFF
        and     rax, rcx
        jmp     .float_scale
.float_positive:
        test    r9d, 4
        jz      .float_scale
        mov     r11d, 2
.float_scale:
        movq    xmm0, rax
        movsd   xmm1, [rel float_ten]
.float_scale_loop:
        test    r10d, r10d
        jz      .float_round
        mulsd   xmm0, xmm1
        dec     r10d
        jmp     .float_scale_loop
.float_round:
        addsd   xmm0, [rel float_half]
        cvttsd2si rax, xmm0
        mov     r10d, [rbp - 0x88]
        lea     r8, [rel float_pow10]
        mov     r8, [r8 + r10 * 8]
        xor     edx, edx
        div     r8
        mov     [rbp - 0x90], rdx          ; fractional remainder
        mov     r10d, r11d                 ; sign flag used by digits_sign
        xor     r11d, r11d                 ; base-10, lower-case digit path
        mov     r8d, 10
        mov     dword [rbp - 0x9C], 1
        jmp     .digits_begin
.number_unsigned_fetch:
.number_fetch:
        mov     rax, [rdi]
        add     rdi, 8

        ; Preserve the parsed width while the conversion uses R8 as its base.
        mov     [rbp - 0x84], r8d
        mov     dword [rbp - 0x9C], 0
        mov     r14d, r10d                 ; qword flag before R10 is reused
        xor     r10d, r10d                 ; negative-sign flag
        test    r11d, 1
        jz      .unsigned_value
        test    r14d, r14d
        jnz     .signed_value_ready
        movsxd  rax, eax
.signed_value_ready:
        test    rax, rax
        jns     .positive_value
        neg     rax                         ; INT64_MIN remains valid unsigned
        mov     r10d, 1
        jmp     .value_ready
.positive_value:
        test    r9d, 4
        jz      .value_ready
        mov     r10d, 2                    ; explicit plus-sign flag
        jmp     .value_ready
.unsigned_value:
        test    r14d, r14d
        jnz     .value_ready
        mov     eax, eax
.value_ready:

        test    r11d, 2
        jnz     .base_hex_upper
        cmp     byte [rsi - 1], 'p'
        je      .base_hex_lower
        cmp     byte [rsi - 1], 'x'
        je      .base_hex_lower
        cmp     byte [rsi - 1], 'X'
        je      .base_hex_upper
        mov     r8d, 10
        jmp     .digits_begin
.base_hex_lower:
        mov     r8d, 16
        jmp     .digits_begin
.base_hex_upper:
        mov     r8d, 16

.digits_begin:
        lea     r15, [rbp - 0x40]
        xor     ecx, ecx
        test    rax, rax
        jnz     .digits_loop
        dec     r15
        mov     byte [r15], '0'
        jmp     .digits_sign
.digits_loop:
        xor     edx, edx
        div     r8
        mov     ecx, edx
        cmp     ecx, 9
        jbe     .digit_numeric
        test    r11d, 2
        jnz     .digit_upper
        add     ecx, 'a' - 10
        jmp     .digit_store
.digit_upper:
        add     ecx, 'A' - 10
        jmp     .digit_store
.digit_numeric:
        add     ecx, '0'
.digit_store:
        dec     r15
        mov     [r15], cl
        test    rax, rax
        jnz     .digits_loop

.digits_sign:
        cmp     r10d, 1
        jne     .digits_plus
        dec     r15
        mov     byte [r15], '-'
        jmp     .digits_ready
.digits_plus:
        cmp     r10d, 2
        jne     .digits_ready
        dec     r15
        mov     byte [r15], '+'

.digits_ready:
        cmp     dword [rbp - 0x9C], 0
        jne     .float_digits_ready
        mov     r14, r15                   ; rendered start pointer
        lea     rax, [rbp - 0x40]
        sub     rax, r14
        mov     r15d, eax                 ; rendered length
.digits_width_ready:
        mov     r8d, [rbp - 0x84]
        cmp     r8d, r15d
        jbe     .number_body_no_left_padding
        sub     r8d, r15d                  ; padding count
        test    r9d, 2
        jnz     .number_body_left
        test    r9d, 1
        jz      .number_pad_space
.number_pad_zero:
        cmp     byte [r14], '-'
        je      .number_pad_zero_sign
        cmp     byte [r14], '+'
        jne     .number_pad_zero_loop
.number_pad_zero_sign:
        mov     al, [r14]
        inc     r14
        dec     r15d
        EMIT_AL
.number_pad_zero_loop:
        mov     al, '0'
        EMIT_AL
        dec     r8d
        jnz     .number_pad_zero_loop
        jmp     .number_body_no_left_padding
.number_pad_space:
        mov     al, ' '
.number_pad_space_loop:
        EMIT_AL
        dec     r8d
        jnz     .number_pad_space_loop
        jmp     .number_body_no_left_padding
.number_body_left:
        mov     r10d, r8d
        jmp     .number_body

.number_body_no_left_padding:
        xor     r10d, r10d
        jmp     .number_body

.number_body:
        mov     rdx, r14
        mov     ecx, r15d
.number_body_loop:
        test    ecx, ecx
        jz      .number_left_padding_done
        mov     al, [rdx]
        inc     rdx
        EMIT_AL
        dec     ecx
        jmp     .number_body_loop
.number_left_padding_done:
        test    r10d, r10d
        jz      .format_loop
        mov     al, ' '
.number_left_padding_loop:
        EMIT_AL
        dec     r10d
        jnz     .number_left_padding_loop
        jmp     .format_loop

.float_digits_ready:
        mov     r14, r15                   ; rendered start pointer
        lea     rsi, [rbp - 0x40]          ; append after whole-number digits
        mov     ecx, [rbp - 0x88]
        test    ecx, ecx
        jz      .float_fraction_done
        mov     byte [rsi], '.'
        inc     rsi
        mov     rax, [rbp - 0x90]
        mov     r10d, ecx
        dec     ecx
        lea     r8, [rel float_pow10]
        mov     r8, [r8 + rcx * 8]
.float_fraction_loop:
        xor     edx, edx
        div     r8
        add     eax, '0'
        mov     [rsi], al
        inc     rsi
        mov     [rbp - 0x90], rdx
        dec     r10d
        jz      .float_fraction_done
        mov     rax, r8
        xor     edx, edx
        mov     ecx, 10
        div     rcx
        mov     r8, rax
        mov     rax, [rbp - 0x90]
        jmp     .float_fraction_loop
.float_fraction_done:
        mov     rax, rsi
        sub     rax, r14
        mov     r15d, eax
        mov     rsi, [rbp - 0xA8]
        jmp     .digits_width_ready

.string_narrow:
        mov     rdx, [rdi]
        add     rdi, 8
        test    rdx, rdx
        jnz     .string_narrow_loop
        lea     rdx, [rel null_string]
.string_narrow_loop:
        mov     al, [rdx]
        test    al, al
        jz      .format_loop
        inc     rdx
        EMIT_AL
        jmp     .string_narrow_loop

.string_wide:
        mov     rdx, [rdi]
        add     rdi, 8
        test    rdx, rdx
        jnz     .string_wide_loop
        lea     rdx, [rel null_string]
.string_wide_loop:
        movzx   eax, word [rdx]
        test    eax, eax
        jz      .format_loop
        inc     rdx
        inc     rdx
        ; Runtime paths are ASCII/UTF-16LE. Preserve the low byte just as the
        ; existing narrow log file does for all shipped path names.
        EMIT_AL
        jmp     .string_wide_loop

.character:
        mov     rax, [rdi]
        add     rdi, 8
        EMIT_AL
        jmp     .format_loop

.literal_percent_out:
        inc     rsi
        mov     al, '%'
        EMIT_AL
        jmp     .format_loop

.finish:
        mov     byte [r12 + rbx], 0
        mov     eax, ebx
        jmp     .return
.unsupported:
        mov     byte [r12], 0
        mov     eax, -1
        jmp     .return
.invalid_capacity:
        mov     eax, -2
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

section .rdata
align 8
float_ten:   dq 0x4024000000000000
float_half:  dq 0x3FE0000000000000
float_pow10: dq 1, 10, 100, 1000, 10000, 100000, 1000000
null_string: db '(null)', 0

section .note.GNU-stack noalloc noexec nowrite progbits
