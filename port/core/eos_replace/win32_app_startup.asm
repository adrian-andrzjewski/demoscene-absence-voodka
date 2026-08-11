; win32_app_startup.asm - production subsystem initialization coordinator.
;
; The production command-line parser constructs one fixed-layout configuration
; record here, so the shipped target owns service order, quit checkpoints, and
; ordinary-init rollback branches. The reference executable retains its C++
; sequence solely as a differential oracle.

BITS 64
DEFAULT REL

%include "win64_abi.inc"

%define CFG_HWND              0
%define CFG_REC_DIR           8
%define CFG_DIAG_DIR          16
%define CFG_TIMELINE_PATH     24
%define CFG_MUSIC_PATH        32
%define CFG_ASM_AUDIO         40
%define CFG_REFERENCE_AUDIO   44
%define CFG_ASM_PRESENTER     48
%define CFG_AUTO_PAUSE        52
%define CFG_AUTO_CLOSE        56

extern vk_app_progress_init
extern vk_app_input_init
extern vk_app_platform_init
extern vk_app_quit_requested
extern vk_app_shutdown_all
extern vk_app_shutdown_and_exit
extern vk_app_timer_init
extern vk_app_timeline_init
extern vk_app_rec_init
extern vk_app_log_music
extern vk_app_audio_set_mode
extern vk_app_audio_init
extern vk_app_log_input_failure
extern vk_app_log_arena_failure
extern vk_app_log_audio_failure
extern vk_app_set_assembly_presenter
extern vk_app_present_init
extern vk_app_diag_init
extern vk_app_log_present_failure
extern vk_app_log_automation_failure
extern vk_app_log_automation
extern asm_lifecycle_start

global asm_voodka_initialize_subsystems

section .text

; int asm_voodka_initialize_subsystems(const AppStartupConfig* cfg)
; Returns 1 after every service has initialized.  A zero return means an
; ordinary initialization failure was logged and fully rolled back here.
; Quit checkpoints call the no-return shutdown-and-exit adapter instead.
asm_voodka_initialize_subsystems:
        push    rbp
        mov     rbp, rsp
        push    r12
        sub     rsp, 0x28                    ; RSP%16 == 0 at every CALL
        mov     r12, rcx                     ; stable config pointer

        mov     rcx, [r12 + CFG_HWND]
        call    vk_app_progress_init

        mov     rcx, [r12 + CFG_HWND]
        call    vk_app_input_init
        test    eax, eax
        jnz     .input_ok
        call    vk_app_log_input_failure
        call    vk_app_shutdown_all
        xor     eax, eax
        jmp     .done
.input_ok:

        call    vk_app_platform_init
        test    eax, eax
        jnz     .platform_ok
        call    vk_app_log_arena_failure
        call    vk_app_shutdown_all
        xor     eax, eax
        jmp     .done
.platform_ok:

        call    vk_app_quit_requested
        test    eax, eax
        jz      .platform_live
        call    vk_app_shutdown_and_exit
.platform_live:
        call    vk_app_timer_init

        mov     rcx, [r12 + CFG_TIMELINE_PATH]
        call    vk_app_timeline_init
        mov     rcx, [r12 + CFG_REC_DIR]
        call    vk_app_rec_init

        mov     rcx, [r12 + CFG_MUSIC_PATH]
        call    vk_app_log_music
        mov     ecx, [r12 + CFG_ASM_AUDIO]
        call    vk_app_audio_set_mode
        mov     rcx, [r12 + CFG_MUSIC_PATH]
        mov     edx, 44100
        call    vk_app_audio_init
        test    eax, eax
        jnz     .audio_ok
        mov     ecx, [r12 + CFG_REFERENCE_AUDIO]
        call    vk_app_log_audio_failure
        call    vk_app_shutdown_all
        xor     eax, eax
        jmp     .done
.audio_ok:

        call    vk_app_quit_requested
        test    eax, eax
        jz      .audio_live
        call    vk_app_shutdown_and_exit
.audio_live:
        mov     ecx, [r12 + CFG_ASM_PRESENTER]
        call    vk_app_set_assembly_presenter
        mov     rcx, [r12 + CFG_HWND]
        mov     edx, 1280
        mov     r8d, 800
        call    vk_app_present_init
        test    eax, eax
        jnz     .present_ok
        call    vk_app_log_present_failure
        call    vk_app_shutdown_all
        xor     eax, eax
        jmp     .done
.present_ok:

        mov     rcx, [r12 + CFG_DIAG_DIR]
        call    vk_app_diag_init
        call    vk_app_quit_requested
        test    eax, eax
        jz      .diag_live
        call    vk_app_shutdown_and_exit
.diag_live:

        mov     rcx, [r12 + CFG_HWND]
        mov     edx, [r12 + CFG_AUTO_PAUSE]
        mov     r8d, [r12 + CFG_AUTO_CLOSE]
        call    asm_lifecycle_start
        test    eax, eax
        jnz     .automation_ok
        call    vk_app_log_automation_failure
        call    vk_app_shutdown_all
        xor     eax, eax
        jmp     .done
.automation_ok:
        mov     ecx, [r12 + CFG_AUTO_PAUSE]
        mov     edx, [r12 + CFG_AUTO_CLOSE]
        call    vk_app_log_automation
        mov     eax, 1
.done:
        add     rsp, 0x28
        pop     r12
        pop     rbp
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
