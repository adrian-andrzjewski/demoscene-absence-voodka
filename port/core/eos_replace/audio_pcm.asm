; audio_pcm.asm - Phase 2F native 8-bit MOD sample mixer.
;
; The checked-in soundtrack uses signed 8-bit mono samples, forward loops,
; linear interpolation, stereo output, and libxmp's default integer downmix.
; This gate intentionally implements that module-specific path.  General
; 16-bit/stereo samples, spline interpolation, IT filters, and Paula output
; are outside the soundtrack contract and remain future work if needed.

BITS 64
DEFAULT REL

%define MOD_SAMPLE_HEADER                20
%define MOD_SAMPLE_HEADER_BYTES          30
%define MOD_SAMPLE_DATA_OFFSET           1084
%define MOD_ORDER_TABLE                  952
%define MOD_ORDER_COUNT                 950
%define MOD_PATTERN_BYTES                3584
%define MOD_CHANNELS                     14
%define MOD_SAMPLE_COUNT                 31
%define DOWNMIX_SHIFT                    11 ; libxmp DOWNMIX_SHIFT(12) - amplify(1)

%define STATE_NOTE                       6
%define STATE_INSTRUMENT                 7
%define STATE_SAMPLE                     8
%define STATE_VOLUME                     9
%define STATE_PAN                        10
%define STATE_RESTART                    11
%define RESTART_EDGE                     1
%define STATE_SAMPLE_POSITION            20
%define STATE_SAMPLE_STEP                28
%define STATE_TICK_FRAMES                36
%define STATE_MIXER_VOLUME               40
%define STATE_BYTES                      41
%define FRAME_BYTES                      (MOD_CHANNELS * STATE_BYTES)

%define LOCAL_SAMPLE_DATA                -388
%define LOCAL_SAMPLE_INDEX               -392
%define LOCAL_FRAME_INDEX                -396
%define LOCAL_CHANNEL                    -400
%define LOCAL_TICK_FRAMES                -404
%define LOCAL_SAMPLE_PTR                 -416
%define LOCAL_SAMPLE_LENGTH              -420
%define LOCAL_LOOP_START                 -424
%define LOCAL_LOOP_END                   -428
%define LOCAL_LOOP_FLAG                  -432
%define LOCAL_POS_INT                    -436
%define LOCAL_FRAC                       -440
%define LOCAL_STEP_FP                    -444
%define LOCAL_TARGET_L                   -448
%define LOCAL_TARGET_R                   -452
%define LOCAL_DELTA_L                    -456
%define LOCAL_DELTA_R                    -460
%define LOCAL_RAMP_LEFT                  -464
%define LOCAL_REMAIN                     -468
%define LOCAL_LAST_L                     -472
%define LOCAL_LAST_R                     -476
%define LOCAL_SAMPLE_VALUE               -480
%define LOCAL_LEVEL_L                    -484
%define LOCAL_LEVEL_R                    -488
%define LOCAL_BUF_PTR                    -496
%define LOCAL_AC_COUNT                   -500
%define LOCAL_AC_STEP                    -504
%define LOCAL_AC_MUL                     -508
%define LOCAL_STATES                     -516
%define LOCAL_DOUBLE_POS                 -524
%define LOCAL_PREV_L                     -532
%define LOCAL_PREV_R                     -536
%define LOCAL_NEXT_SAMPLE                -540

; Keep the 14-entry history arrays below the saved-register area.  The
; prologue saves seven qwords below RBP (-8 through -64); placing OLD_L at
; -64 would overwrite those saves during REP STOSD initialization.
%define OLD_L                            -640
%define OLD_R                            -696
%define SLEFT                            -752
%define SRIGHT                           -808
%define MIX_BUFFER                       -32000
%define STACK_BYTES                      32768

global asm_audio_mix_tick_states

section .text

; uint32_t asm_audio_mix_tick_states(const uint8_t* module,
;                                    uint32_t moduleSize,
;                                    const AudioTickState* states,
;                                    uint32_t stateFrames,
;                                    int16_t* output,
;                                    uint32_t outputCapacity)
asm_audio_mix_tick_states:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15
        ; Windows grows the stack through a guard page.  A raw 32 KB
        ; subtraction can leave the accumulator below an uncommitted page;
        ; touch each page before using the local mixer buffer.
        mov     rax, rsp
        sub     rax, STACK_BYTES
