; p5.asm - NASM x64 port of CODE/P5/P5.AS^ (part 5: morphing torus over a
; reflective water world with stone-ring/floor objects on a long camera path).
;
; Faithful port. Reuses the ported VR/objects layer used by swiatynia city (P2):
;   - vk_vr_world_render_frame   : visibility + VirSort + WorldKol walk + prepare+draw
;   - vk_prepare_object / vk_draw_object : single-object render (rysujCiulusa)
;   - vk_make_camera_matrix + cam_* globals, vk_load_object into lo_objects,
;     shared `textury` (swiatynia city (P2)), water.p5.inc (torus ustep village (P5) 128x128 ripple -> 256x256 water).
;
; Timeline (ModPos): 4 intro czensc overlay scenes (ends 0x141f/0x143f/0x151f/
; 0x153f), then Main (morph + world + water) until >0x1b3f.
;
; ABI: routines calling C/EOS/helpers use the 8-push prologue + sub 0x28 ->
; RSP%16==0 at every call site.

BITS 64
DEFAULT REL

%include "eos.inc"
%include "video.inc"
%include "pal.inc"
%include "vodka.inc"
%include "water.p5.inc"

extern _screen
extern _scr_Addr
extern _scrSel
extern _file_addr
extern ModPos
extern GetModPos
extern Code32_addr
extern eos_dispatch
extern white

; shared VR objects/selectors (swiatynia city (P2) / loader / cammat)
extern textury
extern lo_objects
extern lo_bump
extern lo_number
extern cam_cameraX, cam_cameraY, cam_cameraZ
extern cam_eyeAX, cam_eyeAY, cam_eyeAZ
extern vk_make_camera_matrix
extern vk_load_object
extern vk_vr_world_render_frame
extern vk_prepare_object
extern vk_draw_object
extern gs_sel
extern fs_sel

; water consumers (defined in p7.asm / here)
extern _bufor1
extern _bufor2
extern _obrazek
extern _waterWorld

ruchow  EQU 3859

; vodka <idx>, <offvar> then allocate a selector on the file -> textury slot
; NOTE: the selector base must be the FULL 64-bit real pointer
; (Code32 + _file_addr + file offset). An earlier version passed
; (Code32 + file offset) truncated to 32 bits: sel_base_table then held a
; garbage low-32 "pointer" and tm_face faulted on the first textured face.
%macro vodkasel 3
        mov     esi, [rel _file_addr]
        add     rsi, qword [rel Code32_addr]
        mov     eax, [rsi + (%1)*8]
        mov     r10, rax
        add     r10, rsi                ; table_rt + file offset (full 64-bit)
        mov     rsi, r10
        mov     edi, 0xffff
        mov     eax, EOS_ALLOCATE_SELECTOR
        call    eos_dispatch
        mov     word [rel %3], ax
%endmacro

section .data align=16
global scene_torus_ustep_village

torus_ustep_village_sun:      dd 0
sun_step:    dd 0
_pal:        dd 0
fn:          dd 0
_torusMorph: dd 0
_tabMorph:   dd 0
morph_addr:  times 64 dd 0
_ObjectAddress: dd 0
ktory_morph: dd 4
add_morph:   dd 5
przelot:     dd 0
ramki:       dd 0
_waterWorld: dd 0
obrazek_off: dd 0
_voodka:     dd 0
_voodka2:    dd 0
_adr1:       dd 0
_ovset:      dd 0
znikanie:    dd 0
trasa_ruch:  dd 0
obj3:        dd 0
cam_save:    times 6 dd 0
scr_selw:    dw 0

; intro overlay tables (31 entries of 3 dwords), tail entries pre-filled
tablica1: times 31*3 dd 0
          dd 1,0,(320*90)+150
          dd 1,0,(320*105)+170
          dd 1,0,(320*80)+154
          dd 0,0,0
          dd 1,0,(320*100)+140
          dd 1,0,(320*89)+169
          dd 1,0,(320*105)+155
          dd 0,0,0
          dd 1,0,(320*90)+170
          dd 0,0,0
tablica2: times 31*3 dd 0
          dd 1,0,(320*90)+150
          dd 1,0,(320*105)+170
          dd 1,0,(320*80)+154
          dd 0,0,0
          dd 1,0,(320*100)+140
          dd 1,0,(320*89)+169
          dd 1,0,(320*105)+155
          dd 0,0,0
          dd 1,0,(320*90)+170
          dd 0,0,0

%include "p5_world.inc"
%include "p5_trasa.inc"

section .bss align=16
worldzet: resd 1000
worldkol: resd 1000

section .data align=16
r_tmp_kol: dq 0
r_tmp_obj: dq 0
r_tmp_tex: dq 0
_obidx:    dd 0

section .text

; =================================================================== scene_torus_ustep_village ===
scene_torus_ustep_village:
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

        lea     rsi, [rel white]
        call    pal_set

        mov     eax, [rel _scr_Addr]
        mov     [rel _screen], eax
        movzx   ebx, word [rel _scrSel]
        mov     [rel scr_selw], bx
        mov     [gs_sel], ebx

        ; ---- sort scratch for the per-face painter sort (P2.AS^ SortMem) ----
        extern prep_sort
        call    prep_sort

        ; VirSort key shift: torus ustep village (P5)'s VIRSORT.PM applies sar bx,4 to low16(zet)
        extern virsort_shift
        mov     dword [rel virsort_shift], 4

        ; ---- waterWorld + texture selectors ----
        AllocateMemory 256*256, _waterWorld
        mov     eax, EOS_ALLOCATE_SELECTOR
        mov     esi, [rel _waterWorld]
        add     rsi, qword [rel Code32_addr]
        mov     edi, 256*256
        call    eos_dispatch
        mov     word [rel textury+0], ax

        AllocateMemoryFree 128*2*128, _bufor1
        AllocateMemoryFree 128*2*128, _bufor2

        vodka   36, obrazek_off
        mov     eax, [rel obrazek_off]
        mov     [rel _obrazek], eax
        vodkasel 39, fn, textury+2
        vodkasel 40, fn, textury+4
        vodkasel 38, fn, textury+6
        vodka   37, _pal
        vodka   72, torus_ustep_village_sun              ; 2world.inc: 19-frame 64x64 sun sprite
                                        ; (P5.AS^:156 `vodka 72,sun`)

        ; ---- load objects 31..34 into lo_objects ----
        mov     dword [rel lo_bump], 0x02000000
        mov     dword [rel lo_number], 0
        mov     dword [rel _obidx], 31
.obj_loop:
        mov     eax, [rel _obidx]
        cmp     eax, 35
        jae     .obj_done
        mov     esi, [rel _file_addr]
        add     rsi, qword [rel Code32_addr]
        movsxd  r9, eax
        mov     ebx, [rsi + r9*8]
        mov     eax, ebx
        add     eax, [rel _file_addr]
        mov     rcx, [rel Code32_addr]
        mov     edx, eax
        movzx   r8d, word [rel textury+0]
        call    vk_load_object
        inc     dword [rel _obidx]
        jmp     .obj_loop
.obj_done:

        ; ---- morph target points (128 * xyz), scale <<4 ----
        vodka   35, _torusMorph
        mov     esi, [rel _torusMorph]
        add     rsi, qword [rel Code32_addr]
        mov     ecx, 128
.idid:
        mov     eax, [rsi]
        shl     eax, 4
        mov     [rsi], eax
        mov     eax, [rsi+4]
        shl     eax, 4
        mov     [rsi+4], eax
        mov     eax, [rsi+8]
        shl     eax, 4
        mov     [rsi+8], eax
        add     rsi, 12
        dec     ecx
        jnz     .idid

        AllocateMemoryFree 98304+1536, _tabMorph
        call    MakeMorphTable

        ; ---- intro overlays ----
        mov     dword [rel znikanie], 0
        vodka   45, _voodka
        vodka   46, _voodka2
        vodka   42, _adr1
.czensc_1:
        mov     esi, [rel _adr1]
        mov     edi, [rel _screen]
        call    copy16000
        call    napis1
        Ekran
        cmp     dword [rel znikanie], 127
        jg      .cze1
        inc     dword [rel znikanie]
        mov     edi, [rel _pal]
        add     rdi, qword [rel Code32_addr]
        mov     eax, [rel znikanie]
        mov     bl, al
        shr     bl, 1
        call    pal_fadein10
.cze1:
        call    GetModPos
        cmp     word [rel ModPos], 0x141f
        jle     .czensc_1

        mov     dword [rel znikanie], 0
        vodka   47, _voodka2
        call    copy_tab2_to_tab1
        lea     rsi, [rel white]
        call    pal_set
        vodka   41, _adr1
.czensc_2:
        mov     esi, [rel _adr1]
        mov     edi, [rel _screen]
        call    copy16000
        call    napis1
        Ekran
        cmp     dword [rel znikanie], 127
        jg      .cze2
        inc     dword [rel znikanie]
        mov     edi, [rel _pal]
        add     rdi, qword [rel Code32_addr]
        mov     eax, [rel znikanie]
        mov     bl, al
        shr     bl, 1
        call    pal_fadein10
.cze2:
        call    GetModPos
        cmp     word [rel ModPos], 0x143f
        jle     .czensc_2

        mov     dword [rel znikanie], 0
        vodka   48, _voodka2
        call    copy_tab2_to_tab1
        lea     rsi, [rel white]
        call    pal_set
        vodka   43, _adr1
.czensc_3:
        mov     esi, [rel _adr1]
        mov     edi, [rel _screen]
        call    copy16000
        call    napis1
        Ekran
        cmp     dword [rel znikanie], 127
        jg      .cze3
        inc     dword [rel znikanie]
        mov     edi, [rel _pal]
        add     rdi, qword [rel Code32_addr]
        mov     eax, [rel znikanie]
        mov     bl, al
        shr     bl, 1
        call    pal_fadein10
.cze3:
        call    GetModPos
        call    intro_fade
        cmp     word [rel ModPos], 0x151f
        jle     .czensc_3

        mov     dword [rel znikanie], 0
        vodka   49, _voodka2
        call    copy_tab2_to_tab1
        vodka   44, _adr1
.czensc_4:
        mov     esi, [rel _adr1]
        mov     edi, [rel _screen]
        call    copy16000
        call    napis1
        Ekran
        cmp     dword [rel znikanie], 127
        jg      .cze4
        inc     dword [rel znikanie]
        mov     edi, [rel _pal]
        add     rdi, qword [rel Code32_addr]
        mov     eax, [rel znikanie]
        mov     bl, al
        shr     bl, 1
.cze4:
        call    GetModPos
        call    intro_fade
        cmp     word [rel ModPos], 0x153f
        jle     .czensc_4

        lea     rsi, [rel white]
        call    pal_set
        mov     dword [rel znikanie], 0
        WaitVbl
        mov     [rel ramki], eax

; ------------------------------------------------------------------ Main ---
.main:
        cmp     dword [rel znikanie], 83
        jg      .kdkd
        mov     edi, [rel _pal]
        add     rdi, qword [rel Code32_addr]
        mov     eax, [rel znikanie]
        mov     bl, al
        shr     bl, 1
        call    pal_fadein10
        mov     eax, [rel ramki]
        shl     eax, 1
        add     [rel znikanie], eax
.kdkd:

        ; ---- morph once trasa_ruch >= 454 ----
        cmp     dword [rel trasa_ruch], 227*2
        jl      .oob
        mov     dword [rel przelot], 1
        mov     eax, [rel ramki]
        add     [rel torus_ustep_village_world+20], eax
        shl     eax, 1
        add     [rel torus_ustep_village_world+20], eax
        mov     ebx, [rel add_morph]
        mov     eax, [rel ktory_morph]
        cmp     eax, 62
        jl      .okd
        neg     ebx
        neg     dword [rel add_morph]
        mov     eax, 62
.okd:
        cmp     eax, 0
        jg      .okd2
        xor     eax, eax
        neg     ebx
        neg     dword [rel add_morph]
.okd2:
        add     [rel ktory_morph], ebx
        lea     r8, [rel morph_addr]
        mov     eax, [r8 + rax*4]
        mov     esi, [rel _ObjectAddress]
        add     rsi, qword [rel Code32_addr]
        mov     [rsi], eax
.oob:

        ; ---- camera from trasa_ruch ----
        mov     eax, [rel trasa_ruch]
        cmp     eax, ruchow-2
        jb      .udu
        mov     dword [rel trasa_ruch], 0
        xor     eax, eax
