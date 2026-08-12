; win32_arena.asm - production EOS arena and embedded archive service.
;
; The generated embedded_runtime.asm owns the byte-exact vodka.dat payload.
; This service exposes it as the archive source and keeps the existing EOS
; arena-offset/cache contract used by the demo core.  No runtime filesystem
; lookup is part of the shipped image.

BITS 64
DEFAULT REL

%include "win64_abi.inc"

%define kArenaSize              0x04000000
%define kArenaCursorStart       0x00040000

%define MEM_COMMIT              0x00001000
%define MEM_RESERVE             0x00002000
%define MEM_RELEASE             0x00008000
%define PAGE_READWRITE          4

extern VirtualAlloc
extern VirtualFree
extern MessageBoxA
extern ExitProcess
extern voodka_embedded_archive
extern voodka_embedded_archive_size

global asm_arena_platform_init
global asm_arena_platform_shutdown
global asm_arena_base
global asm_arena_alloc
global asm_arena_free
global asm_arena_load_internal_file
global asm_arena_archive_base
global asm_arena_archive_size
global asm_arena_archive_path

section .bss
align 8
asm_arena_base_ptr:       resq 1
asm_arena_archive_ptr:    resq 1
asm_arena_cursor:         resd 1
asm_arena_archive_bytes:  resd 1
asm_arena_cached_file:    resd 1

section .rdata
arena_name_voodka: db "voodka.dat", 0
arena_name_vodka:  db "vodka.dat", 0
arena_embedded_path: db "embedded:vodka.dat", 0
arena_no_memory:   db "VOODKA arena exhausted; refusing to grow.", 0
arena_title:       db "arena", 0

section .text

; int arena_equal_ci(const char* left, const char* right)
arena_equal_ci:
        push    rbp
        mov     rbp, rsp
        xor     eax, eax
.loop:
        mov     r8b, [rcx]
        mov     r9b, [rdx]
        movzx   r10d, r8b
        sub     r10d, 'A'
        cmp     r10d, 'Z' - 'A'
        ja      .left_ready
        add     r8b, 'a' - 'A'
.left_ready:
        movzx   r10d, r9b
        sub     r10d, 'A'
        cmp     r10d, 'Z' - 'A'
        ja      .right_ready
        add     r9b, 'a' - 'A'
.right_ready:
        cmp     r8b, r9b
        jne     .done
        test    r8b, r8b
        je      .equal
        inc     rcx
        inc     rdx
        jmp     .loop
.equal:
        mov     eax, 1
.done:
        pop     rbp
        ret

; int asm_arena_platform_init(const char* repositoryRoot)
; repositoryRoot is retained in the ABI for the reference bridge, but the
; production service intentionally ignores it: the archive is in this image.
asm_arena_platform_init:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20                    ; aligned before VirtualAlloc
        cmp     qword [rel asm_arena_base_ptr], 0
        jne     .already_ready

        xor     ecx, ecx
        mov     edx, kArenaSize
        mov     r8d, MEM_RESERVE | MEM_COMMIT
        mov     r9d, PAGE_READWRITE
        call    VirtualAlloc
        test    rax, rax
        jz      .failed
        mov     [rel asm_arena_base_ptr], rax
        mov     dword [rel asm_arena_cursor], kArenaCursorStart
        mov     dword [rel asm_arena_cached_file], 0
        lea     rax, [rel voodka_embedded_archive]
        mov     [rel asm_arena_archive_ptr], rax
        mov     eax, dword [rel voodka_embedded_archive_size]
        mov     [rel asm_arena_archive_bytes], eax
        mov     eax, 1
        jmp     .return

.already_ready:
        mov     eax, 1
        jmp     .return
.failed:
        xor     eax, eax
.return:
        add     rsp, 0x20
        pop     rbp
        ret

