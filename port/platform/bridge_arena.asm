; bridge_arena.asm - production vk::arena namespace ABI.
;
; The shipped target's arena implementation is already native in
; win32_arena.asm.  This file replaces the last C++ namespace veneer while
; retaining its decorated MSVC ABI and diagnostic behavior.

BITS 64
DEFAULT REL

%include "win64_abi.inc"

extern asm_arena_platform_init
extern asm_arena_platform_shutdown
extern asm_arena_base
extern asm_arena_alloc
extern asm_arena_free
extern asm_arena_load_internal_file
extern asm_arena_archive_base
extern asm_arena_archive_size
extern asm_arena_archive_path
extern vk_log_printf

global ?kFramebufferOffset@vk@@3IB
global ?kBackbufferOffset@vk@@3IB
global ?arena@vk@@YAPEAEXZ
global ?platformInit@vk@@YA_NXZ
global ?platformShutdown@vk@@YAXXZ
global ?arenaAlloc@vk@@YAII@Z
global ?arenaFree@vk@@YAXI@Z
global ?loadInternalFile@vk@@YAIPEBD@Z
global ?archiveBytes@vk@@YAPEBXXZ
global ?archiveSize@vk@@YA_KXZ

section .rdata
align 4
?kFramebufferOffset@vk@@3IB: dd 0x00020000
?kBackbufferOffset@vk@@3IB:   dd 0x00010000

arena_loaded_format: db "[arena] loaded archive %s (%u bytes)", 10, 0
arena_ready_format: db "[arena] arena ready, 64 MB, base=%p", 10, 0
arena_missing_format: db "[arena] warning: archive not found", 10, 0
arena_unknown_format: db "[arena] loadInternalFile: unknown internal file '%s'", 10, 0
arena_null_name: db "(null)", 0

section .text

; uint8_t* vk::arena(void)
?arena@vk@@YAPEAEXZ:
        jmp     asm_arena_base

; bool vk::platformInit(void)
?platformInit@vk@@YA_NXZ:
        push    rbp
        mov     rbp, rsp
        push    r12
        sub     rsp, 0x28

        xor     ecx, ecx                    ; repository fallback is unused
        call    asm_arena_platform_init
        test    eax, eax
        jz      .failed

        call    asm_arena_archive_size
        test    eax, eax
        jz      .missing
        mov     r12d, eax
        call    asm_arena_archive_path
        mov     rdx, rax
        mov     r8d, r12d
        lea     rcx, [rel arena_loaded_format]
        call    vk_log_printf
        call    asm_arena_base
        mov     rdx, rax
        lea     rcx, [rel arena_ready_format]
        call    vk_log_printf
        mov     eax, 1
        jmp     .done

.missing:
        lea     rcx, [rel arena_missing_format]
        call    vk_log_printf
        mov     eax, 1
        jmp     .done

.failed:
        xor     eax, eax
.done:
        add     rsp, 0x28
        pop     r12
        pop     rbp
        ret

; void vk::platformShutdown(void)
?platformShutdown@vk@@YAXXZ:
        jmp     asm_arena_platform_shutdown

; uint32_t vk::arenaAlloc(uint32_t bytes)
?arenaAlloc@vk@@YAII@Z:
        jmp     asm_arena_alloc

; void vk::arenaFree(uint32_t offset)
?arenaFree@vk@@YAXI@Z:
        jmp     asm_arena_free

; uint32_t vk::loadInternalFile(const char* name)
?loadInternalFile@vk@@YAIPEBD@Z:
        push    rbp
        mov     rbp, rsp
        push    r12
        sub     rsp, 0x28
        mov     r12, rcx
        call    asm_arena_load_internal_file
        test    eax, eax
        jnz     .done

        mov     rdx, r12
        test    r12, r12
        jnz     .have_name
        lea     rdx, [rel arena_null_name]
.have_name:
        lea     rcx, [rel arena_unknown_format]
        call    vk_log_printf
        xor     eax, eax
.done:
        add     rsp, 0x28
        pop     r12
        pop     rbp
        ret

; const void* vk::archiveBytes(void)
?archiveBytes@vk@@YAPEBXXZ:
        jmp     asm_arena_archive_base

; size_t vk::archiveSize(void)
?archiveSize@vk@@YA_KXZ:
        jmp     asm_arena_archive_size

section .note.GNU-stack noalloc noexec nowrite progbits
