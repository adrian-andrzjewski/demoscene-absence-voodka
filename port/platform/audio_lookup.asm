; audio_lookup.asm - lower_bound primitive for dedicated-player seek mapping.
;
; uint32_t asm_audio_lower_bound_u32(const uint32_t* values,
;                                    uint32_t count, uint32_t key)
; Returns the first index whose value is >= key.  If key is above the whole
; range, returns count-1, matching the former C++ tick lookup.  count==0
; therefore returns UINT32_MAX, preserving the old underflow behavior for an
; uninitialized runtime (which is rejected before normal use).

BITS 64
DEFAULT REL

global asm_audio_lower_bound_u32

section .text

asm_audio_lower_bound_u32:
        xor     eax, eax                    ; low = 0
        mov     r9d, edx                     ; high = count

.lower_bound_loop:
        cmp     eax, r9d
        jae     .lower_bound_done
        mov     r10d, eax
        add     r10d, r9d
        shr     r10d, 1                     ; mid = (low + high) / 2
        cmp     dword [rcx + r10 * 4], r8d
        jb      .lower_bound_raise_low
        mov     r9d, r10d
        jmp     .lower_bound_loop

.lower_bound_raise_low:
        lea     eax, [r10d + 1]
        jmp     .lower_bound_loop

.lower_bound_done:
        cmp     eax, edx
        jne     .lower_bound_return
        dec     eax                         ; count - 1, including zero -> -1

.lower_bound_return:
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
