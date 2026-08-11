; audio_mod.asm - production parser for the checked-in 14CH FastTracker module.
;
; This is an offline parser gate, not production playback yet.  It accepts the
; classic 14-channel MOD layout used by amnezja2.mod, validates all offsets and
; sample bounds, and emits a compact immutable inventory for the NASM mixer to
; consume later.  No Windows or C runtime calls are made here.

BITS 64
DEFAULT REL

%define MOD_TITLE_BYTES                  20
%define MOD_SAMPLE_HEADER                20
%define MOD_SAMPLE_COUNT                 31
%define MOD_SAMPLE_HEADER_BYTES          30
%define MOD_SAMPLE_LENGTH                22
%define MOD_SAMPLE_LOOP_START            26
%define MOD_SAMPLE_LOOP_LENGTH           28
%define MOD_SONG_LENGTH                  950
%define MOD_RESTART_ORDER                951
%define MOD_ORDER_TABLE                  952
%define MOD_HEADER_BYTES                 1084
%define MOD_MAGIC                        1080
%define MOD_CHANNELS                     14
%define MOD_ROWS                         64
%define MOD_EVENT_BYTES                  4
%define MOD_PATTERN_BYTES_PER_PATTERN    (MOD_ROWS * MOD_CHANNELS * MOD_EVENT_BYTES)

; audio_mod_abi.h, packed summary layout.
%define SUMMARY_STATUS                   0
%define SUMMARY_MODULE_BYTES             4
%define SUMMARY_HEADER_BYTES             8
%define SUMMARY_PATTERN_DATA_OFFSET      12
%define SUMMARY_SAMPLE_DATA_OFFSET       16
%define SUMMARY_SAMPLE_DATA_BYTES        20
%define SUMMARY_TRAILING_BYTES           24
%define SUMMARY_ROWS_PER_LOOP            28
%define SUMMARY_MODPOS_PER_LOOP          32
%define SUMMARY_ORDER_COUNT              36
%define SUMMARY_PATTERN_COUNT            40
%define SUMMARY_CHANNEL_COUNT            44
%define SUMMARY_INSTRUMENT_COUNT         48
%define SUMMARY_POPULATED_EVENTS         52
%define SUMMARY_NOTE_EVENTS              56
%define SUMMARY_INSTRUMENT_EVENTS        60
%define SUMMARY_VOLUME_EVENTS             64
%define SUMMARY_ORDER_TABLE              68
%define SUMMARY_PATTERN_ROWS             196
%define SUMMARY_SAMPLES                   452
%define SUMMARY_SAMPLE_BYTES             16
%define SUMMARY_PRIMARY_EFFECTS          948
%define SUMMARY_SECONDARY_EFFECTS        1076
%define SUMMARY_EFFECT_BYTES             8
%define SUMMARY_EFFECT_COUNT              0
%define SUMMARY_EFFECT_MIN_PARAM          4
%define SUMMARY_EFFECT_MAX_PARAM          5
%define SUMMARY_BYTES                    1204

global asm_audio_parse_mod
section .text

; uint32_t asm_audio_parse_mod(const uint8_t* data,
;                              uint32_t size,
;                              AudioModSummary* out)
asm_audio_parse_mod:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15

        mov     r12, rcx                    ; source bytes
        mov     r14d, edx                   ; source size
        mov     r13, r8                     ; output summary
        test    r13, r13
        jz      .bad_no_output

        ; Clear the complete ABI record and mark it invalid until every check
        ; below has succeeded.
        mov     rdi, r13
        xor     eax, eax
        mov     ecx, SUMMARY_BYTES
        cld
        rep stosb
        mov     dword [r13 + SUMMARY_STATUS], 1

        test    r12, r12
        jz      .bad
        cmp     r14d, MOD_HEADER_BYTES
        jb      .bad
        cmp     dword [r12 + MOD_MAGIC], 0x48433431 ; "14CH" little-endian
        jne     .bad

        mov     [r13 + SUMMARY_MODULE_BYTES], r14d
        mov     dword [r13 + SUMMARY_HEADER_BYTES], MOD_HEADER_BYTES
        mov     dword [r13 + SUMMARY_CHANNEL_COUNT], MOD_CHANNELS
        mov     dword [r13 + SUMMARY_INSTRUMENT_COUNT], MOD_SAMPLE_COUNT

        movzx   eax, byte [r12 + MOD_SONG_LENGTH]
        test    eax, eax
        jz      .bad
        cmp     eax, 128
        ja      .bad
        mov     [r13 + SUMMARY_ORDER_COUNT], eax

        ; Copy the order list and derive the highest referenced pattern.
        lea     rdi, [r13 + SUMMARY_ORDER_TABLE]
        lea     rsi, [r12 + MOD_ORDER_TABLE]
        mov     ecx, 128
        rep movsb
        xor     ebx, ebx                    ; highest pattern index
        xor     esi, esi
        mov     ecx, [r13 + SUMMARY_ORDER_COUNT]
