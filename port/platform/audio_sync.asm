; audio_sync.asm - assembly state-command acknowledgement loop.
;
; uint32_t asm_audio_issue_state(AudioLiveControl* control, uint32_t state,
;                                uint32_t* lastState,
;                                uint32_t* lastSequence,
;                                uint32_t* sequenceOut)
;
; This is the exact former C++ issueState contract: publish the requested
; state, atomically increment the command sequence, wait up to 5000 one-ms
; polls for the worker's matching acknowledgement, then update the cached
; state/sequence and optional result pointer.

BITS 64
DEFAULT REL

extern Sleep
global asm_audio_issue_state

section .text

asm_audio_issue_state:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0x38                    ; RSP%16 == 0 at CALL

        mov     r12, rcx                     ; control
        mov     r13d, edx                    ; requested state
        mov     r14, r8                      ; cached state pointer
        mov     r15, r9                      ; cached sequence pointer
        mov     r10, [rbp + 0x30]            ; optional sequenceOut (arg 5)
        mov     [rsp + 0x20], r10

        mov     eax, r13d
        xchg    dword [r12 + 0], eax         ; InterlockedExchange

        mov     eax, 1
        lock xadd dword [r12 + 4], eax       ; eax = previous sequence
        inc     eax                          ; eax = new sequence
        mov     [rsp + 0x28], eax            ; preserve across Sleep
        xor     ebx, ebx                    ; poll count

.state_wait:
        mov     r11d, [rsp + 0x28]
        cmp     dword [r12 + 12], r11d       ; acknowledgedSequence
        jne     .state_poll
        mov     eax, r13d
        and     eax, 1
        cmp     dword [r12 + 8], eax         ; acknowledgedState
        jne     .state_poll

        mov     eax, r13d
        and     eax, 1
        mov     [r14], eax
        mov     [r15], r11d
        mov     r10, [rsp + 0x20]
        test    r10, r10
        jz      .state_success
        mov     [r10], r11d
.state_success:
        mov     eax, 1
        jmp     .state_done

.state_poll:
        cmp     ebx, 5000
        jae     .state_failure
        inc     ebx
        mov     ecx, 1
        call    Sleep
        jmp     .state_wait

.state_failure:
        xor     eax, eax

.state_done:
        add     rsp, 0x38
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        pop     rbp
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