.stack_probe:
        sub     rsp, 0x1000
        test    byte [rsp], 0
        cmp     rsp, rax
        jne     .stack_probe

        mov     r12, rcx                    ; module
        mov     r13, r8                     ; tick states
        mov     r14d, r9d                   ; state frame count
        mov     r15, [rbp + 48]             ; output
        mov     ebx, [rbp + 56]             ; output capacity
        test    r12, r12
        jz      .bad
        test    r13, r13
        jz      .bad
        test    r15, r15
        jz      .bad
        test    r14d, r14d
        jz      .bad
        mov     qword [rbp + LOCAL_STATES], r13

        ; Derive the packed sample-data offset from the highest order pattern.
        ; This retains the parser's module-size-independent layout contract.
        movzx   eax, byte [r12 + MOD_ORDER_COUNT]
        test    eax, eax
        jz      .bad
        xor     edx, edx
        xor     r10d, r10d
.find_pattern:
        cmp     edx, eax
        jae     .pattern_done
        movzx   ecx, byte [r12 + MOD_ORDER_TABLE + rdx]
        cmp     ecx, r10d
        jbe     .pattern_next
        mov     r10d, ecx
.pattern_next:
        inc     edx
        jmp     .find_pattern
.pattern_done:
        inc     r10d
        imul    r10d, MOD_PATTERN_BYTES
        add     r10d, MOD_SAMPLE_DATA_OFFSET
        mov     dword [rbp + LOCAL_SAMPLE_DATA], r10d

        ; Clear per-channel mixer history.  libxmp starts note ramps and
        ; anticlick state from zero.
        lea     rdi, [rbp + OLD_L]
        xor     eax, eax
        mov     ecx, MOD_CHANNELS
        rep stosd
        lea     rdi, [rbp + OLD_R]
        mov     ecx, MOD_CHANNELS
        rep stosd
        lea     rdi, [rbp + SLEFT]
        mov     ecx, MOD_CHANNELS
        rep stosd
        lea     rdi, [rbp + SRIGHT]
        mov     ecx, MOD_CHANNELS
        rep stosd

        mov     dword [rbp + LOCAL_FRAME_INDEX], 0
        xor     esi, esi                    ; output frame count

.frame_loop:
        cmp     dword [rbp + LOCAL_FRAME_INDEX], r14d
        jae     .done
        mov     eax, dword [rbp + LOCAL_FRAME_INDEX]
        imul    eax, FRAME_BYTES
        mov     rdx, qword [rbp + LOCAL_STATES]
        lea     r8, [rdx + rax]              ; derive, do not carry, state ptr

        mov     eax, dword [r8 + STATE_TICK_FRAMES]
        test    eax, eax
        jz      .bad
        mov     dword [rbp + LOCAL_TICK_FRAMES], eax
        mov     rdx, rbx
        sub     rdx, rsi
        jc      .bad
        cmp     rax, rdx
        ja      .bad

        ; Clear the signed 32-bit stereo accumulator.
        lea     rdi, [rbp + MIX_BUFFER]
        mov     ecx, eax
        shl     ecx, 1
        xor     eax, eax
        rep stosd

        xor     r9d, r9d                    ; channel
.channel_loop:
        cmp     r9d, MOD_CHANNELS
        jae     .render_tick
        mov     eax, r9d
        imul    eax, STATE_BYTES
        lea     r11, [r8 + rax]              ; current channel state
        mov     dword [rbp + LOCAL_CHANNEL], r9d

        ; libxmp marks a note/position restart for anti-click processing.  It
        ; discharges the previous voice tail before the new sample is mixed,
        ; then starts the replacement voice's volume ramp from zero.  Keep
        ; the tail in 32-bit accumulator units and preserve the exact
        ; 16-bit-square weighting used by do_anticlick().
        movzx   eax, byte [r11 + STATE_RESTART]
        test    eax, RESTART_EDGE
        jz      .restart_done
        mov     ecx, dword [rbp + LOCAL_TICK_FRAMES]
        shr     ecx, 3
        test    ecx, ecx
        jz      .restart_clear_history
        mov     eax, 1 << 24
        xor     edx, edx
        div     ecx
        mov     dword [rbp + LOCAL_AC_STEP], eax
        imul    eax, ecx
        mov     dword [rbp + LOCAL_AC_MUL], eax
        lea     rdi, [rbp + MIX_BUFFER]
        mov     ecx, dword [rbp + LOCAL_TICK_FRAMES]
        shr     ecx, 3
.restart_anticlick_loop:
        mov     eax, dword [rbp + LOCAL_AC_STEP]
        sub     dword [rbp + LOCAL_AC_MUL], eax
        mov     edx, dword [rbp + LOCAL_AC_MUL]
        test    edx, edx
        jle     .restart_clear_history
        shr     edx, 8
        imul    edx, edx
        mov     eax, edx
        mov     rdx, qword [rbp + SLEFT]
        ; SLEFT/SRIGHT are arrays, so index them using the current channel.
        mov     eax, dword [rbp + LOCAL_CHANNEL]
        lea     r10, [rbp + SLEFT]
        movsxd  rdx, dword [r10 + rax * 4]
        mov     eax, dword [rbp + LOCAL_AC_MUL]
        shr     eax, 8
        imul    eax, eax
        movsxd  rdx, edx
        imul    rdx, rax
        sar     rdx, 32
        add     dword [rdi], edx
        mov     eax, dword [rbp + LOCAL_CHANNEL]
        lea     r10, [rbp + SRIGHT]
        movsxd  rdx, dword [r10 + rax * 4]
        mov     eax, dword [rbp + LOCAL_AC_MUL]
        shr     eax, 8
        imul    eax, eax
        movsxd  rdx, edx
        imul    rdx, rax
        sar     rdx, 32
        add     dword [rdi + 4], edx
        add     rdi, 8
        dec     ecx
        jnz     .restart_anticlick_loop
.restart_clear_history:
        mov     eax, dword [rbp + LOCAL_CHANNEL]
        lea     r10, [rbp + OLD_L]
        mov     dword [r10 + rax * 4], 0
        lea     r10, [rbp + OLD_R]
        mov     dword [r10 + rax * 4], 0
        lea     r10, [rbp + SLEFT]
        mov     dword [r10 + rax * 4], 0
        lea     r10, [rbp + SRIGHT]
        mov     dword [r10 + rax * 4], 0
.restart_done:

        movzx   eax, byte [r11 + STATE_VOLUME]
        test    eax, eax
        jnz     .voice_volume_ready
        movzx   eax, byte [r11 + STATE_MIXER_VOLUME]
        test    eax, eax
        jz      .voice_silent
.voice_volume_ready:
        cmp     byte [r11 + STATE_INSTRUMENT], 0xff
        je      .voice_silent

        ; Convert public 0..64 volume and 0..255 pan to libxmp's mixer
        ; levels: vi->vol * (0x80 +/- internal_pan), with vi->vol=vol*16.
        movzx   ecx, byte [r11 + STATE_PAN]
        mov     edx, eax
        mov     r10d, 256
        sub     r10d, ecx
        imul    edx, r10d
        shl     edx, 4
        mov     dword [rbp + LOCAL_TARGET_L], edx
        imul    eax, ecx
        shl     eax, 4
        mov     dword [rbp + LOCAL_TARGET_R], eax

        ; A note restart resets the source position in the tracker state, but
        ; libxmp reuses the voice and preserves its volume-ramp history.  Do
        ; not zero OLD_L/OLD_R here; zero-volume snapshots already discharge
        ; those targets through voice_silent.

        movzx   eax, byte [r11 + STATE_SAMPLE]
        cmp     eax, MOD_SAMPLE_COUNT
        jae     .voice_silent
        mov     dword [rbp + LOCAL_SAMPLE_INDEX], eax

        ; Decode this sample's raw MOD header.
        imul    ecx, eax, MOD_SAMPLE_HEADER_BYTES
        lea     r10, [r12 + MOD_SAMPLE_HEADER + rcx]
        movzx   eax, byte [r10 + 22]
        shl     eax, 8
        movzx   ecx, byte [r10 + 23]
        or      eax, ecx
        shl     eax, 1
        mov     dword [rbp + LOCAL_SAMPLE_LENGTH], eax
        test    eax, eax
        jz      .voice_silent

        movzx   eax, byte [r10 + 26]
        shl     eax, 8
        movzx   ecx, byte [r10 + 27]
        or      eax, ecx
        shl     eax, 1
        mov     dword [rbp + LOCAL_LOOP_START], eax
        movzx   eax, byte [r10 + 28]
        shl     eax, 8
        movzx   ecx, byte [r10 + 29]
        or      eax, ecx
        shl     eax, 1
        add     eax, dword [rbp + LOCAL_LOOP_START]
        cmp     eax, dword [rbp + LOCAL_SAMPLE_LENGTH]
        jbe     .loop_end_valid
        mov     eax, dword [rbp + LOCAL_SAMPLE_LENGTH]
