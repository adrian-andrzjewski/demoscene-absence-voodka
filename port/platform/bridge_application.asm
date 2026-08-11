; bridge_application.asm - shipped application/startup bridge.
;
; This replaces the production bridge.cpp body.  Every operation below is a
; narrow C ABI service used by the NASM host/core, and every implementation it
; forwards to is already native assembly.  The C++ bridge remains in the
; reference executable as the behavioral oracle.

BITS 64
DEFAULT REL

%include "win64_abi.inc"

extern ?audioSeekRows@vk@@YAII@Z
extern ?audioSeekMs@vk@@YAIH@Z
extern ?audioSeekOrder@vk@@YAIH@Z
extern ?progressInit@vk@@YAXPEAX@Z
extern ?inputInit@vk@@YA_NPEAX@Z
extern ?platformInit@vk@@YA_NXZ
extern ?quitRequested@vk@@YA_NXZ
extern ?timerInit@vk@@YAXXZ
extern ?timelineInit@vk@@YAXPEBD@Z
extern ?recInit@vk@@YAXPEBD@Z
extern ?audioSetAssemblyMode@vk@@YAX_N@Z
extern ?audioInit@vk@@YAHPEBDH@Z
extern ?setAssemblyPresenter@vk@@YAX_N@Z
extern ?initPresent@vk@@YA_NPEAXHH@Z
extern ?diagReadbackInit@vk@@YAXPEBD@Z
extern ?selfTestPattern@vk@@YAXXZ
extern ?diagReadbackEnabled@vk@@YA_NXZ
extern ?presentFrame@vk@@YAXXZ
extern ?audioSelfCheck@vk@@YAHH@Z
extern ?keyDown@vk@@YAXE@Z
extern ?keyUp@vk@@YAXE@Z
extern ?pauseToggle@vk@@YAXXZ
extern ?requestQuit@vk@@YAXXZ
extern ?updateInput@vk@@YAXXZ
extern asm_shutdown_all
extern asm_shutdown_and_exit
extern asm_voodka_resolve_music_path
extern vk_log_printf

global vk_app_seek_modpos
global vk_app_seek_ms
global vk_app_seek_order
global vk_app_seek_part
global vk_app_seek_scene
global vk_scene_part_from_name
global vk_app_no_entry_seek
global vk_app_log_selftest
global vk_app_selftest_pattern
global vk_app_diag_readback_enabled
global vk_app_present_frame
global vk_app_log_audio_check
global vk_app_audio_self_check
global vk_app_log_demo_start
global vk_app_progress_init
global vk_app_input_init
global vk_app_platform_init
global vk_app_quit_requested
global vk_app_shutdown_all
global vk_app_shutdown_and_exit
global ?shutdownAll@vk@@YAXXZ
global ?shutdownAndExit@vk@@YAXXZ
global vk_app_timer_init
global vk_app_timeline_init
global vk_app_rec_init
global vk_app_log_music
global vk_app_audio_set_mode
global vk_app_audio_init
global vk_app_log_input_failure
global vk_app_log_arena_failure
global vk_app_log_audio_failure
global vk_app_set_assembly_presenter
global vk_app_present_init
global vk_app_diag_init
global vk_app_log_present_failure
global vk_app_log_automation_failure
global vk_app_log_automation
global vk_app_resolve_music_path
global vk_set_entry_scene
global vk_get_entry_scene
global vk_key_down
global vk_key_up
global vk_pause_toggle
global vk_request_quit
global vk_platform_update_input
global vk_platform_quit_requested

section .bss
align 4
app_entry_scene: resd 1

section .rdata
app_empty_string: db 0
app_none_string: db '(none)', 0
app_unknown_scene: db 'unknown scene', 0
app_enabled_string: db 'enabled', 0
app_off_string: db 'off', 0

