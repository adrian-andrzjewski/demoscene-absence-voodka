; audio_tracker.asm - Phase 2C offline tracker/timing state machine.
;
; This is deliberately not production audio yet.  It reproduces the checked-in
; FastTracker module's order/row/tick timeline without calling Windows, C, or
; libxmp.  The module uses five ticks per row and only Fxx changes the clock:
; values below 20h set speed, values 20h and above set BPM.

BITS 64
DEFAULT REL

%define MOD_ORDER_TABLE                  952
%define MOD_HEADER_BYTES                 1084
%define MOD_ROWS                         64
%define MOD_CHANNELS                     14
%define MOD_EVENT_BYTES                  4
%define MOD_PATTERN_BYTES               (MOD_ROWS * MOD_CHANNELS * MOD_EVENT_BYTES)
%define MOD_ROW_BYTES                    (MOD_CHANNELS * MOD_EVENT_BYTES)

; audio_tracker_abi.h, packed TraceEntry layout.
%define TRACE_FRAME                       0
%define TRACE_TIME_MS                     4
%define TRACE_POS                         8
%define TRACE_PATTERN                    12
%define TRACE_ROW                        16
%define TRACE_ROWS                       20
%define TRACE_SPEED                      24
%define TRACE_BPM                        28
%define TRACE_FRAME_TIME_US              32
%define TRACE_BYTES                      36

global asm_audio_trace_rows
section .text

; uint32_t asm_audio_trace_rows(const uint8_t* data,
;                               uint32_t size,
;                               AudioTraceEntry* out,
;                               uint32_t capacity)
asm_audio_trace_rows:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 32

        mov     r12, rcx                    ; module bytes
        mov     r14d, edx                   ; module size
        mov     r13, r8                     ; output entries
        test    r12, r12
        jz      .bad
        test    r13, r13
        jz      .bad
        cmp     r14d, MOD_HEADER_BYTES
        jb      .bad

        movzx   eax, byte [r12 + 950]        ; order count
        test    eax, eax
        jz      .bad
        cmp     eax, 128
        ja      .bad
        mov     [rbp - 72], eax             ; preserve order count
        imul    eax, MOD_ROWS
        cmp     r9d, eax                    ; caller supplied capacity
        jb      .bad

        ; Validate the highest referenced pattern before walking rows.  The
        ; parser gate performs the same bound check; keeping this entry point
        ; independent makes the state-machine ABI useful by itself.
        xor     esi, esi
        xor     r8d, r8d                    ; highest pattern index
        mov     ecx, [rbp - 72]
.find_pattern:
        movzx   eax, byte [r12 + MOD_ORDER_TABLE + rsi]
        cmp     eax, r8d
        jbe     .find_next
        mov     r8d, eax
.find_next:
        inc     esi
        dec     ecx
        jnz     .find_pattern
        inc     r8d                         ; pattern count
        cmp     r8d, 64
        ja      .bad
        mov     eax, r8d
        imul    eax, MOD_PATTERN_BYTES
        add     eax, MOD_HEADER_BYTES
        cmp     r14d, eax
        jb      .bad

        ; State: order=rbx, row=r11d, output=rdi, entry count=esi,
        ; replay frame counter=r14d, scan frame counter=r15d,
        ; playback clock=xmm5, scan time=xmm4, speed=r10d, bpm=r9d.
        xor     ebx, ebx
        xor     r11d, r11d
        xor     esi, esi
        xor     edi, edi
        mov     rdi, r13
        xor     r14d, r14d
        xor     r15d, r15d
        xorpd   xmm4, xmm4
        xorpd   xmm5, xmm5
        mov     r10d, 6                     ; MOD default before row 0
        mov     r9d, 125

.order_loop:
        ; libxmp's scanner stores an integer timestamp for each order.  The
        ; live player resets current_time to that timestamp on order changes,
        ; so retain the scanner's fractional time and pending frame count
        ; separately from the per-tick playback clock.
        mov     eax, r15d
        cvtsi2sd xmm0, eax
        mov     eax, 2500
        cvtsi2sd xmm1, eax
        mulsd   xmm0, xmm1
        cvtsi2sd xmm1, r9d
        divsd   xmm0, xmm1
        addsd   xmm0, xmm4
        cvttsd2si eax, xmm0
        cvtsi2sd xmm5, eax
        mov     dword [rbp - 80], 0          ; scanner row count
        xor     r11d, r11d

.row_loop:
        ; Apply row-level Fxx commands in channel order.  The last command
        ; on a row wins, matching libxmp's event traversal for this module.
        movzx   eax, byte [r12 + MOD_ORDER_TABLE + rbx]
        imul    eax, MOD_PATTERN_BYTES
        add     eax, MOD_HEADER_BYTES
        mov     ecx, r11d
        imul    ecx, MOD_ROW_BYTES
        add     eax, ecx
        lea     r8, [r12 + rax]
        mov     ecx, MOD_CHANNELS
.event_loop:
        movzx   eax, byte [r8 + 2]
        and     eax, 0x0f
        cmp     eax, 0x0f
        jne     .event_next
        movzx   edx, byte [r8 + 3]
        test    edx, edx
        jz      .event_next

        ; The scanner accounts for rows since the previous timing command
        ; before applying the command.  Its row loop increments row_count at
        ; the end of the row, so the command's own row is included under the
        ; newly selected speed/BPM.
        mov     eax, [rbp - 80]
        imul    eax, r10d
        add     r15d, eax
        mov     dword [rbp - 80], 0
        cmp     edx, 0x20
        jae     .scan_set_bpm
        mov     r10d, edx
        jmp     .event_next
.scan_set_bpm:
        mov     eax, 2500
        cvtsi2sd xmm1, eax
        cvtsi2sd xmm0, r15d
        mulsd   xmm0, xmm1
        cvtsi2sd xmm1, r9d
        divsd   xmm0, xmm1
        addsd   xmm4, xmm0
        xor     r15d, r15d
        mov     r9d, edx
.event_next:
        add     r8, MOD_EVENT_BYTES
        dec     ecx
        jnz     .event_loop

        ; Advance one tick before publishing the row.  xmp_play_frame first
        ; reads the row, then adds frame_time to current_time, so row 0 is
        ; reported at one tick rather than at time zero.  Keep the clock as an
        ; IEEE-754 double and add once per tick, matching libxmp's player.c.
        mov     eax, 2500
        cvtsi2sd xmm0, eax
        cvtsi2sd xmm1, r9d
        divsd   xmm0, xmm1                  ; tick duration in milliseconds
        addsd   xmm5, xmm0

        mov     [rdi + TRACE_FRAME], r14d
        cvttsd2si eax, xmm5                 ; xmp_frame_info.time truncates
        mov     [rdi + TRACE_TIME_MS], eax
        mov     [rdi + TRACE_POS], ebx
        movzx   eax, byte [r12 + MOD_ORDER_TABLE + rbx]
        mov     [rdi + TRACE_PATTERN], eax
        mov     [rdi + TRACE_ROW], r11d
        mov     dword [rdi + TRACE_ROWS], MOD_ROWS
        mov     [rdi + TRACE_SPEED], r10d
        mov     [rdi + TRACE_BPM], r9d
        mov     eax, 1000
        cvtsi2sd xmm1, eax
        mulsd   xmm1, xmm0
        cvttsd2si eax, xmm1                  ; p->frame_time * 1000
        mov     [rdi + TRACE_FRAME_TIME_US], eax

        inc     esi
        add     rdi, TRACE_BYTES

        inc     dword [rbp - 80]             ; scanner row_count++

        ; Finish the remaining ticks in this row.  The next row's first tick
        ; is added at the top of its iteration, after its Fxx commands.
        mov     eax, r10d
        dec     eax
        jz      .row_complete
        mov     ecx, eax
.remaining_ticks:
        addsd   xmm5, xmm0
        dec     ecx
        jnz     .remaining_ticks
        add     r14d, r10d
.row_complete:
        inc     r11d
        cmp     r11d, MOD_ROWS
        jb      .row_loop
        mov     eax, [rbp - 80]
        imul    eax, r10d
        add     r15d, eax                    ; pending rows at order end
        mov     dword [rbp - 80], 0
        xor     r11d, r11d
        inc     rbx
        cmp     ebx, [rbp - 72]
        jb      .order_loop

        mov     eax, esi
        add     rsp, 32
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

.bad:
        xor     eax, eax
        add     rsp, 32
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret
