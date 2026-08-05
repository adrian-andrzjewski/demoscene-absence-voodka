; p2.asm - NASM x64 port of CODE/P2/P2.AS^  (part 2: the 3D stadium fly-through
; + the reflective water floor).
;
; Faithful port. The per-frame world render is delegated to vk_p2_render_frame
; (p2loop.asm) which already composes MakeCameraMatrix-input visibility +
; VirSort + the WorldKol walk + prepareObjectVirtual + drawObject, so this file
; only sequences the P2 stage: camera path selection, world angle adders, the
; two frame loops (Main world / Main2 water), the sun sprite, and the drops.
;
; Timeline (ModPos): P2 spans 0x0400..0x0B40 (per app.cpp kPartStartModPos).
;   Main  : world fly-through (camera from trasa/widoki), exits at >0x730.
;   wodda : fade + pikus water picture; Main2 loops camera+world until 0xB3F.
;
; EOS/allocator, palette (pal.inc), screen (video.inc), and the archive
; (vodka.inc) macros match the other parts. Object loading uses vk_load_object
; (loader.asm); the WZet/Kol scratch and the World table come from p2world.asm;
; camera selection from p2path.asm.
;
; ABI: 8-push prologue + sub 0x28 -> RSP%16==0 at every call site.

BITS 64
DEFAULT REL

%include "eos.inc"
%include "video.inc"
%include "pal.inc"
%include "vodka.inc"
%include "water.inc"

; WaitVbl + store ramki. EOS wait_vbl returns the per-frame retrace DELTA
; (~1); the port's eos_dispatch does the same (bridge vk_wait_vbl computes
; the delta), so no local last_vbl bookkeeping is needed here anymore.
%macro WaitVblDelta 0
        WaitVbl
        mov     [rel ramki], eax
%endmacro

extern _screen
extern _scr_Addr
extern _file_addr
extern ModPos
extern GetModPos
extern Code32_addr
extern eos_dispatch
extern white
extern cam_cameraX
extern cam_cameraY
extern cam_cameraZ
extern cam_eyeAX
extern cam_eyeAY
extern cam_eyeAZ
extern fs_sel
extern gs_sel

; p2 render loop + camera path
extern vk_p2_render_frame
extern vk_p2_camera
extern vk_make_camera_matrix
extern vk_load_object

; world table (p2world.asm) + object struct offsets (loader.asm)
extern vk_p2_world
extern vk_p2_worldsobjects
extern lo_objects

section .data align=16
global part2

ramki:      dd 0
last_vbl:   dd 0
trasa_ruch: dd 0
plum:       dd 0
bolek:      dd 1
ileFadow:   dd 0
znacznik:   dd 0
lampa:      db 0
; world palette (2WORLD.PAL, vodka 37) - arena offset, add Code32_addr to use.
_pal:       dd 0
spos:       dd 0
sun:        dd 0
sun_step:   dd 0
waterWorld: dd 0
stary:      dd 0

; shared texture-selector table (world +44 type -> selector). Filled in boot.
global textury
textury:    times 10 dw 0

; working scr + count multiples
_scrSel:    dw 0

; obroty - world[0] (torus) scripted rotation for ModPos >= 0x600 (P2.AS^ 45-65).
; idx = (ModPos & 0xf)*3; each triple is (dax,day,daz) added to world[0]'s angles.
obroty:     dd 22,22,8
            dd 22,22,8
            dd -22,22,8
            dd -22,22,8
            dd -22,22,8
            dd -22,22,8
            dd -22,-22,8
            dd -22,-22,8
            dd -22,-22,8
            dd -22,-22,8
            dd -22,-22,-13
            dd -22,-22,-13
            dd -22,-22,-13
            dd -22,-22,-13
            dd -3,-14,12
            dd -3,-14,12
            dd -3,-14,12
            dd -3,-14,12
            dd -3,-14,12
            dd -3,-14,12

; object file indices 12..15 (VODKA.TXT, 0-based) - the four stadium walls.
; texture index 0 (selector from textury[0]) as the original LoadObject 12,0.

section .bss align=16
worldzet:   resd 256
worldkol:   resd 256

section .text

; ------------------------------------------------------------------ part2 ---
global part2
part2:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0x28

        ; ---- screen setup: _screen = _scr_Addr, clear backbuffer ----
        mov     eax, [rel _scr_Addr]
        mov     [rel _screen], eax
        mov     edi, eax
        add     rdi, qword [rel Code32_addr]
        xor     eax, eax
        mov     ecx, 16000
        rep stosd

        ; ---- screen selector (gs for tm_face): backbuffer base ----
        ; tm_face writes pixels through sel_base_table[gs_sel]; without this
        ; the 3D raster writes to a stale/null screen base and is invisible.
        mov     eax, EOS_ALLOCATE_SELECTOR
        mov     esi, [rel _scr_Addr]
        add     rsi, qword [rel Code32_addr]
        mov     edi, 320*200
        call    eos_dispatch                 ; -> ax = handle
        movzx   edx, ax
        mov     [rel gs_sel], edx

        ; ---- sort scratch for the per-face painter sort (P2.AS^ SortMem) ----
        extern prep_sort
        call    prep_sort

        ; ---- allocate waterWorld (256*256) + its selector into textury[0] ----
        AllocateMemory 256*256, waterWorld
        mov     eax, EOS_ALLOCATE_SELECTOR
        mov     rsi, [rel waterWorld]
        add     rsi, qword [rel Code32_addr]
        mov     edi, 256*256
        call    eos_dispatch                 ; -> ax = handle
        movzx   edx, ax
        mov     word [rel textury+0], dx       ; t[0] = waterWorld (unused as texture)

        ; ---- wall textures (reference CODE/PART2): t[1]=t001(1),
        ;      t[2..4]=t002(2), t[5]=env(3); world types 1,2,5 use these ----
        ;      (an earlier version shifted t[1]/t[2] to obrazek/t001 - the
        ;      floor then showed the gold obrazek noise instead of t001)
        %macro texsel_from_vodka 2       ; %1=vka idx, %2=textury word slot
        ; NOTE: _file_addr is a DWORD (globals.asm resd). A 64-bit load also
        ; scoops the following dword (`len`, which P1 sets to 81), so after
        ; P1 runs rsi becomes garbage (0x51_00040000) and the table deref
        ; crashes. Keep this a 32-bit load (zero-extends cleanly).
        mov     esi, [rel _file_addr]
        add     rsi, qword [rel Code32_addr]
        mov     r10, rsi                ; archive offset-table real ptr
        mov     eax, [r10 + (%1)*8]     ; file offset (relative to the table)
        mov     r10, rax
        add     r10, rsi                ; base = table_rt + file_off (has _file_addr!)
        mov     rsi, r10                ; full 64-bit real ptr
        mov     edi, 256*256            ; generous limit (buffer within arena)
        mov     eax, EOS_ALLOCATE_SELECTOR
        call    eos_dispatch
        movzx   edx, ax
        mov     word [rel %2], dx
        %endmacro
        texsel_from_vodka 1, textury+2
        texsel_from_vodka 2, textury+4
        texsel_from_vodka 2, textury+6
        texsel_from_vodka 2, textury+8
        texsel_from_vodka 3, textury+10

        ; ---- sun sprite (vodka 16 = klatki.dat) ----
        vodka   16, sun

        ; ---- load the four wall/torus objects (12..15) with texsel=textury[0]
        ; (seed the loader's bump allocator + object counter first)
        extern lo_bump
        extern lo_number
        mov     dword [rel lo_bump], 0x02000000
        mov     dword [rel lo_number], 0
        mov     dword [rel _obidx], 12
.load_obj_loop:
        mov     eax, [rel _obidx]
        cmp     eax, 16
        jae     .load_done
        ; resolve the arena offset of file <eax>: fileOff = _file_addr + rel
        mov     esi, [rel _file_addr]
        add     rsi, qword [rel Code32_addr]
        movsxd  r9, eax
        mov     ebx, [rsi + r9*8]           ; file relative offset
        mov     eax, ebx
        add     eax, [rel _file_addr]       ; arena offset of file data
        ; vk_load_object(base, fileOff, textureSel=textury[0])
        mov     rcx, [rel Code32_addr]
        mov     edx, eax
        movzx   r8d, word [rel textury+0]
        call    vk_load_object
        inc     dword [rel _obidx]
        jmp     .load_obj_loop
.load_done:

        ; ---- allocate stary (320*200 copy buffer) ----
        AllocateMemory 64000, stary

        ; ---- initial camera from first_ruch (= trasa[0] xyz angles) ----
        extern vk_p2_trasa
        lea     rsi, [rel vk_p2_trasa]
        mov     eax, [rsi + 0]
        mov     [rel cam_cameraX], eax
        mov     eax, [rsi + 4]
        mov     [rel cam_cameraY], eax
        mov     eax, [rsi + 8]
        mov     [rel cam_cameraZ], eax
        mov     eax, [rsi + 12]
        mov     [rel cam_eyeAX], eax
        mov     eax, [rsi + 16]
        mov     [rel cam_eyeAY], eax
        mov     eax, [rsi + 20]
        mov     [rel cam_eyeAZ], eax

        mov     dword [rel ramki], 0
        mov     dword [rel trasa_ruch], 0
        mov     dword [rel ileFadow], 0

        ; (eos_dispatch WAIT_VBL returns the per-frame delta, matching the
        ; original EOS; no last_vbl priming needed here anymore)

        ; ---- world palette (2WORLD.PAL) for the stadium; P1 hands off with a
        ; full-white palette (see p1.asm .virtual), so P2 fades into _pal below.
        vodka   37, _pal

; ------------------------------------------------------------------- Main ---
.main_loop:
        ; ---- palette fade-in from P1's white end-state toward _pal (world).
        ; Faithful port of P2.AS^ Main 130-143: a per-frame ileFadow ramp that
        ; steps pal_fadein10 by (ileFadow>>1) toward _pal, dissolving white.
        mov     eax, [rel ileFadow]
        cmp     eax, 63
        jg      .pal_nicosc
        cmp     eax, 126
        jle     .pal_here
        mov     dword [rel ileFadow], 63
        jmp     .pal_out
.pal_here:
        inc     dword [rel ileFadow]
.pal_out:
        movzx   ebx, byte [rel ileFadow]
        sar     bl, 1
        mov     edi, [rel _pal]
        add     rdi, qword [rel Code32_addr]
        call    pal_fadein10
.pal_nicosc:

        call    GetModPos
        movzx   eax, word [rel ModPos]

        ; ---- camera: trasa path or scripted widoki ----
        movzx   ecx, ax
        mov     edx, [rel trasa_ruch]
        lea     r8, [rel p2_cam_out]
        call    vk_p2_camera
        ; apply camera result to globals
        mov     eax, [rel p2_cam_out+0]
        mov     [rel cam_cameraX], eax
        mov     eax, [rel p2_cam_out+4]
        mov     [rel cam_cameraY], eax
        mov     eax, [rel p2_cam_out+8]
        mov     [rel cam_cameraZ], eax
        mov     eax, [rel p2_cam_out+12]
        mov     [rel cam_eyeAX], eax
        mov     eax, [rel p2_cam_out+16]
        mov     [rel cam_eyeAY], eax
        mov     eax, [rel p2_cam_out+20]
        mov     [rel cam_eyeAZ], eax

        ; ---- trasa-path camera advance + world rotation (P2.AS^ ruchamy) ----
        ; Only the trasa path (ModPos <= 0x63F) advances trasa_ruch / rotates the
        ; world; the scripted widoki phase does neither.
        lea     r12, [rel vk_p2_world]      ; world base (register-indirect avoids
                                            ; ADDR32 reloc to the external .data)
        cmp     word [rel ModPos], 0x63f
        jg      .no_ruch

        ; --- ModPos <= 0x500: slow advance, no world rotation ---
        cmp     word [rel ModPos], 0x500
        jle     .slow_adv

        ; --- ModPos > 0x500: one white camera-flash + re-apply world palette ----
        cmp     byte [rel lampa], 0
        jne     .blysk_ok
        mov     byte [rel lampa], 1
        lea     rsi, [rel white]
        call    pal_set
        mov     esi, [rel _pal]
        add     rsi, qword [rel Code32_addr]
        call    pal_set
.blysk_ok:
        ; trasa_ruch += ramki (full rate)
        mov     eax, [rel ramki]
        add     [rel trasa_ruch], eax

        ; --- ModPos >= 0x600: world[0] (torus) obroty-table spin ---
        cmp     word [rel ModPos], 0x600
        jge     .obroty

        ; --- 0x500 < ModPos < 0x600: world[0].ay/az fast spin + katys ----
        mov     eax, [rel ramki]
        shl     eax, 1
        add     dword [r12 + 6*4], eax   ; world[0].ay += ramki*2
        shl     eax, 1
        add     dword [r12 + 7*4], eax   ; world[0].az += ramki*4
        jmp     .do_katys

.obroty:
        lea     r13, [rel obroty]              ; obroty base (indexed access needs
                                               ; a 64-bit index reg - rel/32-bit can't)
        movzx   eax, word [rel ModPos]
        and     eax, 0xf
        imul    eax, eax, 3                    ; (ModPos&0xf)*3  (dword count)
        movsxd  rcx, eax
        shl     rcx, 2                         ; byte offset
        mov     ebx, [r13 + rcx]
        add     dword [r12 + 20], ebx
        mov     ebx, [r13 + rcx + 4]
        add     dword [r12 + 24], ebx
        mov     ebx, [r13 + rcx + 8]
        add     dword [r12 + 28], ebx
        jmp     .no_katys

.slow_adv:
        ; ModPos <= 0x500: trasa_ruch += (ramki>4 ? ramki>>2 : 1)
        mov     eax, [rel ramki]
        cmp     eax, 4
        jg      .ksdk
        mov     eax, 1
        jmp     .slow_apply
.ksdk:
        sar     eax, 2
.slow_apply:
        add     [rel trasa_ruch], eax
        jmp     .no_katys

.do_katys:
        ; ---- world angle adders: world[i].angle += world[i].adder ----
        mov     r13d, [rel vk_p2_worldsobjects]   ; value
        xor     ecx, ecx
.katys:
        cmp     ecx, r13d
        jae     .no_katys
        mov     eax, [r12 + 32]
        add     [r12 + 20], eax
        mov     eax, [r12 + 36]
        add     [r12 + 24], eax
        mov     eax, [r12 + 40]
        add     [r12 + 28], eax
        add     r12, 48
        inc     ecx
        jmp     .katys
.no_katys:
.no_ruch:

        Screen0

        ; ---- camera matrix from eye angles ----
        mov     ecx, [rel cam_eyeAX]
        mov     edx, [rel cam_eyeAY]
        mov     r8d, [rel cam_eyeAZ]
        call    vk_make_camera_matrix

        ; ---- render the world (visibility+sort+walk: prepare+draw) ----
        mov     rcx, [rel Code32_addr]          ; base
        lea     rdx, [rel vk_p2_world]      ; direct data label address
        mov     r8d, [rel vk_p2_worldsobjects]
        lea     r9, [rel worldzet]
        lea     rax, [rel worldkol]
        mov     [rel p2_kol_tmp], rax
        lea     rax, [rel lo_objects]
        mov     [rel p2_obj_tmp], rax
        lea     rax, [rel textury]
        mov     [rel p2_tex_tmp], rax
        ; vk_p2_render_frame(base, world, count, zet, kol, objects, textury, trace=0)
        ; 5th..8th args at [rsp+0x20..0x38] (callee reads they at +0x20/+0x28/+0x30/+0x38).
        sub     rsp, 0x20
        mov     rax, [rel p2_kol_tmp]
        mov     [rsp+0x20], rax
        mov     rax, [rel p2_obj_tmp]
        mov     [rsp+0x28], rax
        mov     rax, [rel p2_tex_tmp]
        mov     [rsp+0x30], rax
        mov     qword [rsp+0x38], 0
        call    vk_p2_render_frame
        add     rsp, 0x20

        ; ---- sun sprite ----
        call    sloneczko

        ; ---- present ----
        WaitVblDelta
        Ekran

        ; ---- currant: once the fade ramp has run, commit the full world
        ; palette (faithful port of P2.AS^ currant 309-312). ----
        cmp     dword [rel ileFadow], 63
        jle     .currant_skip
        mov     esi, [rel _pal]
        add     rsi, qword [rel Code32_addr]
        call    pal_set
.currant_skip:

        ; ---- loop / exit to water stage ----
        call    GetModPos
        movzx   eax, word [rel ModPos]
        cmp     eax, 0x730
        jle     .main_loop

        ; ---- wodda: fade to white, draw pikus water picture, then Main2 ----
        lea     rsi, [rel white]
        call    pal_set
        call    pikus

        ; restore stary (the pre-water screen) into the framebuffer
        mov     esi, [rel stary]
        add     rsi, qword [rel Code32_addr]
        mov     edi, [rel _screen]
        add     rdi, qword [rel Code32_addr]
        mov     ecx, 16000
        rep movsd

        WaitVbl
        ; re-apply the world palette for the water stage (faithful port of
        ; P2.AS^ wodda 331-334: wait_vbl then pal_set(_pal)).
        mov     esi, [rel _pal]
        add     rsi, qword [rel Code32_addr]
        call    pal_set

        ; world[0] angle adders for Main2 water wobble
        lea     r12, [rel vk_p2_world]
        mov     dword [r12+32], 16
        mov     dword [r12+36], 6
        mov     dword [r12+40], 2

; ------------------------------------------------------------------ Main2 ---
.main2_loop:
        call    GetModPos
        movzx   eax, word [rel ModPos]

        ; ---- spos toggle: world[0].angleX *= -1 on modpos&3==0 ----
        mov     eax, [rel ModPos]
        cmp     eax, [rel spos]
        je      .spos_done
        and     eax, 3
        jnz     .spos_pos
        neg     dword [r12+32]
.spos_pos:
        movzx   eax, word [rel ModPos]
        mov     [rel spos], eax
.spos_done:

        ; ---- camera from trasa (Main2 uses trasa path, not widoki) ----
        movzx   ecx, word [rel ModPos]
        and     ecx, 0x63f                  ; force trasa branch
        mov     edx, [rel trasa_ruch]
        lea     r8, [rel p2_cam_out]
        call    vk_p2_camera
        mov     eax, [rel p2_cam_out+0]
        mov     [rel cam_cameraX], eax
        mov     eax, [rel p2_cam_out+4]
        mov     [rel cam_cameraY], eax
        mov     eax, [rel p2_cam_out+8]
        mov     [rel cam_cameraZ], eax
        mov     eax, [rel p2_cam_out+12]
        mov     [rel cam_eyeAX], eax
        mov     eax, [rel p2_cam_out+16]
        mov     [rel cam_eyeAY], eax
        mov     eax, [rel p2_cam_out+20]
        mov     [rel cam_eyeAZ], eax

        mov     eax, [rel ramki]
        add     [rel trasa_ruch], eax

        ; ---- world angle adders for all records ----
        lea     r12, [rel vk_p2_world]
        mov     r13d, [rel vk_p2_worldsobjects]
        xor     ecx, ecx
.katyz:
        cmp     ecx, r13d
        jae     .katyz_done
        mov     eax, [r12 + 32]
        add     [r12 + 20], eax
        mov     eax, [r12 + 36]
        add     [r12 + 24], eax
        mov     eax, [r12 + 40]
        add     [r12 + 28], eax
        add     r12, 48
        inc     ecx
        jmp     .katyz
.katyz_done:

        Screen0
        mov     ecx, [rel cam_eyeAX]
        mov     edx, [rel cam_eyeAY]
        mov     r8d, [rel cam_eyeAZ]
        call    vk_make_camera_matrix

        ; ---- render ----
        sub     rsp, 0x20
        mov     rax, [rel p2_kol_tmp]
        mov     [rsp+0x20], rax
        mov     rax, [rel p2_obj_tmp]
        mov     [rsp+0x28], rax
        mov     rax, [rel p2_tex_tmp]
        mov     [rsp+0x30], rax
        mov     qword [rsp+0x38], 0
        mov     rcx, [rel Code32_addr]
        lea     rdx, [rel vk_p2_world]
        mov     r8d, [rel vk_p2_worldsobjects]
        lea     r9, [rel worldzet]
        call    vk_p2_render_frame
        add     rsp, 0x20

        ; ---- bolek toggle (sun sweep direction) ----
        movzx   eax, word [rel ModPos]
        and     eax, 0x3f
        cmp     eax, 0x20
        jge     .dwar
        mov     dword [rel bolek], 1
        jmp     .sun
.dwar:
        mov     dword [rel bolek], -1
        .sun:
        call    sloneczko

        WaitVblDelta

        ; ---- fade toward white near the end (0xB20..0xB3F) ----
        movzx   eax, word [rel ModPos]
        cmp     eax, 0xB20
        jl      .no_fade
        and     eax, 31
        shl     eax, 1
        movzx   ebx, al
        lea     rdi, [rel white]
        call    pal_fadein10
        ; re-apply the stage world palette so the fade stays legible
        ; (faithful port of P2.AS^ parker 434-443: pal_fadein10 then pal_set _pal)
        mov     esi, [rel _pal]
        add     rsi, qword [rel Code32_addr]
        call    pal_set
.no_fade:

        Ekran

        call    GetModPos
        movzx   eax, word [rel ModPos]
        cmp     eax, 0xB3F
        jle     .main2_loop

        ; ---- teardown: free selectors/memory (no-op in port) ----
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

; ------------------------------------------------------------- sloneczko ----
; Blits the 64x64 sun sprite (klatki.dat frame at sun_step*4096) to screen at
; (254, 141) = row 205, col 254 as in the original. Advances sun_step by
; bolek*ramki/4 clamped to [0,35].
sloneczko:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        sub     rsp, 0x20

        ; sun_step in [0,35]
        mov     eax, [rel sun_step]
        cmp     eax, 36
        jl      .sk1
        sub     eax, 35
.sk1:
        cmp     eax, 0
        jg      .sk2
        add     eax, 35
.sk2:
        mov     [rel sun_step], eax

        ; sprite base = sun + sun_step*4096
        mov     eax, [rel sun_step]
        shl     eax, 12
        mov     esi, [rel sun]
        add     esi, eax
        add     rsi, qword [rel Code32_addr]

        ; dest = screen + ((205-64)*320)+254
        mov     edi, [rel _screen]
        add     rdi, qword [rel Code32_addr]
        add     rdi, ((205-64)*320)+254

        mov     r14, 64                 ; rows
.sr1:
        mov     r13, 64                 ; cols
.sr2:
        lodsb
        or      al, al
        jz      .skip
        mov     [rdi], al
.skip:
        inc     rdi
        dec     r13
        jnz     .sr2
        add     rdi, 320-64
        dec     r14
        jnz     .sr1

        ; advance sun_step (bounded: keep it a valid 0..35 frame index)
        mov     ebx, [rel bolek]
        mov     eax, [rel ramki]
        cmp     eax, 4
        jle     .slow
        shr     eax, 2
        jmp     .doit
.slow:
        mov     eax, 1
.doit:
        imul    ebx
        add     [rel sun_step], eax

        add     rsp, 0x20
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ------------------------------------------------------------------ pikus ---
; Water picture: renders the reflective floor stage (from P2/WATER).
; Loads the water picture/palette and runs the drop+Water raster loop until
; ModPos > 0x73f.
pikus:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0x28

        AllocateMemoryFree 320*200*2, _bufor1
        AllocateMemoryFree 320*200*2, _bufor2

        ; ---- water picture ----
        ; shared water.inc drawWater samples `_obrazek` as a 160x100 picture;
        ; obrazek.dat (vodka 0) is the grayscale water picture.
        extern _obrazek
        vodka   0, _obrazek

        ; render until 0x73f
.pikus_loop:
        ; a few water drops around the current drop position
        mov     eax, [rel licznik]
        and     eax, 127
        lea     rbx, [rel tablica3]
        mov     ebx, [rbx + rax*4]
        mov     esi, [rel _bufor1]
        add     rsi, qword [rel Code32_addr]
        add     rsi, rbx                ; 64-bit add: ebx is an arena-relative delta
        mov     byte [rsi], 0xFF
        mov     byte [rsi+2], 0xFF
        mov     byte [rsi+4], 0xFF
        mov     byte [rsi+640], 0xFF
        mov     byte [rsi+642], 0xFF
        mov     byte [rsi+644], 0xFF

        mov     eax, [rel ramki]
        cmp     eax, 2
        jge     .drop_amt
        inc     dword [rel licznik]
        jmp     .drop_done
.drop_amt:
        shr     eax, 1
        add     [rel licznik], eax
.drop_done:

        mov     edi, [rel _screen]
        add     rdi, qword [rel Code32_addr]
        xor     eax, eax
        mov     ecx, 8000
        rep stosq                        ; clear screen (bg = water pic base)

        call    drawWater
        call    calculateWater
        inc     dword [rel nPage]

        WaitVblDelta
        Ekran

        call    GetModPos
        movzx   eax, word [rel ModPos]
        cmp     eax, 0x73f
        jle     .pikus_loop

        lea     rsi, [rel white]
        call    pal_set

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

; ------------------------------------------------------------ data/section ---
; camera selection scratch + render-frame arg temps
section .data align=16
p2_cam_out: times 8 dd 0
p2_kol_tmp: dq 0
p2_obj_tmp: dq 0
p2_tex_tmp: dq 0
_obidx:   dd 0
; _bufor1/_bufor2/nPage are provided by p7.asm (shared water.inc consumers)
licznik:  dd 0

extern _bufor1
extern _bufor2
extern nPage

%include "p2_tablica3.asm"   ; module-local tablica3 (single-dd, like p7)
