; win32_d3d_dispatch.asm - production D3D11 service boundary.
;
; d3d11_asm_present.asm owns COM/device/swap-chain/resource work.  This file
; owns the remaining host-facing state: palette conversion, self-test pixels,
; frame recording, readback diagnostics, Win32 file handles, and the exact
; decorated vk:: ABI formerly supplied by d3d11_dispatch.cpp.

BITS 64
DEFAULT REL

%include "win64_abi.inc"

%define GENERIC_WRITE               0x40000000
%define FILE_SHARE_READ             0x00000001
%define CREATE_ALWAYS               2
%define FILE_ATTRIBUTE_NORMAL       0x00000080
%define INVALID_HANDLE_VALUE        0xFFFFFFFFFFFFFFFF
%define MEM_COMMIT                  0x00001000
%define MEM_RESERVE                 0x00002000
%define MEM_RELEASE                 0x00008000
%define PAGE_READWRITE              4

%define SCREEN_W                    320
%define SCREEN_H                    200
%define FRAMEBUFFER_BYTES           (SCREEN_W * SCREEN_H)
%define PALETTE_BYTES               768
%define FRAMEBUFFER_OFFSET          0x20000

extern CreateFileA
extern WriteFile
extern FlushFileBuffers
extern CloseHandle
extern VirtualAlloc
extern VirtualFree

extern asm_present_init
extern asm_present_set_palette
extern asm_present_draw
extern asm_present_readback
extern asm_present_present
extern asm_present_shutdown
extern vk_arena_get
extern vk_framebuffer_ptr
extern vk_platform_update_input
extern vk_platform_quit_requested
extern vk_app_shutdown_and_exit
extern vk_log_printf

global ?initPresent@vk@@YA_NPEAXHH@Z
global ?shutdownPresent@vk@@YAXXZ
global ?setAssemblyPresenter@vk@@YAX_N@Z
global ?setPalette@vk@@YAXQEBE00@Z
global ?currentPalette@vk@@YAXQEAE@Z
global ?presentFrame@vk@@YAXXZ
global ?recInit@vk@@YAXPEBD@Z
global ?recClose@vk@@YAXXZ
global ?selfTestPattern@vk@@YAXXZ
global ?diagReadbackInit@vk@@YAXPEBD@Z
global ?diagReadbackShutdown@vk@@YAXXZ
global ?diagReadbackEnabled@vk@@YA_NXZ

section .bss
align 8
d3d_palette:            resb PALETTE_BYTES
d3d_hwnd:               resq 1
d3d_width:              resd 1
d3d_height:             resd 1
d3d_ready:              resd 1
d3d_present_count:      resq 1
d3d_record_handle:      resq 1
d3d_diag_gpu_handle:    resq 1
d3d_diag_src_handle:    resq 1
d3d_diag_pal_handle:    resq 1
d3d_diag_enabled:       resd 1
d3d_diag_captured:      resd 1
d3d_diag_pixels:        resq 1
d3d_diag_bytes:         resq 1
d3d_record_path:        resb 1024
d3d_diag_gpu_path:      resb 1024
d3d_diag_src_path:      resb 1024
d3d_diag_pal_path:      resb 1024

section .data
msg_presenter_asm: db "[d3d] presenter=native x64 assembly", 10, 0
msg_presenter_cpp: db "[d3d] C++ presenter is unavailable in VOODKA.exe; native x64 assembly remains active", 10, 0
msg_init:          db "[d3d] initPresent assembly(%p,%d,%d)", 10, 0
msg_init_fail:     db "[d3d] assembly presenter init failed (%u)", 10, 0
msg_ready:         db "[d3d] assembly presenter ready", 10, 0
msg_present_count: db "[d3d] assembly presentFrame #%llu", 10, 0
msg_draw_fail:     db "[d3d] assembly presenter draw failed (%u)", 10, 0
msg_present_fail:  db "[d3d] assembly Present failed (%08x)", 10, 0
msg_recording:     db "[rec] recording frames to %s", 10, 0
msg_diag_open_fail: db "[d3d] assembly readback diagnostics could not open %s", 10, 0
msg_diag_enabled:   db "[d3d] assembly readback diagnostics on -> %s", 10, 0
msg_diag_large:     db "[d3d] assembly readback diagnostic is too large", 10, 0
msg_diag_read_fail: db "[d3d] assembly readback failed on diagnostic frame %u", 10, 0

suffix_frames: db "frames.raw", 0
suffix_gpu:    db "frame_gpu.raw", 0
suffix_src:    db "frame_src.raw", 0
suffix_pal:    db "frame_pal.raw", 0

self_palette:
        db 63, 0, 0,  0, 63, 0,  0, 0, 63,  63, 63, 0
        db 0, 63, 63, 63, 0, 63,  63, 63, 63, 31, 31, 31

section .text

; Build dst = dir + "\\" + suffix, matching std::string(dir) + "\\" + suffix.
; rcx=dir, rdx=suffix, r8=destination.
d3d_build_path:
        mov     r10, rcx
        mov     r11, r8
.copy_dir:
        mov     al, [r10]
        test    al, al
        jz      .append_separator
        mov     [r11], al
        inc     r10
        inc     r11
        jmp     .copy_dir
.append_separator:
        mov     byte [r11], 0x5c
        inc     r11
.copy_suffix:
        mov     al, [rdx]
        mov     [r11], al
        inc     rdx
        inc     r11
        test    al, al
        jnz     .copy_suffix
        ret

; HANDLE d3d_open_write(const char* path)
d3d_open_write:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x40
        mov     edx, GENERIC_WRITE
        mov     r8d, FILE_SHARE_READ
        xor     r9d, r9d
        mov     qword [rsp + 0x20], CREATE_ALWAYS
        mov     qword [rsp + 0x28], FILE_ATTRIBUTE_NORMAL
        mov     qword [rsp + 0x30], 0
        call    CreateFileA
        add     rsp, 0x40
        pop     rbp
        ret

; int d3d_write_handle(HANDLE handle, const void* bytes, uint32_t length)
d3d_write_handle:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x40
        mov     [rbp - 8], rcx
        mov     [rbp - 16], rdx
        mov     [rbp - 20], r8d
        test    rcx, rcx
        jz      .write_fail
        cmp     rcx, INVALID_HANDLE_VALUE
        je      .write_fail
        mov     rcx, [rbp - 8]
        mov     rdx, [rbp - 16]
        mov     r8d, [rbp - 20]
        lea     r9, [rbp - 32]
        mov     qword [rsp + 0x20], 0
        call    WriteFile
        test    eax, eax
        jz      .write_fail
        mov     eax, [rbp - 32]
        cmp     eax, [rbp - 20]
        jne     .write_fail
        mov     eax, 1
        jmp     .write_return
.write_fail:
        xor     eax, eax
.write_return:
        add     rsp, 0x40
        pop     rbp
        ret

d3d_flush_handle:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20
        test    rcx, rcx
        jz      .flush_return
        cmp     rcx, INVALID_HANDLE_VALUE
        je      .flush_return
        call    FlushFileBuffers
.flush_return:
        add     rsp, 0x20
        pop     rbp
        ret

d3d_close_handle:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20
        test    rcx, rcx
        jz      .close_return
        cmp     rcx, INVALID_HANDLE_VALUE
        je      .close_return
        call    CloseHandle
.close_return:
        add     rsp, 0x20
        pop     rbp
        ret

d3d_alloc_diag_pixels:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20
        mov     eax, [rel d3d_width]
        mov     ecx, [rel d3d_height]
        imul    rax, rcx
        shl     rax, 2
        mov     [rel d3d_diag_bytes], rax
        test    rax, rax
        jz      .alloc_fail
        mov     rdx, rax
        xor     ecx, ecx
        mov     r8d, MEM_COMMIT | MEM_RESERVE
        mov     r9d, PAGE_READWRITE
        call    VirtualAlloc
        mov     [rel d3d_diag_pixels], rax
        test    rax, rax
        jz      .alloc_fail
        mov     eax, 1
        jmp     .alloc_return
.alloc_fail:
        xor     eax, eax
.alloc_return:
        add     rsp, 0x20
        pop     rbp
        ret

d3d_free_diag_pixels:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20
        mov     rcx, [rel d3d_diag_pixels]
        test    rcx, rcx
        jz      .free_clear
        xor     edx, edx
        mov     r8d, MEM_RELEASE
        call    VirtualFree
.free_clear:
        mov     qword [rel d3d_diag_pixels], 0
        mov     qword [rel d3d_diag_bytes], 0
        add     rsp, 0x20
        pop     rbp
        ret

; void vk::setAssemblyPresenter(bool enabled)
?setAssemblyPresenter@vk@@YAX_N@Z:
        test    cl, cl
        jz      .presenter_cpp_message
        lea     rcx, [rel msg_presenter_asm]
        jmp     vk_log_printf
.presenter_cpp_message:
        lea     rcx, [rel msg_presenter_cpp]
        jmp     vk_log_printf

; bool vk::initPresent(void* hwnd, int width, int height)
?initPresent@vk@@YA_NPEAXHH@Z:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20
        mov     [rel d3d_hwnd], rcx
        mov     [rel d3d_width], edx
        mov     [rel d3d_height], r8d
        mov     qword [rel d3d_present_count], 0
        lea     rcx, [rel msg_init]
        mov     rdx, [rel d3d_hwnd]
        mov     r8d, [rel d3d_width]
        mov     r9d, [rel d3d_height]
        call    vk_log_printf
        mov     rcx, [rel d3d_hwnd]
        mov     edx, [rel d3d_width]
        mov     r8d, [rel d3d_height]
        call    asm_present_init
        test    eax, eax
        jz      .present_init_ok
        mov     dword [rel d3d_ready], 0
        mov     edx, eax
        lea     rcx, [rel msg_init_fail]
        call    vk_log_printf
        xor     eax, eax
        jmp     .present_init_return
.present_init_ok:
        mov     dword [rel d3d_ready], 1
        lea     rcx, [rel msg_ready]
        call    vk_log_printf
        mov     eax, 1
.present_init_return:
        add     rsp, 0x20
        pop     rbp
        ret

; void vk::shutdownPresent(void)
?shutdownPresent@vk@@YAXXZ:
        push    rbp
        mov     rbp, rsp
        push    rdi
        sub     rsp, 0x28
        call    asm_present_shutdown
        mov     dword [rel d3d_ready], 0
        mov     dword [rel d3d_width], 0
        mov     dword [rel d3d_height], 0
        mov     qword [rel d3d_present_count], 0
        lea     rdi, [rel d3d_palette]
        xor     eax, eax
        mov     ecx, PALETTE_BYTES
        rep     stosb
        add     rsp, 0x28
        pop     rdi
        pop     rbp
        ret

; void vk::setPalette(const uint8_t r[256], const uint8_t g[256],
;                     const uint8_t b[256])
?setPalette@vk@@YAXQEBE00@Z:
        lea     r10, [rel d3d_palette]
        xor     r9d, r9d
.palette_loop:
        mov     r11d, r9d
        imul    r11d, 3
        movzx   eax, byte [rcx + r9]
        and     eax, 63
        mov     [r10 + r11 + 0], al
        movzx   eax, byte [rdx + r9]
        and     eax, 63
        mov     [r10 + r11 + 1], al
        movzx   eax, byte [r8 + r9]
        and     eax, 63
        mov     [r10 + r11 + 2], al
        inc     r9d
        cmp     r9d, 256
        jb      .palette_loop
        ret

; void vk::currentPalette(uint8_t out[kPaletteBytes])
?currentPalette@vk@@YAXQEAE@Z:
        push    rbp
        mov     rbp, rsp
        push    rsi
        push    rdi
        lea     rsi, [rel d3d_palette]
        mov     rdi, rcx
        mov     ecx, PALETTE_BYTES
        rep     movsb
        pop     rdi
        pop     rsi
        pop     rbp
        ret

; void vk::selfTestPattern(void)
?selfTestPattern@vk@@YAXXZ:
        push    rbp
        mov     rbp, rsp
        push    rsi
        push    rdi
        sub     rsp, 0x20
        call    vk_arena_get
        add     rax, FRAMEBUFFER_OFFSET
        mov     rdi, rax
        lea     rsi, [rel self_palette]
        xor     r10d, r10d
.self_palette_loop:
        mov     eax, r10d
        and     eax, 7
        imul    eax, 3
        lea     rdx, [rsi + rax]
        mov     eax, r10d
        imul    eax, 3
        lea     rcx, [rel d3d_palette]
        add     rcx, rax
        mov     al, [rdx + 0]
        mov     [rcx + 0], al
        mov     al, [rdx + 1]
        mov     [rcx + 1], al
        mov     al, [rdx + 2]
        mov     [rcx + 2], al
        inc     r10d
        cmp     r10d, 256
        jb      .self_palette_loop

        xor     r10d, r10d                    ; y
.self_y_loop:
        xor     r11d, r11d                    ; x
.self_x_loop:
        mov     eax, r11d
        xor     edx, edx
        mov     ecx, 80
        div     ecx
        mov     r9d, eax                      ; x / 80
        mov     eax, r10d
        xor     edx, edx
        mov     ecx, 50
        div     ecx
        lea     eax, [r9 + rax * 2]
        and     eax, 7
        mov     r8d, r10d
        imul    r8d, SCREEN_W
        add     r8d, r11d
        mov     [rdi + r8], al
        inc     r11d
        cmp     r11d, SCREEN_W
        jb      .self_x_loop
        inc     r10d
        cmp     r10d, SCREEN_H
        jb      .self_y_loop
        add     rsp, 0x20
        pop     rdi
        pop     rsi
        pop     rbp
        ret

