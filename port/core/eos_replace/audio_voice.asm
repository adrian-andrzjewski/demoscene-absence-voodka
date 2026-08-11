; audio_voice.asm - production row-start voice identity state.
;
; This gate follows the module's row order and applies the instrument/note
; state changes needed to identify the active sample.  It intentionally does
; not claim to emulate tick effects, voice position, or PCM mixing; those are
; later gates with their own equivalence criteria.

BITS 64
DEFAULT REL

%define MOD_ORDER_TABLE                  952
%define MOD_HEADER_BYTES                 1084
%define MOD_ROWS                         64
%define MOD_CHANNELS                     14
%define MOD_EVENT_BYTES                  4
%define MOD_PATTERN_BYTES                (MOD_ROWS * MOD_CHANNELS * MOD_EVENT_BYTES)
%define MOD_ROW_BYTES                    (MOD_CHANNELS * MOD_EVENT_BYTES)
%define MOD_SAMPLE_HEADER                20
%define MOD_SAMPLE_VOLUME                25
%define MOD_SAMPLE_HEADER_BYTES          30

%define VOICE_EVENT                      0
%define VOICE_NOTE                       8
%define VOICE_INSTRUMENT                 9
%define VOICE_SAMPLE                     10
%define VOICE_SAMPLE_VOLUME              11
%define VOICE_BYTES                      12

global asm_audio_trace_voice_rows

section .text

; uint32_t asm_audio_trace_voice_rows(const uint8_t* data,
;                                     uint32_t size,
;                                     AudioVoiceState* out,
;                                     uint32_t capacity)
asm_audio_trace_voice_rows:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 128                 ; 14 four-byte channel states

        mov     r12, rcx                 ; module bytes
        mov     r13, r8                  ; output states
        mov     r14d, edx                ; module size during validation
        test    r12, r12
        jz      .bad
        test    r13, r13
        jz      .bad
        cmp     r14d, MOD_HEADER_BYTES
        jb      .bad

        movzx   r15d, byte [r12 + 950]   ; order count
        test    r15d, r15d
        jz      .bad
        cmp     r15d, 128
        ja      .bad

        ; Derive and validate the highest referenced pattern.  The parser
        ; gate performs the same check, but this entry point remains useful
        ; as an independent assembly ABI.
        xor     esi, esi
        xor     r11d, r11d
        mov     ecx, r15d
.find_pattern:
        movzx   eax, byte [r12 + MOD_ORDER_TABLE + rsi]
        cmp     eax, r11d
        jbe     .find_next
        mov     r11d, eax
.find_next:
        inc     esi
        dec     ecx
        jnz     .find_pattern
        inc     r11d                    ; pattern count
        cmp     r11d, 64
        ja      .bad
        mov     eax, r11d
        imul    eax, MOD_PATTERN_BYTES
        add     eax, MOD_HEADER_BYTES
        cmp     r14d, eax
        jb      .bad

        ; Capacity is the number of row snapshots for all orders in the
        ; module; each row contributes MOD_CHANNELS output records.
        mov     eax, r15d
        imul    eax, MOD_ROWS
        cmp     r9d, eax
        jb      .bad

        ; Channel state is { current note, current instrument, current
        ; sample, selected instrument volume }.  xmp exposes -1 as 0xff in
        ; the unsigned channel-info fields, and starts sample at zero.
        lea     rdi, [rbp - 128]
        mov     ecx, MOD_CHANNELS
.clear_state:
        mov     byte [rdi + 0], 0xff
        mov     byte [rdi + 1], 0xff
        mov     dword [rdi + 2], 0
        add     rdi, 4
        dec     ecx
        jnz     .clear_state

        xor     ebx, ebx                ; order index
        xor     r10d, r10d              ; row index
        mov     rsi, r13                ; output cursor

.order_loop:
        movzx   eax, byte [r12 + MOD_ORDER_TABLE + rbx]
        imul    eax, MOD_PATTERN_BYTES
        add     eax, MOD_HEADER_BYTES
        lea     r8, [r12 + rax]
        mov     eax, r10d
        imul    eax, MOD_ROW_BYTES
        add     r8, rax                 ; row base

        xor     r14d, r14d              ; channel index
.channel_loop:
        mov     rdx, r8
        mov     eax, r14d
        imul    eax, MOD_EVENT_BYTES
        add     rdx, rax                ; raw event

        ; Start with zeroed optional event fields.
        xor     eax, eax
        mov     qword [rsi + VOICE_EVENT], rax

        ; Decode period, instrument, and note.  The normal period table is
        ; the same table used by audio_event.asm.
        movzx   eax, byte [rdx + 0]
        movzx   ecx, byte [rdx + 1]
        mov     r9d, eax
        and     r9d, 0x0f
        shl     r9d, 8
        or      r9d, ecx                 ; period

        mov     r11d, eax
        shr     r11d, 4
        movzx   eax, byte [rdx + 2]
        mov     ecx, eax
        shr     ecx, 4
        and     ecx, 0x0f
        shl     r11d, 4
        or      r11d, ecx                ; raw instrument number
        mov     byte [rsi + VOICE_EVENT + 1], r11b

        test    r9d, r9d
        jz      .no_note
        lea     r11, [rel normal_periods]
        xor     eax, eax
.period_loop:
        cmp     eax, 36
        jae     .no_note
        movzx   ecx, word [r11 + rax * 2]
        cmp     ecx, r9d
        je      .period_found
        inc     eax
        jmp     .period_loop
.period_found:
        add     eax, 49
        mov     byte [rsi + VOICE_EVENT + 0], al
.no_note:

        ; Primary effect translation is kept identical to the event decoder
        ; so row snapshots contain the same loader-facing event ABI.
        movzx   eax, byte [rdx + 2]
        and     eax, 0x0f
        movzx   ecx, byte [rdx + 3]
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
        mov     byte [rsi + VOICE_EVENT + 3], al
        mov     byte [rsi + VOICE_EVENT + 4], cl
.effect_done:

        ; Locate this channel's persistent state.
        lea     rdi, [rbp - 128]
        mov     eax, r14d
        shl     eax, 2
        add     rdi, rax

        ; A valid instrument selects the corresponding MOD sample in this
        ; soundtrack.  The state keeps the previous sample until a note is
        ; accepted, matching FastTracker's instrument-without-note behavior.
        movzx   eax, byte [rsi + VOICE_EVENT + 1]
        test    eax, eax
        jz      .no_instrument
        movzx   ecx, byte [rsi + VOICE_EVENT + 3]
        cmp     ecx, 3                    ; tone portamento keeps old ins
        je      .no_instrument
        cmp     ecx, 6                    ; tone porta + volume slide
        je      .no_instrument
        dec     eax
        mov     byte [rdi + 1], al       ; xmp instrument is zero-based
        mov     byte [rdi + 3], 0
        imul    rax, MOD_SAMPLE_HEADER_BYTES
        movzx   ecx, byte [r12 + MOD_SAMPLE_HEADER + rax + MOD_SAMPLE_VOLUME]
        mov     byte [rdi + 3], cl
.no_instrument:

        ; A note is accepted only when an instrument is already selected.
        ; Every instrument in amnezja2.mod maps one-to-one to its MOD sample.
        movzx   eax, byte [rsi + VOICE_EVENT + 0]
        test    eax, eax
        jz      .state_written
        movzx   ecx, byte [rsi + VOICE_EVENT + 3]
        cmp     ecx, 3                    ; tone portamento keeps old note
        je      .state_written
        cmp     ecx, 6                    ; tone porta + volume slide
        je      .state_written
        cmp     byte [rdi + 1], 0xff
        je      .state_written
        dec     eax                         ; xmp channel note is zero-based key
        mov     byte [rdi + 0], al
        mov     al, byte [rdi + 1]
        mov     byte [rdi + 2], al

.state_written:
        mov     eax, dword [rdi + 0]
        mov     dword [rsi + VOICE_NOTE], eax
        add     rsi, VOICE_BYTES
        inc     r14d
        cmp     r14d, MOD_CHANNELS
        jb      .channel_loop

        inc     r10d
        cmp     r10d, MOD_ROWS
        jb      .order_loop
        xor     r10d, r10d
        inc     rbx
        cmp     rbx, r15
        jb      .order_loop

        mov     eax, r15d
        imul    eax, MOD_ROWS
        jmp     .return

.bad:
        xor     eax, eax
.return:
        add     rsp, 128
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

section .rdata align=2

normal_periods:
        dw      856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453
        dw      428, 404, 381, 360, 339, 320, 302, 285, 269, 254, 240, 226
        dw      214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 113
