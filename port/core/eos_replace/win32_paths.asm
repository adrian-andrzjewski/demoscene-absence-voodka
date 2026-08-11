; win32_paths.asm - production assembly path resolution for the soundtrack.
;
; Mirrors app.cpp's resolver exactly:
;   1. non-empty --music override
;   2. <exe>\music\amnezja2.mod
;   3. <exe>\amnezja2.mod
;   4. <repositoryRoot>/music/amnezja2.mod
; A missing file returns an empty, stable string. The reference executable
; retains the C++ implementation as the behavioral oracle.

BITS 64
DEFAULT REL

%include "win64_abi.inc"

%define kMusicPathCapacity       2048
%define kFileAttributeDirectory  0x00000010
%define kInvalidFileAttributes   0xFFFFFFFF

extern GetModuleFileNameA
extern GetFileAttributesA

global asm_voodka_resolve_music_path

section .bss
align 8
asm_music_path_buffer:  resb kMusicPathCapacity

section .data
music_suffix_one:       db "music\amnezja2.mod", 0
music_suffix_two:       db "amnezja2.mod", 0
music_suffix_three:     db "/music/amnezja2.mod", 0

section .text

; int path_try_suffix(const char* buffer, uint32_t prefixLength,
;                     const char* suffix)
; Returns 1 when buffer+suffix names an existing regular file.
path_try_suffix:
        push    rbp
        mov     rbp, rsp
        push    rdi
        push    rsi
        sub     rsp, 0x20                    ; RSP%16 == 0 at API call

        mov     r10d, edx
        cmp     r10d, kMusicPathCapacity
        jae     .missing
        lea     rdi, [rcx + r10]
.copy:
        cmp     r10d, kMusicPathCapacity
        jae     .missing
        mov     al, [rsi]
        mov     [rdi], al
        inc     rsi
        inc     rdi
        test    al, al
        jnz     .copy
        ; The NUL was written within the fixed buffer. The file API below can
        ; therefore never observe an unterminated or overrun candidate.

        lea     rcx, [rel asm_music_path_buffer]
        call    GetFileAttributesA
        cmp     eax, kInvalidFileAttributes
        je      .missing
        test    eax, kFileAttributeDirectory
        jnz     .missing
        mov     eax, 1
        jmp     .done

.missing:
        xor     eax, eax
.done:
        add     rsp, 0x20
        pop     rsi
        pop     rdi
        pop     rbp
        ret

; const char* asm_voodka_resolve_music_path(const char* overridePath,
;                                           const char* repositoryRoot)
asm_voodka_resolve_music_path:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        push    r14
        push    r15
        push    rsi
        push    rdi
        sub     rsp, 0x20                    ; RSP%16 == 0 at API calls

        mov     r12, rcx                     ; optional --music override
        mov     r13, rdx                     ; configured repository root
        lea     r14, [rel asm_music_path_buffer]
        mov     byte [r14], 0

        test    r12, r12
        jz      .from_exe
        cmp     byte [r12], 0
        je      .from_exe
        mov     rax, r12
        jmp     .return

.from_exe:
        ; GetModuleFileNameA(NULL, buffer, capacity-1). The explicit spare
        ; byte keeps the path NUL-terminated even at the truncation boundary.
        xor     ecx, ecx
        mov     rdx, r14
        mov     r8d, kMusicPathCapacity - 1
        call    GetModuleFileNameA
        test    eax, eax
        jz      .from_repository
        cmp     eax, kMusicPathCapacity - 1
        jae     .from_repository
        mov     byte [r14 + rax], 0

        ; Keep the directory including its trailing slash, matching the C++
        ; substr(0, slash + 1) behavior.
        mov     r15d, eax
        test    r15d, r15d
        jz      .from_repository
        dec     r15d
.find_slash:
        mov     al, [r14 + r15]
        cmp     al, '\\'
        je      .slash_found
        cmp     al, '/'
        je      .slash_found
        test    r15d, r15d
        jz      .from_repository
        dec     r15d
        jmp     .find_slash

.slash_found:
        inc     r15d
        mov     rcx, r14
        mov     edx, r15d
        lea     rsi, [rel music_suffix_one]
        call    path_try_suffix
        test    eax, eax
        jnz     .return_buffer

        mov     rcx, r14
        mov     edx, r15d
        lea     rsi, [rel music_suffix_two]
        call    path_try_suffix
        test    eax, eax
        jnz     .return_buffer

.from_repository:
        ; Rebuild the buffer from repositoryRoot and try the development-tree
        ; fallback. A null/empty root means there is no fallback candidate.
        test    r13, r13
        jz      .return_empty
        cmp     byte [r13], 0
        je      .return_empty
        xor     ecx, ecx
        mov     rsi, r13
        mov     rdi, r14
.copy_repository:
        cmp     ecx, kMusicPathCapacity
        jae     .return_empty
        mov     al, [rsi]
        mov     [rdi], al
        inc     rsi
        inc     rdi
        inc     ecx
        test    al, al
        jnz     .copy_repository
        dec     ecx                            ; prefix length, exclude NUL
        mov     r15d, ecx
        mov     rcx, r14
        mov     edx, r15d
        lea     rsi, [rel music_suffix_three]
        call    path_try_suffix
        test    eax, eax
        jnz     .return_buffer

.return_empty:
        mov     byte [r14], 0
.return_buffer:
        mov     rax, r14
.return:
        add     rsp, 0x20
        pop     rdi
        pop     rsi
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbp
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
