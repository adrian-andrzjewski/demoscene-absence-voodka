; audio_service.asm - native assembly producer for the live tracker/audio ring.
;
; This is the first production-shim extraction gate.  The host still prepares
; module/timeline storage and owns the Win32 thread handle, but the thread's
; tracker advancement, chunk validation, continuous mixing, ring backpressure,
; seek transaction, and marker publication are all native x64 assembly.
; Producer error codes 1..6 identify tracker/state failures; a mix failure
; stores (returnedFrames << 16) | expectedFrames for ABI diagnostics.

BITS 64
DEFAULT REL

%define PROD_MODULE                 0
%define PROD_MODULE_SIZE            8
%define PROD_STATE_FRAMES          12
%define PROD_MAX_TICK_FRAMES       16
%define PROD_SCRATCH_FRAMES        20
%define PROD_TICK_STARTS           24
%define PROD_MODPOS_BY_TICK        32
%define PROD_RING                  40
%define PROD_CONTROL               48
%define PROD_STATES                56
%define PROD_PCM                   64
%define PROD_HISTORY               72
%define PROD_STOP                  80
%define PROD_FAILED                88
%define PROD_DONE                  96
%define PROD_ERROR                104

%define CONTROL_REQUESTED_SEEK_TICK 16
%define CONTROL_SEEK_SEQUENCE       20
%define CONTROL_PRODUCER_SEEK_ACK   24
%define CONTROL_SEEK_COMMIT_SEQUENCE 28
%define CONTROL_SEEK_RING_BASE      32

%define TICK_STATE_STRIDE           41
%define CHANNEL_COUNT               14
%define TICK_STATE_BYTES            (TICK_STATE_STRIDE * CHANNEL_COUNT)
%define TICK_FRAMES_OFFSET          36
%define TICK_CHUNK                  31
%define HISTORY_QWORDS               28

; Local storage.  The tracker is 1184 bytes and starts above the outgoing
; Win64 home/argument area, which is used by the seven-argument mixer call.
%define LOCAL_TRACKER               0x50
%define LOCAL_STATE_FRAME           0x4F0
%define LOCAL_LAST_SEEK             0x4F4
%define LOCAL_SEGMENT_BASE          0x4F8
%define LOCAL_SEGMENT_RING_BASE     0x4FC
%define LOCAL_SEEK_SEGMENT          0x500
%define LOCAL_CHUNK_STATES          0x504
%define LOCAL_CHUNK_FRAMES          0x508
%define LOCAL_MIXED_FRAMES          0x50C
%define LOCAL_PUSHED_FRAMES         0x510
%define LOCAL_TARGET_TICK           0x514
%define LOCAL_SEEK_CHANGED          0x518
%define LOCAL_BYTES                 0x528

extern Sleep
extern asm_audio_live_init
extern asm_audio_live_next
extern asm_audio_mix_tick_states_continuous
extern asm_audio_ring_push
extern asm_audio_ring_push_marker

global asm_audio_producer_thread

section .text

; DWORD WINAPI asm_audio_producer_thread(AudioAssemblyProducerArgs* args)
asm_audio_producer_thread:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, LOCAL_BYTES

        mov     r12, rcx                    ; producer args
        lea     r13, [rsp + LOCAL_TRACKER]
        mov     dword [rsp + LOCAL_STATE_FRAME], 0
        mov     dword [rsp + LOCAL_LAST_SEEK], 0
        mov     dword [rsp + LOCAL_SEGMENT_BASE], 0
        mov     dword [rsp + LOCAL_SEGMENT_RING_BASE], 0
        mov     dword [rsp + LOCAL_SEEK_SEGMENT], 0

        mov     rcx, [r12 + PROD_MODULE]
        mov     edx, dword [r12 + PROD_MODULE_SIZE]
        mov     r8, r13
        call    asm_audio_live_init
        test    eax, eax
        jnz     .fail_initial_init

.loop:
        call    .stopped
        test    eax, eax
        jnz     .finish

        ; A seek is a producer quiescence transaction.  Acknowledge the
        ; requested sequence, wait for the controller to flush the ring, then
        ; rebuild tracker/mixer state at the requested tick.
        mov     r14, [r12 + PROD_CONTROL]
        mov     edx, dword [r14 + CONTROL_SEEK_SEQUENCE]
        cmp     edx, dword [rsp + LOCAL_LAST_SEEK]
        je      .seek_done
        mov     r15d, edx
        mov     r10d, edx
        xchg    r10d, dword [r14 + CONTROL_PRODUCER_SEEK_ACK]

.seek_commit_wait:
        cmp     r10d, dword [r14 + CONTROL_SEEK_COMMIT_SEQUENCE]
        je      .seek_committed
        call    .stopped
        test    eax, eax
        jnz     .finish
        mov     ecx, 1
        call    Sleep
        jmp     .seek_commit_wait

.seek_committed:
        mov     eax, dword [r14 + CONTROL_REQUESTED_SEEK_TICK]
        mov     edx, dword [r12 + PROD_STATE_FRAMES]
        dec     edx
        cmp     eax, edx
        jbe     .seek_target_ready
        mov     eax, edx