; void asm_arena_platform_shutdown(void)
asm_arena_platform_shutdown:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20
        mov     rcx, [rel asm_arena_base_ptr]
        test    rcx, rcx
        jz      .clear
        xor     edx, edx
        mov     r8d, MEM_RELEASE
        call    VirtualFree
.clear:
        mov     qword [rel asm_arena_base_ptr], 0
        mov     qword [rel asm_arena_archive_ptr], 0
        mov     dword [rel asm_arena_cursor], 0
        mov     dword [rel asm_arena_archive_bytes], 0
        mov     dword [rel asm_arena_cached_file], 0
        add     rsp, 0x20
        pop     rbp
        ret

; uint8_t* asm_arena_base(void)
asm_arena_base:
        mov     rax, [rel asm_arena_base_ptr]
        ret

; uint32_t asm_arena_alloc(uint32_t bytes)
asm_arena_alloc:
        push    rbp
        mov     rbp, rsp
        push    rdi
        sub     rsp, 0x28
        add     ecx, 15
        jc      .exhausted
        and     ecx, ~15
        mov     eax, [rel asm_arena_cursor]
        mov     [rsp], eax
        mov     edx, eax
        add     edx, ecx
        jc      .exhausted
        cmp     edx, kArenaSize
        ja      .exhausted
        mov     [rel asm_arena_cursor], edx
        mov     r8, [rel asm_arena_base_ptr]
        test    r8, r8
        jz      .return
        lea     rdi, [r8 + rax]
        xor     edx, edx
        mov     r8d, ecx
        mov     ecx, r8d
        xor     eax, eax
        cld
        rep     stosb
        mov     eax, [rsp]
        jmp     .done
.return:
        xor     eax, eax
.done:
        add     rsp, 0x28
        pop     rdi
        pop     rbp
        ret
.exhausted:
        xor     ecx, ecx
        lea     rdx, [rel arena_no_memory]
        lea     r8, [rel arena_title]
        mov     r9d, 0x10
        call    MessageBoxA
        mov     ecx, 1
        call    ExitProcess
        xor     eax, eax
        jmp     .done

; void asm_arena_free(uint32_t offset) -- bump allocator, intentionally no-op.
asm_arena_free:
        ret

; uint32_t asm_arena_load_internal_file(const char* name)
asm_arena_load_internal_file:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    rdi
        push    rsi
        sub     rsp, 0x38
        mov     r12, rcx
        mov     rdx, r12
        lea     rcx, [rel arena_name_voodka]
        call    arena_equal_ci
        test    eax, eax
        jnz     .known
        mov     rdx, r12
        lea     rcx, [rel arena_name_vodka]
        call    arena_equal_ci
        test    eax, eax
        jz      .unknown
.known:
        mov     eax, [rel asm_arena_cached_file]
        test    eax, eax
        jnz     .return
        mov     ecx, [rel asm_arena_archive_bytes]
        mov     [rsp + 0x20], ecx
        call    asm_arena_alloc
        mov     [rel asm_arena_cached_file], eax
        mov     r10d, [rsp + 0x20]
        mov     r11d, eax
        mov     r8, [rel asm_arena_base_ptr]
        lea     rdi, [r8 + rax]
        mov     rsi, [rel asm_arena_archive_ptr]
        test    r10d, r10d
        jz      .copy_done
        mov     ecx, r10d
        cld
        rep     movsb
.copy_done:
        mov     eax, r11d
        jmp     .return
.unknown:
        xor     eax, eax
.return:
        add     rsp, 0x38
        pop     rsi
        pop     rdi
        pop     r12
        pop     rbp
        ret

; const void* asm_arena_archive_base(void)
asm_arena_archive_base:
        mov     rax, [rel asm_arena_archive_ptr]
        ret

; uint32_t asm_arena_archive_size(void)
asm_arena_archive_size:
        mov     eax, [rel asm_arena_archive_bytes]
        ret

; const char* asm_arena_archive_path(void)
asm_arena_archive_path:
        lea     rax, [rel arena_embedded_path]
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
