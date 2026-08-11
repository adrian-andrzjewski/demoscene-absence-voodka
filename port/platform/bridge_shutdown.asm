; bridge_shutdown.asm - production shutdown service adapters.
;
; win32_shutdown.asm owns the one-shot coordinator and ordering.  These
; narrow C ABI names now forward directly to the already native assembly
; owners, removing the last C++ wrapper bodies from that teardown path.

BITS 64
DEFAULT REL

extern asm_input_shutdown
extern ?audioShutdown@vk@@YAXXZ
extern ?recClose@vk@@YAXXZ
extern ?diagReadbackShutdown@vk@@YAXXZ
extern ?timelineClose@vk@@YAXXZ
extern ?shutdownPresent@vk@@YAXXZ
extern ?resetSelectors@vk@@YAXXZ
extern asm_arena_platform_shutdown
extern ?logFlush@vk@@YAXXZ
extern ?logShutdown@vk@@YAXXZ

global vk_shutdown_input
global vk_shutdown_audio
global vk_shutdown_recording
global vk_shutdown_diagnostics
global vk_shutdown_timeline
global vk_shutdown_present
global vk_shutdown_selectors
global vk_shutdown_platform
global vk_shutdown_log_flush
global vk_shutdown_log_shutdown

section .text

vk_shutdown_input:
        jmp     asm_input_shutdown

vk_shutdown_audio:
        jmp     ?audioShutdown@vk@@YAXXZ

vk_shutdown_recording:
        jmp     ?recClose@vk@@YAXXZ

vk_shutdown_diagnostics:
        jmp     ?diagReadbackShutdown@vk@@YAXXZ

vk_shutdown_timeline:
        jmp     ?timelineClose@vk@@YAXXZ

vk_shutdown_present:
        jmp     ?shutdownPresent@vk@@YAXXZ

vk_shutdown_selectors:
        jmp     ?resetSelectors@vk@@YAXXZ

vk_shutdown_platform:
        jmp     asm_arena_platform_shutdown

vk_shutdown_log_flush:
        jmp     ?logFlush@vk@@YAXXZ

vk_shutdown_log_shutdown:
        jmp     ?logShutdown@vk@@YAXXZ

section .note.GNU-stack noalloc noexec nowrite progbits
