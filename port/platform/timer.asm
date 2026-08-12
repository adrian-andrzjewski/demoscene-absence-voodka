; timer.asm - native x64 VGA-retrace/QPC timing service.
;
; The original EOS wait_vbl is a deterministic ~70 Hz boundary. This keeps
; the C++ timing contract byte-for-byte at the public ABI while moving QPC
; state, pause parking, sleep/spin pacing, frame counting, and progress hook
; dispatch into assembly. The reference target retains timer.cpp as oracle.

BITS 64
DEFAULT REL

extern QueryPerformanceFrequency
extern QueryPerformanceCounter
extern Sleep
extern ?updateInput@vk@@YAXXZ
extern ?isPaused@vk@@YA_NXZ
extern ?quitRequested@vk@@YA_NXZ
extern ?shutdownAndExit@vk@@YAXXZ
extern ?progressUpdate@vk@@YAXXZ

global ?timerInit@vk@@YAXXZ
global ?getQpcUs@vk@@YA_KXZ
global ?getFrameCounter@vk@@YA_KXZ
global ?waitVbl@vk@@YAXXZ

section .data
timer_qpc_frequency:       dq 0
timer_start_count:         dq 0
timer_next_tick:           dq 0
timer_period_counts:       dq 0
timer_sleep_threshold:     dq 0
timer_frame_counter:       dq 0
timer_one_million:         dq 1000000.0
timer_one_thousand:        dq 1000.0
timer_hertz:               dq 70.0
timer_twelve_hundred_us:   dq 1200.0

section .text

; void vk::timerInit(void)
?timerInit@vk@@YAXXZ:
        sub     rsp, 0x28                    ; RSP%16 == 0 at CALL
        lea     rcx, [rel timer_qpc_frequency]
        call    QueryPerformanceFrequency
        lea     rcx, [rel timer_start_count]
        call    QueryPerformanceCounter

        cvtsi2sd xmm0, qword [rel timer_qpc_frequency]
        divsd   xmm0, [rel timer_hertz]
        cvttsd2si rax, xmm0
        mov     [rel timer_period_counts], rax

        cvtsi2sd xmm0, qword [rel timer_qpc_frequency]
        mulsd   xmm0, [rel timer_twelve_hundred_us]
        divsd   xmm0, [rel timer_one_million]
        cvttsd2si rax, xmm0
        mov     [rel timer_sleep_threshold], rax

        lea     rcx, [rel timer_next_tick]
        call    QueryPerformanceCounter
        add     rsp, 0x28
        ret

; uint64_t vk::getQpcUs(void)
?getQpcUs@vk@@YA_KXZ:
        sub     rsp, 0x28
        lea     rcx, [rsp + 0x20]
        call    QueryPerformanceCounter
        mov     rax, [rsp + 0x20]
        sub     rax, [rel timer_start_count]
        cvtsi2sd xmm0, rax
        mulsd   xmm0, [rel timer_one_million]
        divsd   xmm0, qword [rel timer_qpc_frequency]
        cvttsd2si rax, xmm0
        add     rsp, 0x28
        ret

; uint64_t vk::getFrameCounter(void)
?getFrameCounter@vk@@YA_KXZ:
        mov     rax, [rel timer_frame_counter]
        ret

; Call the process-wide cancellation path at every timing choke point.
timer_maybe_shutdown:
        call    ?quitRequested@vk@@YA_NXZ
        test    al, al                         ; MSVC bool result is AL
        jz      .timer_maybe_done
        call    ?shutdownAndExit@vk@@YAXXZ
.timer_maybe_done:
        ret

; void vk::waitVbl(void)
?waitVbl@vk@@YAXXZ:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0x80                    ; RSP%16 == 0 at CALL

        call    ?updateInput@vk@@YAXXZ
        call    timer_maybe_shutdown
        call    ?isPaused@vk@@YA_NXZ
        test    al, al                         ; MSVC bool result is AL
        jz      .wait_pace

.wait_paused:
        call    ?updateInput@vk@@YAXXZ
        call    ?quitRequested@vk@@YA_NXZ
        test    al, al
        jnz     .wait_pause_exit
        call    ?isPaused@vk@@YA_NXZ
        test    al, al
        jz      .wait_pause_resumed
        mov     ecx, 5
        call    Sleep
        jmp     .wait_paused

.wait_pause_exit:
        call    timer_maybe_shutdown
        jmp     .wait_pace

.wait_pause_resumed:
        call    timer_maybe_shutdown
        lea     rcx, [rel timer_next_tick]
        call    QueryPerformanceCounter

.wait_pace:
        call    timer_maybe_shutdown
        lea     rcx, [rsp + 0x20]
        call    QueryPerformanceCounter
        mov     rax, [rel timer_next_tick]
        add     rax, [rel timer_period_counts]
        mov     r13, rax                       ; next deadline
        mov     r12, rax
        sub     r12, [rsp + 0x20]              ; signed delta
        jle     .wait_tick_ready
        cmp     r12, [rel timer_sleep_threshold]
        jle     .wait_spin

        cvtsi2sd xmm0, r12
        mulsd   xmm0, [rel timer_one_thousand]
        divsd   xmm0, qword [rel timer_qpc_frequency]
        cvttsd2si rax, xmm0
        cmp     rax, 1
        jle     .wait_pace
        dec     eax
        mov     ecx, eax
        call    Sleep
        jmp     .wait_pace

.wait_spin:
        lea     rcx, [rsp + 0x20]
        call    QueryPerformanceCounter
        mov     rax, [rsp + 0x20]
        cmp     rax, r13
        jae     .wait_tick_ready
        call    timer_maybe_shutdown
        jmp     .wait_spin

.wait_tick_ready:
        mov     [rel timer_next_tick], r13
        inc     qword [rel timer_frame_counter]
        call    ?progressUpdate@vk@@YAXXZ

        add     rsp, 0x80
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbp
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
