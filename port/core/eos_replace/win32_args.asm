; win32_args.asm - production command-line storage and selector parsing.
;
; This parser deliberately mirrors the current host's simple substring and
; token rules. It is not a general Windows command-line tokenizer; preserving
; the existing behavior is the migration requirement.

BITS 64
DEFAULT REL

%include "win64_abi.inc"

%define ARG_LIBXMP                 0x00000001
%define ARG_SELFTEST               0x00000002
%define ARG_AUDIOCHECK             0x00000004
%define ARG_RECORD                 0x00000008
%define ARG_DIAG                   0x00000010
%define ARG_MUSIC                  0x00000020
%define ARG_TIMELINE               0x00000040
%define ARG_AUTO_PAUSE             0x00000080
%define ARG_AUTO_CLOSE             0x00000100
%define ARG_MODPOS                 0x00000200
%define ARG_MS                     0x00000400
%define ARG_ORDER                  0x00000800
%define ARG_PART                   0x00001000
%define ARG_SCENE                  0x00002000
%define ARG_FULLSCREEN_1080P       0x00004000

extern asm_find_command_flag
extern asm_copy_command_value

global asm_parse_command_line
global asm_voodka_arg_libxmp
global asm_voodka_arg_selftest
global asm_voodka_arg_audiocheck
global asm_voodka_arg_record
global asm_voodka_arg_diag
global asm_voodka_arg_music
global asm_voodka_arg_timeline
global asm_voodka_arg_auto_pause
global asm_voodka_arg_auto_close
global asm_voodka_arg_modpos
global asm_voodka_arg_ms
global asm_voodka_arg_order
global asm_voodka_arg_part
global asm_voodka_arg_scene
global asm_voodka_arg_audiocheck_seconds
global asm_voodka_arg_fullscreen

section .bss
align 8
asm_arg_flags:          resd 1
asm_arg_auto_pause_v:   resd 1
asm_arg_auto_close_v:   resd 1
asm_arg_modpos_v:       resd 1
asm_arg_ms_v:           resd 1
asm_arg_order_v:        resd 1
asm_arg_part_v:         resd 1
asm_arg_scene_buf:      resb 1024
asm_arg_audiocheck_v:   resd 1
asm_arg_record_buf:     resb 1024
asm_arg_diag_buf:       resb 1024
asm_arg_music_buf:      resb 1024
asm_arg_timeline_buf:   resb 1024

section .data
arg_libxmp_s:       db "--libxmp-audio", 0
arg_selftest_s:     db "--selftest", 0
arg_audiocheck_s:   db "--audiocheck", 0
arg_record_s:       db "--record", 0
arg_diag_s:         db "--diag", 0
arg_music_s:        db "--music", 0
arg_timeline_s:     db "--timeline", 0
arg_auto_pause_s:   db "--auto-pause-ms", 0
arg_auto_close_s:   db "--auto-close-ms", 0
arg_modpos_s:       db "--modpos", 0
arg_ms_s:           db "--ms", 0
arg_order_s:        db "--order", 0
arg_part_s:         db "--part", 0
arg_scene_s:        db "--scene", 0
arg_fullscreen_s:   db "--fullscreen-1920x1080", 0

section .text

; int asm_parse_command_line(const char* commandLine)
asm_parse_command_line:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        sub     rsp, 0x20                    ; RSP%16 == 0 at CALL sites
        mov     r12, rcx

        mov     dword [rel asm_arg_flags], 0
        mov     dword [rel asm_arg_auto_pause_v], -1
        mov     dword [rel asm_arg_auto_close_v], -1
        mov     dword [rel asm_arg_modpos_v], -1
        mov     dword [rel asm_arg_ms_v], -1
        mov     dword [rel asm_arg_order_v], -1
        mov     dword [rel asm_arg_part_v], -1
        mov     byte [rel asm_arg_scene_buf], 0
        mov     dword [rel asm_arg_audiocheck_v], -1
        mov     byte [rel asm_arg_record_buf], 0
        mov     byte [rel asm_arg_diag_buf], 0
        mov     byte [rel asm_arg_music_buf], 0
        mov     byte [rel asm_arg_timeline_buf], 0
        test    r12, r12
        jz      .done

        mov     rcx, r12
        lea     rdx, [rel arg_fullscreen_s]
        call    asm_find_command_flag
        test    rax, rax
        jz      .selftest
        or      dword [rel asm_arg_flags], ARG_FULLSCREEN_1080P

        mov     rcx, r12
        lea     rdx, [rel arg_libxmp_s]
        call    asm_find_command_flag
        test    rax, rax
        jz      .selftest
        or      dword [rel asm_arg_flags], ARG_LIBXMP

.selftest:
        mov     rcx, r12
        lea     rdx, [rel arg_selftest_s]
        call    asm_find_command_flag
        test    rax, rax
        jz      .audiocheck
        or      dword [rel asm_arg_flags], ARG_SELFTEST

.audiocheck:
        mov     rcx, r12
        lea     rdx, [rel arg_audiocheck_s]
        call    asm_find_command_flag
        test    rax, rax
        jz      .record
        or      dword [rel asm_arg_flags], ARG_AUDIOCHECK
        mov     rcx, rax
        call    asm_parse_command_value
        test    edx, edx
        jz      .record
        mov     [rel asm_arg_audiocheck_v], eax

.record:
        mov     rcx, r12
        lea     rdx, [rel arg_record_s]
        call    asm_find_command_flag
        test    rax, rax
        jz      .diag
        mov     rcx, rax
        lea     rdx, [rel asm_arg_record_buf]
        call    asm_copy_command_value
        test    eax, eax
        jz      .diag
        or      dword [rel asm_arg_flags], ARG_RECORD

.diag:
        mov     rcx, r12
        lea     rdx, [rel arg_diag_s]
        call    asm_find_command_flag
        test    rax, rax
        jz      .music
        mov     rcx, rax
        lea     rdx, [rel asm_arg_diag_buf]
        call    asm_copy_command_value
        test    eax, eax
        jz      .music
        or      dword [rel asm_arg_flags], ARG_DIAG

.music:
        mov     rcx, r12
        lea     rdx, [rel arg_music_s]
        call    asm_find_command_flag
        test    rax, rax
        jz      .timeline
        mov     rcx, rax
        lea     rdx, [rel asm_arg_music_buf]
        call    asm_copy_command_value
        test    eax, eax
        jz      .timeline
        or      dword [rel asm_arg_flags], ARG_MUSIC

.timeline:
        mov     rcx, r12
        lea     rdx, [rel arg_timeline_s]
        call    asm_find_command_flag
        test    rax, rax
        jz      .auto_pause
        mov     rcx, rax
        lea     rdx, [rel asm_arg_timeline_buf]
        call    asm_copy_command_value
        test    eax, eax
        jz      .auto_pause
        or      dword [rel asm_arg_flags], ARG_TIMELINE

.auto_pause:
        mov     rcx, r12
        lea     rdx, [rel arg_auto_pause_s]
        call    asm_find_command_flag
        test    rax, rax
        jz      .auto_close
        mov     rcx, rax
        call    asm_parse_command_value
        test    edx, edx
        jz      .auto_close
        mov     [rel asm_arg_auto_pause_v], eax
        or      dword [rel asm_arg_flags], ARG_AUTO_PAUSE

.auto_close:
        mov     rcx, r12
        lea     rdx, [rel arg_auto_close_s]
        call    asm_find_command_flag
        test    rax, rax
        jz      .modpos
        mov     rcx, rax
        call    asm_parse_command_value
        test    edx, edx
        jz      .modpos
        mov     [rel asm_arg_auto_close_v], eax
        or      dword [rel asm_arg_flags], ARG_AUTO_CLOSE

.modpos:
        mov     rcx, r12
        lea     rdx, [rel arg_modpos_s]
        call    asm_find_command_flag
        test    rax, rax
        jz      .ms
        mov     rcx, rax
        call    asm_parse_command_value
        test    edx, edx
        jz      .ms
        mov     [rel asm_arg_modpos_v], eax
        or      dword [rel asm_arg_flags], ARG_MODPOS

.ms:
        mov     rcx, r12
        lea     rdx, [rel arg_ms_s]
        call    asm_find_command_flag
        test    rax, rax
        jz      .order
        mov     rcx, rax
        call    asm_parse_command_value
        test    edx, edx
        jz      .order
        mov     [rel asm_arg_ms_v], eax
        or      dword [rel asm_arg_flags], ARG_MS

.order:
        mov     rcx, r12
        lea     rdx, [rel arg_order_s]
        call    asm_find_command_flag
        test    rax, rax
        jz      .scene
        mov     rcx, rax
        call    asm_parse_command_value
        test    edx, edx
        jz      .scene
        mov     [rel asm_arg_order_v], eax
        or      dword [rel asm_arg_flags], ARG_ORDER

.scene:
        mov     rcx, r12
        lea     rdx, [rel arg_scene_s]
        call    asm_find_command_flag
        test    rax, rax
        jz      .part
        mov     rcx, rax
        lea     rdx, [rel asm_arg_scene_buf]
        call    asm_copy_command_value
        test    eax, eax
        jz      .part
        or      dword [rel asm_arg_flags], ARG_SCENE

.part:
        mov     rcx, r12
        lea     rdx, [rel arg_part_s]
        call    asm_find_command_flag
        test    rax, rax
        jz      .done
        mov     rcx, rax
        call    asm_parse_command_value
        test    edx, edx
        jz      .done
        mov     [rel asm_arg_part_v], eax
        or      dword [rel asm_arg_flags], ARG_PART

.done:
        mov     eax, 1
        add     rsp, 0x20
        pop     r13
        pop     r12
        pop     rbp
        ret

; const char* asm_find_command_flag(const char* command, const char* flag)
asm_find_command_flag:
        test    rcx, rcx
        jz      .not_found
        test    rdx, rdx
        jz      .not_found
        mov     r8, rcx
        mov     r9, rdx
.outer:
        mov     r10, r8
        mov     r11, r9
.inner:
        mov     cl, [r11]
        test    cl, cl
        jz      .found
        mov     al, [r10]
        test    al, al
        jz      .not_found
        cmp     al, cl
        jne     .advance
        inc     r10
        inc     r11
        jmp     .inner
.advance:
        inc     r8
        cmp     byte [r8], 0
        jne     .outer
.not_found:
        xor     eax, eax
        ret
.found:
        mov     rax, r10
        ret

; int asm_copy_command_value(const char* afterFlag, char* destination)
asm_copy_command_value:
        mov     r10, rcx
        mov     r11, rdx
.skip:
        mov     al, [r10]
        cmp     al, ' '
        je      .skip_one
        cmp     al, 9
        je      .skip_one
        cmp     al, '"'
        jne     .copy_start
.skip_one:
        inc     r10
        jmp     .skip
.copy_start:
        xor     r8d, r8d
.copy:
        mov     al, [r10]
        test    al, al
        jz      .finish
        cmp     al, ' '
        je      .finish
        cmp     al, 9
        je      .finish
        cmp     r8d, 1023
        jae     .finish
        mov     [r11 + r8], al
        inc     r8d
        inc     r10
        jmp     .copy
.finish:
        test    r8d, r8d
        jz      .empty
        cmp     byte [r11 + r8 - 1], '"'
        jne     .terminate
        dec     r8d
.terminate:
        mov     byte [r11 + r8], 0
        mov     eax, 1
        ret
.empty:
        mov     byte [r11], 0
        xor     eax, eax
        ret

; uint32_t asm_parse_command_value(const char* afterFlag), EDX=valid
asm_parse_command_value:
        mov     r8, rcx
.skip_value:
        mov     al, [r8]
        cmp     al, ' '
        je      .skip_value_one
        cmp     al, 9
        je      .skip_value_one
        cmp     al, '"'
        je      .skip_value_one
        cmp     al, '='
        jne     .value_start
.skip_value_one:
        inc     r8
        jmp     .skip_value
