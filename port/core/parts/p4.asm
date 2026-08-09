; p4.asm - NASM x64 port of CODE/P4/P4.ASM  (part 4: multi-object 3D viewer).
;
; Scene: 4 sub-objects (222+81+8+256 verts, 440+158+12+384 faces) in one
; 567-vertex model space. Per-face texture mapping over 4 textures (sw.inc,
; v_txr1.inc, proc.inc, metal.inc) with three mapping modes (plane-pkt,
; phong-n_rot, standard-pos), its OWN textured-triangle rasterizer (face),
; Euler-angle object (ob1..9) + camera (ca1..9) rotation matrices, a 2,964-key
; camera path (vodka 74 -> trasa.dat; swing-clamp ruchow=2,951), a scrolling
; logo overlay and a picture + flash outro.
;
; Memory model: stored dwords are arena offsets; deref via `add r, Code32_addr`.
; The raw 567-vertex source block (shape[222] + src1[81] + src2[8] +
; src3[256], src1..3 PREPARED in place) lives in the arena as shape_a8 for
; n_calc and make_chip. The renderer's logical shape+s1+s2+s3 view is rebuilt
; in p4_render_shape after make_chip, matching the original contiguous data
; layout. The con1..c3 face tables (994x6, modified by prepare/co_prepare)
; live in one arena block (con_a8) - n_calc's con_addr and show()/rotate()
; both index it. n_vert_src/n_add/n_vert/n_rot are engine working arrays
; (arena). draw_tab (sort_addr) is arena. rcalc/check live in module .bss
; (small, only this part touches them).
;
; selectors: map1_sel..map4_sel = textures (fs), scr_sel = screen (es). con3
; stores the texture MAP INDEX (0..3) instead of a runtime selector handle;
; show() resolves mapN_sel -> sel_base_table and keeps the texture base in fsq
; (per face) and the screen base in esq (once) - mirrors txtr.asm / p8.
;
; ABI: 8-push prologue + sub 0x28 -> RSP%16==0 at every NASM->C++/EOS call.

BITS 64
DEFAULT REL

%include "eos.inc"
%include "video.inc"
%include "pal.inc"
%include "vodka.inc"

extern _screen
extern _scr_Addr
extern _scrSel
extern framebuffer_off
extern ModPos
extern GetModPos
extern Code32_addr
extern eos_dispatch
extern white
extern sinus
extern sel_base_table
extern len

; engine surfaces (n_calc / rotate_normals / sort / prep_sort)
extern shape_addr
extern n_addr
extern inc_addr
extern con_addr
extern sort_addr
extern points
extern faces
extern r_x, r_y, r_z
extern nrot_addr
extern n_calc
extern rotate_normals
extern prep_sort
extern sort
extern vk_p4_draw_triangle

p_len   EQU 222+81+8+256
f_len   EQU 440+158+12+384

x1_min  EQU -4600
x1_max  EQU 4600
y1_min  EQU -4600
y1_max  EQU 4600
z1_min  EQU -6600
z1_max  EQU 4000

x2_min  EQU 0
x2_max  EQU 320
y2_min  EQU 0
y2_max  EQU 200

zoom    EQU 160
ruchow  EQU 2951

; --------------------------------------------------------------------- .bss
section .bss align=16
global part4

scr_addr:    resd 1
scr_sel:     resw 1
map1_sel:    resw 1
map2_sel:    resw 1
map3_sel:    resw 1
map4_sel:    resw 1

_m1off: resd 1
_m2off: resd 1
_m3off: resd 1
_m4off: resd 1

; arena offsets
con_a8:      resd 1      ; con1..c3 (f_len*6)
shape_a8:    resd 1      ; shape + src1..src3 (p_len*6)
n_vert_src8: resd 1      ; n_vert_src (256*6)
n_add_a8:    resd 1      ; n_add (256*2)
n_vert_a8:   resd 1      ; n_vert (256*6)
n_rot_a8:    resd 1      ; n_rot  (256*4)
draw_a8:     resd 1      ; draw_tab (f_len*4)

ruchy:       resd 1
logo:        resd 1
pic_data:    resd 1
pic_pal:     resd 1

cm_x: resw 1
cm_y: resw 1
cm_z: resw 1

s_x: resd 1
c_x: resd 1
s_y: resd 1
c_y: resd 1
s_z: resd 1
c_z: resd 1

ob1: resd 1
ob2: resd 1
ob3: resd 1
ob4: resd 1
ob5: resd 1
ob6: resd 1
ob7: resd 1
ob8: resd 1
ob9: resd 1

ca1: resd 1
ca2: resd 1
ca3: resd 1
ca4: resd 1
ca5: resd 1
ca6: resd 1
ca7: resd 1
ca8: resd 1
ca9: resd 1

t_x: resd 1
t_y: resd 1
t_z: resd 1
p_x: resd 1
p_y: resd 1
p_z: resd 1
o_x: resd 1
o_y: resd 1
o_z: resd 1

pkt: resw 81*2

pts_src: resw (158+12+384)*3
pts_tab: resw f_len*3
; rcalc/check module .bss (only this part reads them; sizes = original)
rcalc: resw p_len*2
check: resw p_len
ile:   resd 1

; rasterizer shared state
esq:   resq 1        ; screen base (es), resolved by show()
fsq:   resq 1        ; current texture base (fs), resolved per face

x_1: resd 1
x_s: resd 1
y_1: resd 1
p_1: resw 2
x_2: resd 1
y_2: resd 1
p_2: resw 2
x_3: resd 1
y_3: resd 1
p_3: resw 2

dx_1: resd 1
dy_1: resd 1
dx_2: resd 1
dy_2: resd 1
dy_3: resd 1
pd_1: resw 2
pd_2: resw 2

pom: resw 1
mem: resw 2
col: resw 1

frames:    resd 1
ruchy_ptr: resd 1
jcount:    resd 1
znacznik:  resd 1
znacznik2: resd 1
znacznik3: resd 1
sun_step:  resd 1
ciota:     resd 1
ile_fade:  resd 1
mnoznik:   resd 1
ro_z:      resw 1
z_offs:    resw 1
j_offs:    resd 1
j_add:     resd 1
stary:     resw 1

; make_chip scratch targets. The original's shape pointer is followed by the
; rotated s1/s2/s3 working vertices; sync_render_shape rebuilds that logical
; contiguous view after every make_chip call.
p4_s1: resw 81*3
p4_s2: resw (8+256)*3
p4_render_shape: resw p_len*3
align 8
global p4_draw_args
p4_draw_args:
        resd 6
        resd 3
        resd 1
        resq 2
        resd 1

; --------------------------------------------------------------------- .data
section .data align=16

; palettes (raw 6-bit, as included by the original).
; spal1 = sw.pal (64), spal2 = v_txr1.pal (22), spal3 = proc.pal (33),
; spal4 = metal.pal (64).
spal1:
        incbin "sw.pal"
spal2:
        incbin "v_txr1.pal"
spal3:
        incbin "proc.pal"
spal4:
        incbin "metal.pal"
; working palette buffer (make_pal results land here)
pal:    times 256*3 db 0

map_sel_tab: times 4 dw 0

; raw vertex block (source of the arena copy)
sw_shape:
        %include "p4_vws_1.inc"   ; 222
        %include "p4_vws_2.inc"   ; 81
        %include "p4_vws_3.inc"   ; 8
        %include "p4_vws_4.inc"   ; 256

; raw face tables (copied to the arena; prepare/co_prepare modify the copies)
con1:
        %include "p4_vwc_1.inc"   ; 440
c1:
        %include "p4_vwc_2.inc"   ; 158
c2:
        %include "p4_vwc_3.inc"   ; 12
c3:
        %include "p4_vwc_4.inc"   ; 384

; con2 - per-face UV connectivity (pos pair index * 2), 440+158+14 faces x 3
con2:
        %rep 440/8
        dw 0*2,1*2,2*2
        dw 0*2,2*2,3*2
        dw 4*2,5*2,6*2
        dw 4*2,6*2,7*2
        dw 8*2,9*2,10*2
        dw 8*2,10*2,11*2
        dw 12*2,13*2,14*2
        dw 12*2,14*2,15*2
        %endrep
        %rep 158/2
        dw 0*2,1*2,2*2
        dw 0*2,2*2,3*2
        %endrep
        dw 16*2,17*2,18*2
        dw 16*2,18*2,19*2
        dw 20*2,21*2,22*2
        dw 20*2,22*2,23*2
        dw 20*2,21*2,22*2
        dw 20*2,22*2,23*2
        dw 20*2,21*2,22*2
        dw 20*2,22*2,23*2
        dw 20*2,21*2,22*2
        dw 20*2,22*2,23*2
        dw 20*2,21*2,22*2
        dw 20*2,22*2,23*2