.seek_target_ready:
        mov     dword [rsp + LOCAL_TARGET_TICK], eax

        mov     rcx, [r12 + PROD_MODULE]
        mov     edx, dword [r12 + PROD_MODULE_SIZE]
        mov     r8, r13
        call    asm_audio_live_init
        test    eax, eax
        jnz     .fail_seek_init

        xor     ebx, ebx
.discard_seek_ticks:
        cmp     ebx, dword [rsp + LOCAL_TARGET_TICK]
        jae     .discard_done
        mov     rcx, r13
        mov     rdx, [r12 + PROD_STATES]
        call    asm_audio_live_next
        cmp     eax, 1
        jne     .fail_seek_next
        inc     ebx
        jmp     .discard_seek_ticks

.discard_done:
        mov     rdi, [r12 + PROD_HISTORY]
        xor     eax, eax
        mov     ecx, HISTORY_QWORDS
        rep     stosq
        mov     eax, dword [rsp + LOCAL_TARGET_TICK]
        mov     dword [rsp + LOCAL_STATE_FRAME], eax
        mov     dword [rsp + LOCAL_SEGMENT_BASE], eax
        mov     eax, dword [r14 + CONTROL_SEEK_RING_BASE]
        mov     dword [rsp + LOCAL_SEGMENT_RING_BASE], eax
        mov     dword [rsp + LOCAL_SEEK_SEGMENT], 1
        mov     dword [rsp + LOCAL_LAST_SEEK], r15d

.seek_done:
        mov     eax, dword [rsp + LOCAL_STATE_FRAME]
        cmp     eax, dword [r12 + PROD_STATE_FRAMES]
        jb      .make_chunk

        mov     rax, [r12 + PROD_DONE]
        mov     dword [rax], 1
.wait_end_stop:
        call    .stopped
        test    eax, eax
        jnz     .finish
        mov     ecx, 10
        call    Sleep
        jmp     .wait_end_stop

.make_chunk:
        mov     eax, dword [r12 + PROD_STATE_FRAMES]
        sub     eax, dword [rsp + LOCAL_STATE_FRAME]
        cmp     eax, TICK_CHUNK
        jbe     .chunk_count_ready
        mov     eax, TICK_CHUNK
.chunk_count_ready:
        mov     dword [rsp + LOCAL_CHUNK_STATES], eax
        mov     dword [rsp + LOCAL_CHUNK_FRAMES], 0
        mov     dword [rsp + LOCAL_SEEK_CHANGED], 0
        xor     edi, edi

.state_loop:
        cmp     edi, dword [rsp + LOCAL_CHUNK_STATES]
        jae     .state_done
        call    .stopped
        test    eax, eax
        jnz     .finish
        mov     r14, [r12 + PROD_CONTROL]
        mov     eax, dword [r14 + CONTROL_SEEK_SEQUENCE]
        cmp     eax, dword [rsp + LOCAL_LAST_SEEK]
        je      .state_no_seek
        mov     dword [rsp + LOCAL_SEEK_CHANGED], 1
        jmp     .state_done

.state_no_seek:
        mov     eax, edi
        imul    eax, TICK_STATE_BYTES
        mov     rsi, [r12 + PROD_STATES]
        lea     rsi, [rsi + rax]
        mov     rcx, r13
        mov     rdx, rsi
        call    asm_audio_live_next
        cmp     eax, 1
        jne     .fail_live_next
        mov     ebx, dword [rsi + TICK_FRAMES_OFFSET]
        test    ebx, ebx
        jz      .fail_zero_tick_frames
        mov     edx, 1
        lea     rsi, [rsi + TICK_STATE_STRIDE]
.channel_check:
        cmp     edx, CHANNEL_COUNT
        jae     .channel_check_done
        cmp     ebx, dword [rsi + TICK_FRAMES_OFFSET]
        jne     .fail_channel_tick_frames
        add     rsi, TICK_STATE_STRIDE
        inc     edx
        jmp     .channel_check
.channel_check_done:
        add     dword [rsp + LOCAL_CHUNK_FRAMES], ebx
        inc     edi
        jmp     .state_loop

.state_done:
        cmp     dword [rsp + LOCAL_SEEK_CHANGED], 0
        jne     .loop
        call    .stopped
        test    eax, eax
        jnz     .finish

        ; Mix the validated state chunk into the caller-owned PCM scratch.
        mov     rcx, [r12 + PROD_MODULE]
        mov     edx, dword [r12 + PROD_MODULE_SIZE]
        mov     r8, [r12 + PROD_STATES]
        mov     r9d, dword [rsp + LOCAL_CHUNK_STATES]
        mov     rax, [r12 + PROD_PCM]
        mov     [rsp + 0x20], rax
        mov     eax, dword [r12 + PROD_SCRATCH_FRAMES]
        mov     [rsp + 0x28], rax
        mov     rax, [r12 + PROD_HISTORY]
        mov     [rsp + 0x30], rax
        call    asm_audio_mix_tick_states_continuous
        mov     dword [rsp + LOCAL_MIXED_FRAMES], eax
        cmp     eax, dword [rsp + LOCAL_CHUNK_FRAMES]
        jne     .fail_mix_frames

        xor     eax, eax
        mov     dword [rsp + LOCAL_PUSHED_FRAMES], eax
