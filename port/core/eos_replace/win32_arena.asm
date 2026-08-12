; win32_arena.asm - production EOS arena and archive service.
;
; The reference target keeps the C++ vector/string implementation. The shipped
; target owns the 64 MiB linear arena, packaged vodka.dat loading, bump
; allocation, and Load_internal_file copy boundary here.

BITS 64
DEFAULT REL

%include "win64_abi.inc"

%define kArenaSize              0x04000000
%define kArenaCursorStart       0x00040000
%define kArenaPathCapacity      2048

%define GENERIC_READ            0x80000000
%define FILE_SHARE_READ         0x00000001
%define OPEN_EXISTING           3
%define FILE_ATTRIBUTE_NORMAL   0x00000080
%define INVALID_HANDLE_VALUE    0xFFFFFFFFFFFFFFFF

%define MEM_COMMIT              0x00001000
%define MEM_RESERVE             0x00002000
%define MEM_RELEASE             0x00008000
%define PAGE_READWRITE          4

extern GetModuleFileNameA
extern CreateFileA
extern GetFileSize
extern ReadFile
extern CloseHandle
extern VirtualAlloc
extern VirtualFree
extern MessageBoxA
extern ExitProcess

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
asm_arena_bytes_read:     resd 1
align 8
asm_arena_exe_path:       resb kArenaPathCapacity
asm_arena_candidate_path: resb kArenaPathCapacity

section .rdata
arena_suffix_data: db "data\vodka.dat", 0
arena_suffix_root: db "vodka.dat", 0
arena_suffix_dev:  db "\port\data\vodka.dat", 0
arena_name_voodka: db "voodka.dat", 0
arena_name_vodka:  db "vodka.dat", 0
arena_no_memory:   db "VOODKA arena exhausted; refusing to grow.", 0
arena_title:       db "arena", 0

section .text

; rax = strlen(rcx), excluding the terminating NUL.
arena_strlen:
        xor     eax, eax
.loop:
        cmp     byte [rcx + rax], 0
        je      .done
        inc     rax
        jmp     .loop
.done:
        ret

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

; void arena_build_path(const char* prefix, const char* suffix, char* out)
arena_build_path:
        push    rbp
        mov     rbp, rsp
        push    rdi
        push    rsi
        sub     rsp, 0x20
        mov     r10, rcx
        mov     r11, rdx
        mov     rdi, r8
        mov     rcx, r10
        call    arena_strlen
        mov     rcx, rax
        mov     rsi, r10
        cld
        rep     movsb
        mov     rcx, r11
        call    arena_strlen
        mov     rcx, rax
        mov     rsi, r11
        cld
        rep     movsb
        mov     byte [rdi], 0
        add     rsp, 0x20
        pop     rsi
        pop     rdi
        pop     rbp
        ret

; int arena_try_load(const char* path)
; Loads a complete archive into a private VirtualAlloc block. On success the
; path remains in asm_arena_candidate_path for diagnostics and oracle parity.
arena_try_load:
        push    rbp
        mov     rbp, rsp
        push    r12
        sub     rsp, 0x58                    ; aligned before every CALL
        mov     r12, rcx

        mov     rdx, GENERIC_READ
        mov     r8d, FILE_SHARE_READ
        xor     r9d, r9d
        mov     qword [rsp + 0x20], OPEN_EXISTING
        mov     qword [rsp + 0x28], FILE_ATTRIBUTE_NORMAL
        mov     qword [rsp + 0x30], 0
        mov     rcx, r12
        call    CreateFileA
        mov     [rsp + 0x38], rax
        cmp     rax, INVALID_HANDLE_VALUE
        je      .fail

        mov     rcx, rax
        xor     edx, edx
        call    GetFileSize
        cmp     eax, 0xFFFFFFFF
        je      .close_fail
        mov     dword [rsp + 0x40], eax
        test    eax, eax
        jz      .close_fail

        xor     ecx, ecx
        mov     edx, eax
        mov     r8d, MEM_RESERVE | MEM_COMMIT
        mov     r9d, PAGE_READWRITE
        call    VirtualAlloc
        mov     [rsp + 0x48], rax
        test    rax, rax
        jz      .close_fail

        mov     rcx, [rsp + 0x38]
        mov     rdx, rax
        mov     r8d, dword [rsp + 0x40]
        lea     r9, [rel asm_arena_bytes_read]
        mov     qword [rsp + 0x20], 0
        call    ReadFile
        test    eax, eax
        jz      .read_fail
        mov     eax, dword [rel asm_arena_bytes_read]
        cmp     eax, dword [rsp + 0x40]
        jne     .read_fail

        mov     rax, [rsp + 0x38]
        mov     rcx, rax
        call    CloseHandle
        mov     rax, [rsp + 0x48]
        mov     [rel asm_arena_archive_ptr], rax
        mov     eax, dword [rsp + 0x40]
        mov     [rel asm_arena_archive_bytes], eax
        mov     eax, 1
        jmp     .return

.read_fail:
        mov     rcx, [rsp + 0x48]
        xor     edx, edx
        mov     r8d, MEM_RELEASE
        call    VirtualFree
.close_fail:
        mov     rcx, [rsp + 0x38]
        call    CloseHandle
.fail:
        xor     eax, eax
.return:
        add     rsp, 0x58
        pop     r12
        pop     rbp
        ret

; int asm_arena_platform_init(const char* repositoryRoot)
asm_arena_platform_init:
        push    rbp
        mov     rbp, rsp
        push    rsi
        sub     rsp, 0x38                    ; aligned before every CALL
        mov     [rsp + 0x30], rcx
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
        mov     qword [rel asm_arena_archive_ptr], 0
        mov     dword [rel asm_arena_archive_bytes], 0

        xor     ecx, ecx
        lea     rdx, [rel asm_arena_exe_path]
        mov     r8d, kArenaPathCapacity
        call    GetModuleFileNameA
        test    eax, eax
        jz      .try_dev
        mov     r10d, eax
        cmp     r10d, kArenaPathCapacity - 1
        jb      .path_terminated
        mov     r10d, kArenaPathCapacity - 1
.path_terminated:
        lea     rsi, [rel asm_arena_exe_path]
        mov     byte [rsi + r10], 0

        ; Trim the executable filename, leaving a directory prefix.
        lea     rsi, [rel asm_arena_exe_path]
        mov     ecx, r10d
        test    ecx, ecx
        jz      .no_directory
.find_slash:
        dec     ecx
        js      .no_directory
        mov     al, [rsi + rcx]
        cmp     al, '\\'
        je      .slash_found
        cmp     al, '/'
        jne     .find_slash
.slash_found:
        inc     ecx
        mov     byte [rsi + rcx], 0
        jmp     .try_local
.no_directory:
        mov     byte [rel asm_arena_exe_path], 0

.try_local:
        lea     rcx, [rel asm_arena_exe_path]
        lea     rdx, [rel arena_suffix_data]
        lea     r8, [rel asm_arena_candidate_path]
        call    arena_build_path
        lea     rcx, [rel asm_arena_candidate_path]
        call    arena_try_load
        test    eax, eax
        jnz     .ready

        lea     rcx, [rel asm_arena_exe_path]
        lea     rdx, [rel arena_suffix_root]
        lea     r8, [rel asm_arena_candidate_path]
        call    arena_build_path
        lea     rcx, [rel asm_arena_candidate_path]
        call    arena_try_load
        test    eax, eax
        jnz     .ready

.try_dev:
        mov     rcx, [rsp + 0x30]
        test    rcx, rcx
        jz      .ready
        lea     rdx, [rel arena_suffix_dev]
        lea     r8, [rel asm_arena_candidate_path]
        call    arena_build_path
        lea     rcx, [rel asm_arena_candidate_path]
        call    arena_try_load
.ready:
        mov     eax, 1
        jmp     .return
.already_ready:
        mov     eax, 1
        jmp     .return
.failed:
        xor     eax, eax
.return:
        add     rsp, 0x38
        pop     rsi
        pop     rbp
        ret

; void asm_arena_platform_shutdown(void)
asm_arena_platform_shutdown:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20
        mov     rcx, [rel asm_arena_archive_ptr]
        test    rcx, rcx
        jz      .free_arena
        xor     edx, edx
        mov     r8d, MEM_RELEASE
        call    VirtualFree
.free_arena:
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
        ; A missing arena is an invalid caller state; retain the old zero
        ; offset convention rather than dereferencing a null base.
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
        lea     rax, [rel asm_arena_candidate_path]
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