; con3 - per-face render record (8 bytes): dd map index (0..3), db color/plane
; word ({color,plane}), db visibility, db phong. Group order matches the
; original: 440 map1, 144 map2, 14 map1-plane, 12 map3, 384 map4.
con3:
        %rep 440/2
        dd 0
        db 0*16,0
        db 0,0
        dd 0
        db 0*16,0
        db 0,0
        %endrep
        %rep (158-14)/2
        dd 1
        db 8*16,0
        db 1,0
        dd 1
        db 8*16,0
        db 1,0
        %endrep
        %rep 14/2
        dd 0
        db 64,1
        db 1,0
        dd 0
        db 64,1
        db 1,0
        %endrep
        %rep 12/2
        dd 2
        db 9*16,0
        db 1,0
        dd 2
        db 9*16,0
        db 1,0
        %endrep
        %rep 384/2
        dd 3
        db 12*16,0
        db 1,1
        dd 3
        db 12*16,0
        db 1,1
        %endrep

pos:
        dw 10*256,8*256, 10*256,112*256, 63*256,112*256, 63*256,8*256
        dw 63*256,8*256, 63*256,112*256, 126*256,112*256, 126*256,8*256
        dw 126*256,8*256, 126*256,112*256, 189*256,112*256, 189*256,8*256
        dw 189*256,8*256, 189*256,112*256, 248*256,112*256, 248*256,8*256
        dw 8*256,26*256, 8*256,92*256, 236*256,92*256, 236*256,26*256
        dw 8*256,84*256, 8*256,154*256, 236*256,154*256, 236*256,84*256

tablica:
        dw 64-6 dup (0,0)
        dw 1,0
        dw 1,0
        dw 1,0
        dw 0,0
        dw 1,0
        dw 0,0

; --------------------------------------------------------------------- .text
section .text

; ------------------------------------------------------------------- part4 --
global part4
part4:
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

        ; The DOS entry begins with CLD; keep all REP copies and string
        ; operations independent of the direction flag left by the prior part.
        cld

        ; original .data initializers
        mov     dword [rel mnoznik], 1
        mov     dword [rel ile_fade], 64
        mov     dword [rel j_offs], 1
        mov     dword [rel j_add], 9
        mov     dword [rel ciota], 1
        mov     word  [rel stary], 1

        ; white screen at part start
        lea     rsi, [rel white]
        call    pal_set
        v_sync
        v_sync
        v_sync
        v_sync

        ; screen setup (backbuffer)
        mov     ax, [_scrSel]
        mov     [rel scr_sel], ax
        mov     eax, [_scr_Addr]
        mov     [rel scr_addr], eax
        mov     [_screen], eax

        ; ---- load assets --------------------------------------------------
        ; vodkas are the runtime data/vodka.dat positions: 24=sw.inc,
        ; 25=v_txr1.inc, 26=proc.inc, 27=metal.inc, 28=logo_a.dat,
        ; 29=tull.inc, 30=tull.pal, 74=trasa.dat (the original's values).
        vodka   24, _m1off
        vodka   25, _m2off
        vodka   26, _m3off
        vodka   27, _m4off
        vodka   28, logo
        vodka   29, pic_data
        vodka   30, pic_pal
        vodka   74, ruchy

        ; ---- texture selectors --------------------------------------------
        mov     esi, [rel _m1off]
        add     rsi, qword [rel Code32_addr]
        mov     edi, 320*160
        mov     eax, EOS_ALLOCATE_SELECTOR
        call    eos_dispatch
        mov     [rel map1_sel], ax
        movzx   edx, ax
        mov     [rel map_sel_tab+0], dx

        mov     esi, [rel _m2off]
        add     rsi, qword [rel Code32_addr]
        mov     edi, 320*160
        mov     eax, EOS_ALLOCATE_SELECTOR
        call    eos_dispatch
        mov     [rel map2_sel], ax
        movzx   edx, ax
        mov     [rel map_sel_tab+2], dx

        mov     esi, [rel _m3off]
        add     rsi, qword [rel Code32_addr]
        mov     edi, 320*160
        mov     eax, EOS_ALLOCATE_SELECTOR
        call    eos_dispatch
        mov     [rel map3_sel], ax
        movzx   edx, ax
        mov     [rel map_sel_tab+4], dx

        mov     esi, [rel _m4off]
        add     rsi, qword [rel Code32_addr]
        mov     edi, 320*160
        mov     eax, EOS_ALLOCATE_SELECTOR
        call    eos_dispatch
        mov     [rel map4_sel], ax
        movzx   edx, ax
        mov     [rel map_sel_tab+6], dx

        ; screen selector for the rasterizer's es writes
        mov     esi, [rel scr_addr]
        add     rsi, qword [rel Code32_addr]
        mov     edi, 320*200
        mov     eax, EOS_ALLOCATE_SELECTOR
        call    eos_dispatch
        mov     [rel scr_sel], ax

        ; ---- arena allocations --------------------------------------------
        ; con1..c3 (f_len*6)
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, f_len*6
        call    eos_dispatch
        mov     [rel con_a8], edx
        mov     rdi, rdx
        add     rdi, qword [rel Code32_addr]
        lea     rsi, [rel con1]
        mov     ecx, (f_len*6)>>2
        rep movsd

        ; shape block (p_len*6)
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, p_len*6
        call    eos_dispatch
        mov     [rel shape_a8], edx
        mov     rdi, rdx
        add     rdi, qword [rel Code32_addr]
        lea     rsi, [rel sw_shape]
        mov     ecx, (p_len*6)>>2
        rep movsd
        ; p_len*6 is 3402 bytes. Preserve the final two bytes of src3's
        ; last vertex; the original assembler image contains them as part of
        ; the static shape block, while a dword-only copy would drop them.
        mov     ecx, (p_len*6)&3
        rep movsb

        ; n_vert_src / n_add / n_vert / n_rot
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, 256*6
        call    eos_dispatch
        mov     [rel n_vert_src8], edx
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, 256*2
        call    eos_dispatch
        mov     [rel n_add_a8], edx
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, 256*6
        call    eos_dispatch
        mov     [rel n_vert_a8], edx
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, 256*4
        call    eos_dispatch
        mov     [rel n_rot_a8], edx

        ; draw_tab (f_len dwords) - the sort target (arena offset)
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, f_len*4
        call    eos_dispatch
        mov     [rel draw_a8], edx

        ; sort scratch
        mov     eax, [rel draw_a8]
        mov     [rel sort_addr], eax
        call    prep_sort

        ; prepare() halves src1..src3 and rebuilds con1..c3 (arena, in place)
        call    prepare

        ; source-3 normals via the engine n_calc
        mov     eax, [rel shape_a8]
        add     eax, (222+81+8)*6
        mov     [rel shape_addr], eax
        mov     eax, [rel n_vert_src8]
        mov     [rel n_addr], eax
        mov     eax, [rel n_add_a8]
        mov     [rel inc_addr], eax
        mov     eax, [rel con_a8]
        add     eax, (440+158+12)*6
        mov     [rel con_addr], eax
        mov     dword [rel len], 80
        mov     dword [rel points], 256
        mov     dword [rel faces], 384
        call    n_calc

        mov     eax, [rel n_vert_a8]
        mov     [rel n_addr], eax
        mov     eax, [rel n_rot_a8]
        mov     [rel nrot_addr], eax

        call    co_prepare
        call    make_chip
        call    sync_render_shape
        call    make_pts
        call    make_pos

        ; working palette (VGA 0..255 from the 4 spal blocks)
        lea     rsi, [rel spal1]
        lea     rdi, [rel pal+(64*3)]
        mov     bh, -2
        mov     bl, 4
        mov     dl, 6
        mov     ecx, 64
        call    make_pal

        lea     rsi, [rel spal2]
        lea     rdi, [rel pal+(128*3)]
        mov     bh, -22
        mov     bl, -22
        mov     dl, -22
        mov     ecx, 22
        call    make_pal

        ; ---------------------------------------------------------- m_loop
.main_loop:
        mov     eax, EOS_WAIT_VBL
        call    eos_dispatch
        mov     [rel frames], eax

        call    GetModPos

        movzx   eax, word [rel ModPos]
        cmp     eax, 1200h
        jge     .spadaj

        mov     ax, word [rel ModPos]
        cmp     [rel stary], ax
        je      .bolek

        and     ax, 3fh
        cmp     ax, 1
        jne     .prs1
        mov     dword [rel znacznik3], 1
        neg     dword [rel ciota]
.prs1:
        cmp     dword [rel znacznik2], 1
        je      .noz
        cmp     dword [rel znacznik], 1
        jne     .noz

.bolek:
        mov     ax, word [rel ModPos]
        mov     [rel stary], ax

        v_sync
        set_pal pal, 0, 256
        ; P4's sw texture reserves texel 0 for the black clear/unused value.
        ; Keep palette entry 0 black, place the meaningful warm ramp at 1..63,
        ; and leave entry 64 as the generated shaded sw ramp used by the
        ; plane faces (con3 color offset 64).
        set_pal spal1, 1, 63
        set_pal spal3, 128+16, 33
        set_pal spal4, 256-64, 64
        mov     dword [rel znacznik2], 1

.noz:
        mov     eax, [rel ruchy_ptr]
        cmp     eax, ruchow
        jl      .no_out
        mov     dword [rel ruchy_ptr], ruchow
        neg     dword [rel mnoznik]
        jmp     .no_out2
.no_out:
        cmp     eax, 0
        jg      .no_out2
        mov     dword [rel ruchy_ptr], 0
        neg     dword [rel mnoznik]
.no_out2:
        ; load the camera record: ruchy + ruchy_ptr*36
        mov     eax, [rel ruchy_ptr]
        imul    eax, 36
        add     eax, [rel ruchy]
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax

        lodsd
        mov     [rel o_x], eax
        lodsd
        mov     [rel o_y], eax
        lodsd
        mov     [rel o_z], eax

        lodsd
        mov     [r_x], ax
        lodsd
        mov     [r_y], ax
        lodsd
        mov     [r_z], ax

        lodsd
        mov     [rel cm_x], ax
        lodsd
        mov     [rel cm_y], ax
        lodsd
        mov     [rel cm_z], ax

        mov     eax, [rel frames]
        shl     eax, 1
        mov     ebx, [rel mnoznik]
        imul    ebx
        add     [rel ruchy_ptr], eax

        call    swap
        call    prep_rot1
        call    prep_rot2
        call    make_chip
        call    sync_render_shape
        call    rotate
        neg     word [r_x]
        neg     word [r_y]
        neg     word [r_z]
        call    rotate_normals
        neg     word [r_x]
        neg     word [r_y]
        neg     word [r_z]
        call    bit_sort
        call    show
        call    show_logo

        mov     eax, [rel frames]
        shl     eax, 1
        add     [rel ro_z], ax

        inc     dword [rel jcount]
        mov     dword [rel znacznik], 1
        jmp     .main_loop

; ---------------------------------------------------- outro (spadaj) ---------
.spadaj:
        lea     rsi, [rel white]
        call    pal_set

        mov     esi, [rel pic_data]
        add     rsi, qword [rel Code32_addr]
        mov     edi, [rel framebuffer_off]
        add     rdi, qword [rel Code32_addr]
        mov     ecx, 16000
        rep movsd

        ; the original wrote straight to VGA; the port must present
        sub     rsp, 0x20
        extern  vk_present_frame
        call    vk_present_frame
        add     rsp, 0x20

.pic_lo:
        v_sync
        sub     rsp, 0x20
        call    vk_present_frame
        add     rsp, 0x20

        lea     rsi, [rel white]
        mov     edi, [rel pic_pal]
        add     rdi, qword [rel Code32_addr]
        mov     ecx, 768
.co:
        lodsb
        cmp     [rdi], al
        je      .zkip
        dec     al
        mov     [rsi-1], al
.zkip:
        inc     rdi
        loop    .co

        lea     rsi, [rel white]
        call    pal_set

        dec     dword [rel ile_fade]
        jnz     .pic_lo

        ; white buffer back to full brightness for the flash window
        lea     rdi, [rel white]
        mov     al, 3fh
        mov     ecx, 768
        rep stosb

.wa:
        mov     eax, EOS_WAIT_VBL
        call    eos_dispatch
        sub     rsp, 0x20
        call    vk_present_frame
        add     rsp, 0x20
        call    GetModPos
        movzx   eax, word [rel ModPos]
        cmp     eax, 1338h
        jl      .wa

.brum:
        call    GetModPos
        movzx   eax, word [rel ModPos]
        and     eax, 03fh
        lea     r11, [rel tablica]
        cmp     word [r11 + rax*4], 0
        je      .no_flash
        cmp     word [r11 + rax*4 + 2], 1
        je      .no_flash
        mov     word [r11 + rax*4 + 2], 1
        mov     ebx, 2
        lea     rsi, [rel white]
        mov     edi, [rel pic_pal]
        add     rdi, qword [rel Code32_addr]
        call    pal_flash
.no_flash:
        mov     eax, EOS_WAIT_VBL
        call    eos_dispatch
        call    GetModPos
        movzx   eax, word [rel ModPos]
        cmp     eax, 1400h
        jl      .brum

        ; free the texture selectors
        mov     eax, EOS_DEALLOCATE_SELECTOR
        movzx   ebx, word [rel map1_sel]
        call    eos_dispatch
        mov     eax, EOS_DEALLOCATE_SELECTOR
        movzx   ebx, word [rel map2_sel]
        call    eos_dispatch
        mov     eax, EOS_DEALLOCATE_SELECTOR
        movzx   ebx, word [rel map3_sel]
        call    eos_dispatch
        mov     eax, EOS_DEALLOCATE_SELECTOR
        movzx   ebx, word [rel map4_sel]
        call    eos_dispatch

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

; ================================================================= make_pos
; Rotate src1 (81 verts, halved) by the ob1..9 matrix built from r_x=328 into
; pkt (16.16 u/v texel pairs). Runs once at init.
make_pos:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        sub     rsp, 0x20

        mov     word [r_x], 0
        call    prep_rot1
        mov     word [r_x], 328

        ; src1 starts at shape_a8 + 222*6
        mov     eax, [rel shape_a8]
        add     eax, 222*6
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        lea     rdi, [rel pkt]
        mov     ecx, 81
.pp_ro:
        movsx   eax, word [rsi]
        imul    dword [rel ob1]
        sar     eax, 15
        mov     ebp, eax
        movsx   eax, word [rsi+2]
        imul    dword [rel ob2]
        sar     eax, 15
        add     ebp, eax
        movsx   eax, word [rsi+4]
        imul    dword [rel ob3]
        sar     eax, 15
        add     ebp, eax
        mov     [rel p_x], ebp

        movsx   eax, word [rsi]
        imul    dword [rel ob4]
        sar     eax, 15
        mov     ebp, eax
        movsx   eax, word [rsi+2]
        imul    dword [rel ob5]
        sar     eax, 15
        add     ebp, eax
        movsx   eax, word [rsi+4]
        imul    dword [rel ob6]
        sar     eax, 15
        add     ebp, eax
        mov     [rel p_y], ebp

        movsx   eax, word [rsi]
        imul    dword [rel ob7]
        sar     eax, 15
        mov     ebp, eax
        movsx   eax, word [rsi+2]
        imul    dword [rel ob8]
        sar     eax, 15
        add     ebp, eax
        movsx   eax, word [rsi+4]
        imul    dword [rel ob9]
        sar     eax, 15
        add     ebp, eax

        sub     ebp, 8000
        mov     eax, 226+16
        imul    dword [rel p_x]
        idiv    ebp
        add     ax, 96
        shl     ax, 8
        mov     [rdi], ax

        mov     eax, 226
        imul    dword [rel p_y]
        idiv    ebp
        add     ax, 60
        shl     ax, 8
        mov     [rdi+2], ax

        add     rsi, 6
        add     rdi, 4
        dec     ecx
        jnz     .pp_ro

        add     rsp, 0x20
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ================================================================= make_pal
; Build pal bytes from a source by adding signed 6-bit clamps (bh,bl,dl).
make_pal:
.f_lo:
        lodsb
        add     al, bh
        jns     .pa_1
        xor     al, al
.pa_1:
        cmp     al, 63
        jle     .pa_2
        mov     al, 63
.pa_2:
        stosb
        lodsb
        add     al, bl
        jns     .pa_3
        xor     al, al
.pa_3:
        cmp     al, 63
        jle     .pa_4
        mov     al, 63
.pa_4:
        stosb
        lodsb
        add     al, dl
        jns     .pa_5
        xor     al, al
.pa_5:
        cmp     al, 63
        jle     .pa_6
        mov     al, 63
.pa_6:
        stosb
        loop    .f_lo
        ret

; =================================================================== prepare
; Modify the arena copies in place (the original did it in module data):
;   con1[*] *= 2            (440 faces x 3 w)
;   src1[*] = /2            (81 verts x 3 w)   [shape block 222..303)
;   c1[*]   = (x+222)*2     (158 faces)
;   src2[*] = /2                               [shape block 303..311)
;   c2[*]   = (x+222+81)*2  (12 faces)
;   src3[*] = /2                               [shape block 311..567)
;   c3[*]   = x*2           (384 faces)
prepare:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        sub     rsp, 0x20
        mov     eax, [rel con_a8]
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        mov     rdi, rax
        mov     ecx, 440*3
.pr_lo1:
        lodsw
        add     ax, ax
        stosw
        loop    .pr_lo1

        mov     eax, [rel shape_a8]
        add     eax, 222*6
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        mov     rdi, rax
        mov     ecx, 81*3
.pr_lo2:
        lodsw
        sar     ax, 1
        stosw
        loop    .pr_lo2

        mov     eax, [rel con_a8]
        add     eax, 440*6
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        mov     rdi, rax
        mov     ecx, 158*3
.pr_lo3:
        lodsw
        add     ax, 222
        add     ax, ax
        stosw
        loop    .pr_lo3

        mov     eax, [rel shape_a8]
        add     eax, (222+81)*6
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        mov     rdi, rax
        mov     ecx, 8*3
.pr_lo4:
        lodsw
        sar     ax, 1
        stosw
        loop    .pr_lo4

        mov     eax, [rel con_a8]
        add     eax, (440+158)*6
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        mov     rdi, rax
        mov     ecx, 12*3
.pr_lo5:
        lodsw
        add     ax, 222+81
        add     ax, ax
        stosw
        loop    .pr_lo5

        mov     eax, [rel shape_a8]
        add     eax, (222+81+8)*6
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        mov     rdi, rax
        mov     ecx, 256*3
.pr_lo6:
        lodsw
        sar     ax, 1
        stosw
        loop    .pr_lo6

        mov     eax, [rel con_a8]
        add     eax, (440+158+12)*6
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        mov     rdi, rax
        mov     ecx, 384*3
.pr_lo7:
        lodsw
        add     ax, ax
        stosw
        loop    .pr_lo7
        add     rsp, 0x20
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ============================================================== co_prepare
; c3[*] += (222+81+8)*2  (src3 verts are off the combined 567 space)
co_prepare:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        sub     rsp, 0x20
        mov     eax, [rel con_a8]
        add     eax, (440+158+12)*6
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        mov     rdi, rax
        mov     ecx, 384*3
.ps_lo:
        lodsw
        add     ax, (222+81+8)*2
        stosw
        loop    .ps_lo
        add     rsp, 0x20
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ================================================================== make_pts
; Face-vertex centroid tables: pts_tab (440 from con1 via the whole arena
; shape block) and pts_src (554). calc_pts reads the arena shape block.
make_pts:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        sub     rsp, 0x20

        mov     eax, [rel con_a8]
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        lea     rdi, [rel pts_tab]
        mov     bx, 3
        mov     ecx, 440
        call    calc_pts

        mov     eax, [rel con_a8]
        add     eax, 440*6
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        lea     rdi, [rel pts_src]
        mov     bx, 3
        mov     ecx, 158+12+384
        call    calc_pts

        add     rsp, 0x20
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; calc_pts - centroid of the 3 face vertices from the arena shape block,
;            idiv by bx(=3), write x,y,z words. rsi = face table (arena),
;            rdi = pts out, ecx = faces.
calc_pts:
        lea     r14, [rel p4_render_shape]
.cp:
        movzx   ebp, word [rsi]
        lea     r12d, [ebp*2+ebp]
        mov     ax, word [r14 + r12]
        movzx   ebp, word [rsi+2]
        lea     r12d, [ebp*2+ebp]
        add     ax, word [r14 + r12]
        movzx   ebp, word [rsi+4]
        lea     r12d, [ebp*2+ebp]
        add     ax, word [r14 + r12]
        cwd
        idiv    bx
        stosw

        movzx   ebp, word [rsi]
        lea     r12d, [ebp*2+ebp]
        mov     ax, word [r14 + r12 + 2]
        movzx   ebp, word [rsi+2]
        lea     r12d, [ebp*2+ebp]
        add     ax, word [r14 + r12 + 2]
        movzx   ebp, word [rsi+4]
        lea     r12d, [ebp*2+ebp]
        add     ax, word [r14 + r12 + 2]
        cwd
        idiv    bx
        stosw

        movzx   ebp, word [rsi]
        lea     r12d, [ebp*2+ebp]
        mov     ax, word [r14 + r12 + 4]
        movzx   ebp, word [rsi+2]
        lea     r12d, [ebp*2+ebp]
        add     ax, word [r14 + r12 + 4]
        movzx   ebp, word [rsi+4]
        lea     r12d, [ebp*2+ebp]
        add     ax, word [r14 + r12 + 4]
        cwd
        idiv    bx
        stosw

        add     rsi, 6
        dec     ecx
        jnz     .cp
        ret

; ===================================================================== swap
; Present: backbuffer(scr_addr) -> framebuffer + vk_present, then clear the
; backbuffer. (Original: scr_addr -> _0a0000h, then memset 0.)
swap:
        push    rbp
        mov     rbp, rsp
        push    rsi
        push    rdi
        push    rcx
        sub     rsp, 0x28
        mov     esi, [rel scr_addr]
        add     rsi, qword [rel Code32_addr]
        mov     edi, [rel framebuffer_off]
        add     rdi, qword [rel Code32_addr]
        mov     ecx, 16000
        rep movsd
        extern vk_present_frame
        xor     ecx, ecx
        call    vk_present_frame
        mov     edi, [rel scr_addr]
        add     rdi, qword [rel Code32_addr]
        xor     eax, eax
        mov     ecx, 16000
        rep stosd
        add     rsp, 0x28
        pop     rcx
        pop     rdi
        pop     rsi
        pop     rbp
        ret

; ====================================================== sync_render_shape
; Build the original logical shape+s1+s2+s3 view used by calc_pts and rotate.
; The raw arena source block remains separate because make_chip reads those
; prepared morph targets on every frame.
sync_render_shape:
        push    rsi
        push    rdi

        mov     eax, [rel shape_a8]
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        lea     rdi, [rel p4_render_shape]
        mov     ecx, 222*6
        rep movsb

        lea     rsi, [rel p4_s1]
        lea     rdi, [rel p4_render_shape+222*6]
        mov     ecx, 81*6
        rep movsb

        lea     rsi, [rel p4_s2]
        lea     rdi, [rel p4_render_shape+(222+81)*6]
        mov     ecx, (8+256)*6
        rep movsb

        pop     rdi
        pop     rsi
        ret

; ================================================================== make_chip
; ro_z-rotate the moving sub-objects / centroids / normals:
;   src1(81) -> s1, src2+src3(264) -> s2+s3,
;   pts_src(554) -> pts_tab+440*6, n_vert_src(256) -> n_vert.
make_chip:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        sub     rsp, 0x20

        movsx   ebx, word [rel ro_z]
        and     ebx, 3ffh

        mov     word [rel z_offs], 0

        ; sinus base in r12 for ro_chip (no [rel sym + reg] -> ADDR32)
        lea     r12, [rel sinus]

        mov     eax, [rel shape_a8]
        add     eax, 222*6
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        lea     rdi, [rel p4_s1]
        mov     ecx, 81
        call    ro_chip

        cmp     dword [rel znacznik3], 1
        jne     .pj_2

        push    rbx
        mov     ebp, [rel j_offs]
        mov     ebx, 1320
        movsx   eax, word [r12 + rbp*2]
        imul    ebx
        sar     eax, 15
        mov     [rel z_offs], ax
        pop     rbx

        mov     eax, [rel j_add]
        imul    eax, dword [rel frames]
        add     [rel j_offs], eax

        cmp     dword [rel j_offs], 0
        jge     .pj_1
        mov     dword [rel znacznik3], 0
        mov     dword [rel j_offs], 0
        neg     dword [rel j_add]
.pj_1:
        cmp     dword [rel j_offs], 256-1
        jl      .pj_2
        mov     dword [rel j_offs], 256-1
        neg     dword [rel j_add]

.pj_2:
        mov     eax, [rel shape_a8]
        add     eax, (222+81)*6
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        lea     rdi, [rel p4_s2]
        mov     ecx, 8+256
        call    ro_chip

        mov     word [rel z_offs], 0

        lea     rsi, [rel pts_src]
        lea     rdi, [rel pts_tab+(440*6)]
        mov     ecx, 158+12+384
        call    ro_chip

        mov     eax, [rel n_vert_src8]
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        mov     eax, [rel n_vert_a8]
        add     rax, qword [rel Code32_addr]
        mov     rdi, rax
        mov     ecx, 256
        call    ro_chip

        add     rsp, 0x20
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ro_chip - rotate a (x,y,z) table by the 2D ro_z angle (sinus[ebx]).
; r12 = sinus table base (set by make_chip).
ro_chip:
        mov     ax, [rsi]
        imul    word [r12 + rbx*2 + 512]
        mov     bp, dx
        mov     ax, [rsi+2]
        imul    word [r12 + rbx*2]
        sub     bp, dx
        add     bp, bp
        mov     [rdi], bp

        mov     ax, [rsi]
        imul    word [r12 + rbx*2]
        mov     bp, dx
        mov     ax, [rsi+2]
        imul    word [r12 + rbx*2 + 512]
        add     bp, dx
        add     bp, bp
        mov     [rdi+2], bp

        mov     ax, [rsi+4]
        add     ax, [rel z_offs]
        mov     [rdi+4], ax

        add     rsi, 6
        add     rdi, 6
        loop    ro_chip
        ret

; ================================================================ prep_rot1
; Build object rotation matrix ob1..9 from r_x/r_y/r_z (word sine table).
prep_rot1:
        lea     rsi, [rel sinus]
        lea     rdi, [rel sinus+512]

        movsx   ebx, word [r_x]
        and     ebx, 3ffh
        movsx   eax, word [rsi+rbx*2]
        mov     [rel s_x], eax
        movsx   eax, word [rdi+rbx*2]
        mov     [rel c_x], eax

        movsx   ebx, word [r_y]
        and     ebx, 3ffh
        movsx   eax, word [rsi+rbx*2]
        mov     [rel s_y], eax
        movsx   eax, word [rdi+rbx*2]
        mov     [rel c_y], eax

        movsx   ebx, word [r_z]
        and     ebx, 3ffh
        movsx   eax, word [rsi+rbx*2]
        mov     [rel s_z], eax
        movsx   eax, word [rdi+rbx*2]
        mov     [rel c_z], eax

        mov     eax, [rel c_y]
        imul    dword [rel c_z]
        sar     eax, 15
        mov     [rel ob1], eax
        mov     eax, [rel c_x]
        imul    dword [rel s_z]
        mov     ebx, [rel s_x]
        imul    ebx, dword [rel s_y]
        sar     ebx, 15
        imul    ebx, dword [rel c_z]
        sub     ebx, eax
        sar     ebx, 15
        mov     [rel ob2], ebx
        mov     eax, [rel s_x]
        imul    dword [rel s_z]
        mov     ebx, [rel c_x]
        imul    ebx, dword [rel s_y]
        sar     ebx, 15
        imul    ebx, dword [rel c_z]
        add     ebx, eax
        sar     ebx, 15
        mov     [rel ob3], ebx
        mov     eax, [rel c_y]
        imul    dword [rel s_z]
        sar     eax, 15
        mov     [rel ob4], eax
        mov     eax, [rel c_x]
        imul    dword [rel c_z]
        mov     ebx, [rel s_x]
        imul    ebx, dword [rel s_y]
        sar     ebx, 15
        imul    ebx, dword [rel s_z]
        add     ebx, eax
        sar     ebx, 15
        mov     [rel ob5], ebx
        mov     eax, [rel s_x]
        imul    dword [rel c_z]
        mov     ebx, [rel c_x]
        imul    ebx, dword [rel s_y]
        sar     ebx, 15
        imul    ebx, dword [rel s_z]
        sub     ebx, eax
        sar     ebx, 15
        mov     [rel ob6], ebx
        mov     eax, [rel s_y]
        neg     eax
        mov     [rel ob7], eax
        mov     eax, [rel s_x]
        imul    dword [rel c_y]
        sar     eax, 15
        mov     [rel ob8], eax
        mov     eax, [rel c_x]
        imul    dword [rel c_y]
        sar     eax, 15
        mov     [rel ob9], eax
        ret

; ================================================================ prep_rot2
; Build camera rotation matrix ca1..ca9 from cm_x/cm_y/cm_z.
prep_rot2:
        lea     rsi, [rel sinus]
        lea     rdi, [rel sinus+512]

        movsx   ebx, word [rel cm_x]
        and     ebx, 3ffh
        movsx   eax, word [rsi+rbx*2]
        mov     [rel s_x], eax
        movsx   eax, word [rdi+rbx*2]
        mov     [rel c_x], eax

        movsx   ebx, word [rel cm_y]
        and     ebx, 3ffh
        movsx   eax, word [rsi+rbx*2]
        mov     [rel s_y], eax
        movsx   eax, word [rdi+rbx*2]
        mov     [rel c_y], eax

        movsx   ebx, word [rel cm_z]
        and     ebx, 3ffh
        movsx   eax, word [rsi+rbx*2]
        mov     [rel s_z], eax
        movsx   eax, word [rdi+rbx*2]
        mov     [rel c_z], eax

        mov     eax, [rel c_y]
        imul    dword [rel c_z]
        sar     eax, 15
        mov     [rel ca1], eax
        mov     eax, [rel c_x]
        imul    dword [rel s_z]
        mov     ebx, [rel s_x]
        imul    ebx, dword [rel s_y]
        sar     ebx, 15
        imul    ebx, dword [rel c_z]
        sub     ebx, eax
        sar     ebx, 15
        mov     [rel ca2], ebx
        mov     eax, [rel s_x]
        imul    dword [rel s_z]
        mov     ebx, [rel c_x]
        imul    ebx, dword [rel s_y]
        sar     ebx, 15
        imul    ebx, dword [rel c_z]
        add     ebx, eax
        sar     ebx, 15
        mov     [rel ca3], ebx
        mov     eax, [rel c_y]
        imul    dword [rel s_z]
        sar     eax, 15
        mov     [rel ca4], eax
        mov     eax, [rel c_x]
        imul    dword [rel c_z]
        mov     ebx, [rel s_x]
        imul    ebx, dword [rel s_y]
        sar     ebx, 15
        imul    ebx, dword [rel s_z]
        add     ebx, eax
        sar     ebx, 15
        mov     [rel ca5], ebx
        mov     eax, [rel s_x]
        imul    dword [rel c_z]
        mov     ebx, [rel c_x]
        imul    ebx, dword [rel s_y]
        sar     ebx, 15
        imul    ebx, dword [rel s_z]
        sub     ebx, eax
        sar     ebx, 15
        mov     [rel ca6], ebx
        mov     eax, [rel s_y]
        neg     eax
        mov     [rel ca7], eax
        mov     eax, [rel s_x]
        imul    dword [rel c_y]
        sar     eax, 15
        mov     [rel ca8], eax
        mov     eax, [rel c_x]
        imul    dword [rel c_y]
        sar     eax, 15
        mov     [rel ca9], eax
        ret

; ==================================================================== rotate
; Full 3D pass over the face centroids (pts_tab): object+view+project+clip.
; Visible faces go into draw_tab (zet+12000 | face byte offset). For each
; referenced vertex once, rotate+project it into rcalc. Uses the ob/ca
; matrices from prep_rot1/prep_rot2 and the render shape + arena con block.
rotate:
        ; clear check
        lea     rdi, [rel check]
        xor     eax, eax
        mov     ecx, p_len
        rep stosw

        mov     dword [rel ile], 0

        ; r13 = con block base, r14 = render shape + rotated morph targets
        ; r8 = check base, r9 = rcalc base (register bases, not [rel sym+reg])
        mov     eax, [rel con_a8]
        add     rax, qword [rel Code32_addr]
        mov     r13, rax
        lea     r14, [rel p4_render_shape]
        lea     r8, [rel check]
        lea     r9, [rel rcalc]
        lea     rsi, [rel pts_tab]
        mov     eax, [rel draw_a8]
        add     rax, qword [rel Code32_addr]
        mov     rdi, rax
        xor     ebx, ebx
        mov     ecx, f_len

.ro:
        ; object rotate (ob1..9) of the centroid
        movsx   eax, word [rsi]
        imul    dword [rel ob1]
        sar     eax, 15
        mov     ebp, eax
        movsx   eax, word [rsi+2]
        imul    dword [rel ob2]
        sar     eax, 15
        add     ebp, eax
        movsx   eax, word [rsi+4]
        imul    dword [rel ob3]
        sar     eax, 15
        add     ebp, eax
        mov     [rel t_x], ebp

        movsx   eax, word [rsi]
        imul    dword [rel ob4]
        sar     eax, 15
        mov     ebp, eax
        movsx   eax, word [rsi+2]
        imul    dword [rel ob5]
        sar     eax, 15
        add     ebp, eax
        movsx   eax, word [rsi+4]
        imul    dword [rel ob6]
        sar     eax, 15
        add     ebp, eax
        mov     [rel t_y], ebp

        movsx   eax, word [rsi]
        imul    dword [rel ob7]
        sar     eax, 15
        mov     ebp, eax
        movsx   eax, word [rsi+2]
        imul    dword [rel ob8]
        sar     eax, 15
        add     ebp, eax
        movsx   eax, word [rsi+4]
        imul    dword [rel ob9]
        sar     eax, 15
        add     ebp, eax
        mov     [rel t_z], ebp

        ; camera rotate (ca1..9) + object offset
        mov     eax, [rel t_x]
        imul    dword [rel ca1]
        sar     eax, 15
        mov     ebp, eax
        mov     eax, [rel t_y]
        imul    dword [rel ca2]
        sar     eax, 15
        add     ebp, eax
        mov     eax, [rel t_z]
        imul    dword [rel ca3]
        sar     eax, 15
        add     ebp, eax
        add     ebp, [rel o_x]
        mov     [rel p_x], ebp

        mov     eax, [rel t_x]
        imul    dword [rel ca4]
        sar     eax, 15
        mov     ebp, eax
        mov     eax, [rel t_y]
        imul    dword [rel ca5]
        sar     eax, 15
        add     ebp, eax
        mov     eax, [rel t_z]
        imul    dword [rel ca6]
        sar     eax, 15
        add     ebp, eax
        add     ebp, [rel o_y]
        mov     [rel p_y], ebp

        mov     eax, [rel t_x]
        imul    dword [rel ca7]
        sar     eax, 15
        mov     ebp, eax
        mov     eax, [rel t_y]
        imul    dword [rel ca8]
        sar     eax, 15
        add     ebp, eax
        mov     eax, [rel t_z]
        imul    dword [rel ca9]
        sar     eax, 15
        add     ebp, eax
        add     ebp, [rel o_z]
        mov     [rel p_z], ebp

        cmp     dword [rel p_x], x1_min
        jl      .no_face
        cmp     dword [rel p_x], x1_max
        jg      .no_face
        cmp     dword [rel p_y], y1_min
        jl      .no_face
        cmp     dword [rel p_y], y1_max
        jg      .no_face
        cmp     dword [rel p_z], z1_min
        jl      .no_face
        cmp     dword [rel p_z], z1_max
        jg      .no_face

        add     bp, 12000
        mov     [rdi], bp
        mov     [rdi+2], bx
        add     rdi, 4
        inc     dword [rel ile]

        ; vertex fill (once per vertex via check)
        push    rsi
        push    rdi
        push    rbx
        push    rcx

        mov     ecx, 3
.lo:
        movzx   esi, word [r13 + rbx]        ; con1[ebx] (face vertex, byte form)
        cmp     word [r8 + rsi], 0
        jne     .skip
        inc     word [r8 + rsi]

        ; rcalc[esi*2] destination
        lea     r15, [r9 + rsi*2]
        lea     r10, [rsi + rsi*2]           ; 3*vertex byte offset into shape

        movsx   eax, word [r14 + r10]
        imul    dword [rel ob1]
        sar     eax, 15
        mov     ebp, eax
        movsx   eax, word [r14 + r10 + 2]
        imul    dword [rel ob2]
        sar     eax, 15
        add     ebp, eax
        movsx   eax, word [r14 + r10 + 4]
        imul    dword [rel ob3]
        sar     eax, 15
        add     ebp, eax
        mov     [rel t_x], ebp

        movsx   eax, word [r14 + r10]
        imul    dword [rel ob4]
        sar     eax, 15
        mov     ebp, eax
        movsx   eax, word [r14 + r10 + 2]
        imul    dword [rel ob5]
        sar     eax, 15
        add     ebp, eax
        movsx   eax, word [r14 + r10 + 4]
        imul    dword [rel ob6]
        sar     eax, 15
        add     ebp, eax
        mov     [rel t_y], ebp

        movsx   eax, word [r14 + r10]
        imul    dword [rel ob7]
        sar     eax, 15
        mov     ebp, eax
        movsx   eax, word [r14 + r10 + 2]
        imul    dword [rel ob8]
        sar     eax, 15
        add     ebp, eax
        movsx   eax, word [r14 + r10 + 4]
        imul    dword [rel ob9]
        sar     eax, 15
        add     ebp, eax
        mov     [rel t_z], ebp

        mov     eax, [rel t_x]
        imul    dword [rel ca1]
        sar     eax, 15
        mov     ebp, eax
        mov     eax, [rel t_y]
        imul    dword [rel ca2]
        sar     eax, 15
        add     ebp, eax
        mov     eax, [rel t_z]
        imul    dword [rel ca3]
        sar     eax, 15
        add     ebp, eax
        add     ebp, [rel o_x]
        mov     [rel p_x], ebp

        mov     eax, [rel t_x]
        imul    dword [rel ca4]
        sar     eax, 15
        mov     ebp, eax
        mov     eax, [rel t_y]
        imul    dword [rel ca5]
        sar     eax, 15
        add     ebp, eax
        mov     eax, [rel t_z]
        imul    dword [rel ca6]
        sar     eax, 15
        add     ebp, eax
        add     ebp, [rel o_y]
        mov     [rel p_y], ebp

        mov     eax, [rel t_x]
        imul    dword [rel ca7]
        sar     eax, 15
        mov     ebp, eax
        mov     eax, [rel t_y]
        imul    dword [rel ca8]
        sar     eax, 15
        add     ebp, eax
        mov     eax, [rel t_z]
        imul    dword [rel ca9]
        sar     eax, 15
        add     ebp, eax
        add     ebp, [rel o_z]
        mov     [rel p_z], ebp

        ; project
        mov     ebp, [rel p_z]
        add     ebp, 7600
        mov     eax, zoom+32
        imul    dword [rel p_x]
        idiv    ebp
        add     ax, 160
        mov     [r15], ax
        mov     eax, zoom
        imul    dword [rel p_y]
        idiv    ebp
        add     ax, 100
        mov     [r15+2], ax

.skip:
        add     rbx, 2
        dec     ecx
        jnz     .lo

        pop     rcx
        pop     rbx
        pop     rdi
        pop     rsi

.no_face:
        add     rsi, 6
        add     rbx, 6
        dec     ecx
        jnz     .ro
        ret

; ================================================================= bit_sort
bit_sort:
        cmp     dword [rel ile], 0
        je      .exit
        mov     eax, [rel faces]
        push    rax
        mov     eax, [rel ile]
        mov     [rel faces], eax
        call    sort
        pop     rax
        mov     [rel faces], eax
.exit:
        ret

; ===================================================================== show
; Iterate the sorted draw_tab (far -> near); resolve the per-face texture
; selector, gather the 3 vertices (rcalc) + texels (pkt / n_rot / pos) and
; call face. Backface culled for the visibility-flagged faces.
show:
        cmp     dword [rel ile], 0
        je      .zexit

        ; es = scr_sel : resolve the screen base once
        lea     rbx, [rel sel_base_table]
        movzx   eax, word [rel scr_sel]
        and     eax, 0x1ff
        mov     r12, [rbx + rax*8]
        mov     [rel esq], r12

        ; r13 = con block base
        mov     eax, [rel con_a8]
        add     rax, qword [rel Code32_addr]
        mov     r13, rax

        ; rsi = draw_tab arena, walking from the END (far first)
        mov     eax, [rel draw_a8]
        add     rax, qword [rel Code32_addr]
        mov     ecx, [rel ile]
        lea     rsi, [rax + rcx*4 - 4]

        ; r15 = rcalc base (module .bss)
        lea     r15, [rel rcalc]

.lop:
        push    rsi

        ; ---- con3 record for this face ----
        movzx   eax, word [rsi+2]
        mov     ebx, 6
        xor     edx, edx
        div     ebx
        shl     eax, 3
        lea     rbx, [rel con3]
        mov     eax, [rbx+rax]              ; map index 0..3
        lea     rdx, [rel map_sel_tab]
        movzx   eax, word [rdx + rax*2]
        lea     rbx, [rel sel_base_table]
        and     eax, 0x1ff
        mov     r14, [rbx + rax*8]          ; texture base (fs)
        mov     [rel fsq], r14

        movzx   edi, word [rsi+2]           ; face byte offset into con table

        movzx   eax, word [rsi+2]
        mov     ebx, 6
        xor     edx, edx
        div     ebx
        shl     eax, 3
        lea     rbx, [rel con3]
        movzx   edx, word [rbx+rax+4]       ; {plane hi, color lo}
        mov     [rel col], dx
        movzx   ecx, byte [rbx+rax+6]       ; vis
        mov     r9, rcx
        movzx   r10d, byte [rbx+rax+7]      ; phong

        or      dh, dh
        jz      .no_plane
        ; ---- plane (map1-14 faces: pkt texels, verts in src1) ----
        lea     rbp, [rel pkt]
        movzx   ebx, word [r13+rdi]
        movsx   eax, word [r15 + rbx*2]
        mov     [rel x_1], eax
        movsx   eax, word [r15 + rbx*2 + 2]
        mov     [rel y_1], eax
        sub     ebx, 222*2
        mov     eax, dword [rbp + rbx*2]
        mov     [rel p_1], eax
        movzx   ebx, word [r13+rdi+2]
        movsx   eax, word [r15 + rbx*2]
        mov     [rel x_2], eax
        movsx   eax, word [r15 + rbx*2 + 2]
        mov     [rel y_2], eax
        sub     ebx, 222*2
        mov     eax, dword [rbp + rbx*2]
        mov     [rel p_2], eax
        movzx   ebx, word [r13+rdi+4]
        movsx   eax, word [r15 + rbx*2]
        mov     [rel x_3], eax
        movsx   eax, word [r15 + rbx*2 + 2]
        mov     [rel y_3], eax
        sub     ebx, 222*2
        mov     eax, dword [rbp + rbx*2]
        mov     [rel p_3], eax
        jmp     .drawing
.no_plane:
        or      r10b, r10b
        jz      .nshading
        ; ---- phong (map4 faces: n_rot texels, verts in src3) ----
        mov     eax, [rel n_rot_a8]
        add     rax, qword [rel Code32_addr]
        mov     rbp, rax
        movzx   ebx, word [r13+rdi]
        movsx   eax, word [r15 + rbx*2]
        mov     [rel x_1], eax
        movsx   eax, word [r15 + rbx*2 + 2]
        mov     [rel y_1], eax
        sub     ebx, (222+81+8)*2
        movzx   eax, word [rbp + rbx*2]
        add     ax, 128
        shl     ax, 8
        mov     [rel p_1], ax
        movzx   eax, word [rbp + rbx*2 + 2]
        add     ax, 108
        shl     ax, 8
        mov     [rel p_1+2], ax
        movzx   ebx, word [r13+rdi+2]
        movsx   eax, word [r15 + rbx*2]
        mov     [rel x_2], eax
        movsx   eax, word [r15 + rbx*2 + 2]
        mov     [rel y_2], eax
        sub     ebx, (222+81+8)*2
        movzx   eax, word [rbp + rbx*2]
        add     ax, 128
        shl     ax, 8
        mov     [rel p_2], ax
        movzx   eax, word [rbp + rbx*2 + 2]
        add     ax, 108
        shl     ax, 8
        mov     [rel p_2+2], ax
        movzx   ebx, word [r13+rdi+4]
        movsx   eax, word [r15 + rbx*2]
        mov     [rel x_3], eax
        movsx   eax, word [r15 + rbx*2 + 2]
        mov     [rel y_3], eax
        sub     ebx, (222+81+8)*2
        movzx   eax, word [rbp + rbx*2]
        add     ax, 128
        shl     ax, 8
        mov     [rel p_3], ax
        movzx   eax, word [rbp + rbx*2 + 2]
        add     ax, 108
        shl     ax, 8
        mov     [rel p_3+2], ax
        jmp     .drawing
.nshading:
        ; ---- standard (map1 + map2 + map3 faces: pos UVs from con2) ----
        lea     r10, [rel con2]
        lea     r11, [rel pos]
        movzx   ebx, word [r13+rdi]
        movsx   eax, word [r15 + rbx*2]
        mov     [rel x_1], eax
        movsx   eax, word [r15 + rbx*2 + 2]
        mov     [rel y_1], eax
        movzx   ebx, word [r10 + rdi]
        mov     eax, dword [r11 + rbx*2]
        mov     [rel p_1], eax
        movzx   ebx, word [r13+rdi+2]
        movsx   eax, word [r15 + rbx*2]
        mov     [rel x_2], eax
        movsx   eax, word [r15 + rbx*2 + 2]
        mov     [rel y_2], eax
        movzx   ebx, word [r10 + rdi+2]
        mov     eax, dword [r11 + rbx*2]
        mov     [rel p_2], eax
        movzx   ebx, word [r13+rdi+4]
        movsx   eax, word [r15 + rbx*2]
        mov     [rel x_3], eax
        movsx   eax, word [r15 + rbx*2 + 2]
        mov     [rel y_3], eax
        movzx   ebx, word [r10 + rdi+4]
        mov     eax, dword [r11 + rbx*2]
        mov     [rel p_3], eax
.drawing:
        or      r9b, r9b
        jz      .draw
        ; backface cull (16-bit cross product), negative = hidden
        mov     ax, word [rel x_1]
        sub     ax, word [rel x_2]
        mov     bx, word [rel y_3]
        sub     bx, word [rel y_2]
        imul    bx, ax
        mov     ax, word [rel x_2]
        sub     ax, word [rel x_3]
        mov     cx, word [rel y_2]
        sub     cx, word [rel y_1]
        imul    cx, ax
        sub     bx, cx
        js      .hide
.draw:
        lea     rax, [rel p4_draw_args]
        mov     edx, [rel x_1]
        mov     [rax], edx
        mov     edx, [rel y_1]
        mov     [rax + 4], edx
        mov     edx, [rel x_2]
        mov     [rax + 8], edx
        mov     edx, [rel y_2]
        mov     [rax + 12], edx
        mov     edx, [rel x_3]
        mov     [rax + 16], edx
        mov     edx, [rel y_3]
        mov     [rax + 20], edx
        mov     edx, [rel p_1]
        mov     [rax + 24], edx
        mov     edx, [rel p_2]
        mov     [rax + 28], edx
        mov     edx, [rel p_3]
        mov     [rax + 32], edx
        mov     rdx, [rel fsq]
        mov     [rax + 40], rdx
        mov     rdx, [rel esq]
        mov     [rax + 48], rdx
        movzx   edx, byte [rel col]
        mov     [rax + 56], edx
        mov     rcx, rax
        ; show() has one per-face push active here; it already restores the
        ; entry alignment, so reserve the normal 32-byte shadow space.
        sub     rsp, 0x20
        call    vk_p4_draw_triangle
        add     rsp, 0x20
.hide:
        pop     rsi
        sub     rsi, 4
        dec     dword [rel ile]
        jne     .lop
.zexit:
        ret

; ===================================================================== face
; Textured-triangle rasterizer (P4's own, identical shape to txtr.asm's
; tm_face). x_1..3/y_1..3 + p_1..3 from show; low byte of `col` offset added
; to every texel; texture base in fsq, screen base in esq. The production
; show path uses vk_p4_draw_triangle for bounded edge coverage; this original
; fixed-point routine remains below as a source reference.
face:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0x20

        mov     r12, [rel esq]          ; screen base
        mov     r13, [rel fsq]          ; texture base
        xor     edi, edi
        xor     esi, esi
        xor     ebx, ebx

        mov     word [rel pom], 0

        mov     eax, [rel y_1]
        cmp     eax, [rel y_2]
        jle     .pr_1
        mov     eax, [rel x_1]
        xchg    [rel x_2], eax
        mov     [rel x_1], eax
        mov     eax, [rel y_1]
        xchg    [rel y_2], eax
        mov     [rel y_1], eax
        mov     eax, dword [rel p_1]
        xchg    dword [rel p_2], eax
        mov     dword [rel p_1], eax
.pr_1:
        mov     eax, [rel y_1]
        cmp     eax, [rel y_3]
        jle     .pr_2
        mov     eax, [rel x_1]
        xchg    [rel x_3], eax
        mov     [rel x_1], eax
        mov     eax, [rel y_1]
        xchg    [rel y_3], eax
        mov     [rel y_1], eax
        mov     eax, dword [rel p_1]
        xchg    dword [rel p_3], eax
        mov     dword [rel p_1], eax
.pr_2:
        mov     eax, [rel y_2]
        cmp     eax, [rel y_3]
        jle     .pr_3
        mov     eax, [rel x_2]
        xchg    [rel x_3], eax
        mov     [rel x_2], eax
        mov     eax, [rel y_2]
        xchg    [rel y_3], eax
        mov     [rel y_2], eax
        mov     eax, dword [rel p_2]
        xchg    dword [rel p_3], eax
        mov     dword [rel p_2], eax
.pr_3:
        cmp     word [rel y_1], y2_max-1
        jge     .sk
        cmp     word [rel y_3], y2_min
        jl      .sk

        mov     eax, [rel y_2]
        sub     eax, [rel y_1]
        jne     .pr_4
        inc     eax
        mov     word [rel pom], 1
.pr_4:
        mov     [rel dy_1], eax

        mov     eax, [rel y_3]
        sub     eax, [rel y_2]
        jne     .pr_5
        inc     eax
.pr_5:
        mov     [rel dy_2], eax

        mov     eax, [rel y_3]
        sub     eax, [rel y_1]
        jne     .pr_6
        inc     eax
.pr_6:
        mov     [rel dy_3], eax

        mov     eax, [rel x_3]
        sub     eax, [rel x_1]
        shl     eax, 16
        cdq
        idiv    dword [rel dy_3]
        mov     [rel dx_2], eax

        movzx   ebx, word [rel p_1]
        movzx   eax, word [rel p_3]
        sub     eax, ebx
        cdq
        idiv    dword [rel dy_3]
        mov     [rel pd_1], ax

        movzx   ebx, word [rel p_1+2]
        movzx   eax, word [rel p_3+2]
        sub     eax, ebx
        cdq
        idiv    dword [rel dy_3]
        mov     [rel pd_2], ax

        cmp     word [rel pom], 1
        jne     .no

        mov     eax, [rel x_1]
        mov     [rel pom], ax
        shl     eax, 16
        mov     [rel x_s], eax
        mov     eax, [rel x_2]
        shl     eax, 16
        mov     [rel x_1], eax
        mov     eax, dword [rel p_1]
        mov     dword [rel mem], eax
        jmp     .go

.no:
        mov     eax, [rel x_2]
        sub     eax, [rel x_1]
        shl     eax, 16
        cdq
        idiv    dword [rel dy_1]
        mov     [rel dx_1], eax

        mov     eax, [rel dy_1]
        imul    dword [rel dx_2]
        shr     eax, 16
        add     eax, [rel x_1]
        mov     [rel pom], ax

        mov     eax, [rel dy_1]
        imul    dword [rel pd_1]
        add     ax, [rel p_1]
        mov     [rel mem], ax

        mov     eax, [rel dy_1]
        imul    dword [rel pd_2]
        add     ax, [rel p_1+2]
        mov     [rel mem+2], ax

        mov     eax, [rel x_1]
        shl     eax, 16
        mov     [rel x_1], eax
        mov     [rel x_s], eax

.go:
        mov     eax, [rel y_1]
        imul    eax, 320
        mov     [rel y_1], eax
        mov     eax, [rel y_2]
        imul    eax, 320
        mov     [rel y_2], eax

        mov     ax, [rel p_1]
        xchg    word [rel p_1+2], ax
        mov     [rel p_1], ax

        cmp     dword [rel y_3], y2_max-1
        jl      .no_da
        sub     dword [rel y_3], y2_max-1
        mov     eax, [rel y_3]
        sub     [rel dy_3], eax

.no_da:
        xor     ebx, ebx

        mov     bx, [rel x_2]
        sub     bx, [rel pom]
        jnz     .okay
        inc     bx
.okay:
        jg      .norm
        neg     bx

        movzx   ecx, word [rel mem]
        movzx   eax, word [rel p_2]
        sub     eax, ecx
        cdq
        idiv    ebx
        mov     si, ax

        shl     esi, 16

        movzx   ecx, word [rel mem+2]
        movzx   eax, word [rel p_2+2]
        sub     eax, ecx
        cdq
        idiv    ebx
        mov     si, ax

        mov     cx, word [rel col]

.draw_1:
        mov     ebx, [rel y_1]
        cmp     [rel y_2], ebx
        jne     .no_1

        mov     eax, [rel x_3]
        sub     eax, [rel x_2]
        shl     eax, 16
        cdq
        idiv    dword [rel dy_2]
        mov     [rel dx_1], eax

.no_1:
        cmp     ebx, y2_min*320
        jl      .go_1

        ; The original loads these integer edge coordinates into 16-bit
        ; registers and uses signed comparisons for off-screen-left spans.
        ; Zero-extending a negative coordinate turns it into ~65K and drops
        ; the row before the virtual scan can clip it into the viewport.
        movsx   edi, word [rel x_1+2]
        movsx   r14d, word [rel x_s+2]

        cmp     edi, x2_max
        jge     .go_1
        cmp     r14d, x2_min
        jl      .go_1

        mov     edx, dword [rel p_1]

        cmp     r14d, x2_max-1
        jl      .no_c3

.add_2:
        add     edx, esi
        dec     r14d
        cmp     r14d, x2_max-1
        jg      .add_2

.no_c3:
        cmp     edi, x2_min
        jge     .no_c4
        mov     edi, x2_min

.no_c4:
        sub     r14d, edi
        jl      .go_1

        add     edi, r14d
        add     edi, [rel y_1]
        inc     r14d

.fo_1:
        mov     bl, dh
        shld    ebx, edx, 8
        movzx   rbx, bx
        mov     al, [r13 + rbx]
        add     al, cl
        mov     r15d, edi
        mov     [r12 + r15], al
        dec     edi
        add     edx, esi
        dec     r14d
        jnz     .fo_1

.go_1:
        mov     eax, [rel dx_1]
        add     [rel x_1], eax
        mov     eax, [rel dx_2]
        add     [rel x_s], eax
        mov     ax, [rel pd_2]
        add     [rel p_1], ax
        mov     ax, [rel pd_1]
        add     [rel p_1+2], ax
        add     dword [rel y_1], 320

        dec     dword [rel dy_3]
        jne     .draw_1
.sk:
        add     rsp, 0x20
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

.norm:
        movzx   ecx, word [rel mem]
        movzx   eax, word [rel p_2]
        sub     eax, ecx
        cdq
        idiv    ebx
        mov     si, ax

        shl     esi, 16

        movzx   ecx, word [rel mem+2]
        movzx   eax, word [rel p_2+2]
        sub     eax, ecx
        cdq
        idiv    ebx
        mov     si, ax

        mov     cx, word [rel col]

.draw_2:
        mov     ebx, [rel y_1]
        cmp     [rel y_2], ebx
        jne     .no_2

        mov     eax, [rel x_3]
        sub     eax, [rel x_2]
        shl     eax, 16
        cdq
        idiv    dword [rel dy_2]
        mov     [rel dx_1], eax

.no_2:
        cmp     ebx, y2_min*320
        jl      .go_2

        movsx   edi, word [rel x_s+2]
        movsx   r14d, word [rel x_1+2]

        cmp     edi, x2_max
        jge     .go_2
        cmp     r14d, x2_min
        jl      .go_2

        mov     edx, dword [rel p_1]

        cmp     edi, x2_min
        jge     .no_c1

.add_1:
        add     edx, esi
        inc     edi
        cmp     edi, x2_min
        jl      .add_1

.no_c1:
        cmp     r14d, x2_max-1
        jl      .no_c2
        mov     r14d, x2_max-1

.no_c2:
        sub     r14d, edi
        jl      .go_2

        add     edi, r14d
        add     edi, [rel y_1]
        inc     r14d

.fo_2:
        mov     bl, dh
        shld    ebx, edx, 8
        movzx   rbx, bx
        mov     al, [r13 + rbx]
        add     al, cl
        mov     r15d, edi
        mov     [r12 + r15], al
        inc     edi
        add     edx, esi
        dec     r14d
        jnz     .fo_2

.go_2:
        mov     eax, [rel dx_1]
        add     [rel x_1], eax
        mov     eax, [rel dx_2]
        add     [rel x_s], eax
        mov     ax, [rel pd_2]
        add     [rel p_1], ax
        mov     ax, [rel pd_1]
        add     [rel p_1+2], ax
        add     dword [rel y_1], 320

        dec     dword [rel dy_3]
        jne     .draw_2
        jmp     .sk

; ================================================================ show_logo
; Scroll a 64x50 logo frame (from the arena logo buffer + sun_step*3200) at
; screen (4,255). sun_step advances by frames/2 * ciota.
show_logo:
        cmp     dword [rel sun_step], 15
        jl      .sun_ok1
        sub     dword [rel sun_step], 14
.sun_ok1:
        cmp     dword [rel sun_step], 0
        jg      .sun_ok2
        add     dword [rel sun_step], 14
.sun_ok2:
        mov     eax, [rel sun_step]
        imul    eax, 64*50
        add     eax, [rel logo]
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        mov     edi, [rel scr_addr]
        add     edi, (4*320)+255
        add     rdi, qword [rel Code32_addr]
        mov     ecx, 50
.sp1:
        mov     ebp, 64
.sp2:
        lodsb
        or      al, al
        jz      .sun_sk
        mov     [rdi], al
.sun_sk:
        inc     rdi
        dec     ebp
        jnz     .sp2
        add     rdi, 320-64
        dec     ecx
        jnz     .sp1

        mov     eax, [rel frames]
        cmp     eax, 2
        jle     .plo
        shr     eax, 1
        jmp     .doit
.plo:
        mov     eax, 1
.doit:
        imul    dword [rel ciota]
        add     [rel sun_step], eax
        ret