; void vk::recInit(const char* dir)
?recInit@vk@@YAXPEBD@Z:
        push    rbp
        mov     rbp, rsp
        push    r12
        sub     rsp, 0x28
        mov     r12, rcx
        call    ?recClose@vk@@YAXXZ
        test    r12, r12
        jz      .rec_init_return
        mov     rcx, r12
        lea     rdx, [rel suffix_frames]
        lea     r8, [rel d3d_record_path]
        call    d3d_build_path
        lea     rcx, [rel d3d_record_path]
        call    d3d_open_write
        mov     [rel d3d_record_handle], rax
        cmp     rax, INVALID_HANDLE_VALUE
        je      .rec_init_return
        lea     rcx, [rel msg_recording]
        lea     rdx, [rel d3d_record_path]
        call    vk_log_printf
.rec_init_return:
        add     rsp, 0x28
        pop     r12
        pop     rbp
        ret

; void vk::recClose(void)
?recClose@vk@@YAXXZ:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20
        mov     rcx, [rel d3d_record_handle]
        call    d3d_close_handle
        mov     qword [rel d3d_record_handle], INVALID_HANDLE_VALUE
        add     rsp, 0x20
        pop     rbp
        ret

d3d_record_frame:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20
        mov     [rbp - 8], rcx
        mov     rcx, [rel d3d_record_handle]
        mov     rdx, [rbp - 8]
        mov     r8d, FRAMEBUFFER_BYTES
        call    d3d_write_handle
        mov     rcx, [rel d3d_record_handle]
        lea     rdx, [rel d3d_palette]
        mov     r8d, PALETTE_BYTES
        call    d3d_write_handle
        mov     rcx, [rel d3d_record_handle]
        call    d3d_flush_handle
        add     rsp, 0x20
        pop     rbp
        ret

; void vk::diagReadbackShutdown(void)
?diagReadbackShutdown@vk@@YAXXZ:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20
        mov     rcx, [rel d3d_diag_gpu_handle]
        call    d3d_close_handle
        mov     rcx, [rel d3d_diag_src_handle]
        call    d3d_close_handle
        mov     rcx, [rel d3d_diag_pal_handle]
        call    d3d_close_handle
        call    d3d_free_diag_pixels
        mov     qword [rel d3d_diag_gpu_handle], INVALID_HANDLE_VALUE
        mov     qword [rel d3d_diag_src_handle], INVALID_HANDLE_VALUE
        mov     qword [rel d3d_diag_pal_handle], INVALID_HANDLE_VALUE
        mov     dword [rel d3d_diag_enabled], 0
        mov     dword [rel d3d_diag_captured], 0
        add     rsp, 0x20
        pop     rbp
        ret

; void vk::diagReadbackInit(const char* dir)
?diagReadbackInit@vk@@YAXPEBD@Z:
        push    rbp
        mov     rbp, rsp
        push    r12
        sub     rsp, 0x28
        mov     r12, rcx
        call    ?diagReadbackShutdown@vk@@YAXXZ
        test    r12, r12
        jz      .diag_init_return

        mov     rcx, r12
        lea     rdx, [rel suffix_gpu]
        lea     r8, [rel d3d_diag_gpu_path]
        call    d3d_build_path
        mov     rcx, r12
        lea     rdx, [rel suffix_src]
        lea     r8, [rel d3d_diag_src_path]
        call    d3d_build_path
        mov     rcx, r12
        lea     rdx, [rel suffix_pal]
        lea     r8, [rel d3d_diag_pal_path]
        call    d3d_build_path

        lea     rcx, [rel d3d_diag_gpu_path]
        call    d3d_open_write
        mov     [rel d3d_diag_gpu_handle], rax
        lea     rcx, [rel d3d_diag_src_path]
        call    d3d_open_write
        mov     [rel d3d_diag_src_handle], rax
        lea     rcx, [rel d3d_diag_pal_path]
        call    d3d_open_write
        mov     [rel d3d_diag_pal_handle], rax
        cmp     qword [rel d3d_diag_gpu_handle], INVALID_HANDLE_VALUE
        je      .diag_init_fail
        cmp     qword [rel d3d_diag_src_handle], INVALID_HANDLE_VALUE
        je      .diag_init_fail
        cmp     qword [rel d3d_diag_pal_handle], INVALID_HANDLE_VALUE
        je      .diag_init_fail
        call    d3d_alloc_diag_pixels
        test    eax, eax
        jz      .diag_init_fail
        mov     dword [rel d3d_diag_enabled], 1
        mov     dword [rel d3d_diag_captured], 0
        lea     rcx, [rel msg_diag_enabled]
        mov     rdx, r12
        call    vk_log_printf
        jmp     .diag_init_return
.diag_init_fail:
        lea     rcx, [rel msg_diag_open_fail]
        mov     rdx, r12
        call    vk_log_printf
        call    ?diagReadbackShutdown@vk@@YAXXZ
.diag_init_return:
        add     rsp, 0x28
        pop     r12
        pop     rbp
        ret

; bool vk::diagReadbackEnabled(void)
?diagReadbackEnabled@vk@@YA_NXZ:
        mov     eax, [rel d3d_diag_enabled]
        ret

d3d_capture_diag:
        push    rbp
        mov     rbp, rsp
        push    r12
        sub     rsp, 0x28
        mov     r12, rcx
        cmp     dword [rel d3d_diag_enabled], 0
        je      .capture_return
        cmp     dword [rel d3d_diag_captured], 4
        jae     .capture_return
        inc     dword [rel d3d_diag_captured]

        mov     rcx, [rel d3d_diag_src_handle]
        mov     rdx, r12
        mov     r8d, FRAMEBUFFER_BYTES
        call    d3d_write_handle
        mov     rcx, [rel d3d_diag_pal_handle]
        lea     rdx, [rel d3d_palette]
        mov     r8d, PALETTE_BYTES
        call    d3d_write_handle
        mov     rcx, [rel d3d_diag_src_handle]
        call    d3d_flush_handle
        mov     rcx, [rel d3d_diag_pal_handle]
        call    d3d_flush_handle

        mov     rax, [rel d3d_diag_bytes]
        mov     edx, 0xffffffff
        cmp     rax, rdx
        ja      .capture_too_large
        mov     rcx, [rel d3d_diag_pixels]
        test    rcx, rcx
        jz      .capture_read_fail
        mov     edx, eax
        call    asm_present_readback
        test    eax, eax
        jnz     .capture_read_fail
        mov     rcx, [rel d3d_diag_gpu_handle]
        mov     rdx, [rel d3d_diag_pixels]
        mov     r8d, [rel d3d_diag_bytes]
        call    d3d_write_handle
        mov     rcx, [rel d3d_diag_gpu_handle]
        call    d3d_flush_handle
        jmp     .capture_return
.capture_too_large:
        lea     rcx, [rel msg_diag_large]
        call    vk_log_printf
        jmp     .capture_return
.capture_read_fail:
        lea     rcx, [rel msg_diag_read_fail]
        mov     edx, [rel d3d_diag_captured]
        call    vk_log_printf
.capture_return:
        add     rsp, 0x28
        pop     r12
        pop     rbp
        ret

; void vk::presentFrame(void)
?presentFrame@vk@@YAXXZ:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        sub     rsp, 0x20                    ; RSP%16 == 0 at external calls
        call    vk_platform_update_input
        call    vk_platform_quit_requested
        test    eax, eax
        jz      .present_not_quitting
        call    vk_app_shutdown_and_exit
.present_not_quitting:
        cmp     dword [rel d3d_ready], 0
        je      .present_return

        mov     r13, [rel d3d_present_count]
        inc     qword [rel d3d_present_count]
        test    r13d, 0x3fff
        jnz     .present_no_count_log
        lea     rcx, [rel msg_present_count]
        mov     rdx, r13
        call    vk_log_printf
.present_no_count_log:
        call    vk_framebuffer_ptr
        mov     r12, rax
        mov     rcx, r12
        call    d3d_record_frame
        lea     rcx, [rel d3d_palette]
        call    asm_present_set_palette
        call    vk_arena_get
        mov     rcx, rax
        mov     edx, FRAMEBUFFER_OFFSET
        call    asm_present_draw
        test    eax, eax
        jz      .present_draw_ok
        mov     edx, eax
        lea     rcx, [rel msg_draw_fail]
        call    vk_log_printf
        jmp     .present_return
.present_draw_ok:
        mov     rcx, r12
        call    d3d_capture_diag
        call    asm_present_present
        test    eax, eax
        jz      .present_return
        cmp     eax, 0x087a0001
        je      .present_return
        mov     edx, eax
        lea     rcx, [rel msg_present_fail]
        call    vk_log_printf
.present_return:
        add     rsp, 0x20
        pop     r13
        pop     r12
        pop     rbp
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
