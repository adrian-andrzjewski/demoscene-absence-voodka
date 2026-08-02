; eos_dispatch.asm - the flat-model EOS service dispatcher.
;
; Receives the service id in eax and register args per eos.inc, adapts to the
; C++ platform layer (Microsoft x64 ABI) and restores EOS-style results.
;
; Calling convention used for platform calls (Microsoft x64):
;   rcx, rdx, r8, r9  = first four args (int/ptr), caller cleans the stack.
;   We must preserve rbx?, rsi, rdi, r12-r15 and XMM across our calls.

BITS 64
DEFAULT REL

%include "eos.inc"

section .text

extern vk_arena_get
extern vk_arena_alloc
extern vk_arena_free
extern vk_selector_alloc
extern vk_selector_free
extern vk_selector_base
extern vk_wait_vbl
extern vk_get_modpos
extern vk_load_internal_file
extern vk_audio_play
extern vk_audio_stop
extern vk_audio_clear
extern vk_audio_set_pattern

; the exported selector base table (bridge.cpp) - index by handle
section .data
extern sel_base_table

global eos_dispatch
global Code32_addr

section .data
; The arena base pointer (== platform arena()), the single qword that turns
; every stored 32-bit offset into a real address.  Set once by boot.asm.
Code32_addr: dq 0

section .text

; Helper that forwards to a C function with MS x64 ABI.  We do the forwards
; explicitly per service so flags/registers stay predictable.

eos_dispatch:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15
        ; 8 pushes (incl rbp) -> rsp%16==8; sub 0x28 -> 0 at call sites
        sub     rsp, 0x28

        cmp     eax, EOS_QUERY_MEMORY
        je      .query_mem
        cmp     eax, EOS_ALLOCATE_MEMORY
        je      .alloc_mem
        cmp     eax, EOS_DEALLOCATE_MEMORY
        je      .dealloc_mem
        cmp     eax, EOS_ALLOCATE_SELECTOR
        je      .alloc_sel
        cmp     eax, EOS_DEALLOCATE_SELECTOR
        je      .dealloc_sel
        cmp     eax, EOS_WAIT_VBL
        je      .wait_vbl
        cmp     eax, EOS_GET_INFO
        je      .get_info
        cmp     eax, EOS_LOAD_INTERNAL_FILE
        je      .load_internal
        cmp     eax, EOS_QUERY_SOUNDCARD
        je      .query_snd
        cmp     eax, EOS_LOAD_MODULE
        je      .load_module
        cmp     eax, EOS_SET_PATTERN
        je      .set_pattern
        cmp     eax, EOS_PLAY_MODULE
        je      .play
        cmp     eax, EOS_STOP_MODULE
        je      .stop
        cmp     eax, EOS_CLEAR_MODULE
        je      .clear
        cmp     eax, EOS_USE_INT_08
        je      .noop
        cmp     eax, EOS_USE_INT_09
        je      .noop
        cmp     eax, EOS_WRITE_EXTERNAL_FILE
        je      .noop

        jmp     .done_ok            ; unknown -> no-op, eax stays

; ---- query memory: edx = 0xFFFFFFFF => eax = free bytes -------------------
.query_mem:
        ; report a fixed large value (we never run out in practice)
        mov     eax, 6800000
        jmp     .done_ok

; ---- allocate memory: edx = bytes -> edx = arena offset (zeroed) ----------
.alloc_mem:
        mov     ecx, edx
        call    vk_arena_alloc        ; (bytes) -> uint32 offset in eax
        mov     edx, eax
        jmp     .done_ok

; ---- deallocate memory: edx = offset (no-op) ------------------------------
.dealloc_mem:
        jmp     .done_ok

; ---- allocate selector: rsi=real ptr (offset+Code32_addr), edi=limit
;      -> bx = handle ----------------------------------------------------------
.alloc_sel:
        mov     rcx, rsi
        mov     edx, edi
        call    vk_selector_alloc     ; (base, limit) -> eax handle
        mov     bx, ax
        jmp     .done_ok

; ---- deallocate selector: bx = handle --------------------------------------
.dealloc_sel:
        movzx   ecx, bx
        call    vk_selector_free
        jmp     .done_ok

; ---- wait vsync: -> eax = frame counter ------------------------------------
.wait_vbl:
        call    vk_wait_vbl
        mov     eax, eax
        jmp     .done_ok

; ---- get info: -> bl = song position (ModPos) ------------------------------
.get_info:
        call    vk_get_modpos
        mov     bl, al
        jmp     .done_ok

; ---- load internal file: edx = name ptr -> eax = arena offset --------------
.load_internal:
        mov     rcx, rdx
        call    vk_load_internal_file
        jmp     .done_ok

; ---- audio stubs ------------------------------------------------------------
.query_snd:
        mov     eax, 1
        jmp     .done_ok
.load_module:
        xor     eax, eax
        jmp     .done_ok
.set_pattern:
        movzx   ecx, bx
        call    vk_audio_set_pattern
        jmp     .done_ok
.play:
        call    vk_audio_play
        jmp     .done_ok
.stop:
        call    vk_audio_stop
        jmp     .done_ok
.clear:
        call    vk_audio_clear
        jmp     .done_ok

.noop:
        jmp     .done_ok

.done_ok:
        add     rsp, 0x28
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret
