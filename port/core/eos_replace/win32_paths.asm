; win32_paths.asm - production soundtrack identity.
;
; The shipped player does not probe or open a filesystem module.  Keep the
; historical resolver ABI so command-line/application code remains stable,
; returning an explicit embedded identity for the default case.

BITS 64
DEFAULT REL

global asm_voodka_resolve_music_path

section .rdata
music_embedded_path: db "embedded:amnezja2.mod", 0

section .text

; const char* asm_voodka_resolve_music_path(const char* overridePath,
;                                           const char* repositoryRoot)
asm_voodka_resolve_music_path:
        test    rcx, rcx
        jz      .embedded
        cmp     byte [rcx], 0
        je      .embedded
        mov     rax, rcx
        ret
.embedded:
        lea     rax, [rel music_embedded_path]
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
