; audio_lifecycle.asm - assembly ownership of the dedicated-player lifecycle.
;
; The tracker, mixer, storage, ring, producer, WASAPI worker, controller, and
; seek transaction already have fixed assembly ABIs. This file is the final
; orchestration boundary for that service: it builds the runtime records,
; performs startup/rollback, publishes play state, and owns idempotent stop.
; The reference target still retains its libxmp implementation as the oracle.

BITS 64
DEFAULT REL

%define RUNTIME_STORAGE             0
%define RUNTIME_PRODUCER_ARGS     112
%define RUNTIME_RING              224
%define RUNTIME_CONTROL           288
%define RUNTIME_WORKER_ARGS       328
%define RUNTIME_WORKER_SERVICE    352
%define RUNTIME_REPORT            376
%define RUNTIME_PRODUCER_HANDLE   528
%define RUNTIME_WORKER_HANDLE     536
%define RUNTIME_PRODUCER_STOP     544
%define RUNTIME_PRODUCER_FAILED   548
%define RUNTIME_WORKER_RESULT     552
%define RUNTIME_PRODUCER_DONE     556
%define RUNTIME_PRODUCER_ERROR    560
%define RUNTIME_INITIALIZED       564
%define RUNTIME_SHUTTING_DOWN     568
%define RUNTIME_PLAYING           572

%define STORAGE_MODULE             0
%define STORAGE_MODULE_SIZE        8
%define STORAGE_STATE_FRAMES      12
%define STORAGE_MAX_TICK_FRAMES   20
%define STORAGE_ORDER_COUNT       24
%define STORAGE_SCRATCH_FRAMES    32
%define STORAGE_TICK_STARTS       40
%define STORAGE_MODPOS_BY_TICK    48
%define STORAGE_STATES            64
%define STORAGE_RING_SAMPLES      72
%define STORAGE_RING_MARKERS      80
%define STORAGE_PRODUCER_STATES   88
%define STORAGE_PRODUCER_PCM      96
%define STORAGE_PRODUCER_HISTORY 104

%define PROD_MODULE                0
%define PROD_MODULE_SIZE           8
%define PROD_STATE_FRAMES         12
%define PROD_MAX_TICK_FRAMES      16
%define PROD_SCRATCH_FRAMES       20
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

%define WORKER_ARGS                0
%define WORKER_REPORT              8
%define WORKER_RESULT             16

%define LIFECYCLE_PRODUCER_HANDLE  0
%define LIFECYCLE_PRODUCER_ENTRY   8
%define LIFECYCLE_PRODUCER_ARGS   16
%define LIFECYCLE_RING            24
%define LIFECYCLE_PRODUCER_FAILED 32
%define LIFECYCLE_WORKER_HANDLE   40
%define LIFECYCLE_WORKER_ENTRY    48
%define LIFECYCLE_WORKER_ARGS     56
%define LIFECYCLE_CONTROL         64
%define LIFECYCLE_PRODUCER_STOP   72

%define REPORT_DEVICE_FRAMES      88
%define REPORT_SNAPSHOT_UPDATES  112
%define REPORT_UNDERRUN_EVENTS    120

%define RING_SAMPLES               0

%define RUNTIME_BYTES            600

extern GetEnvironmentVariableA
extern asm_audio_runtime_state
extern asm_audio_service_storage_init
extern asm_audio_ring_init
extern asm_audio_ring_close
extern asm_audio_start_workers
extern asm_audio_stop_workers
extern asm_audio_producer_thread
extern asm_audio_ring_thread_entry
extern ?logPrint@vk@@YAXPEBDZZ

global ?audioAsmInit@vk@@YAHPEBDH@Z
global ?audioAsmShutdown@vk@@YAXXZ
global ?audioAsmPlay@vk@@YAHXZ
global ?audioAsmStop@vk@@YAHXZ

section .data
audio_fail_environment:
        db "VOODKA_ASM_AUDIO_FAIL_DEVICE", 0
audio_forced_failure_message:
        db "[audio-asm] forced device failure injection", 10, 0
audio_storage_failure_format:
        db "[audio-asm] native module/storage preparation failed "
        db "status=%u", 10, 0
audio_ring_failure_message:
        db "[audio-asm] ring initialization failed", 10, 0
audio_prebuffer_failure_format:
        db "[audio-asm] producer prebuffer failed failed=%ld done=%ld "
        db "error=%ld write=%u read=%u", 10, 0
audio_worker_creation_failure_message:
        db "[audio-asm] worker controller creation failed", 10, 0
audio_worker_exit_failure_message:
        db "[audio-asm] assembly WASAPI worker exited during startup", 10, 0
audio_active_format:
        db "[audio-asm] dedicated player active, orders=%u, 44100Hz stereo", 10, 0