app_seek_modpos_format: db '[app] seek --modpos %ld -> reached ModPos %u', 10, 0
app_seek_ms_format: db '[app] seek --ms %ld -> reached ModPos %u', 10, 0
app_seek_order_format: db '[app] seek --order %ld -> reached ModPos %u', 10, 0
app_seek_part_format: db '[app] seek --part %ld (%s) -> ModPos 0x%x reached %u', 10, 0
app_seek_scene_format: db '[app] seek --scene %s -> ModPos 0x%x reached %u', 10, 0
app_no_seek_format: db '[app] no entry seek (module starts at beginning)', 10, 0
app_selftest_format: db '[app] SELF-TEST: rendering known pattern', 10, 0
app_audio_check_format: db '[app] AUDIO CHECK: running %d s', 10, 0
app_demo_start_format: db '[app] arena=%p starting demo core', 10, 0
app_music_format: db "[app] music module: '%s'", 10, 0
app_input_failure_format: db '[app] input watcher init failed', 10, 0
app_arena_failure_format: db '[app] arena init failed', 10, 0
app_reference_audio_failure: db '[app] reference audio initialization failed', 10, 0
app_assembly_audio_failure: db '[app] assembly audio initialization failed', 10, 0
app_present_failure_format: db '[app] D3D11 init failed', 10, 0
app_automation_failure_format: db '[app] lifecycle automation initialization failed', 10, 0
app_automation_format: db '[app] lifecycle automation: pause=%s close=%s', 10, 0

scene_oko:          db 'oko + szklo', 0
scene_swiatynia:    db 'swiatynia city', 0
scene_tunel:        db 'tunel + wygibasy', 0
scene_processorek:  db 'processorek Nevosolek', 0
scene_torus:        db 'torus ustep village', 0
scene_gratki:       db 'gratki', 0
scene_gratki_woda:  db 'gratki + woda', 0
scene_lampa:        db 'nad czerwonym lampa', 0

scene_name_table:
        dq 0
        dq scene_oko
        dq scene_swiatynia
        dq scene_tunel
        dq scene_processorek
        dq scene_torus
        dq scene_gratki
        dq scene_gratki_woda
        dq scene_lampa

scene_token_oko:         db 'oko-szklo', 0
scene_token_swiatynia:   db 'swiatynia-city', 0
scene_token_tunel:       db 'tunel-wygibasy', 0
scene_token_processorek: db 'processorek-nevosolek', 0
scene_token_torus:       db 'torus-ustep-village', 0
scene_token_gratki:      db 'gratki', 0
scene_token_woda:        db 'gratki-woda', 0
scene_token_lampa:       db 'nad-czerwonym-lampa', 0

section .text

; int scene_token_equals(const char* token, const char* expected)
scene_token_equals:
        xor     eax, eax
.compare:
        mov     r8b, [rcx]
        mov     r9b, [rdx]
        cmp     r8b, '_'
        jne     .token_not_underscore
        mov     r8b, '-'
.token_not_underscore:
        cmp     r9b, '_'
        jne     .expected_not_underscore
        mov     r9b, '-'
.expected_not_underscore:
        movzx   r10d, r8b
        sub     r10d, 'A'
        cmp     r10d, 'Z' - 'A'
        ja      .token_lower
        add     r8b, 'a' - 'A'
.token_lower:
        movzx   r10d, r9b
        sub     r10d, 'A'
        cmp     r10d, 'Z' - 'A'
        ja      .expected_lower
        add     r9b, 'a' - 'A'
.expected_lower:
        cmp     r8b, r9b
        jne     .not_equal
        test    r8b, r8b
        je      .equal
        inc     rcx
        inc     rdx
        jmp     .compare
.equal:
        mov     eax, 1
.not_equal:
        ret

; const char* scene_name_for_part(uint32_t part)
scene_name_for_part:
        cmp     ecx, 8
        ja      .unknown
        lea     rax, [rel scene_name_table]
        mov     rax, [rax + rcx * 8]
        test    rax, rax
        jnz     .done
.unknown:
        lea     rax, [rel app_unknown_scene]
.done:
        ret

