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

        ; ---- allocate waterWorld (256*256) + its selector into textury[0] ----
        AllocateMemory 256*256, waterWorld
        mov     eax, EOS_ALLOCATE_SELECTOR
        mov     rsi, [rel waterWorld]
        add     rsi, qword [rel Code32_addr]
        mov     edi, 256*256
        call    eos_dispatch                 ; -> ax = handle
        movzx   edx, ax
        mov     word [rel textury+0], dx       ; t[0] = waterWorld (unused as texture)

        ; ---- real wall textures (reference PART2): t[1]=obrazek(0),
        ;      t[2..4]=t001(1), t[5]=env(3); world types 1,2,4,5 use these ----
        %macro texsel_from_vodka 2       ; %1=vka idx, %2=textury word slot
        mov     esi, [rel _file_addr]
        add     rsi, qword [rel Code32_addr]
        mov     eax, [rsi + (%1)*8]     ; file offset
        mov     r10, rax
        add     r10, qword [rel Code32_addr]
        mov     esi, r10d
        mov     edi, 256*256            ; generous limit (buffer within arena)
        mov     eax, EOS_ALLOCATE_SELECTOR
        call    eos_dispatch
        movzx   edx, ax
        mov     word [rel %2], dx
        %endmacro
        texsel_from_vodka 0, textury+2
        texsel_from_vodka 1, textury+4
        texsel_from_vodka 1, textury+6
        texsel_from_vodka 1, textury+8
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

        ; ---- blysk_no: one white camera-flash + re-apply world palette at
        ; ModPos > 0x500 (faithful port of P2.AS^ 202-212). ----
        cmp     word [rel ModPos], 0x500
        jle     .no_blysk
        cmp     byte [rel lampa], 0
        jne     .no_blysk
        mov     byte [rel lampa], 1
        lea     rsi, [rel white]
        call    pal_set
        mov     esi, [rel _pal]
        add     rsi, qword [rel Code32_addr]
        call    pal_set
.no_blysk:

        ; ---- advance trasa_ruch by ramki (frame-rate-scaled) ----
        mov     eax, [rel ramki]
        cmp     eax, 4
        jg      .adv
        mov     eax, 1
.adv:
        mov     ebx, eax
        shr     ebx, 2
        test    ebx, ebx
        jnz     .adv_apply
        mov     ebx, 1
.adv_apply:
        add     [rel trasa_ruch], ebx

        ; ---- world angle adders: world[i].angle += world[i].adder ----
        lea     r12, [rel vk_p2_world]      ; direct data label address
        mov     r13d, [rel vk_p2_worldsobjects]   ; value
        xor     ecx, ecx
.katys:
        cmp     ecx, r13d
        jae     .katys_done
        mov     eax, [r12 + 32]
        add     [r12 + 20], eax
        mov     eax, [r12 + 36]
        add     [r12 + 24], eax
        mov     eax, [r12 + 40]
        add     [r12 + 28], eax
        add     r12, 48
        inc     ecx
        jmp     .katys
.katys_done:

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
        sub     rsp, 0x20
        mov     rax, [rel p2_kol_tmp]
        mov     [rsp+0x20], rax
        mov     rax, [rel p2_obj_tmp]
        mov     [rsp+0x30], rax
        mov     rax, [rel p2_tex_tmp]
        mov     [rsp+0x38], rax
        mov     qword [rsp+0x40], 0
        call    vk_p2_render_frame
        add     rsp, 0x20

        ; ---- sun sprite ----
        call    sloneczko

        ; ---- present ----
        WaitVbl
        mov     [rel ramki], eax
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
        mov     [rsp+0x30], rax
        mov     rax, [rel p2_tex_tmp]
        mov     [rsp+0x38], rax
        mov     qword [rsp+0x40], 0
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

        WaitVbl
        mov     [rel ramki], eax

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
        ; re-clamp so the sprite offset never leaves the 36-frame table
        mov     eax, [rel sun_step]
        cmp     eax, 35
        jg      .wrap_hi
        cmp     eax, 0
        jge     .wrap_done
.wrap_hi:
        xor     edx, edx
        mov     ecx, 36
        idiv    ecx
        test    edx, edx
        jns     .wrap_pos
        add     edx, 36
.wrap_pos:
        mov     [rel sun_step], edx
.wrap_done:

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

        WaitVbl
        mov     [rel ramki], eax
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