.find_pattern:
        movzx   eax, byte [r13 + SUMMARY_ORDER_TABLE + rsi]
        cmp     eax, ebx
        jbe     .find_next
        mov     ebx, eax
.find_next:
        inc     esi
        dec     ecx
        jnz     .find_pattern
        inc     ebx                         ; count, not highest index
        test    ebx, ebx
        jz      .bad
        cmp     ebx, 64
        ja      .bad
        mov     [r13 + SUMMARY_PATTERN_COUNT], ebx

        ; This module family has 64 rows in every pattern.  Keep the rows in
        ; the summary so the eventual mixer does not need to rediscover them.
        lea     rdi, [r13 + SUMMARY_PATTERN_ROWS]
        mov     eax, MOD_ROWS
        mov     ecx, 64
        rep stosd

        mov     eax, ebx
        imul    eax, MOD_PATTERN_BYTES_PER_PATTERN
        add     eax, MOD_HEADER_BYTES
        mov     [r13 + SUMMARY_SAMPLE_DATA_OFFSET], eax
        mov     dword [r13 + SUMMARY_PATTERN_DATA_OFFSET], MOD_HEADER_BYTES

        ; Parse the 31 standard 30-byte sample headers.  Lengths and loop
        ; fields are big-endian words measured in sample bytes/positions.
        xor     ebx, ebx                    ; total sample bytes
        xor     esi, esi
.sample_loop:
        cmp     esi, MOD_SAMPLE_COUNT
        jae     .samples_done
        imul    edi, esi, MOD_SAMPLE_HEADER_BYTES
        lea     r11, [r12 + MOD_SAMPLE_HEADER + rdi]
        mov     rax, r11

        movzx   edx, byte [r11 + MOD_SAMPLE_LENGTH]
        shl     edx, 8
        movzx   edi, byte [r11 + MOD_SAMPLE_LENGTH + 1]
        or      edx, edi
        shl     edx, 1                      ; sample length in bytes

        movzx   ecx, byte [r11 + MOD_SAMPLE_LOOP_START]
        shl     ecx, 8
        movzx   edi, byte [r11 + MOD_SAMPLE_LOOP_START + 1]
        or      ecx, edi
        shl     ecx, 1                      ; loop start in bytes

        movzx   eax, byte [r11 + MOD_SAMPLE_LOOP_LENGTH]
        shl     eax, 8
        movzx   edi, byte [r11 + MOD_SAMPLE_LOOP_LENGTH + 1]
        or      eax, edi
        shl     eax, 1                      ; loop length in bytes

        mov     edi, esi
        shl     edi, 4
        lea     rdi, [r13 + SUMMARY_SAMPLES + rdi]
        mov     [rdi + 0], edx
        mov     [rdi + 4], ecx
        lea     edx, [rcx + rax]
        mov     [rdi + 8], edx
        xor     r10d, r10d
        cmp     eax, 2
        jbe     .sample_no_loop
        mov     r10d, 2                      ; XMP_SAMPLE_LOOP
.sample_no_loop:
        mov     [rdi + 12], r10d
        add     ebx, dword [rdi + 0]
        inc     esi
        jmp     .sample_loop