.udu:
        mov     ebx, 24
        mul     ebx
        lea     rsi, [rel torus_ustep_village_trasa]
        mov     ebx, [rsi + rax + 0]
        mov     [rel cam_cameraX], ebx
        mov     ebx, [rsi + rax + 4]
        mov     [rel cam_cameraY], ebx
        mov     ebx, [rsi + rax + 8]
        mov     [rel cam_cameraZ], ebx
        mov     ebx, [rsi + rax + 12]
        mov     [rel cam_eyeAX], ebx
        mov     ebx, [rsi + rax + 16]
        mov     [rel cam_eyeAY], ebx
        mov     ebx, [rsi + rax + 20]
        mov     [rel cam_eyeAZ], ebx

        Screen0
        call    rysujCiulusa

        ; ---- mirror reflection into waterWorld ----
        mov     esi, [rel _screen]
        add     rsi, qword [rel Code32_addr]
        mov     edi, [rel _waterWorld]
        add     rdi, qword [rel Code32_addr]
        add     rsi, 32                 ; 64-bit: a 32-bit add would zero the
        add     rdi, 25*256             ; upper half of the real pointer
        mov     r12, 200
.io01:
        mov     r13, 256
.io02:
        movzx   eax, byte [rsi]
        and     eax, 31
        movzx   ebx, byte [rdi]
        or      ebx, eax
        mov     [rdi], bl
        inc     rsi
        inc     rdi
        dec     r13
        jnz     .io02
        add     rsi, 320-256
        dec     r12
        jnz     .io01

        Screen0

        ; ---- world render ----
        mov     ecx, [rel cam_eyeAX]
        mov     edx, [rel cam_eyeAY]
        mov     r8d, [rel cam_eyeAZ]
        call    vk_make_camera_matrix

        ; world angle adders
        lea     r12, [rel torus_ustep_village_world]
        mov     r13d, [rel torus_ustep_village_worldsobjects]
        xor     ecx, ecx
.katys:
        cmp     ecx, r13d
        jae     .kat_done
        mov     eax, [r12 + 32]
        add     [r12 + 20], eax
        mov     eax, [r12 + 36]
        add     [r12 + 24], eax
        mov     eax, [r12 + 40]
        add     [r12 + 28], eax
        add     r12, 48
        inc     ecx
        jmp     .katys
.kat_done:

        lea     rax, [rel worldkol]
        mov     [rel r_tmp_kol], rax
        lea     rax, [rel lo_objects]
        mov     [rel r_tmp_obj], rax
        lea     rax, [rel textury]
        mov     [rel r_tmp_tex], rax

        ; vk_vr_world_render_frame(base, world, count, zet, kol, objects, textury, trace=0)
        ; MS ABI stack args: [rsp+0x20]=kol [rsp+0x28]=objects [rsp+0x30]=textury
        ; [rsp+0x38]=trace (the callee reads them at [rbp+0x30..0x48]).
        ; (An earlier +8-shifted layout made the callee see trace=textury:
        ;  it traced into the texture table instead of drawing.)
        sub     rsp, 0x40
        mov     rax, [rel r_tmp_kol]
        mov     [rsp+0x20], rax
        mov     rax, [rel r_tmp_obj]
        mov     [rsp+0x28], rax
        mov     rax, [rel r_tmp_tex]
        mov     [rsp+0x30], rax
        mov     qword [rsp+0x38], 0
        mov     rcx, [rel Code32_addr]
        lea     rdx, [rel torus_ustep_village_world]
        mov     r8d, [rel torus_ustep_village_worldsobjects]
        lea     r9, [rel worldzet]
        call    vk_vr_world_render_frame
        add     rsp, 0x40

        call    drawWaterTorusUstepVillage
        call    calculateWaterTorusUstepVillage

        mov     eax, [rel ramki]
        add     [rel trasa_ruch], eax

        WaitVbl
        mov     [rel ramki], eax
        call    sloneczko
        Ekran

        call    GetModPos
        cmp     word [rel ModPos], 0x1b3f
        jg      .spieee
        jmp     .main
.spieee:

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

