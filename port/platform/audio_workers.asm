; audio_workers.asm - Win32 worker-handle ownership for the dedicated player.
;
; The assembly player owns worker startup, rollback, joining, and handle
; cleanup.  The fixed lifecycle record is supplied by the transitional host
; shim and keeps the C++ and assembly targets layout-compatible.

BITS 64
DEFAULT REL

extern CreateThread
extern WaitForSingleObject
extern CloseHandle
extern Sleep

global asm_audio_create_worker
global asm_audio_wait_worker
global asm_audio_close_worker
global asm_audio_start_workers
global asm_audio_stop_workers

section .text

; uint32_t asm_audio_create_worker(HANDLE* slot,
;                                  LPTHREAD_START_ROUTINE entry,
;                                  void* argument)
asm_audio_create_worker:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        push    r14
        sub     rsp, 0x38                    ; RSP%16 == 0 at CALL

        mov     r12, rcx                     ; output handle slot
        mov     r13, rdx                     ; thread entry
        mov     r14, r8                      ; thread argument
        test    r12, r12
        jz      .create_failed
        mov     qword [r12], 0

        xor     ecx, ecx                     ; lpThreadAttributes
        xor     edx, edx                     ; dwStackSize
        mov     r8, r13                      ; lpStartAddress
        mov     r9, r14                      ; lpParameter
        mov     qword [rsp + 0x20], 0        ; dwCreationFlags
        mov     qword [rsp + 0x28], 0        ; lpThreadId
        call    CreateThread
        test    rax, rax
        jz      .create_failed
        mov     [r12], rax
        mov     eax, 1
        jmp     .create_done

.create_failed:
        xor     eax, eax

.create_done:
        add     rsp, 0x38
        pop     r14
        pop     r13
        pop     r12
        pop     rbp
        ret

; DWORD asm_audio_wait_worker(HANDLE handle, DWORD timeout)
asm_audio_wait_worker:
        jmp     WaitForSingleObject

; uint32_t asm_audio_close_worker(HANDLE* slot)
asm_audio_close_worker:
        push    rbp
        mov     rbp, rsp
        push    r12
        sub     rsp, 0x28                    ; RSP%16 == 0 at CALL

        mov     r12, rcx
        test    r12, r12
        jz      .close_success
        mov     rcx, [r12]
        test    rcx, rcx
        jz      .close_success
        call    CloseHandle
        mov     qword [r12], 0

.close_success:
        mov     eax, 1
        add     rsp, 0x28
        pop     r12
        pop     rbp
        ret

; uint32_t asm_audio_start_workers(const AudioWorkerLifecycleArgs* args)
;
; Return values preserve the C++ startup branches:
;   0 = producer prebuffered and worker is alive
;   1 = producer creation/prebuffer failure
;   2 = worker controller creation failure
;   3 = worker exited during the startup grace period
asm_audio_start_workers:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0x28                    ; RSP%16 == 0 at CALL

        mov     r12, rcx                     ; lifecycle record
        test    r12, r12
        jz      .start_producer_failure

        mov     rcx, [r12 + 0]               ; producer handle slot
        mov     rdx, [r12 + 8]               ; producer entry
        mov     r8, [r12 + 16]               ; producer argument
        call    asm_audio_create_worker
        test    eax, eax
        jz      .start_producer_failure

        mov     r13, [r12 + 24]              ; PCM ring
        mov     r14, [r12 + 32]              ; producerFailed
        xor     ebx, ebx
.start_prebuffer:
        cmp     ebx, 5000
        jae     .start_producer_failure
        mov     eax, [r13 + 20]              ; writeFrame
        sub     eax, [r13 + 16]              ; - readFrame (uint32 wrap)
        cmp     eax, 8192
        jae     .start_prebuffer_ready
        cmp     dword [r14], 0
        jne     .start_producer_failure
        inc     ebx
        mov     ecx, 1
        call    Sleep
        jmp     .start_prebuffer

.start_prebuffer_ready:
        mov     rcx, [r12 + 40]              ; worker handle slot
        mov     rdx, [r12 + 48]              ; worker entry
        mov     r8, [r12 + 56]               ; worker argument
        call    asm_audio_create_worker
        test    eax, eax
        jz      .start_worker_failure

        mov     ecx, 250                     ; original startup grace period
        call    Sleep
        mov     rax, [r12 + 40]               ; worker handle slot
        mov     rcx, [rax]                    ; actual HANDLE
        xor     edx, edx                     ; zero-time early-exit check
        call    asm_audio_wait_worker
        test    eax, eax                     ; WAIT_OBJECT_0
        jz      .start_worker_early_exit
        xor     eax, eax
        jmp     .start_done

.start_producer_failure:
        mov     eax, 1
        jmp     .start_done
.start_worker_failure:
        mov     eax, 2
        jmp     .start_done
.start_worker_early_exit:
        mov     eax, 3

.start_done:
        add     rsp, 0x28
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        pop     rbp
        ret

; uint32_t asm_audio_stop_workers(const AudioWorkerLifecycleArgs* args)
;
; Publishes the worker stop state, increments its control sequence, joins and
; closes the worker first, then joins and closes the producer.  This is the
; exact former C++ teardown order and is idempotent for null handle slots.
asm_audio_stop_workers:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0x28                    ; RSP%16 == 0 at CALL

        mov     r12, rcx
        test    r12, r12
        jz      .stop_done
        mov     rbx, [r12 + 0]               ; producer slot
        mov     r15, [r12 + 40]              ; worker slot
        mov     r13, [r12 + 64]              ; AudioLiveControl
        mov     r14, [r12 + 72]              ; producerStop

        test    r14, r14
        jz      .stop_worker
        mov     eax, 1
        xchg    dword [r14], eax              ; InterlockedExchange(stop, 1)

.stop_worker:
        test    r15, r15
        jz      .stop_producer
        test    r13, r13
        jz      .stop_worker_join
        mov     eax, 2
        xchg    dword [r13 + 0], eax          ; requestedState = stop
        mov     eax, 1
        lock xadd dword [r13 + 4], eax        ; InterlockedIncrement(sequence)
.stop_worker_join:
        mov     rcx, [r15]
        mov     edx, 0xffffffff               ; INFINITE
        call    asm_audio_wait_worker
        mov     rcx, r15
        call    asm_audio_close_worker

.stop_producer:
        test    rbx, rbx
        jz      .stop_done
        mov     rcx, [rbx]
        mov     edx, 0xffffffff               ; INFINITE
        call    asm_audio_wait_worker
        mov     rcx, rbx
        call    asm_audio_close_worker

.stop_done:
        mov     eax, 1
        add     rsp, 0x28
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        pop     rbp
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
