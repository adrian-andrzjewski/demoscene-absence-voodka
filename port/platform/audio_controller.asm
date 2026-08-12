;
; Public controller/query ABI for the dedicated assembly player. The runtime
; block is initialized and cleared by audio_lifecycle.asm; these steady-state
; query and control paths require no C++ implementation body.

BITS 64
DEFAULT REL

%define RUNTIME_STORAGE             0
%define RUNTIME_CONTROL           288
%define RUNTIME_REPORT            376
%define RUNTIME_INITIALIZED       564
%define RUNTIME_SHUTTING_DOWN     568
%define RUNTIME_PLAYING           572
%define RUNTIME_LAST_STATE        576
%define RUNTIME_LAST_SEQUENCE     580
%define RUNTIME_SEEK_BASE         584
%define RUNTIME_SEEK_TIME_BASE    592

%define STORAGE_ORDER_COUNT         24

%define REPORT_PUBLISHED_MODPOS   104
%define REPORT_PUBLISHED_FRAME    108
%define REPORT_UNDERRUN_EVENTS    120
%define REPORT_SNAPSHOT_UPDATES   112
%define REPORT_WORKER_EXIT         96
%define REPORT_DEVICE_FRAMES       88

extern Sleep
extern asm_audio_runtime_state
extern asm_audio_issue_state
extern ?isPaused@vk@@YA_NXZ
extern ?getQpcUs@vk@@YA_KXZ
extern ?updateInput@vk@@YAXXZ
extern ?quitRequested@vk@@YA_NXZ
extern ?shutdownAndExit@vk@@YAXXZ
extern ?logPrint@vk@@YAXPEBDZZ

global ?audioAsmModPos@vk@@YAIXZ
global ?audioAsmModLength@vk@@YAIXZ
global ?audioAsmElapsedSec@vk@@YANXZ
global ?audioAsmPump@vk@@YAXXZ
global ?audioAsmSelfCheck@vk@@YAHH@Z

section .data
audio_self_check_format:
        db "[audio-asm] self-check: %.2fs device_frames=%u "
        db "underruns=%u markers=%u worker_exit=%u", 10, 0
audio_sample_rate:
        dq 44100.0

section .text

; uint32_t vk::audioAsmModPos(void)
?audioAsmModPos@vk@@YAIXZ:
        lea     rax, [rel asm_audio_runtime_state]
        cmp     dword [rax + RUNTIME_INITIALIZED], 0
        je      .modpos_zero
        mfence
        mov     eax, dword [rax + RUNTIME_REPORT + REPORT_PUBLISHED_MODPOS]
        ret
.modpos_zero:
        xor     eax, eax
        ret

; uint32_t vk::audioAsmModLength(void)
?audioAsmModLength@vk@@YAIXZ:
        lea     rax, [rel asm_audio_runtime_state]
        cmp     dword [rax + RUNTIME_INITIALIZED], 0
        je      .modlength_zero
        mov     eax, dword [rax + RUNTIME_STORAGE + STORAGE_ORDER_COUNT]
        ret
.modlength_zero:
        xor     eax, eax
        ret

; double vk::audioAsmElapsedSec(void)
?audioAsmElapsedSec@vk@@YANXZ:
        lea     r10, [rel asm_audio_runtime_state]
        cmp     dword [r10 + RUNTIME_INITIALIZED], 0
        je      .elapsed_zero
        mfence
        mov     eax, dword [r10 + RUNTIME_REPORT + REPORT_PUBLISHED_FRAME]
        sub     eax, dword [r10 + RUNTIME_SEEK_BASE]
        jnc     .elapsed_delta_ready
        xor     eax, eax
.elapsed_delta_ready:
        movsxd  rax, eax
        cvtsi2sd xmm0, rax
        divsd   xmm0, [rel audio_sample_rate]
        movsd   xmm1, [r10 + RUNTIME_SEEK_TIME_BASE]
        addsd   xmm0, xmm1
        ret
.elapsed_zero:
        pxor    xmm0, xmm0
        ret

; void vk::audioAsmPump(void)
?audioAsmPump@vk@@YAXXZ:
        push    rbp
        mov     rbp, rsp
        push    r12
        sub     rsp, 0x28                    ; RSP%16 == 0 at CALL

        lea     r12, [rel asm_audio_runtime_state]
        cmp     dword [r12 + RUNTIME_INITIALIZED], 0
        je      .pump_done
        cmp     dword [r12 + RUNTIME_SHUTTING_DOWN], 0
        jne     .pump_done

        cmp     dword [r12 + RUNTIME_PLAYING], 0
        je      .pump_paused
        call    ?isPaused@vk@@YA_NXZ
        test    al, al                         ; MSVC bool result is AL
        jnz     .pump_paused
        xor     edx, edx                    ; desired running state
        jmp     .pump_state_ready
.pump_paused:
        mov     edx, 1                      ; desired paused state
.pump_state_ready:
        cmp     edx, dword [r12 + RUNTIME_LAST_STATE]
        je      .pump_done

        mov     rcx, r12
        add     rcx, RUNTIME_CONTROL
        mov     r8, r12
        add     r8, RUNTIME_LAST_STATE
        mov     r9, r12
        add     r9, RUNTIME_LAST_SEQUENCE
        mov     qword [rsp + 0x20], 0
        call    asm_audio_issue_state

.pump_done:
        add     rsp, 0x28
        pop     r12
        pop     rbp
        ret

; int vk::audioAsmSelfCheck(int seconds)
?audioAsmSelfCheck@vk@@YAHH@Z:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0x30                    ; RSP%16 == 0 at CALL

        lea     r14, [rel asm_audio_runtime_state]
        cmp     dword [r14 + RUNTIME_INITIALIZED], 0
        je      .selfcheck_not_initialized
        test    ecx, ecx
        jg      .selfcheck_seconds_ready
        mov     ecx, 20
.selfcheck_seconds_ready:
        movsxd  r13, ecx
        imul    r13, 1000000
        call    ?getQpcUs@vk@@YA_KXZ
        add     r13, rax                    ; deadline in microseconds

.selfcheck_loop:
        call    ?getQpcUs@vk@@YA_KXZ
        cmp     rax, r13
        jae     .selfcheck_report
        call    ?updateInput@vk@@YAXXZ
        call    ?quitRequested@vk@@YA_NXZ
        test    al, al                         ; MSVC bool result is AL
        jz      .selfcheck_no_quit
        call    ?shutdownAndExit@vk@@YAXXZ
.selfcheck_no_quit:
        call    ?audioAsmPump@vk@@YAXXZ
        mov     ecx, 10
        call    Sleep
        jmp     .selfcheck_loop

.selfcheck_report:
        lea     r15, [r14 + RUNTIME_REPORT]
        call    ?audioAsmElapsedSec@vk@@YANXZ
        movq    rdx, xmm0                   ; duplicate vararg FP in GPR
        mov     r8d, dword [r15 + REPORT_DEVICE_FRAMES]
        mov     r9d, dword [r15 + REPORT_UNDERRUN_EVENTS]
        mov     eax, dword [r15 + REPORT_SNAPSHOT_UPDATES]
        mov     dword [rsp + 0x20], eax
        mov     eax, dword [r15 + REPORT_WORKER_EXIT]
        mov     dword [rsp + 0x28], eax
        lea     rcx, [rel audio_self_check_format]
        call    ?logPrint@vk@@YAXPEBDZZ

        cmp     dword [r15 + REPORT_UNDERRUN_EVENTS], 0
        jne     .selfcheck_failed
        cmp     dword [r15 + REPORT_WORKER_EXIT], 0
        jne     .selfcheck_failed
        xor     eax, eax
        jmp     .selfcheck_done
.selfcheck_failed:
        mov     eax, 1
        jmp     .selfcheck_done
.selfcheck_not_initialized:
        mov     eax, 1
.selfcheck_done:
        add     rsp, 0x30
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbp
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