; uint32_t vk_app_seek_modpos(uint32_t requested)
vk_app_seek_modpos:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        sub     rsp, 0x20
        mov     r12d, ecx
        call    ?audioSeekRows@vk@@YAII@Z
        mov     r13d, eax
        lea     rcx, [rel app_seek_modpos_format]
        movsxd  rdx, r12d
        mov     r8d, r13d
        call    vk_log_printf
        mov     eax, r13d
        add     rsp, 0x20
        pop     r13
        pop     r12
        pop     rbp
        ret

; uint32_t vk_app_seek_ms(int ms)
vk_app_seek_ms:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        sub     rsp, 0x20
        mov     r12d, ecx
        call    ?audioSeekMs@vk@@YAIH@Z
        mov     r13d, eax
        lea     rcx, [rel app_seek_ms_format]
        movsxd  rdx, r12d
        mov     r8d, r13d
        call    vk_log_printf
        mov     eax, r13d
        add     rsp, 0x20
        pop     r13
        pop     r12
        pop     rbp
        ret

; uint32_t vk_app_seek_order(int order)
vk_app_seek_order:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        sub     rsp, 0x20
        mov     r12d, ecx
        call    ?audioSeekOrder@vk@@YAIH@Z
        mov     r13d, eax
        lea     rcx, [rel app_seek_order_format]
        movsxd  rdx, r12d
        mov     r8d, r13d
        call    vk_log_printf
        mov     eax, r13d
        add     rsp, 0x20
        pop     r13
        pop     r12
        pop     rbp
        ret

; void vk_app_seek_part(uint32_t part, uint32_t modpos)
vk_app_seek_part:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        push    r14
        sub     rsp, 0x28
        mov     r12d, ecx
        mov     r13d, edx
        mov     ecx, r13d
        call    ?audioSeekRows@vk@@YAII@Z
        mov     r14d, eax
        mov     ecx, r12d
        call    scene_name_for_part
        mov     r10, rax
        lea     rcx, [rel app_seek_part_format]
        movsxd  rdx, r12d
        mov     r8, r10
        mov     r9d, r13d
        mov     dword [rsp + 0x20], r14d
        call    vk_log_printf
        mov     ecx, r12d
        call    vk_set_entry_scene
        mov     eax, r14d
        add     rsp, 0x28
        pop     r14
        pop     r13
        pop     r12
        pop     rbp
        ret

; void vk_app_seek_scene(uint32_t part, uint32_t modpos)
vk_app_seek_scene:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        push    r14
        sub     rsp, 0x28
        mov     r12d, ecx
        mov     r13d, edx
        mov     ecx, r13d
        call    ?audioSeekRows@vk@@YAII@Z
        mov     r14d, eax
        mov     ecx, r12d
        call    scene_name_for_part
        mov     r10, rax
        lea     rcx, [rel app_seek_scene_format]
        mov     rdx, r10
        mov     r8d, r13d
        mov     r9d, r14d
        call    vk_log_printf
        mov     ecx, r12d
        call    vk_set_entry_scene
        mov     eax, r14d
        add     rsp, 0x28
        pop     r14
        pop     r13
        pop     r12
        pop     rbp
        ret

; int vk_scene_part_from_name(const char* token)
vk_scene_part_from_name:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20
        mov     [rbp - 8], rcx
        test    rcx, rcx
        jz      .scene_zero

        mov     rcx, [rbp - 8]
        lea     rdx, [rel scene_token_oko]
        call    scene_token_equals
        test    eax, eax
        jnz     .scene_one
        mov     rcx, [rbp - 8]
        lea     rdx, [rel scene_token_swiatynia]
        call    scene_token_equals
        test    eax, eax
        jnz     .scene_two
        mov     rcx, [rbp - 8]
        lea     rdx, [rel scene_token_tunel]
        call    scene_token_equals
        test    eax, eax
        jnz     .scene_three
        mov     rcx, [rbp - 8]
        lea     rdx, [rel scene_token_processorek]
        call    scene_token_equals
        test    eax, eax
        jnz     .scene_four
        mov     rcx, [rbp - 8]
        lea     rdx, [rel scene_token_torus]
        call    scene_token_equals
        test    eax, eax
        jnz     .scene_five
        mov     rcx, [rbp - 8]
        lea     rdx, [rel scene_token_gratki]
        call    scene_token_equals
        test    eax, eax
        jnz     .scene_six
        mov     rcx, [rbp - 8]
        lea     rdx, [rel scene_token_woda]
        call    scene_token_equals
        test    eax, eax
        jnz     .scene_seven
        mov     rcx, [rbp - 8]
        lea     rdx, [rel scene_token_lampa]
        call    scene_token_equals
        test    eax, eax
        jnz     .scene_eight
