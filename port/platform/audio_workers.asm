; audio_workers.asm - Win32 worker-handle ownership for the dedicated player.
;
; The player still decides when each worker is created and what rollback means.
; These helpers own only the ABI-sensitive CreateThread, wait, and CloseHandle
; calls, keeping handles in the caller's fixed Runtime record.

BITS 64
DEFAULT REL

extern CreateThread
extern WaitForSingleObject
extern CloseHandle

global asm_audio_create_worker
global asm_audio_wait_worker
global asm_audio_close_worker

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

section .note.GNU-stack noalloc noexec nowrite progbits
