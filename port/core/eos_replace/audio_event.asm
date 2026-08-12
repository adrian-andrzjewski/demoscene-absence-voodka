; audio_event.asm - production MOD event decoder.
;
; The checked-in soundtrack is a 14-channel FastTracker MOD whose packed
; pattern records use the classic four-byte ProTracker event format.  This
; entry point intentionally has no Windows, C, or libxmp dependency: it
; translates one immutable disk event into the eight-byte event shape used by
; the validation oracle.

BITS 64
DEFAULT REL

%define EVENT_NOTE                       0
%define EVENT_INSTRUMENT                 1
%define EVENT_VOLUME                     2
%define EVENT_EFFECT                     3
%define EVENT_PARAMETER                  4
%define EVENT_SECONDARY_EFFECT           5
%define EVENT_SECONDARY_PARAMETER        6
%define EVENT_FLAGS                      7

global asm_audio_decode_event

section .text

; uint32_t asm_audio_decode_event(const uint8_t* raw4, AudioEvent* out)
asm_audio_decode_event:
        test    rcx, rcx
        jz      .bad
        test    rdx, rdx
        jz      .bad

        mov     r8, rcx                    ; raw event
        mov     r9, rdx                    ; output event
        xor     eax, eax
        mov     qword [r9], rax            ; all optional fields start at 0

        ; The period is the low 12 bits of bytes 0/1.  The sample number is
        ; split across the high nibble of byte 0 and the high nibble of byte
        ; 2.  This is exactly libxmp_decode_protracker_event().
        movzx   eax, byte [r8 + 0]
        movzx   ecx, byte [r8 + 1]
        mov     r10d, eax
        and     r10d, 0x0f
        shl     r10d, 8
        or      r10d, ecx                  ; period

        mov     r11d, eax
        shr     r11d, 4                    ; instrument high nibble
        movzx   eax, byte [r8 + 2]
        mov     ecx, eax
        shr     ecx, 4                    ; instrument low nibble
        and     ecx, 0x0f
        shl     r11d, 4
        or      r11d, ecx
        mov     byte [r9 + EVENT_INSTRUMENT], r11b

        ; The module contains the normal Amiga period table.  Keeping this
        ; lookup table in assembly reproduces libxmp's period_to_note result
        ; for every period used by the soundtrack without pulling libm into
        ; the future assembly-only executable.
        test    r10d, r10d
        jz      .no_note
        lea     r11, [rel normal_periods]
        xor     eax, eax
.period_loop:
        cmp     eax, 36
        jae     .no_note
        movzx   ecx, word [r11 + rax * 2]
        cmp     ecx, r10d
        je      .period_found
        inc     eax
        jmp     .period_loop
.period_found:
        add     eax, 49                   ; 856-period C-3 is xmp note 49
        mov     byte [r9 + EVENT_NOTE], al
.no_note:

        mov     eax, [r8 + 2]
        and     eax, 0x0f                 ; primary effect nibble
        movzx   ecx, byte [r8 + 3]        ; primary effect parameter

        ; ProTracker 8xx is a filter command that libxmp intentionally does
        ; not expose as a normal event.  The zero-parameter continuation
        ; rewrites are also part of the loader ABI, not playback-time state.
        cmp     eax, 8
        je      .effect_done
        test    ecx, ecx
        jnz     .check_extended
        cmp     eax, 5
        je      .effect_03
        cmp     eax, 6
        je      .effect_04
        cmp     eax, 1
        je      .effect_clear
        cmp     eax, 2
        je      .effect_clear
        cmp     eax, 0x0a
        je      .effect_clear
        jmp     .effect_write
.effect_03:
        mov     eax, 3
        jmp     .effect_write
.effect_04:
        mov     eax, 4
        jmp     .effect_write
.effect_clear:
        xor     eax, eax
        jmp     .effect_write
.check_extended:
        cmp     eax, 0x0e
        jne     .effect_write
        cmp     ecx, 0xa0
        je      .effect_clear_both
        cmp     ecx, 0xb0
        je      .effect_clear_both
        jmp     .effect_write
.effect_clear_both:
        xor     eax, eax
        xor     ecx, ecx
.effect_write:
        mov     byte [r9 + EVENT_EFFECT], al
        mov     byte [r9 + EVENT_PARAMETER], cl
.effect_done:
        xor     eax, eax
        ret

.bad:
        mov     eax, 1
        ret

section .rdata align=2

; Periods 856..113 map to xmp notes 49..84 for the normal Amiga tuning used
; by amnezja2.mod.  The module audit verifies that every nonzero period is in
; this table before this decoder is accepted as the native event path.
normal_periods:
        dw      856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453
        dw      428, 404, 381, 360, 339, 320, 302, 285, 269, 254, 240, 226
        dw      214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 113
