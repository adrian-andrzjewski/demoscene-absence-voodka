; win32_platform_abi.asm - production namespace-vk logging/timeline ABI.
;
; The C++ reference target keeps log.cpp and timeline.cpp as its oracle. The
; shipped target exposes the same MSVC-decorated C++ symbols directly from
; NASM, forwarding formatting to the proven assembly formatter/sink and
; retaining vk_log_printf only as the narrow variadic bridge.

BITS 64
DEFAULT REL

%include "win64_abi.inc"

extern asm_log_init
extern asm_log_flush
extern asm_log_shutdown
extern asm_log_vformat
extern asm_timeline_open
extern asm_timeline_write
extern asm_timeline_flush
extern asm_timeline_close
extern vk_log_printf
extern vk_audio_elapsed_us

global ?logInit@vk@@YAXXZ
global ?logPrint@vk@@YAXPEBDZZ
global ?logFlush@vk@@YAXXZ
global ?logShutdown@vk@@YAXXZ
global ?timelineInit@vk@@YAXPEBD@Z
global ?timelineFrame@vk@@YAX_K0I@Z
global ?timelineClose@vk@@YAXXZ

section .data
log_session_message: db "---- VOODKA x64 port session ----", 10, 0
timeline_header: db "# frame qpc_us modpos audio_elapsed_us", 10, 0
timeline_write_message: db "[timeline] writing '%s'", 10, 0
timeline_open_message: db "[timeline] cannot open '%s'", 10, 0
timeline_frame_format: db "%llu %llu %u %llu", 10, 0

section .text

; void vk::logInit(void)
?logInit@vk@@YAXXZ:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20
        call    asm_log_init
        lea     rcx, [rel log_session_message]
        call    vk_log_printf
        add     rsp, 0x20
        pop     rbp
        ret

; void vk::logPrint(const char*, ...)
?logPrint@vk@@YAXPEBDZZ:
        jmp     vk_log_printf

; void vk::logFlush(void)
?logFlush@vk@@YAXXZ:
        jmp     asm_log_flush

; void vk::logShutdown(void)
?logShutdown@vk@@YAXXZ:
        jmp     asm_log_shutdown

; void vk::timelineInit(const char* path)
?timelineInit@vk@@YAXPEBD@Z:
        push    rbp
        mov     rbp, rsp
        push    r12
        sub     rsp, 0x28                    ; RSP%16 == 0 at every CALL
        mov     r12, rcx
        test    r12, r12
        jz      .timeline_init_done
        cmp     byte [r12], 0
        je      .timeline_init_done

        mov     rcx, r12
        call    asm_timeline_open
        test    eax, eax
        jnz     .timeline_open
        lea     rcx, [rel timeline_open_message]
        mov     rdx, r12
        call    vk_log_printf
        jmp     .timeline_init_done

.timeline_open:
        lea     rcx, [rel timeline_header]
        mov     edx, 39                     ; strlen(header)
        call    asm_timeline_write
        call    asm_timeline_flush
        lea     rcx, [rel timeline_write_message]
        mov     rdx, r12
        call    vk_log_printf
.timeline_init_done:
        add     rsp, 0x28
        pop     r12
        pop     rbp
        ret

; void vk::timelineFrame(uint64_t frame, uint64_t qpcUs, uint32_t modpos)
?timelineFrame@vk@@YAX_K0I@Z:
        push    rbp
        mov     rbp, rsp
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0xC0                    ; RSP%16 == 0 at every CALL
        mov     r12, rcx                     ; frame
        mov     r13, rdx                     ; qpcUs
        mov     r14d, r8d                    ; ModPos

        call    vk_audio_elapsed_us
        mov     r15, rax
        mov     [rsp + 0x20], r12
        mov     [rsp + 0x28], r13
        mov     [rsp + 0x30], r14
        mov     [rsp + 0x38], r15
        lea     rcx, [rsp + 0x40]
        mov     edx, 128
        lea     r8, [rel timeline_frame_format]
        lea     r9, [rsp + 0x20]              ; MS x64 va_list slots
        call    asm_log_vformat
        test    eax, eax
        js      .timeline_frame_done
        mov     edx, eax
        lea     rcx, [rsp + 0x40]
        call    asm_timeline_write
.timeline_frame_done:
        add     rsp, 0xC0
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbp
        ret

; void vk::timelineClose(void)
?timelineClose@vk@@YAXXZ:
        call    asm_timeline_flush
        jmp     asm_timeline_close

section .note.GNU-stack noalloc noexec nowrite progbits
