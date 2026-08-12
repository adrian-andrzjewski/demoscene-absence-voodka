; boot.asm - assembly demo entry.  Replaces the phase-1b smoke loop.
;
; DemoStart32 (Microsoft x64 ABI):
;       int DemoStart32(void* arenaBase, uint64_t arenaSize)
;
; Flow (mirrors DEMO.AS^ start32):
;   - Code32_addr = arenaBase
;   - _file_addr = LoadFile "voodka.dat"   (packed archive arena offset)
;   - _scr_Addr  = backbuffer arena offset (== platform kBackbufferOffset)
;   - framebuffer_off = platform framebuffer offset
;   - run the complete scene sequence (gratki, then gratki + woda)
;   - return 0
;
; Framebuffer/backbuffer offsets come from the platform via the bridge.

BITS 64
DEFAULT REL

%include "eos.inc"
%include "video.inc"
%include "vodka.inc"

section .text

extern vk_load_internal_file
extern vk_framebuffer_offset
extern vk_backbuffer_offset
extern Code32_addr
extern eos_dispatch

extern _scr_Addr
extern _scrSel
extern _file_addr
extern _screen
extern GetModPos
extern ModPos

; shared tunnel tables (DEMO.AS^): _tableToonel arena offset, filled by the
; standalone vk_make_toonel (toonel.asm) at Start32 time.
global _tableToonel
section .bss
_tableToonel: resd 1
section .text
extern vk_make_toonel

extern scene_oko_szklo
extern scene_swiatynia_city
extern scene_tunel_wygibasy
extern scene_processorek_nevosolek
extern scene_torus_ustep_village
extern scene_gratki
extern scene_gratki_woda
extern scene_nad_czerwonym_lampa

global DemoStart32
DemoStart32:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        ; 5 pushes (40): entry RSP%16==8 -> after pushes ==0; sub 0x20 keeps 0.
        sub     rsp, 0x20

        ; preserve arenaBase (rcx = first arg) in r12 across all calls
        mov     r12, rcx
        mov     [rel Code32_addr], r12

        ; framebuffer_off = platform offset
        call    vk_framebuffer_offset
        mov     [rel framebuffer_off], eax

        ; load the packed archive (name passed via dispatch)
        lea     rdx, [rel archive_name]
        mov     eax, EOS_LOAD_INTERNAL_FILE
        call    eos_dispatch
        mov     [rel _file_addr], eax

        ; _scr_Addr = kBackbufferOffset
        call    vk_backbuffer_offset
        mov     [rel _scr_Addr], eax

        ; _scrSel = selector over the backbuffer (DEMO.AS^ allocates the
        ; screen selector at Start32; the tunnel and object scenes read _scrSel
        ; for gs_sel). Without this, standalone scene runs (--scene NAME, or legacy --part N) inherit
        ; tm_face writes to a null screen base.
        mov     eax, EOS_ALLOCATE_SELECTOR
        mov     esi, [rel _scr_Addr]
        add     rsi, qword [rel Code32_addr]
        mov     edi, 320*200
        call    eos_dispatch
        mov     [rel _scrSel], ax

        ; shared tunnel tables (built once in Start32, used by the tunnel parts)
        ; _tableToonel = 128000-byte arena table: u/v coordinates for 320x200.
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, 128000
        call    eos_dispatch
        mov     [rel _tableToonel], edx
        mov     rcx, rdx
        add     rcx, qword [rel Code32_addr]   ; real 128000-byte arena buffer
        call    vk_make_toonel

        ; ---- run the selected scene ----------------------------------------
        ; vk_get_entry_scene(): 0 = full sequence (default), 1..8 = run only
        ; that scene. The audio timeline was seeked by --scene or its numeric
        ; --part historical selector.
        extern vk_get_entry_scene
        call    vk_get_entry_scene

        cmp     eax, 0
        je      .full_sequence
        cmp     eax, 1
        je      .single_oko_szklo
        cmp     eax, 2
        je      .single_swiatynia_city
        cmp     eax, 3
        je      .single_tunel_wygibasy
        cmp     eax, 4
        je      .single_processorek_nevosolek
        cmp     eax, 5
        je      .single_torus_ustep_village
        cmp     eax, 6
        je      .single_gratki
        cmp     eax, 7
        je      .single_gratki_woda
        cmp     eax, 8
        je      .single_nad_czerwonym_lampa
        ; unknown single part: default to the full slice
        jmp     .full_sequence

.single_oko_szklo:
        call    scene_oko_szklo
        jmp     .done
.single_swiatynia_city:
        call    scene_swiatynia_city
        jmp     .done
.single_tunel_wygibasy:
        call    scene_tunel_wygibasy
        jmp     .done
.single_processorek_nevosolek:
        call    scene_processorek_nevosolek
        jmp     .done
.single_torus_ustep_village:
        call    scene_torus_ustep_village
        jmp     .done
.single_gratki:
        call    scene_gratki
        jmp     .done
.single_gratki_woda:
        call    scene_gratki_woda
        jmp     .done
.single_nad_czerwonym_lampa:
        call    scene_nad_czerwonym_lampa
        jmp     .done

.full_sequence:
        ; current implemented slice: the eight scenes in order. processorek
        ; Nevosolek (multi-object 3D viewer) runs the full scene from its own
        ; ModPos window
        ; (0x0D40..0x1400) and hands off to torus ustep village (P5) at 0x1400.
        ; (run progress is reported centrally by the platform via the ModPos
        ; timeline; see port/platform/progress.cpp)
        call    scene_oko_szklo
        call    scene_swiatynia_city
        call    scene_tunel_wygibasy
        call    scene_processorek_nevosolek
        call    scene_torus_ustep_village
        call    scene_gratki
        call    scene_gratki_woda
        call    scene_nad_czerwonym_lampa

.done:
        xor     eax, eax
        add     rsp, 0x20
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

section .data
archive_name: db "voodka.dat", 0

section .note.GNU-stack noalloc noexec nowrite progbits
