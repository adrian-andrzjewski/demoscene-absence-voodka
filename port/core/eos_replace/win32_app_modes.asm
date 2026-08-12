; win32_app_modes.asm - production assembly mode and entry-seek dispatcher.
;
; The argument parser already owns the raw command-line interpretation. This
; layer owns the former app.cpp branch order, scene-start table, self-test loop,
; audio-check default, crash-filter handoff, and DemoStart32 result return.
; Namespace-vk calls remain explicit fixed-layout ABI adapters; their
; implementations are NASM-owned in the production image.

BITS 64
DEFAULT REL

%include "win64_abi.inc"

extern asm_voodka_arg_modpos
extern asm_voodka_arg_ms
extern asm_voodka_arg_order
extern asm_voodka_arg_part
extern asm_voodka_arg_scene
extern asm_voodka_arg_selftest
extern asm_voodka_arg_audiocheck
extern asm_voodka_arg_audiocheck_seconds

extern vk_app_seek_modpos
extern vk_app_seek_ms
extern vk_app_seek_order
extern vk_app_seek_part
extern vk_app_seek_scene
extern vk_app_no_entry_seek
extern vk_scene_part_from_name

extern vk_app_log_selftest
extern vk_app_selftest_pattern
extern vk_app_diag_readback_enabled
extern vk_app_present_frame
extern vk_app_log_audio_check
extern vk_app_audio_self_check
extern vk_app_log_demo_start
extern asm_install_crash_filter
extern DemoStart32
extern Sleep

global asm_voodka_apply_entry_seek
global asm_voodka_run_mode

section .data
align 4
scene_start_modpos:
        dd      0x0000, 0x0400, 0x0B40, 0x0D40
        dd      0x1400, 0x1B40, 0x1C40, 0x2040

section .text

; int asm_voodka_apply_entry_seek(void)
; Returns 1 when a selector was applied, 0 when the default start was kept.
asm_voodka_apply_entry_seek:
        push    rbp
        mov     rbp, rsp
        push    r12
        sub     rsp, 0x28                    ; RSP%16 == 0 at every CALL

        ; Existing precedence: modpos, ms, order, canonical scene, --part.
        call    asm_voodka_arg_modpos
        test    eax, eax
        js      .try_ms
        mov     ecx, eax
        call    vk_app_seek_modpos
        mov     eax, 1
        jmp     .done

.try_ms:
        call    asm_voodka_arg_ms
        test    eax, eax
        js      .try_order
        mov     ecx, eax
        call    vk_app_seek_ms
        mov     eax, 1
        jmp     .done

.try_order:
        call    asm_voodka_arg_order
        test    eax, eax
        js      .try_scene
        mov     ecx, eax
        call    vk_app_seek_order
        mov     eax, 1
        jmp     .done

.try_scene:
        call    asm_voodka_arg_scene
        test    rax, rax
        jz      .try_part
        mov     r12, rax
        mov     rcx, r12
        call    vk_scene_part_from_name
        test    eax, eax
        jz      .none
        mov     r12d, eax
        dec     eax
        lea     rdx, [rel scene_start_modpos]
        mov     edx, [rdx + rax * 4]
        mov     ecx, r12d
        call    vk_app_seek_scene
        mov     eax, 1
        jmp     .done

.try_part:
        call    asm_voodka_arg_part
        cmp     eax, 1
        jl      .none
        cmp     eax, 8
        jg      .none
        mov     r12d, eax
        dec     eax
        lea     rdx, [rel scene_start_modpos]
        mov     edx, [rdx + rax * 4]
        mov     ecx, r12d
        call    vk_app_seek_part
        mov     eax, 1
        jmp     .done

.none:
        call    vk_app_no_entry_seek
        xor     eax, eax
.done:
        add     rsp, 0x28
        pop     r12
        pop     rbp
        ret

; int asm_voodka_run_mode(void* arenaBase, uint64_t arenaSize)
; Runs one of the three production modes and returns its application status.
asm_voodka_run_mode:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        push    r14
        sub     rsp, 0x28                    ; RSP%16 == 0 at every CALL

        mov     r12, rcx                     ; arena base
        mov     r13, rdx                     ; arena size

        call    asm_voodka_arg_selftest
        test    eax, eax
        jz      .try_audio_check

        call    vk_app_log_selftest
        call    vk_app_selftest_pattern
        xor     r14d, r14d
.selftest_loop:
        cmp     r14d, 60
        jae     .selftest_done
        call    vk_app_diag_readback_enabled
        test    eax, eax
        jz      .selftest_done
        call    vk_app_present_frame
        mov     ecx, 16
        call    Sleep
        inc     r14d
        jmp     .selftest_loop
.selftest_done:
        xor     eax, eax
        jmp     .done

.try_audio_check:
        call    asm_voodka_arg_audiocheck
        test    eax, eax
        jz      .run_demo
        call    asm_voodka_arg_audiocheck_seconds
        mov     r14d, eax
        test    r14d, r14d
        jg      .audio_check_seconds_ready
        mov     r14d, 20
.audio_check_seconds_ready:
        mov     ecx, r14d
        call    vk_app_log_audio_check
        mov     ecx, r14d
        call    vk_app_audio_self_check
        jmp     .done

.run_demo:
        mov     rcx, r12
        call    vk_app_log_demo_start
        call    asm_install_crash_filter
        mov     rcx, r12
        mov     rdx, r13
        call    DemoStart32
.done:
        add     rsp, 0x28
        pop     r14
        pop     r13
        pop     r12
        pop     rbp
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
