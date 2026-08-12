; win32_arena.asm - production EOS arena and compressed archive service.
;
; The generated embedded_runtime.asm owns the single compressed VPK1 payload.
; This service decodes vodka.dat into its final arena allocation and keeps the
; existing EOS arena-offset/cache contract used by the demo core.  No runtime
; filesystem lookup is part of the shipped image.

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
extern voodka_embedded_payload
extern voodka_embedded_payload_size
extern voodka_embedded_archive_size
extern voodka_embedded_module_size
extern voodka_embedded_module_decoded
extern voodka_decode_embedded_asset

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
arena_embedded_path: db "embedded:vodka.dat", 0
arena_no_memory:   db "VOODKA arena exhausted; refusing to grow.", 0
arena_title:       db "arena", 0

section .text

; int asm_arena_platform_init(const char* repositoryRoot)
; repositoryRoot is retained in the ABI for the reference bridge, but the
; production service intentionally ignores it: the archive is in this image.
asm_arena_platform_init:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x30                    ; aligned, with stack arg for decoder
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

        ; Allocate and decode the archive directly into the arena.  The
        ; decompressed bytes are now the one runtime copy used by the demo.
        mov     ecx, dword [rel voodka_embedded_archive_size]
        call    asm_arena_alloc
        mov     dword [rel asm_arena_cached_file], eax
        mov     r10, [rel asm_arena_base_ptr]
        mov     edx, dword [rel asm_arena_cached_file]
        add     r10, rdx
        mov     [rel asm_arena_archive_ptr], r10
        mov     eax, dword [rel voodka_embedded_archive_size]
        mov     [rel asm_arena_archive_bytes], eax
        mov     ecx, 1                       ; VPK1 asset id: vodka.dat
        lea     rdx, [rel voodka_embedded_payload]
        mov     r8d, dword [rel voodka_embedded_payload_size]
        mov     r9, r10
        mov     eax, dword [rel asm_arena_archive_bytes]
        mov     dword [rsp + 0x20], eax
        call    voodka_decode_embedded_asset
        test    eax, eax
        jz      .decode_failed

        ; Decode the module once into its persistent BSS destination.  The
        ; audio service retains this pointer for the complete soundtrack.
        mov     ecx, 2                       ; VPK1 asset id: amnezja2.mod
        lea     rdx, [rel voodka_embedded_payload]
        mov     r8d, dword [rel voodka_embedded_payload_size]
        lea     r9, [rel voodka_embedded_module_decoded]
        mov     eax, dword [rel voodka_embedded_module_size]
        mov     dword [rsp + 0x20], eax
        call    voodka_decode_embedded_asset
        test    eax, eax
        jz      .decode_failed
        mov     eax, 1
        jmp     .return

.already_ready:
        mov     eax, 1
        jmp     .return
.failed:
        xor     eax, eax
.decode_failed:
        mov     rcx, [rel asm_arena_base_ptr]
        test    rcx, rcx
        jz      .clear_failed
        xor     edx, edx
        mov     r8d, MEM_RELEASE
        call    VirtualFree
.clear_failed:
        mov     qword [rel asm_arena_base_ptr], 0
        mov     qword [rel asm_arena_archive_ptr], 0
        mov     dword [rel asm_arena_cursor], 0
        mov     dword [rel asm_arena_archive_bytes], 0
        mov     dword [rel asm_arena_cached_file], 0
.return:
        add     rsp, 0x30
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
        test    r12, r12
        jz      .unknown

        ; Accept both historical spellings, case-insensitively, without a
        ; helper call or a runtime string copy.
        movzx   eax, byte [r12 + 0]
        or      al, 0x20
        cmp     al, 'v'
        jne     .unknown
        movzx   eax, byte [r12 + 1]
        or      al, 0x20
        cmp     al, 'o'
        jne     .unknown
        movzx   eax, byte [r12 + 2]
        or      al, 0x20
        cmp     al, 'o'
        je      .long_name
        cmp     al, 'd'
        jne     .unknown

        ; vodka.dat
        movzx   eax, byte [r12 + 3]
        or      al, 0x20
        cmp     al, 'k'
        jne     .unknown
        movzx   eax, byte [r12 + 4]
        or      al, 0x20
        cmp     al, 'a'
        jne     .unknown
        cmp     byte [r12 + 5], '.'
        jne     .unknown
        movzx   eax, byte [r12 + 6]
        or      al, 0x20
        cmp     al, 'd'
        jne     .unknown
        movzx   eax, byte [r12 + 7]
        or      al, 0x20
        cmp     al, 'a'
        jne     .unknown
        movzx   eax, byte [r12 + 8]
        or      al, 0x20
        cmp     al, 't'
        jne     .unknown
        cmp     byte [r12 + 9], 0
        je      .known
        jmp     .unknown

.long_name:
        ; voodka.dat
        movzx   eax, byte [r12 + 3]
        or      al, 0x20
        cmp     al, 'd'
        jne     .unknown
        movzx   eax, byte [r12 + 4]
        or      al, 0x20
        cmp     al, 'k'
        jne     .unknown
        movzx   eax, byte [r12 + 5]
        or      al, 0x20
        cmp     al, 'a'
        jne     .unknown
        cmp     byte [r12 + 6], '.'
        jne     .unknown
        movzx   eax, byte [r12 + 7]
        or      al, 0x20
        cmp     al, 'd'
        jne     .unknown
        movzx   eax, byte [r12 + 8]
        or      al, 0x20
        cmp     al, 'a'
        jne     .unknown
        movzx   eax, byte [r12 + 9]
        or      al, 0x20
        cmp     al, 't'
        jne     .unknown
        cmp     byte [r12 + 10], 0
        jne     .unknown
.known:
        mov     eax, [rel asm_arena_cached_file]
        test    eax, eax
        jnz     .return
        mov     rax, [rel asm_arena_archive_ptr]
        sub     rax, [rel asm_arena_base_ptr]
        mov     [rel asm_arena_cached_file], eax
        mov     eax, dword [rel asm_arena_cached_file]
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