; ------------------------------------------------------------- rysujCiulusa ----
rysujCiulusa:
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

        mov     eax, [rel cam_cameraX]
        mov     [rel cam_save+0], eax
        mov     eax, [rel cam_cameraY]
        mov     [rel cam_save+4], eax
        mov     eax, [rel cam_cameraZ]
        mov     [rel cam_save+8], eax
        mov     eax, [rel cam_eyeAX]
        mov     [rel cam_save+12], eax
        mov     eax, [rel cam_eyeAY]
        mov     [rel cam_save+16], eax
        mov     eax, [rel cam_eyeAZ]
        mov     [rel cam_save+20], eax

        mov     dword [rel cam_cameraX], 0
        mov     dword [rel cam_cameraY], 0x3494
        mov     dword [rel cam_cameraZ], 0x985
        mov     dword [rel cam_eyeAX], 0x110
        mov     dword [rel cam_eyeAY], 0
        mov     dword [rel cam_eyeAZ], 0
        mov     ecx, [rel cam_eyeAX]
        mov     edx, [rel cam_eyeAY]
        mov     r8d, [rel cam_eyeAZ]
        call    vk_make_camera_matrix

        lea     rbx, [rel torus_ustep_village_world]
        cmp     dword [rbx], 0
        je      .noVis
        mov     eax, [rbx + 44]
        lea     r9, [rel textury]
        movzx   ecx, word [r9 + rax*2]
        mov     [fs_sel], ecx
        mov     eax, [rbx + 16]
        lea     r12, [rel lo_objects]
        mov     edx, [r12 + rax*4]
        lea     r8, [rbx + 4]
        lea     r9, [rbx + 20]
        mov     rcx, [rel Code32_addr]
        call    vk_prepare_object
        mov     eax, [rbx + 16]
        lea     r12, [rel lo_objects]
        mov     edx, [r12 + rax*4]
        mov     rcx, [rel Code32_addr]
        call    vk_draw_object
.noVis:
        mov     eax, [rel cam_save+0]
        mov     [rel cam_cameraX], eax
        mov     eax, [rel cam_save+4]
        mov     [rel cam_cameraY], eax
        mov     eax, [rel cam_save+8]
        mov     [rel cam_cameraZ], eax
        mov     eax, [rel cam_save+12]
        mov     [rel cam_eyeAX], eax
        mov     eax, [rel cam_save+16]
        mov     [rel cam_eyeAY], eax
        mov     eax, [rel cam_save+20]
        mov     [rel cam_eyeAZ], eax

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

; ----------------------------------------------------------- MakeMorphTable ----
MakeMorphTable:
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

        lea     rax, [rel lo_objects]
        mov     ecx, [rax + 3*4]
        mov     [rel obj3], ecx
        mov     eax, ecx
        add     eax, 36
        mov     [rel _ObjectAddress], eax

        ; r12 = real ptr to object 3's original vertex list
        mov     eax, ecx
        add     rax, qword [rel Code32_addr]
        mov     ebx, [rax + 36]
        add     rbx, qword [rel Code32_addr]
        mov     r12, rbx

        ; deltas: rsi=original verts, rdi=torusMorph target, rbx=_tabMorph
        mov     ebx, [rel _tabMorph]
        add     rbx, qword [rel Code32_addr]
        mov     edi, [rel _torusMorph]
        add     rdi, qword [rel Code32_addr]
        mov     rsi, r12
        mov     r13, 128
.calDeltaz:
        mov     eax, [rdi]
        sub     eax, [rsi]
        shl     eax, 16
        sar     eax, 6
        mov     [rbx], eax
        mov     eax, [rdi+4]
        sub     eax, [rsi+4]
        shl     eax, 16
        sar     eax, 6
        mov     [rbx+4], eax
        mov     eax, [rdi+8]
        sub     eax, [rsi+8]
        shl     eax, 16
        sar     eax, 6
        mov     [rbx+8], eax
        add     rsi, 12
        add     rdi, 12
        add     rbx, 12
        dec     r13
        jnz     .calDeltaz

        ; copy original vertices (1536B) into _tabMorph+1536 (frame base)
        mov     rsi, r12
        mov     rdi, [rel _tabMorph]
        add     rdi, qword [rel Code32_addr]
        add     rdi, 1536
        mov     ecx, 1536
        rep movsb

        ; build 64 chained frames: rel = (prev<<16 + delta)>>16
        mov     ebx, [rel _tabMorph]
        add     rbx, qword [rel Code32_addr]
        mov     rsi, rbx
        add     rsi, 1536
        mov     rdi, rbx
        add     rdi, 1536*2
        mov     r14, 64
.calcRest:
        mov     r15, 128
