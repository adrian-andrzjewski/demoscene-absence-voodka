; p4.asm - NASM x64 port of CODE/P4/P4.ASM  (part 4: multi-textured 3D chip /
; four-plane "plate" logo with phong shading and sprite overlays).
;
; Faithful port. P4 is a self-contained fixed-point 3D part:
;   - own rotation: prep_rot1 (ob matrix from r_*) / prep_rot2 (ca matrix
;     from cm_*); rotate() transforms pts_tab through ob then ca+o, clips to
;     the box, fills draw_tab (painter records) + rcalc (projected verts).
;   - textured-triangle rasterizer show()/face() with three shading modes.
;   - borrows only the engine's n_calc (per-vertex normals) and `sort`
;     (radix draw order).
;
; Memory model:
;   - Most tables (con1, c1..c3, src1..3, shape, s1..3, pts_src, pts_tab,
;     rcalc, check, pkt, n_vert_src, n_add, n_vert, n_rot, pos, con2, con3)
;     stay MODULE .data/.bss, addressed directly (the original's flat ptrs).
;   - The two tables the ENGINE touches live in the arena: draw_tab (sort
;     target) and the n_calc inputs/output (we copy post-prepare src3/c3
;     into arena, run n_calc into arena n_vert/n_add, then copy the normals
;     back into module n_vert_src).
;   - Per-frame normal rotation is implemented locally (p4_rotate_normals)
;     over module n_vert -> n_rot, rebuilding the ob matrix from the negated
;     angles just like the engine's rotate_normals (arena-independent).
;   - Texture selectors are emulated via sel_base_table; show() resolves the
;     per-face selector handle to a base (mapQ) for face().
;   - The original decrements the shared `white` toward pic_pal during the
;     ending fade; we use a module-local p4_white to keep the shared palette
;     intact for later parts.
;
; Timeline (ModPos): P4 m_loop spans 0x0D40..0x11FF (part window), then the
; spadaj ending (fade + pic + brum) runs out to ~0x1400 (matches app.cpp).
;
; ABI: 8-push prologue + sub 0x28 -> RSP%16==0 at every C++ call site.

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
extern len
extern sel_base_table

; engine surfaces (engine.asm)
extern shape_addr
extern n_addr
extern inc_addr
extern con_addr
extern sort_addr
extern points
extern faces
extern r_x, r_y, r_z
extern n_calc
extern sort
extern prep_sort
extern sinus

; constants (P4.ASM)
x1_min  EQU -4600
x1_max  EQU 4600
y1_min  EQU -4600
y1_max  EQU 4600
z1_min  EQU -6600
z1_max  EQU 4000
zoom    EQU 160
x2_min  EQU 0
x2_max  EQU 320
y2_min  EQU 0
y2_max  EQU 200
n_src1  EQU 81
n_shape EQU 222
n_src2  EQU 8
n_src3  EQU 256
p_len   EQU 222+81+8+256
n_con1  EQU 440
n_c1    EQU 158
n_c2    EQU 12
n_c3    EQU 384
f_len   EQU 440+158+12+384
ruchow  EQU 2951

; P4AR <arena_offset_var>, <dst_reg> - load real arena pointer
%macro P4AR 2
        mov     eax, [rel %1]          ; 32-bit load zero-extends into rax
        mov     %2, rax
        add     %2, qword [rel Code32_addr]
%endmacro

section .data align=16
global part4

; palettes (spal1..4) + working palette
spal1:  incbin "sw.pal"
spal2:  incbin "v_txr1.pal"
spal3:  incbin "proc.pal"
spal4:  incbin "metal.pal"
pal:    times 256*3 db 0
p4_white: times 768 db 63

; static source geometry
src1:
        %include "p4_src1.inc"   ; 81 verts
src2:
        %include "p4_src2.inc"   ; 8 verts
src3:
        %include "p4_src3.inc"   ; 256 verts
shape:
        %include "p4_shape.inc"  ; 222 verts
; combined vertex space {shape, s1, s2, s3} must stay contiguous (calc_pts)
s1:     times n_src1*3 dw 0
s2:     times n_src2*3 dw 0
s3:     times n_src3*3 dw 0
; connection block {con1, c1, c2, c3} must stay contiguous (con1[edi] indexing)
con1:
        %include "p4_con1.inc"   ; 440 faces
c1:
        %include "p4_c1.inc"     ; 158 faces
c2:
        %include "p4_c2.inc"     ; 12 faces
c3:
        %include "p4_c3.inc"     ; 384 faces

; pos sprite positions (14 dword x,y pairs)
pos:
        dw 10*256,8*256, 10*256,112*256, 63*256,112*256, 63*256,8*256
        dw 63*256,8*256, 63*256,112*256, 126*256,112*256, 126*256,8*256
        dw 126*256,8*256, 126*256,112*256, 189*256,112*256, 189*256,8*256
        dw 189*256,8*256, 189*256,112*256, 248*256,112*256, 248*256,8*256
        dw 8*256,26*256, 8*256,92*256, 236*256,92*256, 236*256,26*256
        dw 8*256,84*256, 8*256,154*256, 236*256,154*256, 236*256,84*256

; con2: per-face pos index, sampled at 6-byte stride in show() (3696 bytes)
con2:
%rep 55
        dw 0*2,1*2,2*2
        dw 0*2,2*2,3*2
        dw 4*2,5*2,6*2
        dw 4*2,6*2,7*2
        dw 8*2,9*2,10*2
        dw 8*2,10*2,11*2
        dw 12*2,13*2,14*2
        dw 12*2,14*2,15*2
%endrep
%rep 79
        dw 0*2,1*2,2*2
        dw 0*2,2*2,3*2
%endrep
        dw 16*2,17*2,18*2
        dw 16*2,18*2,19*2
%rep 8
        dw 20*2,21*2,22*2
        dw 20*2,22*2,23*2
%endrep

; flash schedule (64 dword entries {signal, done})
tablica:
        times 58 dw 0,0
        dw 1,0
        dw 1,0
        dw 1,0
        dw 0,0
        dw 1,0
        dw 0,0

; runtime scalar globals (P4.ASM data block)
scr_addr: dd 0
scr_sel:  dw 0
map1_sel: dw 0
map2_sel: dw 0
map3_sel: dw 0
map4_sel: dw 0
map1: dd 0
map2: dd 0
map3: dd 0
map4: dd 0
logo:   dd 0
pic_data: dd 0
pic_pal:  dd 0
ile_fade: dd 64

cm_x: dw 0
cm_y: dw 0
cm_z: dw 0
s_x:  dd 0
c_x:  dd 0
s_y:  dd 0
c_y:  dd 0
s_z:  dd 0
c_z:  dd 0
ob1:  dd 0
ob2:  dd 0
ob3:  dd 0
ob4:  dd 0
ob5:  dd 0
ob6:  dd 0
ob7:  dd 0
ob8:  dd 0
ob9:  dd 0
ca1:  dd 0
ca2:  dd 0
ca3:  dd 0
ca4:  dd 0
ca5:  dd 0
ca6:  dd 0
ca7:  dd 0
ca8:  dd 0
ca9:  dd 0
t_x:  dd 0
t_y:  dd 0
t_z:  dd 0
p_x:  dd 0
p_y:  dd 0
p_z:  dd 0
o_x:  dd 0
o_y:  dd 0
o_z:  dd 0
ile:  dd 0
jcount: dd 0
frames: dd 0
ruchy:  dd 0
ruchy_ptr: dd 0
znacznik:  dd 0
znacznik2: dd 0
znacznik3: dd 0
sun_step:  dd 0
stary: dw 1
ciota: dd 1
mnoznik: dd 1
ro_z: dw 0
z_offs: dw 0
j_offs: dd 1
j_add:  dd 9

; engine arena offsets used here
draw_tab_a: dd 0
src3_a: dd 0
c3_a:   dd 0
n_vert_a: dd 0
n_add_a:  dd 0
faces_saved: dd 0
; P4 working-buffer arena offsets (kept OUT of the module's small .data/.bss;
; the arena is 64MB).  Allocated in p4_alloc_bufs.
pts_src_a: dd 0
pts_tab_a: dd 0
rcalc_a:  dd 0
check_a:  dd 0
pkt_a:    dd 0
n_vert_src_a: dd 0
n_vert2_a: dd 0
n_rot_a:  dd 0
con3_a:   dd 0
con_a:    dd 0
shape_a2: dd 0
src1_a:   dd 0
src2_a:   dd 0


; resolved bases for face()
mapQ: dq 0
esq:  dq 0

; face engine scratch (P4.ASM x_1..mem) - uninitialized, goes to .bss
section .bss align=16
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
pom:  resw 1
mem:  resw 4
col:  resw 1
; per-face mode flags (from con3) kept across show()'s shading branches
vis_flag: resb 1
phong_flag: resb 1

section .text

; =================================================================== part4 ===
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

        cld
        mov     eax, [rel _scr_Addr]
        mov     [rel scr_addr], eax
        mov     [rel _screen], eax
        ; screen selector for face()/show() (records backbuffer base)
        mov     eax, EOS_ALLOCATE_SELECTOR
        mov     esi, [rel scr_addr]
        add     rsi, qword [rel Code32_addr]
        mov     edi, 320*200
        call    eos_dispatch
        mov     [rel scr_sel], ax

        lea     rsi, [rel p4_white]
        call    pal_set
        v_sync
        v_sync
        v_sync
        v_sync

        vodka   24, map1
        vodka   25, map2
        vodka   26, map3
        vodka   27, map4
        vodka   28, logo
        vodka   29, pic_data
        vodka   30, pic_pal
        vodka   74, ruchy

        ; allocate selectors for the four maps
        mov     eax, EOS_ALLOCATE_SELECTOR
        mov     esi, [rel map1]
        add     rsi, qword [rel Code32_addr]
        mov     edi, 0xffff
        call    eos_dispatch
        mov     [rel map1_sel], ax
        mov     eax, EOS_ALLOCATE_SELECTOR
        mov     esi, [rel map2]
        add     rsi, qword [rel Code32_addr]
        mov     edi, 0xffff
        call    eos_dispatch
        mov     [rel map2_sel], ax
        mov     eax, EOS_ALLOCATE_SELECTOR
        mov     esi, [rel map3]
        add     rsi, qword [rel Code32_addr]
        mov     edi, 0xffff
        call    eos_dispatch
        mov     [rel map3_sel], ax
        mov     eax, EOS_ALLOCATE_SELECTOR
        mov     esi, [rel map4]
        add     rsi, qword [rel Code32_addr]
        mov     edi, 0xffff
        call    eos_dispatch
        mov     [rel map4_sel], ax

        ; engine draw-order table (arena) for `sort`
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, f_len*4
        call    eos_dispatch
        mov     [rel draw_tab_a], edx

        call    p4_alloc_bufs

        call    prepare
        call    p4_engine_set           ; arena src3/c3 + n_calc -> n_vert_src

        call    co_prepare
        call    make_chip
        call    make_pts

        call    make_pos

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

        call    p4_build_con3

.m_loop:
        WaitVbl
        mov     [rel frames], eax

        call    GetModPos
        movzx   eax, word [rel ModPos]
        cmp     eax, 0x1200
        jge     .spadaj

        movzx   eax, word [rel ModPos]
        cmp     [rel stary], ax
        je      .bolek
        and     ax, 0x3f
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
        movzx   eax, word [rel ModPos]
        mov     [rel stary], ax
        v_sync
        set_pal pal, 0, 256
        set_pal spal1, 0, 64
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
        mov     eax, [rel ruchy_ptr]
        imul    eax, 36
        mov     esi, [rel ruchy]
        add     esi, eax
        add     rsi, qword [rel Code32_addr]
        lodsd
        mov     [rel o_x], eax
        lodsd
        mov     [rel o_y], eax
        lodsd
        mov     [rel o_z], eax
        lodsd
        mov     word [rel r_x], ax
        lodsd
        mov     word [rel r_y], ax
        lodsd
        mov     word [rel r_z], ax
        lodsd
        mov     word [rel cm_x], ax
        lodsd
        mov     word [rel cm_y], ax
        lodsd
        mov     word [rel cm_z], ax


        mov     eax, [rel frames]
        add     eax, eax
        mov     ebx, [rel mnoznik]
        imul    ebx
        add     [rel ruchy_ptr], eax

        call    swap
        call    prep_rot1
        call    prep_rot2
        call    make_chip
        call    rotate
        neg     word [rel r_x]
        neg     word [rel r_y]
        neg     word [rel r_z]
        call    p4_rotate_normals
        neg     word [rel r_x]
        neg     word [rel r_y]
        neg     word [rel r_z]
        call    bit_sort
        call    show
        call    show_logo

        ; present the framebuffer (swap() blitted scr->framebuffer earlier)
        extern vk_present_frame
        sub     rsp, 0x20
        call    vk_present_frame
        add     rsp, 0x20

        mov     eax, [rel frames]
        shl     eax, 1
        add     word [rel ro_z], ax
        inc     dword [rel jcount]
        mov     dword [rel znacznik], 1
        jmp     .m_loop

.spadaj:
        lea     rsi, [rel p4_white]
        call    pal_set

        mov     esi, [rel pic_data]
        add     rsi, qword [rel Code32_addr]
        mov     edi, [rel framebuffer_off]
        add     rdi, qword [rel Code32_addr]
        mov     ecx, 16000
        rep movsd

.pic_lo:
        v_sync
        lea     rsi, [rel p4_white]
        mov     edi, [rel pic_pal]
        add     rdi, qword [rel Code32_addr]
        mov     ecx, 768
.co:
        lodsb
        cmp     byte [rdi], al
        je      .zkip
        dec     al
        mov     [rsi-1], al
.zkip:
        inc     rdi
        loop    .co
        lea     rsi, [rel p4_white]
        call    pal_set
        dec     dword [rel ile_fade]
        jnz     .pic_lo

        lea     rdi, [rel p4_white]
        mov     al, 0x3f
        mov     ecx, 768
        rep stosb

.wa:
        call    GetModPos
        cmp     word [rel ModPos], 0x1338
        jl      .wa

.brum:
        call    GetModPos
        movzx   eax, word [rel ModPos]
        and     eax, 0x3f
        lea     rbx, [rel tablica]
        cmp     dword [rbx + rax*4], 0
        je      .no_flash
        cmp     dword [rbx + rax*4 + 2], 1
        je      .no_flash
        mov     dword [rbx + rax*4 + 2], 1
        lea     rsi, [rel p4_white]
        call    pal_set
        lea     rsi, [rel p4_white]
        call    pal_set
        mov     esi, [rel pic_pal]
        add     rsi, qword [rel Code32_addr]
        call    pal_set
.no_flash:
        cmp     word [rel ModPos], 0x1400
        jl      .brum

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

; ================================================================= prepare ----
prepare:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        sub     rsp, 0x20

        P4AR con_a, rsi
        mov     rdi, rsi
        mov     ecx, n_con1*3
.pr_lo1:
        lodsw
        add     ax, ax
        stosw
        loop    .pr_lo1

        P4AR src1_a, rsi
        mov     rdi, rsi
        mov     ecx, n_src1*3
.pr_lo2:
        lodsw
        sar     ax, 1
        stosw
        loop    .pr_lo2

        P4AR con_a, rsi
        add     rsi, n_con1*6
        mov     rdi, rsi
        mov     ecx, n_c1*3
.pr_lo3:
        lodsw
        add     ax, 222
        add     ax, ax
        stosw
        loop    .pr_lo3

        P4AR src2_a, rsi
        mov     rdi, rsi
        mov     ecx, n_src2*3
.pr_lo4:
        lodsw
        sar     ax, 1
        stosw
        loop    .pr_lo4

        P4AR con_a, rsi
        add     rsi, (n_con1+n_c1)*6
        mov     rdi, rsi
        mov     ecx, n_c2*3
.pr_lo5:
        lodsw
        add     ax, 222+81
        add     ax, ax
        stosw
        loop    .pr_lo5

        P4AR src3_a, rsi
        mov     rdi, rsi
        mov     ecx, n_src3*3
.pr_lo6:
        lodsw
        sar     ax, 1
        stosw
        loop    .pr_lo6

        P4AR con_a, rsi
        add     rsi, (n_con1+n_c1+n_c2)*6
        mov     rdi, rsi
        mov     ecx, n_c3*3
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

; ======================================================== p4_alloc_bufs ------
; Allocate P4's working tables in the arena (keeps the module .data/.bss small
; enough to fit the linker's section sizing, matching the P1 arena pattern).
p4_alloc_bufs:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        sub     rsp, 0x20
        AllocateMemory (n_c1+n_c2+n_c3)*3*2, pts_src_a
        AllocateMemory f_len*3*2, pts_tab_a
        AllocateMemory p_len*2*2, rcalc_a
        AllocateMemory p_len*2, check_a
        AllocateMemory n_src1*2*2, pkt_a
        AllocateMemory n_src3*3*2, n_vert_src_a
        AllocateMemory n_src3*3*2, n_vert2_a
        AllocateMemory n_src3*2*2, n_rot_a
        AllocateMemory f_len*8, con3_a
        ; copy the connection geometry (con1+c1+c2+c3) into an arena block so the
        ; working prepare/co_prepare/calc_pts/rotate/show can write/read it there
        ; (the module .data copy stays pristine as the source).
        AllocateMemory f_len*6, con_a
        mov     edi, [rel con_a]
        add     rdi, qword [rel Code32_addr]
        lea     rsi, [rel con1]
        mov     ecx, (f_len*6)>>3
        rep movsd
        ; combined shape space {shape,s1,s2,s3} in arena (p_len*6 bytes)
        AllocateMemory p_len*6, shape_a2
        mov     edi, [rel shape_a2]
        add     rdi, qword [rel Code32_addr]
        lea     rsi, [rel shape]
        mov     ecx, (n_shape*6)>>2
        rep movsd
        ; src1/2/3 in arena
        AllocateMemory n_src1*6, src1_a
        mov     edi, [rel src1_a]
        add     rdi, qword [rel Code32_addr]
        lea     rsi, [rel src1]
        mov     ecx, (n_src1*6)>>2
        rep movsd
        AllocateMemory n_src2*6, src2_a
        mov     edi, [rel src2_a]
        add     rdi, qword [rel Code32_addr]
        lea     rsi, [rel src2]
        mov     ecx, (n_src2*6)>>2
        rep movsd
        AllocateMemory n_src3*6, src3_a
        mov     edi, [rel src3_a]
        add     rdi, qword [rel Code32_addr]
        lea     rsi, [rel src3]
        mov     ecx, (n_src3*6)>>2
        rep movsd
        add     rsp, 0x20
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ============================================================ p4_engine_set ----
p4_engine_set:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        sub     rsp, 0x28

        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, n_src3*3*2
        call    eos_dispatch
        mov     [rel src3_a], edx
        mov     rdi, rdx
        add     rdi, qword [rel Code32_addr]
        lea     rsi, [rel src3]
        mov     ecx, (n_src3*3*2)>>2
        rep movsd

        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, n_c3*3*2
        call    eos_dispatch
        mov     [rel c3_a], edx
        mov     rdi, rdx
        add     rdi, qword [rel Code32_addr]
        lea     rsi, [rel c3]
        mov     ecx, (n_c3*3*2)>>2
        rep movsd

        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, n_src3*3*2
        call    eos_dispatch
        mov     [rel n_vert_a], edx
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, n_src3*2
        call    eos_dispatch
        mov     [rel n_add_a], edx

        mov     eax, [rel src3_a]
        mov     [rel shape_addr], eax
        mov     eax, [rel c3_a]
        mov     [rel con_addr], eax
        mov     eax, [rel n_vert_a]
        mov     [rel n_addr], eax
        mov     eax, [rel n_add_a]
        mov     [rel inc_addr], eax
        mov     dword [rel len], 80
        mov     dword [rel points], n_src3
        mov     dword [rel faces], n_c3
        call    n_calc

        mov     esi, [rel n_vert_a]
        add     rsi, qword [rel Code32_addr]
        mov     edi, [rel n_vert_src_a]
        add     rdi, qword [rel Code32_addr]
        mov     ecx, (n_src3*3*2)>>2
        rep movsd

        mov     eax, [rel draw_tab_a]
        mov     [rel sort_addr], eax
        call    prep_sort

        add     rsp, 0x28
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; =========================================================== p4_build_con3 ----
p4_build_con3:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rdi
        push    rsi
        push    rcx
        sub     rsp, 0x20
        P4AR con3_a, rdi


        movzx   ecx, word [rel map1_sel]
        mov     ebx, n_con1
.b1:
        mov     [rdi], ecx
        mov     byte [rdi+4], 0
        mov     byte [rdi+5], 0
        mov     byte [rdi+6], 0
        mov     byte [rdi+7], 0
        add     rdi, 8
        dec     ebx
        jnz     .b1

        movzx   ecx, word [rel map2_sel]
        mov     ebx, 158-14
.b2:
        mov     [rdi], ecx
        mov     byte [rdi+4], 8*16
        mov     byte [rdi+5], 0
        mov     byte [rdi+6], 1
        mov     byte [rdi+7], 0
        add     rdi, 8
        dec     ebx
        jnz     .b2

        movzx   ecx, word [rel map1_sel]
        mov     ebx, 14
.b3:
        mov     [rdi], ecx
        mov     byte [rdi+4], 64
        mov     byte [rdi+5], 1
        mov     byte [rdi+6], 1
        mov     byte [rdi+7], 0
        add     rdi, 8
        dec     ebx
        jnz     .b3

        movzx   ecx, word [rel map3_sel]
        mov     ebx, 12
.b4:
        mov     [rdi], ecx
        mov     byte [rdi+4], 9*16
        mov     byte [rdi+5], 0
        mov     byte [rdi+6], 1
        mov     byte [rdi+7], 0
        add     rdi, 8
        dec     ebx
        jnz     .b4

        movzx   ecx, word [rel map4_sel]
        mov     ebx, n_c3
.b5:
        mov     [rdi], ecx
        mov     byte [rdi+4], 12*16
        mov     byte [rdi+5], 0
        mov     byte [rdi+6], 1
        mov     byte [rdi+7], 1
        add     rdi, 8
        dec     ebx
        jnz     .b5

        add     rsp, 0x20
        pop     rcx
        pop     rsi
        pop     rdi
        pop     rbx
        pop     rbp
        ret

; ================================================================ make_pos ----
make_pos:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        sub     rsp, 0x20
        P4AR src1_a, rsi
        P4AR pkt_a, rdi
        mov     ecx, n_src1
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
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ================================================================ make_pal ----
make_pal:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        sub     rsp, 0x20
.f_lo:
        lodsb
        add     al, bh
        jns     .pa1
        xor     al, al
.pa1:
        cmp     al, 63
        jle     .pa2
        mov     al, 63
.pa2:
        stosb
        lodsb
        add     al, bl
        jns     .pa3
        xor     al, al
.pa3:
        cmp     al, 63
        jle     .pa4
        mov     al, 63
.pa4:
        stosb
        lodsb
        add     al, dl
        jns     .pa5
        xor     al, al
.pa5:
        cmp     al, 63
        jle     .pa6
        mov     al, 63
.pa6:
        stosb
        loop    .f_lo
        add     rsp, 0x20
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ================================================================ co_prepare ----
co_prepare:
        push    rbp
        mov     rbp, rsp
        push    rsi
        push    rdi
        sub     rsp, 0x20
        P4AR con_a, rsi
        add     rsi, (n_con1+n_c1+n_c2)*6
        mov     rdi, rsi
        mov     ecx, n_c3*3
.pr_lo8:
        lodsw
        add     ax, (222+81+8)*2
        stosw
        loop    .pr_lo8
        add     rsp, 0x20
        pop     rdi
        pop     rsi
        pop     rbp
        ret

; ================================================================ make_pts ----
make_pts:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        sub     rsp, 0x20
        mov     bx, 3
        P4AR shape_a2, r12
        P4AR con_a, rsi
        P4AR pts_tab_a, r13
        mov     rdi, r13
        mov     ecx, n_con1
        call    calc_pts
        P4AR con_a, rsi
        add     rsi, n_con1*6
        P4AR pts_src_a, r13
        mov     rdi, r13
        mov     ecx, n_c1+n_c2+n_c3
        call    calc_pts
        add     rsp, 0x20
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; calc_pts: average 3 verts of each face from shape into edi.
; rsi=faces, edi=dst, ecx=count, r12=shape base, bx=3 divisor.

; calc_pts: average 3 verts of each face from shape into dst.
; rsi=faces, rdi=dst, ecx=count, r12=shape base, bx=3 divisor.
calc_pts:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        sub     rsp, 0x20
        mov     r13, rdi              ; dst
        mov     rdi, r12              ; shape base
.calc_pts_loop:
        movzx   ebp, word [rsi]
        lea     r8, [rbp*2+rbp]
        mov     ax, [rdi+r8]
        movzx   ebp, word [rsi+2]
        lea     r8, [rbp*2+rbp]
        add     ax, [rdi+r8]
        movzx   ebp, word [rsi+4]
        lea     r8, [rbp*2+rbp]
        add     ax, [rdi+r8]
        cwd
        idiv    bx
        mov     [r13], ax
        movzx   ebp, word [rsi]
        lea     r8, [rbp*2+rbp]
        mov     ax, [rdi+r8+2]
        movzx   ebp, word [rsi+2]
        lea     r8, [rbp*2+rbp]
        add     ax, [rdi+r8+2]
        movzx   ebp, word [rsi+4]
        lea     r8, [rbp*2+rbp]
        add     ax, [rdi+r8+2]
        cwd
        idiv    bx
        mov     [r13+2], ax
        movzx   ebp, word [rsi]
        lea     r8, [rbp*2+rbp]
        mov     ax, [rdi+r8+4]
        movzx   ebp, word [rsi+2]
        lea     r8, [rbp*2+rbp]
        add     ax, [rdi+r8+4]
        movzx   ebp, word [rsi+4]
        lea     r8, [rbp*2+rbp]
        add     ax, [rdi+r8+4]
        cwd
        idiv    bx
        mov     [r13+4], ax
        add     rsi, 6
        add     r13, 6
        dec     ecx
        jnz     .calc_pts_loop
        add     rsp, 0x20
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret
; ==================================================================== swap ----
swap:
        push    rbp
        mov     rbp, rsp
        push    rsi
        push    rdi
        sub     rsp, 0x20
        mov     esi, [rel scr_addr]
        add     rsi, qword [rel Code32_addr]
        mov     edi, [rel framebuffer_off]
        add     rdi, qword [rel Code32_addr]
        mov     ecx, 16000
        rep movsd
        mov     edi, [rel scr_addr]
        add     rdi, qword [rel Code32_addr]
        xor     eax, eax
        mov     ecx, 16000
        rep stosd
        add     rsp, 0x20
        pop     rdi
        pop     rsi
        pop     rbp
        ret

; ================================================================ make_chip ----
make_chip:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        sub     rsp, 0x20

        movsx   ebx, word [rel ro_z]
        and     ebx, 0x3ff
        mov     word [rel z_offs], 0

        P4AR src1_a, rsi
        P4AR shape_a2, rdi
        add     rdi, n_shape*6
        mov     ecx, n_src1
        call    ro_chip

        cmp     dword [rel znacznik3], 1
        jne     .pj_2
        mov     r14d, [rel j_offs]
        lea     r13, [rel sinus]
        mov     ebx, 1320
        movsx   eax, word [r13 + r14*2]
        imul    ebx
        sar     eax, 15
        mov     word [rel z_offs], ax
        mov     eax, [rel j_add]
        imul    dword [rel frames]
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
        movsx   ebx, word [rel ro_z]
        and     ebx, 0x3ff
        P4AR src2_a, rsi
        P4AR shape_a2, rdi
        add     rdi, (n_shape+n_src1)*6
        mov     ecx, n_src2+n_src3
        call    ro_chip

        mov word [rel z_offs], 0
        movsx   ebx, word [rel ro_z]
        and     ebx, 0x3ff
        P4AR pts_src_a, rsi
        P4AR pts_tab_a, rdi
        add     rdi, n_con1*6
        mov     ecx, n_c1+n_c2+n_c3
        call    ro_chip

        movsx   ebx, word [rel ro_z]
        and     ebx, 0x3ff
        P4AR n_vert_src_a, rsi
        P4AR n_vert2_a, rdi
        mov     ecx, n_src3
        call    ro_chip

        add     rsp, 0x20
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ro_chip: rotate xyz vertices through z angle (ebx = sinus index) into rdi.
ro_chip:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        sub     rsp, 0x20
        lea     r12, [rel sinus]
.ro_loop:
        mov     ax, [rsi]
        imul    word [r12+rbx*2+512]
        mov     bp, dx
        mov     ax, [rsi+2]
        imul    word [r12+rbx*2]
        sub     bp, dx
        add     bp, bp
        mov     [rdi], bp
        mov     ax, [rsi]
        imul    word [r12+rbx*2]
        mov     bp, dx
        mov     ax, [rsi+2]
        imul    word [r12+rbx*2+512]
        add     bp, dx
        add     bp, bp
        mov     [rdi+2], bp
        mov     ax, [rsi+4]
        add     ax, [rel z_offs]
        mov     [rdi+4], ax
        add     rsi, 6
        add     rdi, 6
        dec     ecx
        jnz     .ro_loop
        add     rsp, 0x20
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ----------------------------------------------------------------------------
; emit 3x3 rotation matrix from the s_*/c_* sin/cos components into %1..%9.
%macro emit_matrix 9
        mov     eax, [rel c_y]
        imul    dword [rel c_z]
        sar     eax, 15
        mov     [rel %1], eax
        mov     eax, [rel c_x]
        imul    dword [rel s_z]
        mov     ebx, [rel s_x]
        imul    ebx, dword [rel s_y]
        sar     ebx, 15
        imul    ebx, dword [rel c_z]
        sub     ebx, eax
        sar     ebx, 15
        mov     [rel %2], ebx
        mov     eax, [rel s_x]
        imul    dword [rel s_z]
        mov     ebx, [rel c_x]
        imul    ebx, dword [rel s_y]
        sar     ebx, 15
        imul    ebx, dword [rel c_z]
        add     ebx, eax
        sar     ebx, 15
        mov     [rel %3], ebx
        mov     eax, [rel c_y]
        imul    dword [rel s_z]
        sar     eax, 15
        mov     [rel %4], eax
        mov     eax, [rel c_x]
        imul    dword [rel c_z]
        mov     ebx, [rel s_x]
        imul    ebx, dword [rel s_y]
        sar     ebx, 15
        imul    ebx, dword [rel s_z]
        add     ebx, eax
        sar     ebx, 15
        mov     [rel %5], ebx
        mov     eax, [rel s_x]
        imul    dword [rel c_z]
        mov     ebx, [rel c_x]
        imul    ebx, dword [rel s_y]
        sar     ebx, 15
        imul    ebx, dword [rel s_z]
        sub     ebx, eax
        sar     ebx, 15
        mov     [rel %6], ebx
        mov     eax, [rel s_y]
        neg     eax
        mov     [rel %7], eax
        mov     eax, [rel s_x]
        imul    dword [rel c_y]
        sar     eax, 15
        mov     [rel %8], eax
        mov     eax, [rel c_x]
        imul    dword [rel c_y]
        sar     eax, 15
        mov     [rel %9], eax
%endmacro

; ================================================================ prep_rot1 ----
prep_rot1:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        sub     rsp, 0x20
        lea     rsi, [rel sinus]
        lea     rdi, [rel sinus+512]
        movsx   ebx, word [rel r_x]
        and     ebx, 0x3ff
        movsx   eax, word [rsi+rbx*2]
        mov     [rel s_x], eax
        movsx   eax, word [rdi+rbx*2]
        mov     [rel c_x], eax
        movsx   ebx, word [rel r_y]
        and     ebx, 0x3ff
        movsx   eax, word [rsi+rbx*2]
        mov     [rel s_y], eax
        movsx   eax, word [rdi+rbx*2]
        mov     [rel c_y], eax
        movsx   ebx, word [rel r_z]
        and     ebx, 0x3ff
        movsx   eax, word [rsi+rbx*2]
        mov     [rel s_z], eax
        movsx   eax, word [rdi+rbx*2]
        mov     [rel c_z], eax
        emit_matrix ob1, ob2, ob3, ob4, ob5, ob6, ob7, ob8, ob9
        add     rsp, 0x20
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ================================================================ prep_rot2 ----
prep_rot2:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        sub     rsp, 0x20
        lea     rsi, [rel sinus]
        lea     rdi, [rel sinus+512]
        movsx   ebx, word [rel cm_x]
        and     ebx, 0x3ff
        movsx   eax, word [rsi+rbx*2]
        mov     [rel s_x], eax
        movsx   eax, word [rdi+rbx*2]
        mov     [rel c_x], eax
        movsx   ebx, word [rel cm_y]
        and     ebx, 0x3ff
        movsx   eax, word [rsi+rbx*2]
        mov     [rel s_y], eax
        movsx   eax, word [rdi+rbx*2]
        mov     [rel c_y], eax
        movsx   ebx, word [rel cm_z]
        and     ebx, 0x3ff
        movsx   eax, word [rsi+rbx*2]
        mov     [rel s_z], eax
        movsx   eax, word [rdi+rbx*2]
        mov     [rel c_z], eax
        emit_matrix ca1, ca2, ca3, ca4, ca5, ca6, ca7, ca8, ca9
        add     rsp, 0x20
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ======================================================= p4_rotate_normals ----
; Rotates n_vert (module) into n_rot through the ob matrix rebuilt from the
; (already negated) r_* angles, exactly like the engine's rotate_normals.
p4_rotate_normals:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        sub     rsp, 0x20
        lea     rsi, [rel sinus]
        lea     rdi, [rel sinus+512]
        movsx   ebx, word [rel r_x]
        and     ebx, 0x3ff
        movsx   eax, word [rsi+rbx*2]
        mov     [rel s_x], eax
        movsx   eax, word [rdi+rbx*2]
        mov     [rel c_x], eax
        movsx   ebx, word [rel r_y]
        and     ebx, 0x3ff
        movsx   eax, word [rsi+rbx*2]
        mov     [rel s_y], eax
        movsx   eax, word [rdi+rbx*2]
        mov     [rel c_y], eax
        movsx   ebx, word [rel r_z]
        and     ebx, 0x3ff
        movsx   eax, word [rsi+rbx*2]
        mov     [rel s_z], eax
        movsx   eax, word [rdi+rbx*2]
        mov     [rel c_z], eax
        emit_matrix ob1, ob2, ob3, ob4, ob5, ob6, ob7, ob8, ob9

        P4AR n_vert2_a, rsi
        P4AR n_rot_a, rdi
        mov     ecx, n_src3
.rz:
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
        mov     [rdi], bp
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
        mov     [rdi+2], bp
        add     rsi, 6
        add     rdi, 4
        dec     ecx
        jnz     .rz
        add     rsp, 0x20
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; =================================================================== rotate ----
rotate:
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

        P4AR check_a, rdi
        xor     ax, ax
        mov     rcx, p_len
.ro_zero:
        mov     word [rdi], ax
        add     rdi, 2
        dec     rcx
        jnz     .ro_zero

        mov     dword [rel ile], 0
        P4AR con_a, r15
        P4AR shape_a2, r14
        P4AR rcalc_a, r13
        P4AR check_a, r12

        P4AR pts_tab_a, rsi
        mov     edi, [rel draw_tab_a]
        add     rdi, qword [rel Code32_addr]
        xor     ebx, ebx
        mov     ecx, f_len
.ro:
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
        ; p = ca * t + o
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

        mov     eax, [rel p_x]
        cmp     eax, x1_min
        jl      .no_face
        cmp     eax, x1_max
        jg      .no_face
        mov     eax, [rel p_y]
        cmp     eax, y1_min
        jl      .no_face
        cmp     eax, y1_max
        jg      .no_face
        mov     eax, [rel p_z]
        cmp     eax, z1_min
        jl      .no_face
        cmp     eax, z1_max
        jg      .no_face

        add     bp, 12000
        mov     word [rdi], bp
        mov     word [rdi+2], bx
        add     rdi, 4
        inc     dword [rel ile]


        push    rsi
        push    rdi
        push    rbx
        push    rcx
        mov     ecx, 3
.lo:
        movzx   esi, word [r15+rbx]
        cmp     word [r12+rsi*2], 0
        jne     .skip
        inc     word [r12+rsi*2]
        lea     rdi, [r13 + rsi*2]
        lea     rsi, [rsi*2 + rsi]
        add     rsi, r14
        movsx   eax, word [rsi]

        imul    dword [rel ob1]
        sar     eax, 15
        mov     ebp, eax
        movsx   eax, word [rsi + 2]
        imul    dword [rel ob2]
        sar     eax, 15
        add     ebp, eax
        movsx   eax, word [rsi + 4]
        imul    dword [rel ob3]
        sar     eax, 15
        add     ebp, eax
        mov     [rel t_x], ebp
        movsx   eax, word [rsi]
        imul    dword [rel ob4]
        sar     eax, 15
        mov     ebp, eax
        movsx   eax, word [rsi + 2]
        imul    dword [rel ob5]
        sar     eax, 15
        add     ebp, eax
        movsx   eax, word [rsi + 4]
        imul    dword [rel ob6]
        sar     eax, 15
        add     ebp, eax
        mov     [rel t_y], ebp
        movsx   eax, word [rsi]
        imul    dword [rel ob7]
        sar     eax, 15
        mov     ebp, eax
        movsx   eax, word [rsi + 2]
        imul    dword [rel ob8]
        sar     eax, 15
        add     ebp, eax
        movsx   eax, word [rsi + 4]
        imul    dword [rel ob9]
        sar     eax, 15
        add     ebp, eax
        mov     [rel t_z], ebp
        ; p = ca * t + o
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
        mov     [rdi], ax
        mov     eax, zoom
        imul    dword [rel p_y]
        idiv    ebp
        add     ax, 100
        mov     [rdi+2], ax
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
        add     ebx, 6
        dec     ecx
        jnz     .ro

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

; ================================================================ bit_sort ----
bit_sort:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        sub     rsp, 0x20
        cmp     dword [rel ile], 0
        je      .ret
        mov     eax, [rel faces]
        mov     [rel faces_saved], eax
        mov     eax, [rel ile]
        mov     [rel faces], eax
        call    sort
        mov     eax, [rel faces_saved]
        mov     [rel faces], eax
.ret:
        add     rsp, 0x20
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ==================================================================== show ----
show:
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

        cmp     dword [rel ile], 0
        je      .ret

        ; screen base (scr_sel) -> esq
        lea     rbx, [rel sel_base_table]
        movzx   eax, word [rel scr_sel]
        and     eax, 0x1ff
        mov     rdi, [rbx + rax*8]
        mov     [rel esq], rdi



        ; module table bases
        P4AR con_a, r12
        P4AR rcalc_a, r13
        P4AR n_rot_a, r14
        lea     r15, [rel pos]
        lea     r11, [rel con2]
        P4AR pkt_a, r10

        ; rsi = end of draw_tab (arena, painter order)
        mov     eax, [rel ile]
        mov     esi, [rel draw_tab_a]
        add     rsi, qword [rel Code32_addr]
        lea     rsi, [rsi + rax*4 - 4]
.lop:
        push    rsi
        ; caller-saved bases (face() clobbers them) - re-establish each iter
        lea     r9, [rel sel_base_table]
        lea     r11, [rel con2]
        P4AR pkt_a, r10
        movzx   edi, word [rsi+2]        ; face byte offset

        mov     eax, edi
        mov     ebx, 6
        xor     edx, edx
        div     ebx
        shl     eax, 3                   ; face*8
        mov     r8, rax                  ; keep index (P4AR clobbers eax)
        P4AR con3_a, rbx
        ; selector handle -> texture base
        mov     ecx, [rbx + r8]
        movzx   rdx, cx
        and     rdx, 0x1ff
        lea     r9, [rel sel_base_table]
        mov     rdx, [r9 + rdx*8]
        mov     [rel mapQ], rdx
        ; color (word = {flag, color}), visibility, phong
        movzx   edx, word [rbx + rax + 4]
        mov     [rel col], dx
        movzx   ecx, byte [rbx + rax + 6]
        mov     [rel vis_flag], cl
        movzx   ecx, byte [rbx + rax + 7]
        mov     [rel phong_flag], cl
        ; mode select
        test    dh, dh
        jnz     .plane
        cmp     byte [rel phong_flag], 0
        jne     .phong
        jmp     .nshading

.plane:
        movzx   ebx, word [r12+rdi]
        movsx   eax, word [r13+rbx*2]
        mov     [rel x_1], eax
        movsx   eax, word [r13+rbx*2+2]
        mov     [rel y_1], eax
        sub     ebx, 222*2
        mov     eax, dword [r10+rbx*2]
        mov     [rel p_1], eax
        movzx   ebx, word [r12+rdi+2]
        movsx   eax, word [r13+rbx*2]
        mov     [rel x_2], eax
        movsx   eax, word [r13+rbx*2+2]
        mov     [rel y_2], eax
        sub     ebx, 222*2
        mov     eax, dword [r10+rbx*2]
        mov     [rel p_2], eax
        movzx   ebx, word [r12+rdi+4]
        movsx   eax, word [r13+rbx*2]
        mov     [rel x_3], eax
        movsx   eax, word [r13+rbx*2+2]
        mov     [rel y_3], eax
        sub     ebx, 222*2
        mov     eax, dword [r10+rbx*2]
        mov     [rel p_3], eax
        jmp     .drawing

.phong:
        movzx   ebx, word [r12+rdi]
        movsx   eax, word [r13+rbx*2]
        mov     [rel x_1], eax
        movsx   eax, word [r13+rbx*2+2]
        mov     [rel y_1], eax
        sub     ebx, (222+81+8)*2
        mov     ax, word [r14+rbx*2]
        add     ax, 128
        shl     ax, 8
        mov     [rel p_1], ax
        mov     ax, word [r14+rbx*2+2]
        add     ax, 108
        shl     ax, 8
        mov     [rel p_1+2], ax
        movzx   ebx, word [r12+rdi+2]
        movsx   eax, word [r13+rbx*2]
        mov     [rel x_2], eax
        movsx   eax, word [r13+rbx*2+2]
        mov     [rel y_2], eax
        sub     ebx, (222+81+8)*2
        mov     ax, word [r14+rbx*2]
        add     ax, 128
        shl     ax, 8
        mov     [rel p_2], ax
        mov     ax, word [r14+rbx*2+2]
        add     ax, 108
        shl     ax, 8
        mov     [rel p_2+2], ax
        movzx   ebx, word [r12+rdi+4]
        movsx   eax, word [r13+rbx*2]
        mov     [rel x_3], eax
        movsx   eax, word [r13+rbx*2+2]
        mov     [rel y_3], eax
        sub     ebx, (222+81+8)*2
        mov     ax, word [r14+rbx*2]
        add     ax, 128
        shl     ax, 8
        mov     [rel p_3], ax
        mov     ax, word [r14+rbx*2+2]
        add     ax, 108
        shl     ax, 8
        mov     [rel p_3+2], ax
        jmp     .drawing

.nshading:
        movzx   ebx, word [r12+rdi]
        movsx   eax, word [r13+rbx*2]
        mov     [rel x_1], eax
        movsx   eax, word [r13+rbx*2+2]
        mov     [rel y_1], eax
        movzx   ebx, word [r11+rdi]
        mov     eax, dword [r15+rbx*2]
        mov     [rel p_1], eax
        movzx   ebx, word [r12+rdi+2]
        movsx   eax, word [r13+rbx*2]
        mov     [rel x_2], eax
        movsx   eax, word [r13+rbx*2+2]
        mov     [rel y_2], eax
        movzx   ebx, word [r11+rdi+2]
        mov     eax, dword [r15+rbx*2]
        mov     [rel p_2], eax
        movzx   ebx, word [r12+rdi+4]
        movsx   eax, word [r13+rbx*2]
        mov     [rel x_3], eax
        movsx   eax, word [r13+rbx*2+2]
        mov     [rel y_3], eax
        movzx   ebx, word [r11+rdi+4]
        mov     eax, dword [r15+rbx*2]
        mov     [rel p_3], eax

.drawing:
        cmp     byte [rel vis_flag], 0
        jz      .draw
        ; backface cull
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
        call    face
.hide:
        pop     rsi
        sub     rsi, 4
        dec     dword [rel ile]
        jnz     .lop
.ret:
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

; ==================================================================== face ----
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
        sub     rsp, 0x28

        mov     r12, [rel mapQ]     ; texture base
        mov     r13, [rel esq]      ; screen base
        mov     word [rel pom], 0

        ; ---- Y sort (swap v1/v2, v1/v3, v2/v3) ----
        mov     eax, [rel y_1]
        mov     ebx, [rel y_2]
        cmp     eax, ebx
        jle     .pr1
        mov     [rel y_1], ebx
        mov     [rel y_2], eax
        mov     eax, [rel x_1]
        mov     ebx, [rel x_2]
        mov     [rel x_1], ebx
        mov     [rel x_2], eax
        mov     eax, dword [rel p_1]
        mov     ebx, dword [rel p_2]
        mov     dword [rel p_1], ebx
        mov     dword [rel p_2], eax
.pr1:
        mov     eax, [rel y_1]
        mov     ebx, [rel y_3]
        cmp     eax, ebx
        jle     .pr2
        mov     [rel y_1], ebx
        mov     [rel y_3], eax
        mov     eax, [rel x_1]
        mov     ebx, [rel x_3]
        mov     [rel x_1], ebx
        mov     [rel x_3], eax
        mov     eax, dword [rel p_1]
        mov     ebx, dword [rel p_3]
        mov     dword [rel p_1], ebx
        mov     dword [rel p_3], eax
.pr2:
        mov     eax, [rel y_2]
        mov     ebx, [rel y_3]
        cmp     eax, ebx
        jle     .pr3
        mov     [rel y_2], ebx
        mov     [rel y_3], eax
        mov     eax, [rel x_2]
        mov     ebx, [rel x_3]
        mov     [rel x_2], ebx
        mov     [rel x_3], eax
        mov     eax, dword [rel p_2]
        mov     ebx, dword [rel p_3]
        mov     dword [rel p_2], ebx
        mov     dword [rel p_3], eax
.pr3:
        cmp     word [rel y_1], y2_max-1
        jge     .sk
        cmp     word [rel y_3], y2_min
        jl      .sk
        mov     eax, [rel y_2]
        sub     eax, [rel y_1]
        jne     .pr4
        inc     eax
        mov     word [rel pom], 1
.pr4:
        mov     [rel dy_1], eax
        mov     eax, [rel y_3]
        sub     eax, [rel y_2]
        jne     .pr5
        inc     eax
.pr5:
        mov     [rel dy_2], eax
        mov     eax, [rel y_3]
        sub     eax, [rel y_1]
        jne     .pr6
        inc     eax
.pr6:
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
        mov     [rel mem], eax
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
        add     ax, word [rel p_1]
        mov     [rel mem], ax
        mov     eax, [rel dy_1]
        imul    dword [rel pd_2]
        add     ax, word [rel p_1+2]
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
        mov     ax, word [rel p_1]
        xchg    ax, word [rel p_1+2]
        mov     word [rel p_1], ax
        cmp     dword [rel y_3], y2_max-1
        jl      .no_da
        sub     dword [rel y_3], y2_max-1
        mov     eax, [rel y_3]
        mov     ebx, [rel dy_3]
        sub     ebx, eax
        mov     [rel dy_3], ebx
.no_da:
        xor     ebx, ebx
        mov     bx, word [rel x_2]
        sub     bx, word [rel pom]
        jnz     .okay
        inc     bx
.okay:
        jg      .norm
        neg     ebx
        call    p4_slope
        jmp     .draw_1
.norm:
        call    p4_slope
        jmp     .draw_2

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
        movzx   edi, word [rel x_1+2]
        movzx   ebp, word [rel x_s+2]
        cmp     edi, x2_max
        jge     .go_1
        cmp     ebp, x2_min
        jl      .go_1
        mov     edx, dword [rel p_1]
        cmp     ebp, x2_max-1
        jl      .no_c3
.add_2:
        add     edx, esi
        dec     ebp
        cmp     ebp, x2_max-1
        jg      .add_2
.no_c3:
        cmp     edi, x2_min
        jge     .no_c4
        mov     edi, x2_min
.no_c4:
        sub     ebp, edi
        jl      .go_1
        add     edi, ebp
        add     edi, [rel y_1]
        inc     ebp
.fo_1:
        mov     bl, dh
        shld    ebx, edx, 8
        movzx   ebx, bx
        movzx   eax, byte [r12+rbx]
        add     al, cl
        mov     byte [r13+rdi], al
        dec     edi
        add     edx, esi
        dec     ebp
        jnz     .fo_1
.go_1:
        mov     eax, [rel dx_1]
        add     [rel x_1], eax
        mov     eax, [rel dx_2]
        add     [rel x_s], eax
        mov     ax, word [rel pd_2]
        add     word [rel p_1], ax
        mov     ax, word [rel pd_1]
        add     word [rel p_1+2], ax
        add     dword [rel y_1], 320
        dec     dword [rel dy_3]
        jne     .draw_1
        jmp     .sk

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
        movzx   edi, word [rel x_s+2]
        movzx   ebp, word [rel x_1+2]
        cmp     edi, x2_max
        jge     .go_2
        cmp     ebp, x2_min
        jl      .go_2
        mov     edx, dword [rel p_1]
        cmp     edi, x2_min
        jge     .no_c1
.add_1:
        add     edx, esi
        inc     edi
        js      .add_1
.no_c1:
        cmp     ebp, x2_max-1
        jl      .no_c2
        mov     ebp, x2_max-1
.no_c2:
        sub     ebp, edi
        jl      .go_2
        add     edi, [rel y_1]
        inc     ebp
.fo_2:
        mov     bl, dh
        shld    ebx, edx, 8
        movzx   ebx, bx
        movzx   eax, byte [r12+rbx]
        add     al, cl
        mov     byte [r13+rdi], al
        inc     edi
        add     edx, esi
        dec     ebp
        jnz     .fo_2
.go_2:
        mov     eax, [rel dx_1]
        add     [rel x_1], eax
        mov     eax, [rel dx_2]
        add     [rel x_s], eax
        mov     ax, word [rel pd_2]
        add     word [rel p_1], ax
        mov     ax, word [rel pd_1]
        add     word [rel p_1+2], ax
        add     dword [rel y_1], 320
        dec     dword [rel dy_3]
        jne     .draw_2
.sk:
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

; p4_slope: esi = (p_2 - mem) deltas as 16.16; cx = col. ebx = span divisor.
p4_slope:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20
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
        add     rsp, 0x20
        pop     rbp
        ret

; ================================================================ show_logo ----
show_logo:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        sub     rsp, 0x20

        mov     eax, [rel sun_step]
        ; clamp sun_step into the logo frame range [0,14] (logo_a.dat has 15
        ; frames of 64*50 bytes); the original's sub-14 clamp overflows once
        ; sun_step grows, so we robustly wrap instead.
        test    eax, eax
        jns     .sp_pos
        xor     eax, eax
.sp_pos:
        xor     edx, edx
        mov     ecx, 15
        idiv    ecx
        mov     [rel sun_step], edx

        mov     eax, [rel sun_step]
        imul    eax, 64*50
        mov     esi, [rel logo]
        add     esi, eax
        add     rsi, qword [rel Code32_addr]
        mov     edi, [rel scr_addr]
        add     rdi, qword [rel Code32_addr]
        add     rdi, (4*320)+255
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

        add     rsp, 0x20
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret
