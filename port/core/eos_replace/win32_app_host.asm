; win32_app_host.asm - shipped production host coordinator.
;
; This is the production replacement for app.cpp's host body.  It consumes
; the command-line values already parsed by win32_args.asm, preserves the
; existing logging/window/startup/seek/run/shutdown order, and leaves the
; complete C++ host in VOODKA_REFERENCE.exe as the differential oracle.

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

extern asm_log_init
extern vk_log_printf
extern asm_voodka_arg_libxmp
extern asm_voodka_arg_record
extern asm_voodka_arg_diag
extern asm_voodka_arg_music
extern asm_voodka_arg_timeline
extern asm_voodka_arg_auto_pause
extern asm_voodka_arg_auto_close
extern vk_app_resolve_music_path
extern asm_create_voodka_window
extern asm_shutdown_set_window
extern asm_shutdown_all
extern asm_voodka_initialize_subsystems
extern asm_voodka_apply_entry_seek
extern vk_arena_get
extern asm_voodka_run_mode

global asm_voodka_host_main

section .bss
align 8
app_startup_config: resb 64

section .data
app_session_message: db "---- VOODKA x64 port session ----", 10, 0
app_start_message:   db "[app] VOODKA x64 port starting", 10, 0
app_record_message:  db "[app] recording to '%s'", 10, 0
app_no_record:       db "[app] no --record", 10, 0
app_diag_message:    db "[app] readback diag to '%s'", 10, 0
app_timeline_message: db "[app] A/V timeline to '%s'", 10, 0
app_presenter_message: db "[app] native x64 assembly presenter selected (production default)", 10, 0
app_reference_audio_message: db "[app] --libxmp-audio reference path selected", 10, 0
app_assembly_audio_message: db "[app] dedicated assembly audio selected (default)", 10, 0
app_pause_message:    db "[app] auto-pause after %ld ms (resume after 1 s)", 10, 0
app_close_message:    db "[app] auto-close after %ld ms", 10, 0
app_window_failure:   db "[app] assembly window bootstrap failed", 10, 0

section .text

; int asm_voodka_host_main(HINSTANCE hInst, LPSTR ignoredCommandLine, int)
asm_voodka_host_main:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0x20                    ; RSP%16 == 0 at every CALL
        mov     r12, rcx                     ; HINSTANCE

        call    asm_log_init
        lea     rcx, [rel app_session_message]
        call    vk_log_printf
        lea     rcx, [rel app_start_message]
        call    vk_log_printf

        ; Fill the fixed startup record from assembly-owned argument storage.
        lea     r15, [rel app_startup_config]
        mov     [r15 + CFG_ASM_PRESENTER], dword 1

        call    asm_voodka_arg_record
        mov     [r15 + CFG_REC_DIR], rax
        test    rax, rax
        jz      .no_record
        lea     rcx, [rel app_record_message]
        mov     rdx, rax
        call    vk_log_printf
        jmp     .record_done
.no_record:
        lea     rcx, [rel app_no_record]
        call    vk_log_printf
.record_done:

        call    asm_voodka_arg_diag
        mov     [r15 + CFG_DIAG_DIR], rax
        test    rax, rax
        jz      .diag_done
        lea     rcx, [rel app_diag_message]
        mov     rdx, rax
        call    vk_log_printf
.diag_done:

        call    asm_voodka_arg_timeline
        mov     [r15 + CFG_TIMELINE_PATH], rax
        test    rax, rax
        jz      .timeline_done
        lea     rcx, [rel app_timeline_message]
        mov     rdx, rax
        call    vk_log_printf
.timeline_done:

        lea     rcx, [rel app_presenter_message]
        call    vk_log_printf

        call    asm_voodka_arg_libxmp
        and     eax, 1
        mov     [r15 + CFG_REFERENCE_AUDIO], eax
        mov     ecx, 1
        sub     ecx, eax
        mov     [r15 + CFG_ASM_AUDIO], ecx
        test    eax, eax
        jz      .assembly_audio
        lea     rcx, [rel app_reference_audio_message]
        call    vk_log_printf
        jmp     .audio_log_done
.assembly_audio:
        lea     rcx, [rel app_assembly_audio_message]
        call    vk_log_printf
.audio_log_done:

        call    asm_voodka_arg_auto_pause
        mov     [r15 + CFG_AUTO_PAUSE], eax
        test    eax, eax
        js      .pause_done
        lea     rcx, [rel app_pause_message]
        movsxd  rdx, eax
        call    vk_log_printf
.pause_done:

        call    asm_voodka_arg_auto_close
        mov     [r15 + CFG_AUTO_CLOSE], eax
        test    eax, eax
        js      .close_done
        lea     rcx, [rel app_close_message]
        movsxd  rdx, eax
        call    vk_log_printf
.close_done:

        call    asm_voodka_arg_music
        mov     rcx, rax
        call    vk_app_resolve_music_path
        mov     [r15 + CFG_MUSIC_PATH], rax

        mov     rcx, r12
        call    asm_create_voodka_window
        mov     r13, rax                     ; HWND
        test    r13, r13
        jnz     .window_ready
        lea     rcx, [rel app_window_failure]
        call    vk_log_printf
        call    asm_shutdown_all
        mov     eax, 1
        jmp     .done
.window_ready:
        mov     [r15 + CFG_HWND], r13
        mov     rcx, r13
        mov     rdx, r12
        call    asm_shutdown_set_window

        mov     rcx, r15
        call    asm_voodka_initialize_subsystems
        test    eax, eax
        jz      .done                       ; coordinator already rolled back

        call    asm_voodka_apply_entry_seek
        call    vk_arena_get
        mov     r14, rax
        mov     rcx, r14
        mov     edx, 0x04000000              ; 64 MiB arena contract
        call    asm_voodka_run_mode
        mov     r13d, eax                    ; application result
        call    asm_shutdown_all
        mov     eax, r13d
.done:
        add     rsp, 0x20
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbp
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