audio_stopped_format:
        db "[audio-asm] stopped: device_frames=%u underruns=%u markers=%u", 10, 0

section .text

; Clear the assembly-owned runtime. The ring close is deliberately idempotent;
; this preserves the former C++ rollback behavior after a partial init.
audio_clear_runtime:
        lea     rax, [rel asm_audio_runtime_state]
        cmp     qword [rax + RUNTIME_RING + RING_SAMPLES], 0
        je      .clear_zero
        lea     rcx, [rax + RUNTIME_RING]
        call    asm_audio_ring_close
.clear_zero:
        lea     rdi, [rel asm_audio_runtime_state]
        xor     eax, eax
        mov     ecx, RUNTIME_BYTES / 8
        rep     stosq
        ret

; Fill the producer, worker, and lifecycle records from the fixed runtime
; block. The returned pointer is the lifecycle record on this stack frame.
audio_prepare_records:
        ; producerArgs
        lea     rax, [r12 + RUNTIME_STORAGE]
        mov     rdx, [rax + STORAGE_MODULE]
        mov     [r12 + RUNTIME_PRODUCER_ARGS + PROD_MODULE], rdx
        mov     edx, [rax + STORAGE_MODULE_SIZE]
        mov     [r12 + RUNTIME_PRODUCER_ARGS + PROD_MODULE_SIZE], edx
        mov     edx, [rax + STORAGE_STATE_FRAMES]
        mov     [r12 + RUNTIME_PRODUCER_ARGS + PROD_STATE_FRAMES], edx
        mov     edx, [rax + STORAGE_MAX_TICK_FRAMES]
        mov     [r12 + RUNTIME_PRODUCER_ARGS + PROD_MAX_TICK_FRAMES], edx
        mov     edx, [rax + STORAGE_SCRATCH_FRAMES]
        mov     [r12 + RUNTIME_PRODUCER_ARGS + PROD_SCRATCH_FRAMES], edx
        mov     rdx, [rax + STORAGE_TICK_STARTS]
        mov     [r12 + RUNTIME_PRODUCER_ARGS + PROD_TICK_STARTS], rdx
        mov     rdx, [rax + STORAGE_MODPOS_BY_TICK]
        mov     [r12 + RUNTIME_PRODUCER_ARGS + PROD_MODPOS_BY_TICK], rdx
        lea     rdx, [r12 + RUNTIME_RING]
        mov     [r12 + RUNTIME_PRODUCER_ARGS + PROD_RING], rdx
        lea     rdx, [r12 + RUNTIME_CONTROL]
        mov     [r12 + RUNTIME_PRODUCER_ARGS + PROD_CONTROL], rdx
        mov     rdx, [rax + STORAGE_PRODUCER_STATES]
        mov     [r12 + RUNTIME_PRODUCER_ARGS + PROD_STATES], rdx
        mov     rdx, [rax + STORAGE_PRODUCER_PCM]
        mov     [r12 + RUNTIME_PRODUCER_ARGS + PROD_PCM], rdx
        mov     rdx, [rax + STORAGE_PRODUCER_HISTORY]
        mov     [r12 + RUNTIME_PRODUCER_ARGS + PROD_HISTORY], rdx
        lea     rdx, [r12 + RUNTIME_PRODUCER_STOP]
        mov     [r12 + RUNTIME_PRODUCER_ARGS + PROD_STOP], rdx
        lea     rdx, [r12 + RUNTIME_PRODUCER_FAILED]
        mov     [r12 + RUNTIME_PRODUCER_ARGS + PROD_FAILED], rdx
        lea     rdx, [r12 + RUNTIME_PRODUCER_DONE]
        mov     [r12 + RUNTIME_PRODUCER_ARGS + PROD_DONE], rdx
        lea     rdx, [r12 + RUNTIME_PRODUCER_ERROR]
        mov     [r12 + RUNTIME_PRODUCER_ARGS + PROD_ERROR], rdx

        ; workerArgs and workerServiceArgs
        lea     rdx, [r12 + RUNTIME_RING]
        mov     [r12 + RUNTIME_WORKER_ARGS + WORKER_ARGS], rdx
        xor     edx, edx
        mov     [r12 + RUNTIME_WORKER_ARGS + 8], edx
        lea     rdx, [r12 + RUNTIME_CONTROL]
        mov     [r12 + RUNTIME_WORKER_ARGS + 16], rdx
        lea     rdx, [r12 + RUNTIME_WORKER_ARGS]
        mov     [r12 + RUNTIME_WORKER_SERVICE + WORKER_ARGS], rdx
        lea     rdx, [r12 + RUNTIME_REPORT]
        mov     [r12 + RUNTIME_WORKER_SERVICE + WORKER_REPORT], rdx
        lea     rdx, [r12 + RUNTIME_WORKER_RESULT]
        mov     [r12 + RUNTIME_WORKER_SERVICE + WORKER_RESULT], rdx

        ; AudioWorkerLifecycleArgs on the caller's reserved stack area.
        lea     r15, [rsp + 0x50]
        lea     rdx, [r12 + RUNTIME_PRODUCER_HANDLE]
        mov     [r15 + LIFECYCLE_PRODUCER_HANDLE], rdx
        lea     rdx, [rel asm_audio_producer_thread]
        mov     [r15 + LIFECYCLE_PRODUCER_ENTRY], rdx
        lea     rdx, [r12 + RUNTIME_PRODUCER_ARGS]
        mov     [r15 + LIFECYCLE_PRODUCER_ARGS], rdx
        lea     rdx, [r12 + RUNTIME_RING]
        mov     [r15 + LIFECYCLE_RING], rdx
        lea     rdx, [r12 + RUNTIME_PRODUCER_FAILED]
        mov     [r15 + LIFECYCLE_PRODUCER_FAILED], rdx
        lea     rdx, [r12 + RUNTIME_WORKER_HANDLE]
        mov     [r15 + LIFECYCLE_WORKER_HANDLE], rdx
        lea     rdx, [rel asm_audio_ring_thread_entry]
        mov     [r15 + LIFECYCLE_WORKER_ENTRY], rdx
        lea     rdx, [r12 + RUNTIME_WORKER_SERVICE]
        mov     [r15 + LIFECYCLE_WORKER_ARGS], rdx
        lea     rdx, [r12 + RUNTIME_CONTROL]
        mov     [r15 + LIFECYCLE_CONTROL], rdx
        lea     rdx, [r12 + RUNTIME_PRODUCER_STOP]
        mov     [r15 + LIFECYCLE_PRODUCER_STOP], rdx
        ret