.loop_end_valid:
        mov     dword [rbp + LOCAL_LOOP_END], eax
        mov     dword [rbp + LOCAL_LOOP_FLAG], 0
        cmp     eax, dword [rbp + LOCAL_LOOP_START]
        jbe     .loop_checked
        mov     ecx, eax
        sub     ecx, dword [rbp + LOCAL_LOOP_START]
        cmp     ecx, 2
        jbe     .loop_checked
        cmp     eax, 4
        jb      .loop_checked
        mov     dword [rbp + LOCAL_LOOP_FLAG], 1
.loop_checked:

        ; Sum preceding sample byte lengths to locate this sample's data.
        mov     eax, dword [rbp + LOCAL_SAMPLE_INDEX]
        xor     edx, edx
        mov     ecx, dword [rbp + LOCAL_SAMPLE_DATA]
.sample_offset_loop:
        cmp     edx, eax
        jae     .sample_offset_done
        mov     r10d, edx
        imul    r10d, MOD_SAMPLE_HEADER_BYTES
        movzx   edi, byte [r12 + MOD_SAMPLE_HEADER + r10 + 22]
        shl     edi, 8
        movzx   r10d, byte [r12 + MOD_SAMPLE_HEADER + r10 + 23]
        or      edi, r10d
        shl     edi, 1
        add     ecx, edi
        inc     edx
        jmp     .sample_offset_loop
.sample_offset_done:
        movsxd  rax, ecx
        add     rax, r12
        mov     qword [rbp + LOCAL_SAMPLE_PTR], rax

        ; libxmp passes (step * 65536) as an integer to the linear mixer.
        movsd   xmm0, qword [r11 + STATE_SAMPLE_STEP]
        mulsd   xmm0, [rel fp_scale]
        cvttsd2si eax, xmm0
        test    eax, eax
        jle     .voice_silent
        mov     dword [rbp + LOCAL_STEP_FP], eax

        ; VAR_NORM(): integer position and 16-bit fractional position.
        movsd   xmm0, qword [r11 + STATE_SAMPLE_POSITION]
        movsd   qword [rbp + LOCAL_DOUBLE_POS], xmm0
        cvttsd2si eax, xmm0
        mov     dword [rbp + LOCAL_POS_INT], eax
        cvtsi2sd xmm1, eax
        subsd   xmm0, xmm1
        mulsd   xmm0, [rel fp_scale]
        cvttsd2si eax, xmm0
        mov     dword [rbp + LOCAL_FRAC], eax

        mov     eax, dword [rbp + LOCAL_TICK_FRAMES]
        mov     dword [rbp + LOCAL_REMAIN], eax
        shr     eax, 3
        mov     dword [rbp + LOCAL_RAMP_LEFT], eax
        test    eax, eax
        jnz     .ramp_nonzero
        mov     dword [rbp + LOCAL_DELTA_L], 0
        mov     dword [rbp + LOCAL_DELTA_R], 0
        jmp     .ramp_ready
.ramp_nonzero:
        mov     ecx, dword [rbp + LOCAL_CHANNEL]
        lea     r10, [rbp + OLD_L]
        mov     eax, dword [rbp + LOCAL_TARGET_L]
        sub     eax, dword [r10 + rcx * 4]
        cdq
        idiv    dword [rbp + LOCAL_RAMP_LEFT]
        mov     dword [rbp + LOCAL_DELTA_L], eax
        lea     r10, [rbp + OLD_R]
        mov     eax, dword [rbp + LOCAL_TARGET_R]
        sub     eax, dword [r10 + rcx * 4]
        cdq
        idiv    dword [rbp + LOCAL_RAMP_LEFT]
        mov     dword [rbp + LOCAL_DELTA_R], eax
.ramp_ready:
        mov     ecx, dword [rbp + LOCAL_CHANNEL]
        lea     r10, [rbp + SLEFT]
        mov     eax, dword [r10 + rcx * 4]
        mov     dword [rbp + LOCAL_LAST_L], eax
        lea     r10, [rbp + SRIGHT]
        mov     eax, dword [r10 + rcx * 4]
        mov     dword [rbp + LOCAL_LAST_R], eax
        lea     rax, [rbp + MIX_BUFFER]
        mov     edx, dword [rax]
        mov     dword [rbp + LOCAL_PREV_L], edx
        mov     edx, dword [rax + 4]
        mov     dword [rbp + LOCAL_PREV_R], edx
        lea     rax, [rbp + MIX_BUFFER]
        mov     qword [rbp + LOCAL_BUF_PTR], rax

.sample_loop:
        cmp     dword [rbp + LOCAL_REMAIN], 0
        je      .voice_finish_active

        ; libxmp decides the segment boundary from its double-precision
        ; voice position, while the interpolation index is fixed-point.  The
        ; double can cross LOOP_END while LOCAL_POS_INT is still one sample
        ; below it; normalize before sampling so the first wrapped sample is
        ; not rendered from the final pre-loop sample twice.
        cmp     dword [rbp + LOCAL_LOOP_FLAG], 0
        je      .sample_loop_integer_boundary
        movsd   xmm0, qword [rbp + LOCAL_DOUBLE_POS]
        cvtsi2sd xmm1, dword [rbp + LOCAL_LOOP_END]
        comisd  xmm0, xmm1
        jae     .loop_segment_tail
.sample_loop_integer_boundary:
        mov     eax, dword [rbp + LOCAL_POS_INT]
        cmp     dword [rbp + LOCAL_LOOP_FLAG], 0
        je      .one_shot_boundary
        cmp     eax, dword [rbp + LOCAL_LOOP_END]
        jb      .sample_inside
        ; libxmp advances vi->pos in double precision, then restarts the
        ; mixer segment after loop_reposition().  Rebuild the fixed-point
        ; fraction from that double position instead of carrying the integer
        ; mixer phase across the loop boundary.
.loop_segment_tail:
        lea     rdi, [rbp + MIX_BUFFER]
        cmp     qword [rbp + LOCAL_BUF_PTR], rdi
        je      .loop_reposition
        mov     rdx, qword [rbp + LOCAL_BUF_PTR]
        sub     rdx, 8
        mov     eax, dword [rdx]
        sub     eax, dword [rbp + LOCAL_PREV_L]
        mov     ecx, dword [rbp + LOCAL_CHANNEL]
        lea     r10, [rbp + SLEFT]
        mov     dword [r10 + rcx * 4], eax
        mov     eax, dword [rdx + 4]
        sub     eax, dword [rbp + LOCAL_PREV_R]
        lea     r10, [rbp + SRIGHT]
        mov     dword [r10 + rcx * 4], eax
        mov     rdx, qword [rbp + LOCAL_BUF_PTR]
        mov     eax, dword [rdx]
        mov     dword [rbp + LOCAL_PREV_L], eax
        mov     eax, dword [rdx + 4]
        mov     dword [rbp + LOCAL_PREV_R], eax
.loop_reposition:
        movsd   xmm0, qword [rbp + LOCAL_DOUBLE_POS]
        cvtsi2sd xmm1, dword [rbp + LOCAL_LOOP_END]
        comisd  xmm0, xmm1
        jb      .loop_position_ready
        mov     eax, dword [rbp + LOCAL_LOOP_END]
        sub     eax, dword [rbp + LOCAL_LOOP_START]
        cvtsi2sd xmm1, eax
        subsd   xmm0, xmm1
        movsd   qword [rbp + LOCAL_DOUBLE_POS], xmm0
        jmp     .loop_reposition
.loop_position_ready:
        cvttsd2si eax, xmm0
        mov     dword [rbp + LOCAL_POS_INT], eax
        cvtsi2sd xmm1, eax
        subsd   xmm0, xmm1
        mulsd   xmm0, [rel fp_scale]
        cvttsd2si eax, xmm0
        mov     dword [rbp + LOCAL_FRAC], eax
        jmp     .sample_loop
.one_shot_boundary:
        cmp     eax, dword [rbp + LOCAL_SAMPLE_LENGTH]
        jae     .voice_sample_end

.sample_inside:
        mov     rax, qword [rbp + LOCAL_SAMPLE_PTR]
        mov     edx, dword [rbp + LOCAL_POS_INT]
        movsx   eax, byte [rax + rdx]
        shl     eax, 8
        mov     dword [rbp + LOCAL_SAMPLE_VALUE], eax

        inc     edx
        cmp     dword [rbp + LOCAL_LOOP_FLAG], 0
        je      .next_sample_no_loop
        cmp     edx, dword [rbp + LOCAL_LOOP_END]
        jb      .next_sample_ready
        mov     edx, dword [rbp + LOCAL_LOOP_START]
        jmp     .next_sample_ready
.next_sample_no_loop:
        cmp     edx, dword [rbp + LOCAL_SAMPLE_LENGTH]
        jb      .next_sample_ready
        ; libxmp repeats the final source sample into its interpolation guard
        ; bytes, including for one-shots.  The packed MOD has no padding, so
        ; select the final real sample explicitly.
        mov     edx, dword [rbp + LOCAL_SAMPLE_LENGTH]
        dec     edx
        mov     rax, qword [rbp + LOCAL_SAMPLE_PTR]
        movsx   edx, byte [rax + rdx]
        shl     edx, 8
        mov     dword [rbp + LOCAL_NEXT_SAMPLE], edx
        jmp     .interpolation_ready
.next_sample_ready:
        mov     rax, qword [rbp + LOCAL_SAMPLE_PTR]
        movsx   edx, byte [rax + rdx]
        shl     edx, 8
        mov     dword [rbp + LOCAL_NEXT_SAMPLE], edx
.interpolation_ready:
        mov     edx, dword [rbp + LOCAL_NEXT_SAMPLE]
        sub     edx, dword [rbp + LOCAL_SAMPLE_VALUE]
        mov     ecx, dword [rbp + LOCAL_FRAC]
        shr     ecx, 1
        imul    ecx, edx
        sar     ecx, 15
        add     ecx, dword [rbp + LOCAL_SAMPLE_VALUE]
        mov     dword [rbp + LOCAL_SAMPLE_VALUE], ecx

        ; Apply the current ramp level, then accumulate the voice into the
        ; interleaved signed 32-bit stereo tick buffer.
        cmp     dword [rbp + LOCAL_RAMP_LEFT], 0
        je      .constant_level
        mov     ecx, dword [rbp + LOCAL_CHANNEL]
        lea     r10, [rbp + OLD_L]
        mov     eax, dword [r10 + rcx * 4]
        mov     edx, eax
        sar     edx, 8
        mov     dword [rbp + LOCAL_LEVEL_L], edx
        add     eax, dword [rbp + LOCAL_DELTA_L]
        mov     dword [r10 + rcx * 4], eax
        lea     r10, [rbp + OLD_R]
        mov     eax, dword [r10 + rcx * 4]
        mov     edx, eax
        sar     edx, 8
        mov     dword [rbp + LOCAL_LEVEL_R], edx
        add     eax, dword [rbp + LOCAL_DELTA_R]
        mov     dword [r10 + rcx * 4], eax
        dec     dword [rbp + LOCAL_RAMP_LEFT]
        jmp     .level_ready
.constant_level:
        mov     eax, dword [rbp + LOCAL_TARGET_L]
        sar     eax, 8
        mov     dword [rbp + LOCAL_LEVEL_L], eax
        mov     eax, dword [rbp + LOCAL_TARGET_R]
        sar     eax, 8
        mov     dword [rbp + LOCAL_LEVEL_R], eax
.level_ready:
        mov     eax, dword [rbp + LOCAL_SAMPLE_VALUE]
        imul    eax, dword [rbp + LOCAL_LEVEL_L]
        mov     dword [rbp + LOCAL_LAST_L], eax
        mov     rdx, qword [rbp + LOCAL_BUF_PTR]
        mov     ecx, dword [rdx]
        mov     dword [rbp + LOCAL_PREV_L], ecx
        mov     ecx, dword [rdx + 4]
        mov     dword [rbp + LOCAL_PREV_R], ecx
        add     dword [rdx], eax
        mov     eax, dword [rbp + LOCAL_SAMPLE_VALUE]
        imul    eax, dword [rbp + LOCAL_LEVEL_R]
        mov     dword [rbp + LOCAL_LAST_R], eax
        add     dword [rdx + 4], eax
        add     rdx, 8
        mov     qword [rbp + LOCAL_BUF_PTR], rdx

        movsd   xmm0, qword [rbp + LOCAL_DOUBLE_POS]
        addsd   xmm0, qword [r11 + STATE_SAMPLE_STEP]
        movsd   qword [rbp + LOCAL_DOUBLE_POS], xmm0

        mov     eax, dword [rbp + LOCAL_FRAC]
        add     eax, dword [rbp + LOCAL_STEP_FP]
        mov     edx, eax
        shr     edx, 16
        add     dword [rbp + LOCAL_POS_INT], edx
        and     eax, 0xffff
        mov     dword [rbp + LOCAL_FRAC], eax
        dec     dword [rbp + LOCAL_REMAIN]
        jmp     .sample_loop

.voice_sample_end:
        ; libxmp discharges the final voice contribution over the first
        ; tick/8 samples after a one-shot ends.
        lea     rdi, [rbp + MIX_BUFFER]
        cmp     qword [rbp + LOCAL_BUF_PTR], rdi
        je      .voice_sample_end_no_tail
        mov     rdx, qword [rbp + LOCAL_BUF_PTR]
        sub     rdx, 8
        mov     eax, dword [rdx]
        sub     eax, dword [rbp + LOCAL_PREV_L]
        mov     dword [rbp + LOCAL_LAST_L], eax
        mov     eax, dword [rdx + 4]
        sub     eax, dword [rbp + LOCAL_PREV_R]
        mov     dword [rbp + LOCAL_LAST_R], eax
.voice_sample_end_no_tail:
        mov     eax, dword [rbp + LOCAL_REMAIN]
        mov     ecx, dword [rbp + LOCAL_TICK_FRAMES]
        shr     ecx, 3
        cmp     eax, ecx
        jbe     .anticlick_count_ready
        mov     eax, ecx
.anticlick_count_ready:
        test    eax, eax
        jz      .anticlick_done
        mov     dword [rbp + LOCAL_AC_COUNT], eax
        mov     eax, 1 << 24
        xor     edx, edx
        div     dword [rbp + LOCAL_AC_COUNT]
        mov     dword [rbp + LOCAL_AC_STEP], eax
        imul    eax, dword [rbp + LOCAL_AC_COUNT]
        mov     dword [rbp + LOCAL_AC_MUL], eax
        mov     eax, dword [rbp + LOCAL_AC_STEP]
        mov     rdi, qword [rbp + LOCAL_BUF_PTR]
        mov     ecx, dword [rbp + LOCAL_AC_COUNT]
