;
; Controller-side seek transaction for the dedicated assembly player.
; Producer-side tracker rebuild remains in core/eos_replace/audio_service.asm;
; this routine owns the other half of the cross-thread ownership protocol.

BITS 64
DEFAULT REL

%define SEEK_CONTROL              0
%define SEEK_RING                 8
%define SEEK_PRODUCER_FAILED     16
%define SEEK_TARGET_TICK         24
%define SEEK_LAST_STATE          32
%define SEEK_LAST_SEQUENCE       40
%define SEEK_BASE_OUT            48
%define SEEK_SEQUENCE_OUT        56

%define RING_READ                 16
%define RING_WRITE                20
%define RING_MARKER_READ          52
%define RING_MARKER_WRITE         56

%define CONTROL_REQUESTED_STATE    0
%define CONTROL_REQUEST_SEQUENCE   4
%define CONTROL_REQUESTED_SEEK    16
%define CONTROL_SEEK_SEQUENCE     20
%define CONTROL_PRODUCER_ACK     24
%define CONTROL_SEEK_COMMIT       28
%define CONTROL_SEEK_RING_BASE   32
%define CONTROL_WORKER_CONSUMED  36

extern Sleep
extern asm_audio_issue_state

global asm_audio_seek_transaction

section .text

; uint32_t asm_audio_seek_transaction(const AudioSeekTransactionArgs* args)
;
; The return code preserves the former C++ failure distinction needed by the
; host: status 2 means the ring transaction committed but the final resume
; acknowledgement failed, so the caller may still publish its seek metadata.
asm_audio_seek_transaction:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15
        push    rdi
        sub     rsp, 0x30                    ; RSP%16 == 0 at CALL

        mov     r12, rcx                     ; transaction record
        test    r12, r12
        jz      .seek_failed
        mov     r13, [r12 + SEEK_CONTROL]
        mov     r14, [r12 + SEEK_RING]
        mov     r15, [r12 + SEEK_PRODUCER_FAILED]
        test    r13, r13
        jz      .seek_failed
        test    r14, r14
        jz      .seek_failed
        test    r15, r15
        jz      .seek_failed

        ; Pause the WASAPI consumer and wait for its boundary acknowledgement.
        mov     rcx, r13
        mov     edx, 1
        mov     r8, [r12 + SEEK_LAST_STATE]
        mov     r9, [r12 + SEEK_LAST_SEQUENCE]
        mov     qword [rsp + 0x20], 0        ; no sequence output
        call    asm_audio_issue_state
        test    eax, eax
        jz      .seek_failed

        mfence
        mov     eax, dword [r13 + CONTROL_WORKER_CONSUMED]
        mov     r10, [r12 + SEEK_BASE_OUT]
        test    r10, r10
        jz      .base_captured
        mov     dword [r10], eax
.base_captured:
        xchg    eax, dword [r13 + CONTROL_SEEK_RING_BASE]

        ; Publish target and atomically allocate the seek sequence.
        mov     eax, dword [r12 + SEEK_TARGET_TICK]
        xchg    eax, dword [r13 + CONTROL_REQUESTED_SEEK]
        mov     eax, 1
        lock xadd dword [r13 + CONTROL_SEEK_SEQUENCE], eax
        inc     eax                             ; new sequence
        mov     ebx, eax
        mov     r10, [r12 + SEEK_SEQUENCE_OUT]
        test    r10, r10
        jz      .seek_ack_wait
        mov     dword [r10], ebx

.seek_ack_wait:
        xor     edi, edi
.seek_ack_loop:
        cmp     dword [r13 + CONTROL_PRODUCER_ACK], ebx
        je      .seek_acknowledged
        cmp     edi, 5000
        jae     .seek_failed
        cmp     dword [r15], 0
        jne     .seek_failed
        inc     edi
        mov     ecx, 1
        call    Sleep
        jmp     .seek_ack_loop

.seek_acknowledged:
        ; Both owners are quiescent: discard the old PCM and marker segment.
        mfence
        mov     eax, dword [r14 + RING_WRITE]
        mov     dword [r14 + RING_READ], eax
        mov     eax, dword [r14 + RING_MARKER_WRITE]
        mov     dword [r14 + RING_MARKER_READ], eax
        mfence
        mov     eax, ebx
        xchg    eax, dword [r13 + CONTROL_SEEK_COMMIT]

        ; Producer rebuilds tracker state after commit and refills the ring.
        xor     edi, edi
.prebuffer_loop:
        mov     eax, dword [r14 + RING_WRITE]
        sub     eax, dword [r14 + RING_READ]
        cmp     eax, 8192
        jae     .prebuffered
        cmp     dword [r15], 0
        jne     .seek_failed
        cmp     edi, 5000
        jae     .seek_failed
        inc     edi
        mov     ecx, 1
        call    Sleep
        jmp     .prebuffer_loop

.prebuffered:
        ; Resume the consumer only after the new segment has a full cushion.
        mov     rcx, r13
        xor     edx, edx
        mov     r8, [r12 + SEEK_LAST_STATE]
        mov     r9, [r12 + SEEK_LAST_SEQUENCE]
        mov     qword [rsp + 0x20], 0
        call    asm_audio_issue_state
        test    eax, eax
        jz      .resume_failed
        mov     eax, 1
        jmp     .seek_done

.resume_failed:
        mov     eax, 2
        jmp     .seek_done

.seek_failed:
        xor     eax, eax

.seek_done:
        add     rsp, 0x30
        pop     rdi
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        pop     rbp
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