.value_start:
        xor     r11d, r11d
        xor     r9d, r9d                    ; digit count
        mov     r10d, 10
        cmp     byte [r8], '0'
        jne     .digits
        cmp     byte [r8 + 1], 'x'
        je      .hex_prefix
        cmp     byte [r8 + 1], 'X'
        jne     .digits
.hex_prefix:
        add     r8, 2
        mov     r10d, 16
.digits:
        mov     al, [r8]
        xor     ecx, ecx
        cmp     al, '0'
        jb      .value_done
        cmp     al, '9'
        jbe     .decimal_digit
        cmp     r10d, 16
        jne     .value_done
        cmp     al, 'A'
        jb      .lower_hex
        cmp     al, 'F'
        jbe     .upper_hex
.lower_hex:
        cmp     al, 'a'
        jb      .value_done
        cmp     al, 'f'
        ja      .value_done
        movzx   ecx, al
        sub     ecx, 'a' - 10
        jmp     .have_digit
.upper_hex:
        movzx   ecx, al
        sub     ecx, 'A' - 10
        jmp     .have_digit
.decimal_digit:
        movzx   ecx, al
        sub     ecx, '0'
.have_digit:
        imul    r11d, r10d
        add     r11d, ecx
        inc     r9d
        inc     r8
        jmp     .digits
.value_done:
        mov     eax, r11d
        test    r9d, r9d
        jz      .invalid
        mov     edx, 1
        ret
.invalid:
        xor     eax, eax
        xor     edx, edx
        ret

%macro ARG_FLAG_GETTER 2
%1:
        mov     eax, [rel asm_arg_flags]
        and     eax, %2
        ret
%endmacro

ARG_FLAG_GETTER asm_voodka_arg_libxmp,       ARG_LIBXMP
ARG_FLAG_GETTER asm_voodka_arg_selftest,     ARG_SELFTEST
ARG_FLAG_GETTER asm_voodka_arg_audiocheck,   ARG_AUDIOCHECK
ARG_FLAG_GETTER asm_voodka_arg_fullscreen,   ARG_FULLSCREEN_1080P

%macro ARG_VALUE_GETTER 2
%1:
        mov     eax, [rel %2]
        ret
%endmacro

asm_voodka_arg_record:
        cmp     byte [rel asm_arg_record_buf], 0
        jne     .record_yes
        xor     eax, eax
        ret
.record_yes:
        lea     rax, [rel asm_arg_record_buf]
        ret
asm_voodka_arg_diag:
        cmp     byte [rel asm_arg_diag_buf], 0
        jne     .diag_yes
        xor     eax, eax
        ret
.diag_yes:
        lea     rax, [rel asm_arg_diag_buf]
        ret
asm_voodka_arg_music:
        cmp     byte [rel asm_arg_music_buf], 0
        jne     .music_yes
        xor     eax, eax
        ret
.music_yes:
        lea     rax, [rel asm_arg_music_buf]
        ret
asm_voodka_arg_timeline:
        cmp     byte [rel asm_arg_timeline_buf], 0
        jne     .timeline_yes
        xor     eax, eax
        ret
.timeline_yes:
        lea     rax, [rel asm_arg_timeline_buf]
        ret

ARG_VALUE_GETTER asm_voodka_arg_auto_pause,          asm_arg_auto_pause_v
ARG_VALUE_GETTER asm_voodka_arg_auto_close,          asm_arg_auto_close_v
ARG_VALUE_GETTER asm_voodka_arg_modpos,              asm_arg_modpos_v
ARG_VALUE_GETTER asm_voodka_arg_ms,                  asm_arg_ms_v
ARG_VALUE_GETTER asm_voodka_arg_order,               asm_arg_order_v
ARG_VALUE_GETTER asm_voodka_arg_part,                asm_arg_part_v
ARG_VALUE_GETTER asm_voodka_arg_audiocheck_seconds,  asm_arg_audiocheck_v

asm_voodka_arg_scene:
        mov     eax, [rel asm_arg_flags]
        test    eax, ARG_SCENE
        jz      .scene_none
        lea     rax, [rel asm_arg_scene_buf]
        ret
.scene_none:
        xor     eax, eax
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