.anticlick_loop:
        sub     dword [rbp + LOCAL_AC_MUL], eax
        mov     edx, dword [rbp + LOCAL_AC_MUL]
        test    edx, edx
        jle     .anticlick_done
        shr     edx, 8
        imul    edx, edx
        mov     eax, edx
        movsxd  rdx, dword [rbp + LOCAL_LAST_L]
        imul    rdx, rax
        sar     rdx, 32
        add     dword [rdi], edx
        movsxd  rdx, dword [rbp + LOCAL_LAST_R]
        imul    rdx, rax
        sar     rdx, 32
        add     dword [rdi + 4], edx
        add     rdi, 8
        mov     eax, dword [rbp + LOCAL_AC_STEP]
        dec     ecx
        jnz     .anticlick_loop
.anticlick_done:
        mov     ecx, dword [rbp + LOCAL_CHANNEL]
        lea     r10, [rbp + OLD_L]
        mov     dword [r10 + rcx * 4], 0
        lea     r10, [rbp + OLD_R]
        mov     dword [r10 + rcx * 4], 0
        lea     r10, [rbp + SLEFT]
        mov     dword [r10 + rcx * 4], 0
        lea     r10, [rbp + SRIGHT]
        mov     dword [r10 + rcx * 4], 0
        jmp     .channel_next

.voice_finish_active:
        mov     ecx, dword [rbp + LOCAL_CHANNEL]
        lea     r10, [rbp + OLD_L]
        mov     eax, dword [rbp + LOCAL_TARGET_L]
        mov     dword [r10 + rcx * 4], eax
        lea     r10, [rbp + OLD_R]
        mov     eax, dword [rbp + LOCAL_TARGET_R]
        mov     dword [r10 + rcx * 4], eax
        lea     r10, [rbp + SLEFT]
        mov     rdx, qword [rbp + LOCAL_BUF_PTR]
        lea     rdi, [rbp + MIX_BUFFER]
        cmp     rdx, rdi
        je      .keep_active_tail
        sub     rdx, 8
        mov     eax, dword [rdx]
        sub     eax, dword [rbp + LOCAL_PREV_L]
        mov     dword [r10 + rcx * 4], eax
        lea     r10, [rbp + SRIGHT]
        mov     eax, dword [rdx + 4]
        sub     eax, dword [rbp + LOCAL_PREV_R]
        mov     dword [r10 + rcx * 4], eax
.keep_active_tail:
        jmp     .channel_next

.voice_silent:
        mov     ecx, dword [rbp + LOCAL_CHANNEL]
        lea     r10, [rbp + OLD_L]
        mov     dword [r10 + rcx * 4], 0
        lea     r10, [rbp + OLD_R]
        mov     dword [r10 + rcx * 4], 0
        lea     r10, [rbp + SLEFT]
        mov     dword [r10 + rcx * 4], 0
        lea     r10, [rbp + SRIGHT]
        mov     dword [r10 + rcx * 4], 0
.channel_next:
        inc     r9d
        jmp     .channel_loop

.render_tick:
        mov     eax, dword [rbp + LOCAL_TICK_FRAMES]
        lea     rdi, [rbp + MIX_BUFFER]
        lea     rdx, [r15 + rsi * 4]
        mov     ecx, eax
.downmix_loop:
        mov     eax, dword [rdi]
        sar     eax, DOWNMIX_SHIFT
        cmp     eax, 32767
        jle     .downmix_hi_ok
        mov     eax, 32767
.downmix_hi_ok:
        cmp     eax, -32768
        jge     .downmix_left_store
        mov     eax, -32768
.downmix_left_store:
        mov     word [rdx], ax
        mov     eax, dword [rdi + 4]
        sar     eax, DOWNMIX_SHIFT
        cmp     eax, 32767
        jle     .downmix_right_hi_ok
        mov     eax, 32767
.downmix_right_hi_ok:
        cmp     eax, -32768
        jge     .downmix_right_store
        mov     eax, -32768
.downmix_right_store:
        mov     word [rdx + 2], ax
        add     rdi, 8
        add     rdx, 4
        inc     rsi
        dec     ecx
        jnz     .downmix_loop

        inc     dword [rbp + LOCAL_FRAME_INDEX]
        jmp     .frame_loop

.done:
        mov     eax, esi
        jmp     .return
.bad:
        xor     eax, eax
.return:
        add     rsp, STACK_BYTES
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
fp_scale: dq 65536.0
