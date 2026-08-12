; audio_dispatch.asm - production namespace-vk audio ABI.
;
; The dedicated player orchestration is native assembly. This file keeps the
; exact MSVC-decorated namespace ABI and disabled-mode behavior. The reference
; executable has its own audio.cpp ABI and never links this file.

BITS 64
DEFAULT REL

%include "win64_abi.inc"

extern ?audioAsmInit@vk@@YAHPEBDH@Z
extern ?audioAsmShutdown@vk@@YAXXZ
extern ?audioAsmPlay@vk@@YAHXZ
extern ?audioAsmStop@vk@@YAHXZ
extern ?audioAsmModPos@vk@@YAIXZ
extern ?audioAsmModLength@vk@@YAIXZ
extern ?audioAsmElapsedSec@vk@@YANXZ
extern ?audioAsmPump@vk@@YAXXZ
extern ?audioAsmSeekRows@vk@@YAII@Z
extern ?audioAsmSeekMs@vk@@YAIH@Z
extern ?audioAsmSeekOrder@vk@@YAIH@Z
extern ?audioAsmSelfCheck@vk@@YAHH@Z
extern vk_log_printf

global ?audioSetAssemblyMode@vk@@YAX_N@Z
global ?audioInit@vk@@YAHPEBDH@Z
global ?audioShutdown@vk@@YAXXZ
global ?audioPlay@vk@@YAHXZ
global ?audioStop@vk@@YAHXZ
global ?getModPos@vk@@YAIXZ
global ?getModLength@vk@@YAIXZ
global ?audioElapsedSec@vk@@YANXZ
global ?audioPump@vk@@YAXXZ
global ?audioSeekRows@vk@@YAII@Z
global ?audioSeekMs@vk@@YAIH@Z
global ?audioSeekOrder@vk@@YAIH@Z
global ?audioSelfCheck@vk@@YAHH@Z

section .data
audio_assembly_enabled: db 1
audio_disabled_message: db "[audio] libxmp reference path is unavailable in VOODKA.exe", 10, 0

section .text

; void vk::audioSetAssemblyMode(bool enabled)
?audioSetAssemblyMode@vk@@YAX_N@Z:
        mov     [rel audio_assembly_enabled], cl
        ret

; int vk::audioInit(const char* modPath, int sampleRate)
?audioInit@vk@@YAHPEBDH@Z:
        cmp     byte [rel audio_assembly_enabled], 0
        je      .audio_init_disabled
        jmp     ?audioAsmInit@vk@@YAHPEBDH@Z

.audio_init_disabled:
        sub     rsp, 0x28
        lea     rcx, [rel audio_disabled_message]
        call    vk_log_printf
        xor     eax, eax
        add     rsp, 0x28
        ret

; void vk::audioShutdown(void)
?audioShutdown@vk@@YAXXZ:
        jmp     ?audioAsmShutdown@vk@@YAXXZ

; int vk::audioPlay(void)
?audioPlay@vk@@YAHXZ:
        cmp     byte [rel audio_assembly_enabled], 0
        je      .audio_play_disabled
        jmp     ?audioAsmPlay@vk@@YAHXZ
.audio_play_disabled:
        xor     eax, eax
        ret

; int vk::audioStop(void)
?audioStop@vk@@YAHXZ:
        cmp     byte [rel audio_assembly_enabled], 0
        je      .audio_stop_disabled
        jmp     ?audioAsmStop@vk@@YAHXZ
.audio_stop_disabled:
        xor     eax, eax
        ret

; uint32_t vk::getModPos(void)
?getModPos@vk@@YAIXZ:
        cmp     byte [rel audio_assembly_enabled], 0
        je      .audio_modpos_disabled
        jmp     ?audioAsmModPos@vk@@YAIXZ
.audio_modpos_disabled:
        xor     eax, eax
        ret

; uint32_t vk::getModLength(void)
?getModLength@vk@@YAIXZ:
        cmp     byte [rel audio_assembly_enabled], 0
        je      .audio_modlength_disabled
        jmp     ?audioAsmModLength@vk@@YAIXZ
.audio_modlength_disabled:
        xor     eax, eax
        ret

; double vk::audioElapsedSec(void)
?audioElapsedSec@vk@@YANXZ:
        cmp     byte [rel audio_assembly_enabled], 0
        je      .audio_elapsed_disabled
        jmp     ?audioAsmElapsedSec@vk@@YANXZ
.audio_elapsed_disabled:
        pxor    xmm0, xmm0
        ret

; void vk::audioPump(void)
?audioPump@vk@@YAXXZ:
        cmp     byte [rel audio_assembly_enabled], 0
        je      .audio_pump_disabled
        jmp     ?audioAsmPump@vk@@YAXXZ
.audio_pump_disabled:
        ret

; uint32_t vk::audioSeekRows(uint32_t modpos)
?audioSeekRows@vk@@YAII@Z:
        cmp     byte [rel audio_assembly_enabled], 0
        je      .audio_seek_rows_disabled
        jmp     ?audioAsmSeekRows@vk@@YAII@Z
.audio_seek_rows_disabled:
        xor     eax, eax
        ret

; uint32_t vk::audioSeekMs(int ms)
?audioSeekMs@vk@@YAIH@Z:
        cmp     byte [rel audio_assembly_enabled], 0
        je      .audio_seek_ms_disabled
        jmp     ?audioAsmSeekMs@vk@@YAIH@Z
.audio_seek_ms_disabled:
        xor     eax, eax
        ret

; uint32_t vk::audioSeekOrder(int order)
?audioSeekOrder@vk@@YAIH@Z:
        cmp     byte [rel audio_assembly_enabled], 0
        je      .audio_seek_order_disabled
        jmp     ?audioAsmSeekOrder@vk@@YAIH@Z
.audio_seek_order_disabled:
        xor     eax, eax
        ret

; int vk::audioSelfCheck(int seconds)
?audioSelfCheck@vk@@YAHH@Z:
        cmp     byte [rel audio_assembly_enabled], 0
        je      .audio_self_check_disabled
        jmp     ?audioAsmSelfCheck@vk@@YAHH@Z
.audio_self_check_disabled:
        mov     eax, 1
        ret

section .note.GNU-stack noalloc noexec nowrite progbits