.calcAllMor:
        mov     eax, [rsi]
        shl     eax, 16
        add     eax, [rbx]
        sar     eax, 16
        mov     [rdi], eax
        mov     eax, [rsi+4]
        shl     eax, 16
        add     eax, [rbx+4]
        sar     eax, 16
        mov     [rdi+4], eax
        mov     eax, [rsi+8]
        shl     eax, 16
        add     eax, [rbx+8]
        sar     eax, 16
        mov     [rdi+8], eax
        add     rsi, 12
        add     rbx, 12
        add     rdi, 12
        dec     r15
        jnz     .calcAllMor
        ; The inner 128-vertex loop already advanced rsi/rdi by exactly one
        ; frame (128*12B), so they now point at frame[i] / frame[i+1] - the
        ; correct prev/cur pair for the next outer iteration. Only the delta
        ; pointer (rbx) must be rewound to the table start. (The original
        ; restores esi/edi via push/pop then adds 1536 once; adding 1536 here
        ; ON TOP of the walked distance skips a frame and feeds zeros into the
        ; chain - that is what collapsed every built morph frame to ~0.)
        mov     ebx, [rel _tabMorph]
        add     rbx, qword [rel Code32_addr]
        dec     r14
        jnz     .calcRest

        ; fill morph_addr with the 64 frame arena offsets
        lea     rdi, [rel morph_addr]
        mov     eax, [rel _tabMorph]
        add     eax, 1536
        mov     rcx, 64
.filMem:
        mov     [rdi], eax
        add     eax, 1536
        add     rdi, 4
        loop    .filMem

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

; ------------------------------------------------------------------ napis1 ----
napis1:
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

        call    GetModPos
        movzx   eax, word [rel ModPos]
        and     eax, 0x1f
        cmp     eax, 16
        jl      .heree1
        lea     eax, [rax + rax*2]
        shl     eax, 2
        lea     rbx, [rel tablica1]
        mov     ecx, [rbx + rax]
        or      ecx, ecx
        jz      .heree1
        mov     ecx, [rbx + rax + 4]
        or      ecx, ecx
        jnz     .heree1
        mov     dword [rbx + rax + 4], 1
        mov     ecx, [rbx + rax + 8]
        mov     [rel _ovset], ecx
        lea     rsi, [rel white]
        call    pal_set
.heree1:
        WaitVbl
        mov     [rel ramki], eax
        call    sloneczko

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

; --------------------------------------------------------------- sloneczko ----
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

        mov     eax, [rel sun_step]
        cmp     eax, 19
        jl      .sun_ok
        sub     eax, 18
.sun_ok:
        and     eax, 0x3f
        mov     [rel sun_step], eax
        shl     eax, 12
        mov     esi, [rel torus_ustep_village_sun]
        add     esi, eax
        add     rsi, qword [rel Code32_addr]
        mov     edi, [rel _screen]
        add     rdi, qword [rel Code32_addr]
        add     rdi, ((205-64)*320)+254
        mov     r12, 64
.sp1:
        mov     r13, 64
.sp2:
        lodsb
        or      al, al
        jz      .sun_sk
        mov     [rdi], al
.sun_sk:
        inc     rdi
        dec     r13
        jnz     .sp2
        add     rdi, 320-64
        dec     r12
        jnz     .sp1

        mov     eax, [rel ramki]
        cmp     eax, 4
        jle     .plo
        shr     eax, 2
        jmp     .doit
.plo:
        mov     eax, 1
.doit:
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

; ------------------------------------------------------------- helpers ------
copy16000:
        push    rbp
        mov     rbp, rsp
        push    rsi
        push    rdi
        push    rcx
        sub     rsp, 0x20
        add     rsi, qword [rel Code32_addr]
        add     rdi, qword [rel Code32_addr]
        mov     ecx, 16000
        rep movsd
        add     rsp, 0x20
        pop     rcx
        pop     rdi
        pop     rsi
        pop     rbp
        ret

copy_tab2_to_tab1:
        push    rbp
        mov     rbp, rsp
        push    rsi
        push    rdi
        push    rcx
        sub     rsp, 0x20
        lea     rsi, [rel tablica2]
        lea     rdi, [rel tablica1]
        mov     ecx, 0x1f*3
        rep movsd
        add     rsp, 0x20
        pop     rcx
        pop     rdi
        pop     rsi
        pop     rbp
        ret

intro_fade:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rdi
        sub     rsp, 0x20
        mov     ax, word [rel ModPos]
        movzx   ebx, al
        mov     ecx, 1
        call    pal_flash_brighten
        ; torus ustep village (P5)'s source does three restore pal_set calls after the brightening
        ; pal_fadein10 (one white retrace + two unchanged restore retraces).
        v_sync
        v_sync
        add     rsp, 0x20
        pop     rdi
        pop     rbx
        pop     rbp
        ret
