; bridge_services.asm - production C ABI services formerly in bridge.cpp.
;
; This first bridge slice removes the selector table, palette conversion/
; range path, frame-buffer pointer helpers, and present forwarding from the
; shipped C++ adapter. The underlying palette/presenter and arena services are
; already assembly-owned; only their stable decorated ABI is called here.

BITS 64
DEFAULT REL

%define BACKBUFFER_OFFSET 0x00010000
%define FRAMEBUFFER_OFFSET 0x00020000
%define SELECTOR_COUNT 512

extern asm_arena_base
extern asm_arena_alloc
extern asm_arena_free
extern ?setPalette@vk@@YAXQEBE00@Z
extern ?currentPalette@vk@@YAXQEAE@Z
extern ?presentFrame@vk@@YAXXZ

global sel_base_table
global vk_selector_alloc
global vk_selector_free
global vk_selector_base
global vk_set_palette
global vk_get_palette
global vk_set_palette_range
global vk_present_frame
global vk_backbuffer_ptr
global vk_framebuffer_ptr
global vk_framebuffer_offset
global vk_backbuffer_offset
global ?resetSelectors@vk@@YAXXZ
global vk_arena_get
global vk_arena_alloc
global vk_arena_free

section .bss align=64
sel_base_table: resq SELECTOR_COUNT

section .text

; uint64_t vk_arena_get(void)
vk_arena_get:
        sub     rsp, 0x28
        call    asm_arena_base
        add     rsp, 0x28
        ret

; uint32_t vk_arena_alloc(uint32_t bytes)
vk_arena_alloc:
        jmp     asm_arena_alloc

; void vk_arena_free(uint32_t off)
vk_arena_free:
        jmp     asm_arena_free

; uint16_t vk_selector_alloc(uint64_t base, uint64_t limit)
vk_selector_alloc:
        xor     r8d, r8d
        inc     r8d
.selector_find:
        cmp     r8d, SELECTOR_COUNT
        jae     .selector_full
        lea     rax, [rel sel_base_table]
        cmp     qword [rax + r8 * 8], 0
        jne     .selector_next
        mov     [rax + r8 * 8], rcx
        mov     eax, r8d
        ret
.selector_next:
        inc     r8d
        jmp     .selector_find
.selector_full:
        mov     eax, 0xffff
        ret

; void vk_selector_free(uint16_t handle)
vk_selector_free:
        movzx   eax, cx
        test    eax, eax
        jz      .selector_free_done
        cmp     eax, SELECTOR_COUNT
        jae     .selector_free_done
        lea     rdx, [rel sel_base_table]
        mov     qword [rdx + rax * 8], 0
.selector_free_done:
        ret

; uint64_t vk_selector_base(uint16_t handle)
vk_selector_base:
        movzx   eax, cx
        cmp     eax, SELECTOR_COUNT
        jae     .selector_base_invalid
        lea     rdx, [rel sel_base_table]
        mov     rax, [rdx + rax * 8]
        ret
.selector_base_invalid:
        xor     eax, eax
        ret

; void vk::resetSelectors(void)
?resetSelectors@vk@@YAXXZ:
        lea     rdi, [rel sel_base_table]
        xor     eax, eax
        mov     ecx, SELECTOR_COUNT
        rep     stosq
        ret

; void vk_set_palette(const uint8_t* rgb)
vk_set_palette:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        sub     rsp, 0x380                    ; RSP%16 == 0 at CALL
        mov     r12, rcx
        xor     r13d, r13d
.palette_split:
        mov     eax, r13d
        lea     r10, [rax + rax * 2]
        mov     dl, [r12 + r10]
        mov     byte [rsp + 0x50 + r13], dl
        mov     dl, [r12 + r10 + 1]
        mov     byte [rsp + 0x150 + r13], dl
        mov     dl, [r12 + r10 + 2]
        mov     byte [rsp + 0x250 + r13], dl
        inc     r13d
        cmp     r13d, 256
        jb      .palette_split
        lea     rcx, [rsp + 0x50]
        lea     rdx, [rsp + 0x150]
        lea     r8, [rsp + 0x250]
        call    ?setPalette@vk@@YAXQEBE00@Z
        add     rsp, 0x380
        pop     r13
        pop     r12
        pop     rbp
        ret

; void vk_get_palette(uint8_t* out)
vk_get_palette:
        jmp     ?currentPalette@vk@@YAXQEAE@Z

; void vk_set_palette_range(const uint8_t* src, uint32_t start,
;                            uint32_t count)
vk_set_palette_range:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0x700                    ; RSP%16 == 0 at CALL
        mov     r12, rcx
        mov     r13d, edx
        mov     r14d, r8d
        lea     rcx, [rsp + 0x50]
        call    ?currentPalette@vk@@YAXQEAE@Z
        cmp     r13d, 256
        jae     .palette_range_done
        mov     eax, 256
        sub     eax, r13d
        cmp     r14d, eax
        jbe     .palette_range_ready
        mov     r14d, eax
.palette_range_ready:
        xor     r15d, r15d
.palette_range_loop:
        cmp     r15d, r14d
        jae     .palette_range_apply
        mov     eax, r13d
        add     eax, r15d
        lea     r10, [rax + rax * 2]
        mov     eax, r15d
        lea     r11, [rax + rax * 2]
        mov     dl, [r12 + r11]
        mov     byte [rsp + 0x50 + r10], dl
        mov     dl, [r12 + r11 + 1]
        mov     byte [rsp + 0x50 + r10 + 1], dl
        mov     dl, [r12 + r11 + 2]
        mov     byte [rsp + 0x50 + r10 + 2], dl
        inc     r15d
        jmp     .palette_range_loop
.palette_range_apply:
        xor     r15d, r15d
.palette_range_split:
        cmp     r15d, 256
        jae     .palette_range_call
        mov     eax, r15d
        lea     r10, [rax + rax * 2]
        mov     dl, [rsp + 0x50 + r10]
        mov     byte [rsp + 0x380 + r15], dl
        mov     dl, [rsp + 0x50 + r10 + 1]
        mov     byte [rsp + 0x480 + r15], dl
        mov     dl, [rsp + 0x50 + r10 + 2]
        mov     byte [rsp + 0x580 + r15], dl
        inc     r15d
        jmp     .palette_range_split
.palette_range_call:
        lea     rcx, [rsp + 0x380]
        lea     rdx, [rsp + 0x480]
        lea     r8, [rsp + 0x580]
        call    ?setPalette@vk@@YAXQEBE00@Z
.palette_range_done:
        add     rsp, 0x700
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbp
        ret

; void vk_present_frame(void)
vk_present_frame:
        jmp     ?presentFrame@vk@@YAXXZ

; void* vk_backbuffer_ptr(void)
vk_backbuffer_ptr:
        sub     rsp, 0x28
        call    asm_arena_base
        add     rax, BACKBUFFER_OFFSET
        add     rsp, 0x28
        ret

; void* vk_framebuffer_ptr(void)
vk_framebuffer_ptr:
        sub     rsp, 0x28
        call    asm_arena_base
        add     rax, FRAMEBUFFER_OFFSET
        add     rsp, 0x28
        ret

vk_framebuffer_offset:
        mov     eax, FRAMEBUFFER_OFFSET
        ret

vk_backbuffer_offset:
        mov     eax, BACKBUFFER_OFFSET
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