.scene_zero:
        xor     eax, eax
        jmp     .scene_done
.scene_one:
        mov     eax, 1
        jmp     .scene_done
.scene_two:
        mov     eax, 2
        jmp     .scene_done
.scene_three:
        mov     eax, 3
        jmp     .scene_done
.scene_four:
        mov     eax, 4
        jmp     .scene_done
.scene_five:
        mov     eax, 5
        jmp     .scene_done
.scene_six:
        mov     eax, 6
        jmp     .scene_done
.scene_seven:
        mov     eax, 7
        jmp     .scene_done
.scene_eight:
        mov     eax, 8
.scene_done:
        add     rsp, 0x20
        pop     rbp
        ret

vk_app_no_entry_seek:
        sub     rsp, 0x28
        lea     rcx, [rel app_no_seek_format]
        call    vk_log_printf
        add     rsp, 0x28
        ret

vk_app_log_selftest:
        sub     rsp, 0x28
        lea     rcx, [rel app_selftest_format]
        call    vk_log_printf
        add     rsp, 0x28
        ret

vk_app_selftest_pattern:
        jmp     ?selfTestPattern@vk@@YAXXZ

vk_app_diag_readback_enabled:
        sub     rsp, 0x28
        call    ?diagReadbackEnabled@vk@@YA_NXZ
        movzx   eax, al
        add     rsp, 0x28
        ret

vk_app_present_frame:
        jmp     ?presentFrame@vk@@YAXXZ

vk_app_log_audio_check:
        sub     rsp, 0x28
        mov     edx, ecx
        lea     rcx, [rel app_audio_check_format]
        call    vk_log_printf
        add     rsp, 0x28
        ret

vk_app_audio_self_check:
        jmp     ?audioSelfCheck@vk@@YAHH@Z

vk_app_log_demo_start:
        sub     rsp, 0x28
        mov     rdx, rcx
        lea     rcx, [rel app_demo_start_format]
        call    vk_log_printf
        add     rsp, 0x28
        ret

vk_app_progress_init:
        jmp     ?progressInit@vk@@YAXPEAX@Z

vk_app_input_init:
        sub     rsp, 0x28
        call    ?inputInit@vk@@YA_NPEAX@Z
        movzx   eax, al
        add     rsp, 0x28
        ret

vk_app_platform_init:
        sub     rsp, 0x28
        call    ?platformInit@vk@@YA_NXZ
        movzx   eax, al
        add     rsp, 0x28
        ret

vk_app_quit_requested:
        sub     rsp, 0x28
        call    ?quitRequested@vk@@YA_NXZ
        movzx   eax, al
        add     rsp, 0x28
        ret

vk_app_shutdown_all:
?shutdownAll@vk@@YAXXZ:
        jmp     asm_shutdown_all

vk_app_shutdown_and_exit:
?shutdownAndExit@vk@@YAXXZ:
        jmp     asm_shutdown_and_exit

vk_app_timer_init:
        jmp     ?timerInit@vk@@YAXXZ

vk_app_timeline_init:
        jmp     ?timelineInit@vk@@YAXPEBD@Z

vk_app_rec_init:
        jmp     ?recInit@vk@@YAXPEBD@Z

vk_app_log_music:
        sub     rsp, 0x28
        mov     rdx, rcx
        test    rcx, rcx
        jz      .music_none
        cmp     byte [rcx], 0
        jnz     .music_log
.music_none:
        lea     rdx, [rel app_none_string]
.music_log:
        lea     rcx, [rel app_music_format]
        call    vk_log_printf
        add     rsp, 0x28
        ret

vk_app_audio_set_mode:
        jmp     ?audioSetAssemblyMode@vk@@YAX_N@Z

vk_app_audio_init:
        test    rcx, rcx
        jnz     .audio_path_ready
        lea     rcx, [rel app_empty_string]
.audio_path_ready:
        jmp     ?audioInit@vk@@YAHPEBDH@Z

vk_app_log_input_failure:
        sub     rsp, 0x28
        lea     rcx, [rel app_input_failure_format]
        call    vk_log_printf
        add     rsp, 0x28
        ret

vk_app_log_arena_failure:
        sub     rsp, 0x28
        lea     rcx, [rel app_arena_failure_format]
        call    vk_log_printf
        add     rsp, 0x28
        ret

vk_app_log_audio_failure:
        sub     rsp, 0x28
        test    ecx, ecx
        jz      .assembly_failure
        lea     rcx, [rel app_reference_audio_failure]
        jmp     .audio_failure_log
.assembly_failure:
        lea     rcx, [rel app_assembly_audio_failure]
.audio_failure_log:
        call    vk_log_printf
        add     rsp, 0x28
        ret

vk_app_set_assembly_presenter:
        jmp     ?setAssemblyPresenter@vk@@YAX_N@Z

vk_app_present_init:
        sub     rsp, 0x28
        call    ?initPresent@vk@@YA_NPEAXHH@Z
        movzx   eax, al
        add     rsp, 0x28
        ret

vk_app_diag_init:
        jmp     ?diagReadbackInit@vk@@YAXPEBD@Z

vk_app_log_present_failure:
        sub     rsp, 0x28
        lea     rcx, [rel app_present_failure_format]
        call    vk_log_printf
        add     rsp, 0x28
        ret

vk_app_log_automation_failure:
        sub     rsp, 0x28
        lea     rcx, [rel app_automation_failure_format]
        call    vk_log_printf
        add     rsp, 0x28
        ret

vk_app_log_automation:
        sub     rsp, 0x28
        mov     r9d, edx
        test    ecx, ecx
        jns     .pause_enabled
        lea     rdx, [rel app_off_string]
        jmp     .pause_ready
.pause_enabled:
        lea     rdx, [rel app_enabled_string]
.pause_ready:
        test    r9d, r9d
        jns     .close_enabled
        lea     r8, [rel app_off_string]
        jmp     .automation_log
.close_enabled:
        lea     r8, [rel app_enabled_string]
.automation_log:
        lea     rcx, [rel app_automation_format]
        call    vk_log_printf
        add     rsp, 0x28
        ret

vk_app_resolve_music_path:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20
        lea     rdx, [rel voodka_repo_root]
        call    asm_voodka_resolve_music_path
        add     rsp, 0x20
        pop     rbp
        ret

vk_set_entry_scene:
        mov     [rel app_entry_scene], ecx
        ret

vk_get_entry_scene:
        mov     eax, [rel app_entry_scene]
        ret

vk_key_down:
        movzx   ecx, cl
        jmp     ?keyDown@vk@@YAXE@Z

vk_key_up:
        movzx   ecx, cl
        jmp     ?keyUp@vk@@YAXE@Z

vk_pause_toggle:
        jmp     ?pauseToggle@vk@@YAXXZ

vk_request_quit:
        jmp     ?requestQuit@vk@@YAXXZ

vk_platform_update_input:
        jmp     ?updateInput@vk@@YAXXZ

vk_platform_quit_requested:
        sub     rsp, 0x28
        call    ?quitRequested@vk@@YA_NXZ
        movzx   eax, al
        add     rsp, 0x28
        ret

section .rdata
%include "voodka_repo_root.inc"

section .note.GNU-stack noalloc noexec nowrite progbits