.samples_done:
        mov     [r13 + SUMMARY_SAMPLE_DATA_BYTES], ebx
        mov     eax, [r13 + SUMMARY_SAMPLE_DATA_OFFSET]
        add     eax, ebx
        cmp     r14d, eax
        jb      .bad
        mov     ecx, r14d
        sub     ecx, eax
        mov     [r13 + SUMMARY_TRAILING_BYTES], ecx

        mov     eax, [r13 + SUMMARY_ORDER_COUNT]
        imul    eax, MOD_ROWS
        mov     [r13 + SUMMARY_ROWS_PER_LOOP], eax
        shl     eax, 2
        mov     [r13 + SUMMARY_MODPOS_PER_LOOP], eax

        ; Initialize effect minima to 0xff.  Unused effects remain count 0.
        lea     rdi, [r13 + SUMMARY_PRIMARY_EFFECTS]
        mov     ecx, 32
.effect_min_init:
        mov     byte [rdi + SUMMARY_EFFECT_MIN_PARAM], 0xff
        add     rdi, SUMMARY_EFFECT_BYTES
        loop    .effect_min_init

        ; Scan every 4-byte classic MOD event.  The raw effect nibble and
        ; parameter are deliberately retained; the mixer will later apply the
        ; module-specific effect semantics on top of this immutable stream.
        mov     eax, [r13 + SUMMARY_PATTERN_COUNT]
        imul    eax, MOD_ROWS * MOD_CHANNELS
        mov     r15d, eax
        mov     eax, [r13 + SUMMARY_PATTERN_DATA_OFFSET]
        lea     rsi, [r12 + rax]
.event_loop:
        movzx   eax, byte [rsi + 0]
        movzx   ebx, byte [rsi + 1]
        mov     edx, eax
        and     edx, 0x0f
        shl     edx, 8
        or      edx, ebx                      ; period

        shr     eax, 4                        ; sample high nibble
        movzx   ebx, byte [rsi + 2]
        mov     ecx, ebx
        shr     ecx, 4                        ; sample low nibble
        and     ecx, 0x0f
        shl     eax, 4
        or      eax, ecx                      ; sample number
        mov     ebx, eax

        movzx   r8d, byte [rsi + 2]
        and     r8d, 0x0f                     ; primary effect
        movzx   r9d, byte [rsi + 3]           ; primary parameter

        mov     eax, edx
        or      eax, ebx
        or      eax, r8d
        or      eax, r9d
        jz      .event_no_populated
        inc     dword [r13 + SUMMARY_POPULATED_EVENTS]
.event_no_populated:
        test    edx, edx
        jz      .event_no_note
        inc     dword [r13 + SUMMARY_NOTE_EVENTS]
.event_no_note:
        test    ebx, ebx
        jz      .event_no_instrument
        inc     dword [r13 + SUMMARY_INSTRUMENT_EVENTS]
.event_no_instrument:
        ; The classic 4-byte format has no volume column.
        test    r8d, r8d
        jz      .event_no_effect
        lea     rdi, [r13 + SUMMARY_PRIMARY_EFFECTS + r8 * SUMMARY_EFFECT_BYTES]
        inc     dword [rdi + SUMMARY_EFFECT_COUNT]
        cmp     r9b, byte [rdi + SUMMARY_EFFECT_MIN_PARAM]
        jae     .effect_min_done
        mov     [rdi + SUMMARY_EFFECT_MIN_PARAM], r9b
.effect_min_done:
        cmp     r9b, byte [rdi + SUMMARY_EFFECT_MAX_PARAM]
        jbe     .event_no_effect
        mov     [rdi + SUMMARY_EFFECT_MAX_PARAM], r9b
.event_no_effect:
        add     rsi, MOD_EVENT_BYTES
        dec     r15d
        jnz     .event_loop

        mov     dword [r13 + SUMMARY_STATUS], 0
        xor     eax, eax
        jmp     .return
.bad:
        mov     dword [r13 + SUMMARY_STATUS], 1
        mov     eax, 1
.return:
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret
.bad_no_output:
        mov     eax, 1
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret
