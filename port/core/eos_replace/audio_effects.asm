; audio_effects.asm - Phase 2E native tracker tick/effect state gate.
;
; This is an offline, module-specific state engine.  It reproduces the
; xmp_channel_info-equivalent visible state plus a logical sample position and
; one-shot activity flag; loop interpolation, PCM mixing, and Windows audio
; output remain later gates.

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
%define MOD_SAMPLE_HEADER_BYTES          30
%define MOD_SAMPLE_VOLUME                25

%define STATE_BYTES                      80
%define STATE_EVENT                      0
%define STATE_NOTE                       8
%define STATE_INSTRUMENT                 9
%define STATE_SAMPLE                     10
%define STATE_VOLUME                     11
%define STATE_PAN                        12
%define STATE_PERIOD                     16
%define STATE_TARGET                     24
%define STATE_PORTA_SLIDE                32
%define STATE_PORTA_DIR                  36
%define STATE_VOLUME_SLIDE               40
%define STATE_VIB_RATE                   44
%define STATE_VIB_DEPTH                  48
%define STATE_VIB_PHASE                  52
%define STATE_FLAGS                      56
%define STATE_FREQ_SLIDE                 60
%define STATE_ARP_X                      64
%define STATE_ARP_Y                      65
%define STATE_ARP_COUNT                  66
%define STATE_RETRIG_PERIOD              67
%define STATE_ACTIVE                     68
%define STATE_SAMPLE_POS                 72
%define STATE_RESTART                    69
%define RESTART_EDGE                     1
%define RESTART_MIX_VOLUME               0x80

%define FLAG_PITCH                       1
%define FLAG_TONE                        2
%define FLAG_VIBRATO                     4
%define FLAG_VOLUME                      8
%define FLAG_FINE_VOLUME                 16

%define OUT_PERIOD                       0
%define OUT_PITCHBEND                    4
%define OUT_NOTE                         6
%define OUT_INSTRUMENT                   7
%define OUT_SAMPLE                       8
%define OUT_VOLUME                       9
%define OUT_PAN                          10
%define OUT_RESTART                      11
%define OUT_EVENT                        12
%define OUT_SAMPLE_POSITION              20
%define OUT_SAMPLE_STEP                  28
%define OUT_TICK_FRAMES                  36
%define OUT_MIXER_VOLUME                 40
%define OUT_BYTES                        41

%define LOCAL_SPEED                      -2056
%define LOCAL_FRAMES                     -2060
%define LOCAL_CAPACITY                   -2064
%define LOCAL_CHANNEL                    -2068
%define LOCAL_TICK                       -2072
%define LOCAL_ORDER                      -2080
%define LOCAL_LINEAR                     -2076
%define LOCAL_PERIOD_PLUS                -2088
%define LOCAL_EXPONENT                   -2096
%define LOCAL_LOG                        -2104
%define LOCAL_BPM                        -2112
%define LOCAL_STEP                       -2104
%define LOCAL_SAMPLE_LENGTH              -2120
%define LOCAL_LOOP_START                 -2124
%define LOCAL_LOOP_LENGTH                -2128
%define LOCAL_LOOP_END                   -2132

global asm_audio_trace_tick_states
extern asm_audio_decode_event

section .text

; uint32_t asm_audio_trace_tick_states(const uint8_t* data,
;                                      uint32_t size,
;                                      AudioTickState* out,
;                                      uint32_t frameCapacity)
asm_audio_trace_tick_states:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 2080

        mov     r12, rcx                 ; module bytes
        mov     r13, r8                  ; output states
        mov     r14d, edx                ; module size during validation
        mov     dword [rbp + LOCAL_CAPACITY], r9d
        test    r12, r12
        jz      .bad
        test    r13, r13
        jz      .bad
        test    r9d, r9d
        jz      .bad
        cmp     r14d, MOD_HEADER_BYTES
        jb      .bad

        movzx   r15d, byte [r12 + 950]   ; order count
        test    r15d, r15d
        jz      .bad
        cmp     r15d, 128
        ja      .bad

        ; Validate the highest referenced pattern before entering the state
        ; machine.  The parser gate performs the same check independently.
        xor     esi, esi
        xor     r11d, r11d
        mov     ecx, r15d
.find_pattern:
        movzx   eax, byte [r12 + MOD_ORDER_TABLE + rsi]
        cmp     eax, r11d
        jbe     .find_next_pattern
        mov     r11d, eax
.find_next_pattern:
        inc     esi
        dec     ecx
        jnz     .find_pattern
        inc     r11d
        cmp     r11d, 64
        ja      .bad
        mov     eax, r11d
        imul    eax, MOD_PATTERN_BYTES
        add     eax, MOD_HEADER_BYTES
        cmp     r14d, eax
        jb      .bad
        mov     dword [rbp + LOCAL_ORDER], r15d

        ; Reset the 14 channel states.  libxmp exposes the loader's default
        ; panning pattern directly as [0,255,255,0] repeated.
        lea     rdi, [rbp - 2048]
        lea     r11, [rel default_pan]
        xor     ecx, ecx
.clear_state:
        mov     qword [rdi + STATE_EVENT], 0
        mov     byte [rdi + STATE_NOTE], 0xff
        mov     byte [rdi + STATE_INSTRUMENT], 0xff
        mov     byte [rdi + STATE_SAMPLE], 0
        mov     byte [rdi + STATE_VOLUME], 0
        movzx   eax, byte [r11 + rcx]
        mov     dword [rdi + STATE_PAN], eax
        mov     qword [rdi + STATE_PERIOD], 0
        mov     qword [rdi + STATE_TARGET], 0
        mov     dword [rdi + STATE_PORTA_SLIDE], 0
        mov     dword [rdi + STATE_PORTA_DIR], 0
        mov     dword [rdi + STATE_VOLUME_SLIDE], 0
        mov     dword [rdi + STATE_VIB_RATE], 0
        mov     dword [rdi + STATE_VIB_DEPTH], 0
        mov     dword [rdi + STATE_VIB_PHASE], 0
        mov     dword [rdi + STATE_FLAGS], 0
        mov     dword [rdi + STATE_FREQ_SLIDE], 0
        mov     dword [rdi + STATE_ARP_X], 0
        mov     byte [rdi + STATE_ACTIVE], 0
        mov     qword [rdi + STATE_SAMPLE_POS], 0
        add     rdi, STATE_BYTES
        inc     ecx
        cmp     ecx, MOD_CHANNELS
        jb      .clear_state

        mov     dword [rbp + LOCAL_SPEED], 6
        mov     dword [rbp + LOCAL_BPM], 125
        mov     dword [rbp + LOCAL_FRAMES], 0
        xor     ebx, ebx                 ; order index
        xor     r14d, r14d               ; row index
        mov     rsi, r13                 ; output frame cursor

.order_loop:
        movzx   eax, byte [r12 + MOD_ORDER_TABLE + rbx]
        imul    eax, MOD_PATTERN_BYTES
        add     eax, MOD_HEADER_BYTES
        lea     r15, [r12 + rax]
        mov     eax, r14d
        imul    eax, MOD_ROW_BYTES
        add     r15, rax                ; row base

        ; Event phase: clear transient effect flags, decode the fourteen
        ; events, update voice identity, and apply row-level commands.
        xor     ecx, ecx
.clear_flags:
        mov     eax, ecx
        imul    eax, STATE_BYTES
        lea     rdi, [rbp - 2048]
        add     rdi, rax
        mov     dword [rdi + STATE_FLAGS], 0
        mov     byte [rdi + STATE_RESTART], 0
        mov     byte [rdi + STATE_RETRIG_PERIOD], 0
        inc     ecx
        cmp     ecx, MOD_CHANNELS
        jb      .clear_flags

        mov     dword [rbp + LOCAL_CHANNEL], 0
.event_channel_loop:
        mov     eax, dword [rbp + LOCAL_CHANNEL]
        imul    eax, STATE_BYTES
        lea     rdi, [rbp - 2048]
        add     rdi, rax                ; channel state

        mov     eax, dword [rbp + LOCAL_CHANNEL]
        imul    eax, MOD_EVENT_BYTES
        lea     rdx, [r15 + rax]        ; raw event
        mov     rcx, rdx
        lea     rdx, [rdi + STATE_EVENT]
        sub     rsp, 8                  ; RSP%16 == 0 at the call
        call    asm_audio_decode_event
        add     rsp, 8

        ; Each row event resets the MOD arpeggio state.  Effect 0xy then
        ; installs the three-step base/x/y cycle for this channel.
        mov     dword [rdi + STATE_ARP_X], 0

        ; Tone-portamento rows retain the old base note and instrument.
        movzx   eax, byte [rdi + STATE_EVENT + 3]
        xor     r11d, r11d
        cmp     eax, 3
        je      .tone_event
        cmp     eax, 6
        jne     .instrument_event
.tone_event:
        mov     r11d, 1
        jmp     .instrument_done
.instrument_event:
        movzx   eax, byte [rdi + STATE_EVENT + 1]
        test    eax, eax
        jz      .instrument_done
        dec     eax
        mov     byte [rdi + STATE_INSTRUMENT], al
        imul    rax, MOD_SAMPLE_HEADER_BYTES
        movzx   ecx, byte [r12 + MOD_SAMPLE_HEADER + rax + MOD_SAMPLE_VOLUME]
        mov     byte [rdi + STATE_VOLUME], cl
.instrument_done:

        ; Accept a normal note only when an instrument is present.  Every
        ; used instrument in this module maps one-to-one to its sample.
        movzx   eax, byte [rdi + STATE_EVENT + 0]
        test    eax, eax
        jz      .note_done
        cmp     byte [rdi + STATE_INSTRUMENT], 0xff
        je      .note_done
        test    r11d, r11d
        jnz     .tone_note
        dec     eax
        mov     byte [rdi + STATE_NOTE], al
        mov     al, byte [rdi + STATE_INSTRUMENT]
        mov     byte [rdi + STATE_SAMPLE], al
        mov     byte [rdi + STATE_ACTIVE], 1
        mov     byte [rdi + STATE_RESTART], RESTART_EDGE
        mov     qword [rdi + STATE_SAMPLE_POS], 0
        mov     dword [rdi + STATE_VIB_PHASE], 0
        movzx   eax, byte [rdi + STATE_NOTE]
        sub     eax, 48
        lea     r11, [rel base_periods]
        movsd   xmm0, [r11 + rax * 8]
        movsd   [rdi + STATE_PERIOD], xmm0
        jmp     .note_done
.tone_note:
        dec     eax
        sub     eax, 48
        lea     r11, [rel base_periods]
        movsd   xmm0, [r11 + rax * 8]
        movsd   [rdi + STATE_TARGET], xmm0
.note_done:

        ; Apply the module's actual primary effect set.
        movzx   eax, byte [rdi + STATE_EVENT + 3]
        movzx   ecx, byte [rdi + STATE_EVENT + 4]
        test    eax, eax
        jz      .effect_arpeggio
        cmp     eax, 1
        je      .effect_pitch
        cmp     eax, 3
        je      .effect_tone
        cmp     eax, 4
        je      .effect_vibrato
        cmp     eax, 5
        je      .effect_tone_volume
        cmp     eax, 6
        je      .effect_vibrato_volume
        cmp     eax, 0x0a
        je      .effect_volume
        cmp     eax, 0x0c
        je      .effect_set_volume
        cmp     eax, 0x0e
        je      .effect_extended
        cmp     eax, 0x0f
        je      .effect_speed
        jmp     .effect_done
.effect_arpeggio:
        mov     edx, ecx
        shr     ecx, 4
        and     edx, 0x0f
        mov     byte [rdi + STATE_ARP_X], cl
        mov     byte [rdi + STATE_ARP_Y], dl
        jmp     .effect_done
.effect_pitch:
        mov     dword [rdi + STATE_FREQ_SLIDE], ecx
        neg     dword [rdi + STATE_FREQ_SLIDE]
        or      dword [rdi + STATE_FLAGS], FLAG_PITCH
        jmp     .effect_done
.effect_tone:
        test    ecx, ecx
        jz      .tone_direction
        mov     dword [rdi + STATE_PORTA_SLIDE], ecx
.tone_direction:
        or      dword [rdi + STATE_FLAGS], FLAG_TONE
        movsd   xmm0, [rdi + STATE_TARGET]
        xorpd   xmm1, xmm1
        ucomisd xmm0, xmm1
        jbe     .effect_done
        movsd   xmm1, [rdi + STATE_PERIOD]
        ucomisd xmm1, xmm0
        jb      .tone_up
        mov     dword [rdi + STATE_PORTA_DIR], -1
        jmp     .effect_done
.tone_up:
        mov     dword [rdi + STATE_PORTA_DIR], 1
        jmp     .effect_done
.effect_vibrato:
        mov     dword [rdi + STATE_VIB_RATE], ecx
        shr     dword [rdi + STATE_VIB_RATE], 4
        and     ecx, 0x0f
        shl     ecx, 2
        mov     dword [rdi + STATE_VIB_DEPTH], ecx
        or      dword [rdi + STATE_FLAGS], FLAG_VIBRATO
        jmp     .effect_done
.effect_tone_volume:
.tone_volume_direction:
        or      dword [rdi + STATE_FLAGS], FLAG_TONE | FLAG_VOLUME
        mov     edx, ecx
        and     ecx, 0x0f
        shr     edx, 4
        test    edx, edx
        jz      .tone_volume_down
        mov     ecx, edx
        jmp     .tone_volume_store
.tone_volume_down:
        neg     ecx
.tone_volume_store:
        mov     dword [rdi + STATE_VOLUME_SLIDE], ecx
        movsd   xmm0, [rdi + STATE_TARGET]
        xorpd   xmm1, xmm1
        ucomisd xmm0, xmm1
        jbe     .effect_done
        movsd   xmm1, [rdi + STATE_PERIOD]
        ucomisd xmm1, xmm0
        jb      .tone_volume_up_dir
        mov     dword [rdi + STATE_PORTA_DIR], -1
        jmp     .effect_done
.tone_volume_up_dir:
        mov     dword [rdi + STATE_PORTA_DIR], 1
        jmp     .effect_done
.effect_vibrato_volume:
        or      dword [rdi + STATE_FLAGS], FLAG_VIBRATO | FLAG_VOLUME
        mov     edx, ecx
        and     ecx, 0x0f
        shr     edx, 4
        test    edx, edx
        jz      .vibrato_volume_down
        mov     ecx, edx
        jmp     .vibrato_volume_store
.vibrato_volume_down:
        neg     ecx
.vibrato_volume_store:
        mov     dword [rdi + STATE_VOLUME_SLIDE], ecx
        jmp     .effect_done
.effect_volume:
        mov     edx, ecx
        and     ecx, 0x0f
        shr     edx, 4
        test    edx, edx
        jz      .volume_down
        mov     ecx, edx
        jmp     .volume_store
.volume_down:
        neg     ecx
.volume_store:
        mov     dword [rdi + STATE_VOLUME_SLIDE], ecx
        or      dword [rdi + STATE_FLAGS], FLAG_VOLUME
        movzx   ecx, byte [rdi + STATE_EVENT + 4]
        mov     edx, ecx
        and     edx, 0x0f
        cmp     edx, 0x0f
        je      .volume_fine
        shr     ecx, 4
        cmp     ecx, 0x0f
        jne     .effect_done
.volume_fine:
        or      dword [rdi + STATE_FLAGS], FLAG_FINE_VOLUME
        jmp     .effect_done
.effect_set_volume:
        mov     byte [rdi + STATE_VOLUME], cl
        test    cl, cl
        jnz     .effect_done
        mov     byte [rdi + STATE_RESTART], RESTART_EDGE
        jmp     .effect_done
.effect_extended:
        mov     edx, ecx
        and     ecx, 0x0f
        shr     edx, 4
        cmp     edx, 0x0a
        je      .extended_fine_up
        cmp     edx, 0x0b
        je      .extended_fine_down
        cmp     edx, 0x09
        je      .extended_retrig
        jmp     .effect_done
.extended_retrig:
        mov     byte [rdi + STATE_RETRIG_PERIOD], cl
        jmp     .effect_done
.extended_fine_up:
        movzx   eax, byte [rdi + STATE_VOLUME]
        add     eax, ecx
        cmp     eax, 64
        jbe     .fine_up_store
        mov     eax, 64
.fine_up_store:
        mov     byte [rdi + STATE_VOLUME], al
        jmp     .effect_done
.extended_fine_down:
        movzx   eax, byte [rdi + STATE_VOLUME]
        mov     edx, eax
        sub     eax, ecx
        jge     .fine_down_store
        xor     eax, eax
.fine_down_store:
        mov     byte [rdi + STATE_VOLUME], al
        test    eax, eax
        jnz     .effect_done
        test    edx, edx
        jz      .effect_done
        mov     byte [rdi + STATE_RESTART], RESTART_EDGE
        jmp     .effect_done
.effect_speed:
        test    ecx, ecx
        jz      .effect_done
        cmp     ecx, 0x20
        jae     .effect_bpm
        mov     dword [rbp + LOCAL_SPEED], ecx
        jmp     .effect_done
.effect_bpm:
        mov     dword [rbp + LOCAL_BPM], ecx
.effect_done:
        inc     dword [rbp + LOCAL_CHANNEL]
        cmp     dword [rbp + LOCAL_CHANNEL], MOD_CHANNELS
        jb      .event_channel_loop

        mov     dword [rbp + LOCAL_TICK], 0
.tick_loop:
        mov     eax, dword [rbp + LOCAL_FRAMES]
        cmp     eax, dword [rbp + LOCAL_CAPACITY]
        jae     .bad
        mov     dword [rbp + LOCAL_CHANNEL], 0
.tick_channel_loop:
        mov     eax, dword [rbp + LOCAL_CHANNEL]
        imul    eax, STATE_BYTES
        lea     rdi, [rbp - 2048]
        add     rdi, rax                ; channel state

        cmp     dword [rbp + LOCAL_TICK], 0
        jne     .tick_nonzero_updates

        mov     eax, dword [rdi + STATE_FLAGS]
        test    eax, FLAG_FINE_VOLUME
        jz      .tick_update_done
        jmp     .tick_apply_volume

.tick_nonzero_updates:
        mov     eax, dword [rdi + STATE_FLAGS]
        test    eax, FLAG_VOLUME
        jz      .tick_no_volume
.tick_apply_volume:
        movzx   edx, byte [rdi + STATE_VOLUME]
        mov     ecx, edx
        add     ecx, dword [rdi + STATE_VOLUME_SLIDE]
        test    ecx, ecx
        jge     .volume_nonnegative
        xor     ecx, ecx
.volume_nonnegative:
        cmp     ecx, 64
        jbe     .volume_clamped
        mov     ecx, 64
.volume_clamped:
        mov     byte [rdi + STATE_VOLUME], cl
        ; libxmp's mixer_setvol(0) arms the anti-click discharge.  The
        ; tracker snapshot has no separate mixer flag, so carry that edge in
        ; the same one-shot restart field used by note/position changes.
        test    ecx, ecx
        jnz     .tick_no_volume
        test    edx, edx
        jz      .tick_no_volume
        mov     byte [rdi + STATE_RESTART], RESTART_EDGE
.tick_no_volume:
        test    eax, FLAG_PITCH
        jz      .tick_no_pitch
        movsxd  rax, dword [rdi + STATE_FREQ_SLIDE]
        cvtsi2sd xmm0, rax
        addsd   xmm0, [rdi + STATE_PERIOD]
        movsd   [rdi + STATE_PERIOD], xmm0
.tick_no_pitch:
        test    eax, FLAG_TONE
        jz      .tick_update_done
        movsd   xmm0, [rdi + STATE_TARGET]
        xorpd   xmm1, xmm1
        ucomisd xmm0, xmm1
        jbe     .tick_update_done
        movsxd  rax, dword [rdi + STATE_PORTA_SLIDE]
        cvtsi2sd xmm1, rax
        cmp     dword [rdi + STATE_PORTA_DIR], 0
        jg      .tick_tone_up
        movsd   xmm0, [rdi + STATE_PERIOD]
        subsd   xmm0, xmm1
        ucomisd xmm0, [rdi + STATE_TARGET]
        ja      .tick_tone_down_store
        jmp     .tick_tone_clamp
.tick_tone_down_store:
        movsd   [rdi + STATE_PERIOD], xmm0
        jmp     .tick_update_done
.tick_tone_up:
        addsd   xmm1, [rdi + STATE_PERIOD]
        ucomisd xmm1, [rdi + STATE_TARGET]
        jb      .tick_tone_store
        movsd   xmm1, [rdi + STATE_TARGET]
.tick_tone_store:
        movsd   [rdi + STATE_PERIOD], xmm1
        jmp     .tick_update_done
.tick_tone_clamp:
        movsd   xmm0, [rdi + STATE_TARGET]
        movsd   [rdi + STATE_PERIOD], xmm0
        and     dword [rdi + STATE_FLAGS], ~FLAG_TONE
.tick_update_done:

        ; E9x retriggers the current voice every x tracker ticks.  libxmp
        ; resets both the source position and anti-click state at the
        ; retrigger boundary; expose the same edge to the native mixer.
        movzx   eax, byte [rdi + STATE_RETRIG_PERIOD]
        test    eax, eax
        jz      .tick_retrig_done
        cmp     dword [rbp + LOCAL_TICK], 0
        je      .tick_retrig_done
        mov     ecx, eax
        mov     eax, dword [rbp + LOCAL_TICK]
        xor     edx, edx
        div     ecx
        test    edx, edx
        jnz     .tick_retrig_done
        mov     qword [rdi + STATE_SAMPLE_POS], 0
        movzx   edx, byte [rdi + STATE_ACTIVE]
        mov     byte [rdi + STATE_ACTIVE], 1
        mov     byte [rdi + STATE_RESTART], RESTART_EDGE
        ; A retrigger of an already-live voice keeps the public channel
        ; volume.  Only resurrect a voice that libxmp has already marked
        ; finished with the private mixer-volume marker; that is the case
        ; where the mixer must restart the sample while channel_info still
        ; reports volume zero for this tick.
        test    edx, edx
        jnz     .tick_retrig_done
        cmp     byte [rdi + STATE_VOLUME], 0
        je      .tick_retrig_done
        or      byte [rdi + STATE_RESTART], RESTART_MIX_VOLUME
.tick_retrig_done:

        ; Destination record for this channel in the current frame.
        mov     eax, dword [rbp + LOCAL_CHANNEL]
        imul    eax, OUT_BYTES
        lea     rdx, [rsi + rax]
        mov     rax, qword [rdi + STATE_EVENT]
        mov     qword [rdx + OUT_EVENT], rax
        mov     rax, qword [rdi + STATE_SAMPLE_POS]
        mov     qword [rdx + OUT_SAMPLE_POSITION], rax
        mov     byte [rdx + OUT_NOTE], 0
        mov     byte [rdx + OUT_INSTRUMENT], 0
        mov     byte [rdx + OUT_SAMPLE], 0
        mov     byte [rdx + OUT_VOLUME], 0
        mov     byte [rdx + OUT_PAN], 0
        mov     byte [rdx + OUT_RESTART], 0
        mov     byte [rdx + OUT_MIXER_VOLUME], 0
        mov     word [rdx + OUT_PITCHBEND], 0
        mov     dword [rdx + OUT_PERIOD], 0
        movzx   eax, byte [rdi + STATE_NOTE]
        mov     byte [rdx + OUT_NOTE], al
        movzx   eax, byte [rdi + STATE_INSTRUMENT]
        mov     byte [rdx + OUT_INSTRUMENT], al
        movzx   eax, byte [rdi + STATE_SAMPLE]
        mov     byte [rdx + OUT_SAMPLE], al
        cmp     byte [rdi + STATE_INSTRUMENT], 0xff
        je      .snapshot_inactive
        movzx   eax, byte [rdi + STATE_VOLUME]
        mov     byte [rdx + OUT_VOLUME], al
        cmp     byte [rdi + STATE_ACTIVE], 0
        je      .snapshot_mixer_volume_done
        mov     byte [rdx + OUT_MIXER_VOLUME], al
.snapshot_mixer_volume_done:
        test    byte [rdi + STATE_RESTART], RESTART_MIX_VOLUME
        jnz     .snapshot_volume_hidden
        cmp     byte [rdi + STATE_ACTIVE], 0
        jne     .snapshot_volume_active
.snapshot_volume_hidden:
        mov     byte [rdx + OUT_VOLUME], 0
.snapshot_volume_active:
        mov     eax, dword [rdi + STATE_PAN]
        mov     byte [rdx + OUT_PAN], al
        mov     eax, dword [rdi + STATE_RESTART]
        mov     byte [rdx + OUT_RESTART], al

        ; period_plus = channel period + FT2 vibrato contribution.
        movsd   xmm0, [rdi + STATE_PERIOD]
        mov     eax, dword [rdi + STATE_FLAGS]
        test    eax, FLAG_VIBRATO
        jz      .no_vibrato
        mov     eax, dword [rdi + STATE_VIB_PHASE]
        lea     r11, [rel sine_wave]
        mov     ecx, eax
        mov     eax, dword [r11 + rcx * 4]
        imul    eax, dword [rdi + STATE_VIB_DEPTH]
        test    eax, eax
        jns     .vib_nonnegative
        add     eax, 511                  ; C integer division truncates to zero
.vib_nonnegative:
        sar     eax, 9
        cvtsi2sd xmm1, eax
        addsd   xmm0, xmm1
.no_vibrato:
        movsd   [rbp + LOCAL_PERIOD_PLUS], xmm0

        movzx   eax, byte [rdi + STATE_NOTE]
        sub     eax, 48
        lea     r11, [rel base_periods]
        movsd   xmm3, [r11 + rax * 8]
        movsd   [rbp + LOCAL_EXPONENT], xmm3

        ; linear_bend = round(153600 * log2(base_period / period_plus)).
        fld     qword [rbp + LOCAL_EXPONENT]
        fld     qword [rbp + LOCAL_PERIOD_PLUS]
        fdivp   st1, st0
        fld     qword [rel bend_scale]
        fxch    st1
        fyl2x
        fstp    qword [rbp + LOCAL_LOG]
        movsd   xmm0, [rbp + LOCAL_LOG]
        xorpd   xmm1, xmm1
        comisd  xmm0, xmm1
        jb      .linear_negative
        addsd   xmm0, [rel half]
        jmp     .linear_round
.linear_negative:
        subsd   xmm0, [rel half]
.linear_round:
        cvttsd2si eax, xmm0
        mov     dword [rbp + LOCAL_LINEAR], eax

        mov     eax, dword [rbp + LOCAL_LINEAR]
        movzx   ecx, byte [rdi + STATE_ARP_COUNT]
        test    ecx, ecx
        jz      .no_arpeggio
        cmp     ecx, 1
        je      .arpeggio_x
        movzx   eax, byte [rdi + STATE_ARP_Y]
        jmp     .arpeggio_apply
.arpeggio_x:
        movzx   eax, byte [rdi + STATE_ARP_X]
.arpeggio_apply:
        imul    eax, 12800
        add     dword [rbp + LOCAL_LINEAR], eax
.no_arpeggio:
        mov     eax, dword [rbp + LOCAL_LINEAR]
        mov     ecx, eax
        sar     ecx, 7
        mov     word [rdx + OUT_PITCHBEND], cx

        ; final_period = base_period * 2^(-linear_bend / 153600).
        fild    dword [rbp + LOCAL_LINEAR]
        fchs
        fidiv   dword [rel bend_scale_int]
        fld     st0
        frndint
        fsub    st1, st0
        fxch    st1
        f2xm1
        fld1
        faddp   st1, st0
        fscale
        fstp    qword [rbp + LOCAL_PERIOD_PLUS]
        fstp    st0                      ; discard fscale's exponent operand
        fld     qword [rbp + LOCAL_EXPONENT]
        fmul    qword [rbp + LOCAL_PERIOD_PLUS]
        fstp    qword [rbp + LOCAL_PERIOD_PLUS]
        movsd   xmm0, [rbp + LOCAL_PERIOD_PLUS]
        mulsd   xmm0, [rel period_scale]
        cvttsd2si eax, xmm0
        mov     dword [rdx + OUT_PERIOD], eax
        mov     eax, 428
        cvtsi2sd xmm0, eax
        mov     eax, 8287
        cvtsi2sd xmm1, eax
        mulsd   xmm0, xmm1
        mov     eax, 44100
        cvtsi2sd xmm1, eax
        divsd   xmm0, xmm1
        divsd   xmm0, [rbp + LOCAL_PERIOD_PLUS]
        movsd   [rbp + LOCAL_STEP], xmm0
        movsd   [rdx + OUT_SAMPLE_STEP], xmm0
        mov     r10, rdx
        mov     eax, 110250
        xor     edx, edx
        div     dword [rbp + LOCAL_BPM]
        mov     dword [r10 + OUT_TICK_FRAMES], eax
        jmp     .snapshot_lfo

.snapshot_inactive:
        mov     dword [rdx + OUT_PERIOD], 0
        xorpd   xmm0, xmm0
        movsd   [rbp + LOCAL_STEP], xmm0
        movsd   [rdx + OUT_SAMPLE_STEP], xmm0
        mov     r10, rdx
        mov     eax, 110250
        xor     edx, edx
        div     dword [rbp + LOCAL_BPM]
        mov     dword [r10 + OUT_TICK_FRAMES], eax
.snapshot_lfo:
        ; Restart is an edge, not a persistent voice property.  The mixer
        ; consumes it for this snapshot to reset anti-click history; clear it
        ; before the next tracker tick so the ramp can persist.
        and     byte [rdi + STATE_RESTART], RESTART_MIX_VOLUME
        ; FT2 does not advance vibrato on the first tick of a row.  Advance
        ; after rendering ticks 1..N with the current phase.
        cmp     dword [rbp + LOCAL_TICK], 0
        je      .tick_lfo_done
        test    dword [rdi + STATE_FLAGS], FLAG_VIBRATO
        jz      .tick_lfo_done
        mov     eax, dword [rdi + STATE_VIB_PHASE]
        add     eax, dword [rdi + STATE_VIB_RATE]
        and     eax, 63
        mov     dword [rdi + STATE_VIB_PHASE], eax
.tick_lfo_done:
        movzx   eax, byte [rdi + STATE_ARP_X]
        movzx   ecx, byte [rdi + STATE_ARP_Y]
        or      eax, ecx
        jz      .tick_arpeggio_done
        movzx   eax, byte [rdi + STATE_ARP_COUNT]
        inc     eax
        cmp     eax, 3
        jb      .tick_arpeggio_store
        xor     eax, eax
.tick_arpeggio_store:
        mov     byte [rdi + STATE_ARP_COUNT], al
.tick_arpeggio_done:
        ; Advance the logical sample voice exactly far enough to reproduce
        ; libxmp's channel-info sample-end flag.  PCM interpolation remains a
        ; later gate; this state is only used to make one-shot volume go to
        ; zero on the same tick as the oracle.
        cmp     byte [rdi + STATE_ACTIVE], 0
        je      .tick_sample_done
        mov     eax, 110250              ; 44100 * 2500 / 1000
        xor     edx, edx
        div     dword [rbp + LOCAL_BPM]
        cvtsi2sd xmm0, eax                ; frames per tracker tick
        movsd   xmm1, [rbp + LOCAL_STEP]
        mulsd   xmm1, xmm0
        addsd   xmm1, [rdi + STATE_SAMPLE_POS]

        movzx   eax, byte [rdi + STATE_SAMPLE]
        imul    ecx, eax, MOD_SAMPLE_HEADER_BYTES
        lea     r11, [r12 + MOD_SAMPLE_HEADER + rcx]
        movzx   eax, byte [r11 + 22]
        shl     eax, 8
        movzx   ecx, byte [r11 + 23]
        or      eax, ecx
        shl     eax, 1                    ; sample length in frames
        mov     dword [rbp + LOCAL_SAMPLE_LENGTH], eax
        movzx   eax, byte [r11 + 26]
        shl     eax, 8
        movzx   ecx, byte [r11 + 27]
        or      eax, ecx
        shl     eax, 1                    ; loop start in frames
        mov     dword [rbp + LOCAL_LOOP_START], eax
        movzx   eax, byte [r11 + 28]
        shl     eax, 8
        movzx   ecx, byte [r11 + 29]
        or      eax, ecx
        shl     eax, 1                    ; loop length in frames
        mov     dword [rbp + LOCAL_LOOP_LENGTH], eax
        add     eax, dword [rbp + LOCAL_LOOP_START]
        mov     dword [rbp + LOCAL_LOOP_END], eax ; loop end

        cmp     dword [rbp + LOCAL_LOOP_LENGTH], 2
        jb      .tick_sample_no_loop
        cmp     dword [rbp + LOCAL_LOOP_END], 4
        jb      .tick_sample_no_loop
.tick_sample_wrap:
        cvtsi2sd xmm0, dword [rbp + LOCAL_LOOP_END]
        comisd  xmm1, xmm0
        jb      .tick_sample_store
        mov     eax, dword [rbp + LOCAL_LOOP_LENGTH]
        cvtsi2sd xmm0, eax
        subsd   xmm1, xmm0
        jmp     .tick_sample_wrap
.tick_sample_no_loop:
        cvtsi2sd xmm0, dword [rbp + LOCAL_SAMPLE_LENGTH]
        comisd  xmm1, xmm0
        jb      .tick_sample_store
        mov     byte [rdi + STATE_ACTIVE], 0
        movsd   xmm1, xmm0
.tick_sample_store:
        movsd   [rdi + STATE_SAMPLE_POS], xmm1
.tick_sample_done:

        inc     dword [rbp + LOCAL_CHANNEL]
        cmp     dword [rbp + LOCAL_CHANNEL], MOD_CHANNELS
        jb      .tick_channel_loop

        add     rsi, MOD_CHANNELS * OUT_BYTES
        inc     dword [rbp + LOCAL_FRAMES]
        inc     dword [rbp + LOCAL_TICK]
        mov     eax, dword [rbp + LOCAL_TICK]
        cmp     eax, dword [rbp + LOCAL_SPEED]
        jb      .tick_loop

        inc     r14d
        cmp     r14d, MOD_ROWS
        jb      .order_loop
        xor     r14d, r14d
        inc     rbx
        cmp     ebx, dword [rbp + LOCAL_ORDER]
        jb      .order_loop

        mov     eax, dword [rbp + LOCAL_FRAMES]
        jmp     .return

.bad:
        xor     eax, eax
.return:
        add     rsp, 2080
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

section .rdata align=8

default_pan:
        db      0, 255, 255, 0, 0, 255, 255, 0
        db      0, 255, 255, 0, 0, 255

; libxmp's 13696 / pow(2,n/12) values for state notes 48..83.
base_periods:
        dq      856.0, 807.9564116555298, 762.6093027281303, 719.8073314571797
        dq      679.4076502423895, 641.2754289032196, 605.2834046956847, 571.3114575847748
        dq      539.2462093550056, 508.98064522116465, 480.4137566764117, 453.4502043857783
        dq      428.0, 403.9782058277649, 381.30465136406514, 359.90366572858983
        dq      339.70382512119477, 320.6377144516098, 302.64170234784234, 285.6557287923874
        dq      269.6231046775028, 254.49032261058233, 240.20687833820585, 226.72510219288915
        dq      214.0, 201.98910291388245, 190.65232568203257, 179.95183286429491
        dq      169.85191256059738, 160.3188572258049, 151.32085117392117, 142.8278643961937
        dq      134.8115523387514, 127.24516130529116, 120.10343916910293, 113.36255109644458

sine_wave:
        dd      0, 24, 49, 74, 97, 120, 141, 161, 180, 197, 212, 224
        dd      235, 244, 250, 253, 255, 253, 250, 244, 235, 224, 212, 197
        dd      180, 161, 141, 120, 97, 74, 49, 24, 0, -24, -49, -74
        dd      -97, -120, -141, -161, -180, -197, -212, -224, -235, -244, -250, -253
        dd      -255, -253, -250, -244, -235, -224, -212, -197, -180, -161, -141, -120
        dd      -97, -74, -49, -24

bend_scale:     dq      153600.0
period_scale:   dq      4096.0
vib_scale:      dq      512.0
half:           dq      0.5
bend_scale_int: dd      153600