; int vk::audioAsmInit(const char* modPath, int sampleRate)
?audioAsmInit@vk@@YAHPEBDH@Z:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0xA0                    ; RSP%16 == 0 at CALL

        lea     r12, [rel asm_audio_runtime_state]
        mov     r13, rcx                     ; module path
        cmp     dword [r12 + RUNTIME_INITIALIZED], 0
        jne     .init_already_ready

        lea     rcx, [rel audio_fail_environment]
        lea     rdx, [rsp + 0x40]
        mov     r8d, 4
        call    GetEnvironmentVariableA
        test    eax, eax
        jz      .init_no_forced_failure
        lea     rcx, [rel audio_forced_failure_message]
        call    ?logPrint@vk@@YAXPEBDZZ
        xor     eax, eax
        jmp     .init_done

.init_no_forced_failure:
        test    r13, r13
        jz      .init_storage_failed_no_call
        mov     rcx, r13
        lea     rdx, [r12 + RUNTIME_STORAGE]
        call    asm_audio_service_storage_init
        mov     r14d, eax
        jmp     .init_storage_status
.init_storage_failed_no_call:
        mov     r14d, 1
.init_storage_status:
        test    r14d, r14d
        jz      .init_storage_ready
        lea     rcx, [rel audio_storage_failure_format]
        mov     edx, r14d
        call    ?logPrint@vk@@YAXPEBDZZ
        call    audio_clear_runtime
        xor     eax, eax
        jmp     .init_done

.init_storage_ready:
        lea     rax, [r12 + RUNTIME_STORAGE]
        mov     rcx, [rax + STORAGE_RING_SAMPLES]
        mov     rdx, rcx
        lea     rcx, [r12 + RUNTIME_RING]
        mov     r8d, 16384
        mov     r9, [rax + STORAGE_RING_MARKERS]
        mov     dword [rsp + 0x20], 16384
        call    asm_audio_ring_init
        test    eax, eax
        jz      .init_ring_ready
        lea     rcx, [rel audio_ring_failure_message]
        call    ?logPrint@vk@@YAXPEBDZZ
        call    audio_clear_runtime
        xor     eax, eax
        jmp     .init_done

.init_ring_ready:
        call    audio_prepare_records
        mov     rcx, r15
        call    asm_audio_start_workers
        mov     r14d, eax
        test    r14d, r14d
        jz      .init_workers_ready
        cmp     r14d, 1
        jne     .init_worker_status_not_prebuffer
        lea     rcx, [rel audio_prebuffer_failure_format]
        mov     edx, [r12 + RUNTIME_PRODUCER_FAILED]
        mov     r8d, [r12 + RUNTIME_PRODUCER_DONE]
        mov     r9d, [r12 + RUNTIME_PRODUCER_ERROR]
        mov     eax, [r12 + RUNTIME_RING + 20]
        mov     dword [rsp + 0x20], eax
        mov     eax, [r12 + RUNTIME_RING + 16]
        mov     dword [rsp + 0x28], eax
        call    ?logPrint@vk@@YAXPEBDZZ
        jmp     .init_worker_failure
