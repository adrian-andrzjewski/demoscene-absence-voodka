; bridge_file_input.asm - production file and key-map C ABI adapters.
;
; The archive and keyboard state are already owned by native assembly services.
; This file removes the remaining C++ bridge bodies while preserving the
; stable names consumed by eos_dispatch.asm and the P8 key-map snapshot.

BITS 64
DEFAULT REL

extern asm_arena_load_internal_file
extern asm_input_key_map
extern vk_log_printf

global vk_load_internal_file
global vk_key_map_copy

section .text

section .rdata
bridge_unknown_file_message: db "[arena] loadInternalFile: unknown internal file '%s'", 10, 0
bridge_null_file_name:       db "(null)", 0

section .text

; uint32_t vk_load_internal_file(const char* name)
vk_load_internal_file:
        push    rbp
        mov     rbp, rsp
        push    r12
        sub     rsp, 0x28                    ; RSP%16 == 0 at CALL
        mov     r12, rcx
        test    rcx, rcx
        jz      .unknown
        call    asm_arena_load_internal_file
        test    eax, eax
        jnz     .file_done
.unknown:
        lea     rcx, [rel bridge_unknown_file_message]
        test    r12, r12
        jnz     .name_ready
        lea     r12, [rel bridge_null_file_name]
.name_ready:
        mov     rdx, r12
        call    vk_log_printf
        xor     eax, eax
.file_done:
        add     rsp, 0x28
        pop     r12
        pop     rbp
        ret

; void vk_key_map_copy(uint8_t* destination)
;
; The original bridge copied 128 entries and normalized every nonzero source
; byte to one. Keep that behavior even though the current input producer uses
; only zero/one values, because the C ABI is the historical contract.
vk_key_map_copy:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        sub     rsp, 0x28                    ; RSP%16 == 0 at CALL
        mov     r12, rcx
        call    asm_input_key_map
        mov     r13, rax
        xor     ecx, ecx
.copy_loop:
        movzx   eax, byte [r13 + rcx]
        test    eax, eax
        setnz   al
        mov     [r12 + rcx], al
        inc     ecx
        cmp     ecx, 128
        jb      .copy_loop
        add     rsp, 0x28
        pop     r13
        pop     r12
        pop     rbp
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