.pcm_push_loop:
        cmp     eax, dword [rsp + LOCAL_MIXED_FRAMES]
        jae     .pcm_push_done
        call    .stopped
        test    eax, eax
        jnz     .finish
        mov     r14, [r12 + PROD_CONTROL]
        mov     edx, dword [r14 + CONTROL_SEEK_SEQUENCE]
        cmp     edx, dword [rsp + LOCAL_LAST_SEEK]
        je      .pcm_push_no_seek
        mov     dword [rsp + LOCAL_SEEK_CHANGED], 1
        jmp     .loop
.pcm_push_no_seek:
        mov     rcx, [r12 + PROD_RING]
        mov     rdx, [r12 + PROD_PCM]
        mov eax, dword [rsp + LOCAL_PUSHED_FRAMES]
        shl     rax, 2
        add     rdx, rax
        mov     eax, dword [rsp + LOCAL_MIXED_FRAMES]
        sub     eax, dword [rsp + LOCAL_PUSHED_FRAMES]
        mov     r8d, eax
        call    asm_audio_ring_push
        test    eax, eax
        jz      .pcm_push_wait
        add     dword [rsp + LOCAL_PUSHED_FRAMES], eax
        mov     eax, dword [rsp + LOCAL_PUSHED_FRAMES]
        jmp     .pcm_push_loop
.pcm_push_wait:
        mov     ecx, 1
        call    Sleep
        mov     eax, dword [rsp + LOCAL_PUSHED_FRAMES]
        jmp     .pcm_push_loop

.pcm_push_done:
        xor     edi, edi
.marker_loop:
        cmp     edi, dword [rsp + LOCAL_CHUNK_STATES]
        jae     .marker_done
        mov     r14, [r12 + PROD_CONTROL]
        mov     eax, dword [r14 + CONTROL_SEEK_SEQUENCE]
        cmp     eax, dword [rsp + LOCAL_LAST_SEEK]
        je      .marker_no_seek
        mov     dword [rsp + LOCAL_SEEK_CHANGED], 1
        jmp     .loop
.marker_no_seek:
        mov     rsi, [r12 + PROD_TICK_STARTS]
        mov     eax, dword [rsp + LOCAL_STATE_FRAME]
        add     eax, edi
        mov     r10d, dword [rsi + rax * 4]
        cmp     dword [rsp + LOCAL_SEEK_SEGMENT], 0
        je      .marker_frame_ready
        mov     eax, dword [rsp + LOCAL_SEGMENT_BASE]
        mov     edx, dword [rsi + rax * 4]
        sub     r10d, edx
        add     r10d, dword [rsp + LOCAL_SEGMENT_RING_BASE]
.marker_frame_ready:
        mov     rsi, [r12 + PROD_MODPOS_BY_TICK]
        mov     eax, dword [rsp + LOCAL_STATE_FRAME]
        add     eax, edi
        mov     r11d, dword [rsi + rax * 4]
        mov     rcx, [r12 + PROD_RING]
        mov     edx, r10d
        mov     r8d, r11d
        call    asm_audio_ring_push_marker
        cmp     eax, 1
        je      .marker_pushed
        call    .stopped
        test    eax, eax
        jnz     .finish
        mov     ecx, 1
        call    Sleep
        jmp     .marker_frame_ready
.marker_pushed:
        inc     edi
        jmp     .marker_loop

.marker_done:
        mov     eax, dword [rsp + LOCAL_CHUNK_STATES]
        add     dword [rsp + LOCAL_STATE_FRAME], eax
        jmp     .loop

.fail_initial_init:
        mov     edx, 1
        jmp     .fail_with_code
.fail_seek_init:
        mov     edx, 2
        jmp     .fail_with_code
.fail_seek_next:
        mov     edx, 3
        jmp     .fail_with_code
.fail_live_next:
        mov     edx, 4
        jmp     .fail_with_code
.fail_zero_tick_frames:
        mov     edx, 5
        jmp     .fail_with_code
.fail_channel_tick_frames:
        mov     edx, 6
        jmp     .fail_with_code
.fail_mix_frames:
        mov     edx, eax
        shl     edx, 16
        or      edx, dword [rsp + LOCAL_CHUNK_FRAMES]
.fail_with_code:
        mov     rax, [r12 + PROD_ERROR]
        mov     dword [rax], edx
        mov     rax, [r12 + PROD_FAILED]
        mov     dword [rax], 1
.finish:
        mov     rax, [r12 + PROD_FAILED]
        mov     eax, dword [rax]
        add     rsp, LOCAL_BYTES
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; eax = nonzero while the controller requested producer stop.
.stopped:
        mov     rax, [r12 + PROD_STOP]
        mov     eax, dword [rax]
        ret
