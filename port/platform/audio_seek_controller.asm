; audio_seek_controller.asm - final public seek ABI for the dedicated player.
;
; The lower-bound lookup and cross-thread transaction are already native
; assembly. This wrapper now owns the remaining public ModPos/millisecond/
; order selection and the seek-relative frame/time metadata commit.

BITS 64
DEFAULT REL

%define RUNTIME_STORAGE             0
%define RUNTIME_RING              224
%define RUNTIME_CONTROL           288
%define RUNTIME_REPORT            376
%define RUNTIME_PRODUCER_FAILED   548
%define RUNTIME_INITIALIZED       564
%define RUNTIME_LAST_STATE        576
%define RUNTIME_LAST_SEQUENCE     580
%define RUNTIME_SEEK_BASE         584
%define RUNTIME_SEEK_SOURCE       588
%define RUNTIME_SEEK_TIME_BASE    592

%define STORAGE_STATE_FRAMES       12
%define STORAGE_TICK_STARTS        40
%define STORAGE_MODPOS_BY_TICK     48
%define STORAGE_TICK_TIMES_MS      56

%define SEEK_CONTROL                0
%define SEEK_RING                   8
%define SEEK_PRODUCER_FAILED       16
%define SEEK_TARGET_TICK            24
%define SEEK_LAST_STATE             32
%define SEEK_LAST_SEQUENCE          40
%define SEEK_BASE_OUT               48
%define SEEK_SEQUENCE_OUT           56

extern asm_audio_runtime_state
extern asm_audio_lower_bound_u32
extern asm_audio_seek_transaction

global ?audioAsmSeekRows@vk@@YAII@Z
global ?audioAsmSeekMs@vk@@YAIH@Z
global ?audioAsmSeekOrder@vk@@YAIH@Z

section .data
audio_seek_sample_rate:
        dq 44100.0

section .text

; r12 = runtime, r14d = target tick.
; Return the transaction status after committing metadata for status 1 or 2.
audio_seek_tick:
        sub     rsp, 0x28                    ; align transaction call
        lea     rax, [r12 + RUNTIME_CONTROL]
        mov     [rsp + 0x78 + SEEK_CONTROL], rax
        lea     rax, [r12 + RUNTIME_RING]
        mov     [rsp + 0x78 + SEEK_RING], rax
        lea     rax, [r12 + RUNTIME_PRODUCER_FAILED]
        mov     [rsp + 0x78 + SEEK_PRODUCER_FAILED], rax
        mov     dword [rsp + 0x78 + SEEK_TARGET_TICK], r14d
        mov     dword [rsp + 0x78 + 28], 0
        lea     rax, [r12 + RUNTIME_LAST_STATE]
        mov     [rsp + 0x78 + SEEK_LAST_STATE], rax
        lea     rax, [r12 + RUNTIME_LAST_SEQUENCE]
        mov     [rsp + 0x78 + SEEK_LAST_SEQUENCE], rax
        lea     rax, [rsp + 0x68]
        mov     [rsp + 0x78 + SEEK_BASE_OUT], rax
        lea     rax, [rsp + 0x6c]
        mov     [rsp + 0x78 + SEEK_SEQUENCE_OUT], rax
        mov     dword [rsp + 0x68], 0
        mov     dword [rsp + 0x6c], 0

        lea     rcx, [rsp + 0x78]
        call    asm_audio_seek_transaction
        test    eax, eax
        jz      .seek_transaction_failed
        mov     r11d, eax

        mov     eax, dword [rsp + 0x68]
        mov     dword [r12 + RUNTIME_SEEK_BASE], eax
        mov     dword [r12 + RUNTIME_SEEK_SOURCE], r14d
        mov     rdx, [r12 + RUNTIME_STORAGE + STORAGE_TICK_STARTS]
        mov     eax, dword [rdx + r14 * 4]
        mov     ecx, eax                    ; EAX write zero-extends RAX
        cvtsi2sd xmm0, rax
        divsd   xmm0, [rel audio_seek_sample_rate]
        movsd   qword [r12 + RUNTIME_SEEK_TIME_BASE], xmm0
        mov     eax, r11d
        add     rsp, 0x28
        ret

.seek_transaction_failed:
        xor     eax, eax
        add     rsp, 0x28
        ret

; uint32_t vk::audioAsmSeekRows(uint32_t modpos)
?audioAsmSeekRows@vk@@YAII@Z:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0xA0                    ; RSP%16 == 0 at CALL

        mov     r13d, ecx
        lea     r12, [rel asm_audio_runtime_state]
        cmp     dword [r12 + RUNTIME_INITIALIZED], 0
        je      .rows_zero
        mov     rcx, [r12 + RUNTIME_STORAGE + STORAGE_MODPOS_BY_TICK]
        mov     edx, dword [r12 + RUNTIME_STORAGE + STORAGE_STATE_FRAMES]
        mov     r8d, r13d
        call    asm_audio_lower_bound_u32
        mov     r14d, eax
        call    audio_seek_tick
        cmp     eax, 1
        jne     .rows_zero
        mov     rdx, [r12 + RUNTIME_STORAGE + STORAGE_MODPOS_BY_TICK]
        mov     eax, dword [rdx + r14 * 4]
        jmp     .rows_done
.rows_zero:
        xor     eax, eax
.rows_done:
        add     rsp, 0xA0
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbp
        ret

; uint32_t vk::audioAsmSeekMs(int ms)
?audioAsmSeekMs@vk@@YAIH@Z:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0xA0                    ; RSP%16 == 0 at CALL

        test    ecx, ecx
        js      .ms_zero
        mov     r13d, ecx
        lea     r12, [rel asm_audio_runtime_state]
        cmp     dword [r12 + RUNTIME_INITIALIZED], 0
        je      .ms_zero
        mov     rcx, [r12 + RUNTIME_STORAGE + STORAGE_TICK_TIMES_MS]
        mov     edx, dword [r12 + RUNTIME_STORAGE + STORAGE_STATE_FRAMES]
        mov     r8d, r13d
        call    asm_audio_lower_bound_u32
        mov     r14d, eax
        call    audio_seek_tick
        cmp     eax, 1
        jne     .ms_zero
        mov     rdx, [r12 + RUNTIME_STORAGE + STORAGE_MODPOS_BY_TICK]
        mov     eax, dword [rdx + r14 * 4]
        jmp     .ms_done
.ms_zero:
        xor     eax, eax
.ms_done:
        add     rsp, 0xA0
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbp
        ret

; uint32_t vk::audioAsmSeekOrder(int order)
?audioAsmSeekOrder@vk@@YAIH@Z:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0xA0                    ; RSP%16 == 0 at CALL

        test    ecx, ecx
        js      .order_zero
        shl     ecx, 8
        call    ?audioAsmSeekRows@vk@@YAII@Z
        jmp     .order_done
.order_zero:
        xor     eax, eax
.order_done:
        add     rsp, 0xA0
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbp
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