.init_worker_status_not_prebuffer:
        cmp     r14d, 2
        jne     .init_worker_early_exit
        lea     rcx, [rel audio_worker_creation_failure_message]
        call    ?logPrint@vk@@YAXPEBDZZ
        jmp     .init_worker_failure
.init_worker_early_exit:
        lea     rcx, [rel audio_worker_exit_failure_message]
        call    ?logPrint@vk@@YAXPEBDZZ
.init_worker_failure:
        call    ?audioAsmShutdown@vk@@YAXXZ
        xor     eax, eax
        jmp     .init_done

.init_workers_ready:
        mov     eax, 1
        xchg    dword [r12 + RUNTIME_PLAYING], eax
        mov     eax, 1
        xchg    dword [r12 + RUNTIME_INITIALIZED], eax
        lea     rcx, [rel audio_active_format]
        mov     edx, [r12 + RUNTIME_STORAGE + STORAGE_ORDER_COUNT]
        call    ?logPrint@vk@@YAXPEBDZZ
        mov     eax, 1
        jmp     .init_done

.init_already_ready:
        mov     eax, 1
.init_done:
        add     rsp, 0xA0
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbp
        ret

; void vk::audioAsmShutdown(void)
?audioAsmShutdown@vk@@YAXXZ:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0xA0                    ; RSP%16 == 0 at CALL

        lea     r12, [rel asm_audio_runtime_state]
        cmp     dword [r12 + RUNTIME_SHUTTING_DOWN], 0
        jne     .shutdown_done
        mov     eax, 1
        xchg    dword [r12 + RUNTIME_SHUTTING_DOWN], eax
        xor     eax, eax
        xchg    dword [r12 + RUNTIME_PLAYING], eax

        lea     r15, [rsp + 0x50]
        lea     rax, [r12 + RUNTIME_PRODUCER_HANDLE]
        mov     [r15 + LIFECYCLE_PRODUCER_HANDLE], rax
        xor     eax, eax
        mov     [r15 + LIFECYCLE_PRODUCER_ENTRY], rax
        mov     [r15 + LIFECYCLE_PRODUCER_ARGS], rax
        mov     [r15 + LIFECYCLE_RING], rax
        lea     rax, [r12 + RUNTIME_PRODUCER_FAILED]
        mov     [r15 + LIFECYCLE_PRODUCER_FAILED], rax
        lea     rax, [r12 + RUNTIME_WORKER_HANDLE]
        mov     [r15 + LIFECYCLE_WORKER_HANDLE], rax
        xor     eax, eax
        mov     [r15 + LIFECYCLE_WORKER_ENTRY], rax
        mov     [r15 + LIFECYCLE_WORKER_ARGS], rax
        lea     rax, [r12 + RUNTIME_CONTROL]
        mov     [r15 + LIFECYCLE_CONTROL], rax
        lea     rax, [r12 + RUNTIME_PRODUCER_STOP]
        mov     [r15 + LIFECYCLE_PRODUCER_STOP], rax
        mov     rcx, r15
        call    asm_audio_stop_workers

        cmp     qword [r12 + RUNTIME_RING + RING_SAMPLES], 0
        je      .shutdown_log
        lea     rcx, [r12 + RUNTIME_RING]
        call    asm_audio_ring_close
.shutdown_log:
        lea     rcx, [rel audio_stopped_format]
        mov     edx, [r12 + RUNTIME_REPORT + REPORT_DEVICE_FRAMES]
        mov     r8d, [r12 + RUNTIME_REPORT + REPORT_UNDERRUN_EVENTS]
        mov     r9d, [r12 + RUNTIME_REPORT + REPORT_SNAPSHOT_UPDATES]
        call    ?logPrint@vk@@YAXPEBDZZ
        call    audio_clear_runtime
.shutdown_done:
        add     rsp, 0xA0
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbp
        ret

; int vk::audioAsmPlay(void)
?audioAsmPlay@vk@@YAHXZ:
        lea     rax, [rel asm_audio_runtime_state]
        mov     edx, 1
        xchg    dword [rax + RUNTIME_PLAYING], edx
        mov     eax, 1
        ret

; int vk::audioAsmStop(void)
?audioAsmStop@vk@@YAHXZ:
        lea     rax, [rel asm_audio_runtime_state]
        xor     edx, edx
        xchg    dword [rax + RUNTIME_PLAYING], edx
        mov     eax, 1
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
