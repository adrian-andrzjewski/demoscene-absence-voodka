; p1.asm - NASM x64 port of CODE/P1/P1.ASM  (part 1: textured 3D head).
;
; Faithful port of P1: a 3D "head" (602 verts / 1156 faces, shape3/constr3),
; texture-mapped with _rm.inc (map) via tm_face, framed by two 2D cut polygons
; (cut_tab1 built from p_tab/p_tab2), with text logos overlaid, and a three
; step pixel fade (znika1/2/3) driven by the _wlk1..3 mask frames.
;
; Port notes:
;   - Pointer model: the ENGINE needs arena offsets in shape_addr/con_addr...
;     so part start copies the static word tables (shape, con) into arena
;     blocks and points the engine at those offsets.  cut_tab1, p_tab,
;     p_tab2, tablica, logo_tab stay in-module statics.
;   - selectors: map_sel/scr_sel handles (from vk_selector_alloc) go through
;     txtr's fs_sel/gs_sel dwords before tm_face (the original's
;     `mov fs,map_sel` / `mov gs,scr_sel`).
;   - screen = scr_addr (backbuffer = _scr_Addr).  "VGA 0xA0000" becomes the
;     presented framebuffer (framebuffer_off), handled by the Ekran macro.
;   - `logo_tab` first dword was `o logoN` (offset of a dword var); with parts
;     loaded at high VAs we substitute an index 0..3 into the logo_array[]
;     dwords (which hold the arena offsets of the bitmap files).  Blit
;     arithmetic is unchanged.
;   - `move`/`line` are unreferenced (dead) in the original and are omitted.
;
; Timeline (ModPos): entrance ~0x10, exit >0x400; interior thresholds 0x10/
; 0x20/0x30 (znika fade windows), 0x100 (I_nie_znika), 0x200 (tablica +
; logo selection), 0x300 (palette fade), 0x400 (virtual / end).
;
; ABI: prologue uses 8 pushed regs + sub 0x28 so RSP%16==0 at every
; NASM->C++ call (eos_dispatch, pal_set, vk_present_frame).

BITS 64
DEFAULT REL

%include "eos.inc"
%include "video.inc"
%include "pal.inc"
%include "vodka.inc"



extern _screen
extern _scr_Addr
extern _scrSel
extern ModPos
extern GetModPos
extern Code32_addr
extern eos_dispatch
extern white
extern len

; engine surfaces (engine.asm)
extern shape_addr
extern srot_addr
extern n_addr
extern nrot_addr
extern inc_addr
extern con_addr
extern sort_addr
extern points
extern faces
extern r_x, r_y, r_z
extern n_calc
extern rotate_shape
extern rotate_normals
extern sort
extern prep_sort

; texture mapper surfaces (txtr.asm)
extern tm_face
extern x_1, y_1, x_2, y_2, x_3, y_3
extern p_1, p_2, p_3
extern fs_sel, gs_sel

p_num   EQU 602
f_num   EQU 1156
zoom    EQU 400

; --------------------------------------------------------------------- .bss
section .bss align=16
global part1

scr_sel:    resw 1
map_sel:    resw 1
scr_addr:   resd 1

; arena offsets of the four bitmap files, indexed by logo_tab entry[0]
; (idx 0..3 = logo1..logo4); [4] holds the map for the fs selector
logo_array: resd 5

; in-arena working tables (allocated + zeroed at part start)
n_vert:     resd 1          ; 602*3 words (normals)
n_add:      resd 1          ; 602 words    (incidence)
rcalc:      resd 1          ; 602*3 words  (rotated shape)
n_rot:      resd 1          ; 602*2 words  (rotated normals)
plane:      resd 1          ; 602*2 words  (projected)
zet_tab:    resd 1          ; 1156 dwords  (draw order scratch)
shape_a:    resd 1          ; shape arena offset
con_a:      resd 1          ; con arena offset

l_addr:     resd 1          ; logo index 0..3 (from logo_tab entry)
l_add:      resd 1
l_x:        resd 1
l_y:        resd 1
l_sub:      resd 1

ramki:      resd 1

_Znik1:     resd 1
_Znik2:     resd 1
_Znik3:     resd 1
_ZnikL:     resb 1
_ZnikL2:    resb 1
_ZnikL3:    resb 1

sh_x:       resw 1
sh_y:       resw 1
zoomx:      resw 1
zoomy:      resw 1

; per-row left/right cut positions (200 rows * 2 words)
cut_tab1:   resw 400

; --------------------------------------------------------------------- .data
section .data align=16
; rm_eye palette (used at both pal and pal2 sites in the original)
pal:    incbin "rm_eye.pal"
pal2:   incbin "rm_eye.pal"

; static geometry tables (copied into arena at part start)
shape:
%include "p1_shape.inc"
con:
%include "p1_con.inc"

%include "p1_data.inc"

; ------------------------------------------------------------------- .text
section .text

; ------------------------------------------------------------------- part1
global part1
part1:
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

        mov     word [rel zoomx], zoom+30
        mov     word [rel zoomy], zoom
        mov     word [rel sh_x], 160
        mov     word [rel sh_y], 100

        ; logo blit init (original .data defaults: l_add/l_x/l_y/l_sub = 2)
        mov     dword [rel l_addr], 0        ; logo index 0 = logo1
        mov     dword [rel l_add], 2
        mov     dword [rel l_x], 2
        mov     dword [rel l_y], 2
        mov     dword [rel l_sub], 2

        ; ---- load archive files ------------------------------------------
        vodka   9, _Znik1
        vodka   10, _Znik2
        vodka   11, _Znik3

        vodka   4, logo_array          ; map (fs texture)
        vodka   5, logo_array+4        ; logo1
        vodka   6, logo_array+8        ; logo2
        vodka   7, logo_array+12       ; logo3
        vodka   8, logo_array+16       ; logo4

        ; ---- screen addr + selector ---------------------------------------
        mov     ax, [_scrSel]
        mov     [rel scr_sel], ax
        mov     eax, [_scr_Addr]
        mov     [rel scr_addr], eax
        mov     [_screen], eax

        ; selector for the backbuffer screen (gs for tm_face)
        mov     eax, EOS_ALLOCATE_SELECTOR
        lea     rsi, [rel scr_addr]
        mov     esi, [rsi]
        add     rsi, qword [rel Code32_addr]
        mov     edi, 320*200
        call    eos_dispatch
        mov     [rel scr_sel], ax
        mov     [_scrSel], ax

        ; selector for the texture map (256*200)
        mov     eax, EOS_ALLOCATE_SELECTOR
        mov     esi, [rel logo_array]
        add     rsi, qword [rel Code32_addr]
        mov     edi, 256*200
        call    eos_dispatch
        mov     [rel map_sel], ax

        ; ---- engine bring-up ----------------------------------------------
        mov     dword [rel len], 81
        call    p1_copy_tables          ; arena copies of shape/con + zeroed tables

        mov     eax, [rel shape_a]
        mov     [shape_addr], eax
        mov     eax, [rel con_a]
        mov     [con_addr], eax
        mov     eax, [rel rcalc]
        mov     [srot_addr], eax
        mov     eax, [rel n_vert]
        mov     [n_addr], eax
        mov     eax, [rel n_rot]
        mov     [nrot_addr], eax
        mov     eax, [rel n_add]
        mov     [inc_addr], eax
        mov     eax, [rel zet_tab]
        mov     [sort_addr], eax
        mov     dword [points], p_num
        mov     dword [faces], f_num
        call    prep_sort               ; engine radix scratch (drawers*16*4)

        ; prepare: double every con word (index -> byte-offset stepping)
        mov     eax, [rel con_a]
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        mov     rdi, rax
        mov     ecx, f_num*3
.prep_loop:
        lodsw
        add     ax, ax
        stosw
        loop    .prep_loop

        call    n_calc
        call    calc_cut
        call    clear

        ; set palette = rm_eye pal
        lea     rsi, [rel pal]
        call    pal_set

        mov     byte [rel _ZnikL], 0
        mov     byte [rel _ZnikL2], 0
        mov     byte [rel _ZnikL3], 0

.main_loop:
        call    copy

        call    GetModPos
        cmp     word [rel ModPos], 0x0400
        jg      .virtual
        cmp     word [rel ModPos], 0x0100
        jge     .i_nie_znika
        cmp     word [rel ModPos], 0x0010
        jle     .nie_drawujemy
        cmp     word [rel ModPos], 0x0030
        jg      .znika3
        cmp     word [rel ModPos], 0x0020
        jg      .znika2
        jmp     .znika1                 ; 0x10 < ModPos <= 0x20
.i_nie_znika:
        ; present backbuffer -> framebuffer (the old rep movsw to 0xA0000)
        Ekran

        cmp     word [rel ModPos], 0x0300
        jl      .yogi
        mov     ax, [rel ModPos]
        and     ax, 63
        mov     bl, al
        lea     rdi, [rel white]
        call    pal_fadein10
        lea     rsi, [rel pal]
        call    pal_set
.yogi:

.nie_drawujemy:
        call    clear

        call    rotate_shape
        neg     word [r_x]
        neg     word [r_y]
        neg     word [r_z]
        call    rotate_normals
        neg     word [r_x]
        neg     word [r_y]
        neg     word [r_z]
        call    bit_sort

        cmp     word [rel ModPos], 0x0200
        jl      .akio
        movzx   ebx, word [rel ModPos]
        and     bx, 31                  ; 0..31 table index
        lea     rsi, [rel tablica]
        movzx   eax, word [rsi + rbx*4]
        mov     [rel sh_x], ax
        movzx   eax, word [rsi + rbx*4 + 2]
        mov     [rel sh_y], ax
.akio:
        call    p_calc

        ; wait_vbl -> eax = frame counter
        mov     eax, EOS_WAIT_VBL
        call    eos_dispatch
        mov     [rel ramki], eax

        mov     eax, [rel ramki]
        shl     ax, 1
        add     word [r_z], ax
        add     word [r_y], ax
        shl     ax, 1
        add     word [r_x], ax

        call    GetModPos
        call    show

        cmp     word [rel ModPos], 0x0200
        jl      .zenek
        movzx   eax, word [rel ModPos]
        and     ax, 0x00ff
        shl     ax, 4
        movzx   rcx, ax
        lea     rsi, [rel logo_tab]
        add     rsi, rcx
        movzx   ebx, word [rel ModPos]
        and     bx, 0xff00
        sub     bh, 2
        shl     bx, 2
        movzx   rcx, bx
        add     rsi, rcx
        mov     eax, [rsi]
        mov     [rel l_addr], eax
        mov     eax, [rsi+4]
        mov     [rel l_add], eax
        mov     eax, [rsi+8]
        mov     [rel l_x], eax
        mov     ebx, 320
        sub     ebx, eax
        mov     [rel l_sub], ebx
        mov     eax, [rsi+12]
        mov     [rel l_y], eax
.zenek:
        jmp     .main_loop

.virtual:
        lea     rsi, [rel white]
        call    pal_set

        mov     eax, EOS_DEALLOCATE_SELECTOR
        movzx   ebx, word [rel map_sel]
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

; -------------------------------------------------------------- znika1 ----
.znika1:
        mov     esi, [rel scr_addr]
        add     rsi, qword [rel Code32_addr]
        mov     rbp, rsi
        mov     eax, [rel _Znik1]
        add     rax, qword [rel Code32_addr]
        mov     r12, rax
        mov     ecx, 64000
.znika:
        mov     al, [rbp]
        cmp     al, 80
        jb      .zero
        cmp     al, 80+80-1
        ja      .zero
        mov     al, [r12]
        movzx   edx, byte [rel _ZnikL]
        cmp     al, dl
        ja      .zero
        jmp     .ous
.zero:
        mov     byte [rbp], 0
.ous:
        inc     rbp
        inc     r12
        dec     ecx
        jnz     .znika

        mov     eax, [rel ramki]
        cmp     eax, 4
        jge     .q1q1
        mov     eax, 1
        jmp     .qqq1
.q1q1:
        shr     eax, 2
.qqq1:
        movzx   edx, byte [rel _ZnikL]
        cmp     dl, 63
        jbe     .endfck
        mov     byte [rel _ZnikL], 63
        jmp     .fuc1
.endfck:
        add     [rel _ZnikL], al
.fuc1:
        jmp     .i_nie_znika

; -------------------------------------------------------------- znika2 ----
.znika2:
        mov     esi, [rel scr_addr]
        add     rsi, qword [rel Code32_addr]
        mov     rbp, rsi
        mov     eax, [rel _Znik2]
        add     rax, qword [rel Code32_addr]
        mov     r12, rax
        mov     ecx, 64000
.znikaa:
        mov     al, [rbp]
        cmp     al, 80+80-1
        ja      .zeroa
        cmp     al, 80
        jae     .ousa
        mov     al, [r12]
        movzx   edx, byte [rel _ZnikL2]
        cmp     al, dl
        jb      .ousa
.zeroa:
        mov     byte [rbp], 0
.ousa:
        inc     rbp
        inc     r12
        dec     ecx
        jnz     .znikaa

        mov     eax, [rel ramki]
        cmp     eax, 4
        jge     .q1q2
        mov     eax, 1
        jmp     .qqq2
.q1q2:
        shr     eax, 2
.qqq2:
        movzx   edx, byte [rel _ZnikL2]
        cmp     dl, 63
        jb      .endfcka
        mov     byte [rel _ZnikL2], 63
        jmp     .fuc1a
.endfcka:
        add     [rel _ZnikL2], al
.fuc1a:
        jmp     .i_nie_znika

; -------------------------------------------------------------- znika3 ----
.znika3:
        mov     esi, [rel scr_addr]
        add     rsi, qword [rel Code32_addr]
        mov     rbp, rsi
        mov     eax, [rel _Znik3]
        add     rax, qword [rel Code32_addr]
        mov     r12, rax
        mov     ecx, 64000
.znikaq:
        mov     al, [rbp]
        cmp     al, 80+80
        jb      .ous3
        mov     al, [r12]
        movzx   edx, byte [rel _ZnikL3]
        cmp     al, dl
        jb      .ous3
.zero3:
        mov     byte [rbp], 0
.ous3:
        inc     rbp
        inc     r12
        dec     ecx
        jnz     .znikaq

        mov     eax, [rel ramki]
        cmp     eax, 4
        jge     .q1q3
        mov     eax, 1
        jmp     .qqq3
.q1q3:
        shr     eax, 2
.qqq3:
        movzx   edx, byte [rel _ZnikL3]
        cmp     dl, 63
        jb      .endfck3
        mov     byte [rel _ZnikL3], 63
        jmp     .fuc13
.endfck3:
        add     [rel _ZnikL3], al
.fuc13:
        jmp     .i_nie_znika

; -------------------------------------------------------- p1_copy_tables ----
; Allocate + copy the static shape/con tables into the arena; allocate the
; zeroed working tables (n_vert, n_add, rcalc, n_rot, plane, zet_tab).
p1_copy_tables:
        push    rbp
        mov     rbp, rsp
        push    rsi
        push    rdi
        push    rcx
        push    rbx
        ; entry RSP%16==8; push rbp -> 0; 4 more pushes -> stays 0; sub 0x20 keeps 0
        sub     rsp, 0x20

        ; shape: 602*3 words = 3612
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, p_num*3*2
        call    eos_dispatch
        mov     [rel shape_a], edx
        mov     rdi, rdx
        add     rdi, qword [rel Code32_addr]
        lea     rsi, [rel shape]
        mov     ecx, (p_num*3*2)>>2
        rep movsd

        ; con: 1156*3 words = 6936
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, f_num*3*2
        call    eos_dispatch
        mov     [rel con_a], edx
        mov     rdi, rdx
        add     rdi, qword [rel Code32_addr]
        lea     rsi, [rel con]
        mov     ecx, (f_num*3*2)>>2
        rep movsd

        ; zeroed working tables (EOS_ALLOCATE_MEMORY zero-fills)
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, p_num*3*2
        call    eos_dispatch
        mov     [rel n_vert], edx
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, p_num*2
        call    eos_dispatch
        mov     [rel n_add], edx
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, p_num*3*2
        call    eos_dispatch
        mov     [rel rcalc], edx
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, p_num*4
        call    eos_dispatch
        mov     [rel n_rot], edx
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, p_num*4
        call    eos_dispatch
        mov     [rel plane], edx
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, f_num*4
        call    eos_dispatch
        mov     [rel zet_tab], edx

        add     rsp, 0x20
        pop     rbx
        pop     rcx
        pop     rdi
        pop     rsi
        pop     rbp
        ret

; ------------------------------------------------------------------- copy --
copy:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        sub     rsp, 0x20

        ; frame arms from cut_tab1: left band add 80, right band add 160
        lea     rsi, [rel cut_tab1]
        mov     edi, [rel scr_addr]
        add     rdi, qword [rel Code32_addr]
        mov     ecx, 200
.lo1:
        mov     bx, [rsi]
        mov     r12d, ebx
        mov     bp, bx
        inc     bp
.lo2:
        xor     edx, edx
        mov     dx, bx
        add     byte [rdi+rdx], 80
        dec     bx
        dec     bp
        jnz     .lo2
        mov     ebx, r12d
        xor     edx, edx
        mov     dx, bx
        mov     byte [rdi+rdx], 80+52
        mov     byte [rdi+rdx+1], 80+52

        mov     bx, [rsi+2]
        mov     r12d, ebx
        mov     bp, 320
        sub     bp, bx
.lo3:
        xor     edx, edx
        mov     dx, bx
        add     byte [rdi+rdx], 160
        inc     bx
        dec     bp
        jnz     .lo3
        mov     ebx, r12d
        xor     edx, edx
        mov     dx, bx
        mov     byte [rdi+rdx], 160+52
        mov     byte [rdi+rdx+1], 160+52

        add     rsi, 4
        add     rdi, 320
        loop    .lo1

        ; logo blit
        mov     esi, [rel l_addr]       ; logo index 0..3
        lea     rcx, [rel logo_array+4] ; logo1..4 slots
        mov     esi, [rcx + rsi*4]      ; arena offset of the logo bitmap
        add     rsi, qword [rel Code32_addr]
        mov     edi, [rel scr_addr]
        add     rdi, qword [rel Code32_addr]
        mov     edx, [rel l_add]
        add     rdi, rdx
        mov     ecx, [rel l_y]
.co1:
        mov     ebp, [rel l_x]
.co2:
        lodsb
        or      al, al
        jz      .empty
        add     al, 240
        mov     [rdi], al
.empty:
        inc     rdi
        dec     ebp
        jnz     .co2
        mov     edx, [rel l_sub]
        add     rdi, rdx
        loop    .co1

        add     rsp, 0x20
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ---------------------------------------------------------------- clear ----
clear:
        push    rbp
        mov     rbp, rsp
        push    rdi
        push    rcx
        sub     rsp, 0x20
        mov     edi, [rel scr_addr]
        add     rdi, qword [rel Code32_addr]
        mov     eax, 0x01010101
        mov     ecx, 16000
        rep stosd
        add     rsp, 0x20
        pop     rcx
        pop     rdi
        pop     rbp
        ret

; --------------------------------------------------------------- bit_sort ----
; Per face: sum the 3 vertices' z from rcalc (via the prepared con offset),
; add 16000, store into zet_tab.  The high word accumulates 6 per face so
; show() can recover the face byte-offset into con as word [zet+2].
bit_sort:
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

        mov     eax, [rel con_a]
        add     rax, qword [rel Code32_addr]
        mov     r12, rax                ; con ptr (prepared = 2*vertex)
        mov     eax, [rel rcalc]
        add     rax, qword [rel Code32_addr]
        mov     r13, rax                ; rcalc ptr (6 bytes/vertex)
        mov     eax, [rel zet_tab]
        add     rax, qword [rel Code32_addr]
        mov     rdi, rax                ; zet_tab ptr (stosd target)

        xor     eax, eax
        mov     ecx, [faces]
        xor     esi, esi                ; con face byte offset (0,6,12,..)
.make_tab:
        ; z of three vertices: byte offset into rcalc = 3*con + 4
        movzx   ebx, word [r12 + rsi]
        lea     ebx, [rbx*2 + rbx + 4]
        mov     ax, [r13 + rbx]
        movzx   ebx, word [r12 + rsi + 2]
        lea     ebx, [rbx*2 + rbx + 4]
        add     ax, [r13 + rbx]
        movzx   ebx, word [r12 + rsi + 4]
        lea     ebx, [rbx*2 + rbx + 4]
        add     ax, [r13 + rbx]
        add     ax, 16000
        stosd                           ; low = zsum+16000; high = 6*face
        add     rsi, 6
        add     eax, 0x60000
        dec     ecx
        jnz     .make_tab

        call    sort                    ; ascending radix; draw order in high w

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

; ---------------------------------------------------------------- p_calc ----
p_calc:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        sub     rsp, 0x20
        mov     eax, [rel rcalc]
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        mov     eax, [rel plane]
        add     rax, qword [rel Code32_addr]
        mov     rdi, rax
        mov     ecx, [points]
.p_lop:
        movsx   ebx, word [rsi+4]        ; z
        sub     bx, 3600
        mov     ax, [rel zoomx]
        imul    word [rsi]               ; dx:ax = zoomx * x
        idiv    bx
        add     ax, [rel sh_x]
        stosw
        mov     ax, [rel zoomy]
        imul    word [rsi+2]             ; dx:ax = zoomy * y
        idiv    bx
        add     ax, [rel sh_y]
        stosw
        add     rsi, 6
        loop    .p_lop
        add     rsp, 0x20
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ------------------------------------------------------------------ show ----
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

        ; selectors for tm_face (handles are 16-bit)
        movzx   eax, word [rel map_sel]
        mov     [fs_sel], eax
        movzx   eax, word [rel scr_sel]
        mov     [gs_sel], eax

        mov     eax, [rel zet_tab]
        add     rax, qword [rel Code32_addr]
        mov     r12, rax                ; zet_tab
        mov     eax, [rel con_a]
        add     rax, qword [rel Code32_addr]
        mov     r13, rax                ; con
        mov     eax, [rel plane]
        add     rax, qword [rel Code32_addr]
        mov     r14, rax                ; plane (4 bytes/vertex)
        mov     eax, [rel n_rot]
        add     rax, qword [rel Code32_addr]
        mov     r15, rax                ; n_rot (4 bytes/vertex)

        mov     ecx, [faces]
.lop:
        movzx   edi, word [r12+2]       ; high word = 6*face -> con byte offset

        movzx   ebx, word [r13 + rdi]           ; con[6f] = 2*v
        movsx   eax, word [r14 + rbx*2]         ; plane[4v] = x
        mov     [x_1], eax
        movsx   eax, word [r14 + rbx*2 + 2]
        mov     [y_1], eax
        mov     ax, [r15 + rbx*2]
        add     ax, 128
        shl     ax, 8
        mov     [p_1], ax
        mov     ax, [r15 + rbx*2 + 2]
        add     ax, 108
        shl     ax, 8
        mov     [p_1+2], ax

        movzx   ebx, word [r13 + rdi + 2]
        movsx   eax, word [r14 + rbx*2]
        mov     [x_2], eax
        movsx   eax, word [r14 + rbx*2 + 2]
        mov     [y_2], eax
        mov     ax, [r15 + rbx*2]
        add     ax, 128
        shl     ax, 8
        mov     [p_2], ax
        mov     ax, [r15 + rbx*2 + 2]
        add     ax, 108
        shl     ax, 8
        mov     [p_2+2], ax

        movzx   ebx, word [r13 + rdi + 4]
        movsx   eax, word [r14 + rbx*2]
        mov     [x_3], eax
        movsx   eax, word [r14 + rbx*2 + 2]
        mov     [y_3], eax
        mov     ax, [r15 + rbx*2]
        add     ax, 128
        shl     ax, 8
        mov     [p_3], ax
        mov     ax, [r15 + rbx*2 + 2]
        add     ax, 108
        shl     ax, 8
        mov     [p_3+2], ax

        ; backface cull: sign of (y3-y2)*(x1-x2) - (y2-y1)*(x2-x3)
        push    rcx
        mov     ax, [x_1]
        sub     ax, [x_2]
        mov     bx, [y_3]
        sub     bx, [y_2]
        imul    bx, ax
        mov     ax, [x_2]
        sub     ax, [x_3]
        mov     cx, [y_2]
        sub     cx, [y_1]
        imul    cx, ax
        sub     bx, cx
        jge     .hide

        call    tm_face

.hide:
        pop     rcx
        add     r12, 4
        dec     ecx
        jnz     .lop

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

; -------------------------------------------------------------- calc_cut ----
; build cut_tab1: for both polygons (p_tab/p_tab2) interpolate the edge x
; per row into cut_tab1[row*2] (left) and cut_tab1[row*2+1] (right).
calc_cut:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        sub     rsp, 0x20

        lea     rsi, [rel p_tab+4]
        mov     ecx, [rsi-4]            ; segment count (5-1)
.cut1:
        push    rcx
        mov     bx, [rsi]               ; x0
        movzx   r12d, word [rsi+2]      ; y0
        mov     ax, [rsi+4]             ; x1
        mov     cx, [rsi+6]             ; y1
        lea     rdi, [rel cut_tab1]
        movzx   edx, r12w
        shl     edx, 2
        add     rdi, rdx                ; cut_tab1 + y0*4 bytes
        sub     ax, bx
        sub     cx, r12w
        shl     ax, 6
        shl     bx, 6
        cwd
        idiv    cx
.make:
        mov     dx, bx
        shr     dx, 6
        mov     [rdi], dx
        add     rdi, 4
        add     bx, ax
        loop    .make
        pop     rcx
        add     rsi, 4
        loop    .cut1

        lea     rsi, [rel p_tab2+4]
        mov     ecx, [rsi-4]            ; segment count (6-1)
.cut2:
        push    rcx
        mov     bx, [rsi]
        movzx   r12d, word [rsi+2]
        mov     ax, [rsi+4]
        mov     cx, [rsi+6]
        lea     rdi, [rel cut_tab1]
        movzx   edx, r12w
        shl     edx, 2
        add     rdi, rdx
        add     rdi, 2                  ; right column
        sub     ax, bx
        sub     cx, r12w
        shl     ax, 6
        shl     bx, 6
        cwd
        idiv    cx
.make2:
        mov     dx, bx
        shr     dx, 6
        mov     [rdi], dx
        add     rdi, 4
        add     bx, ax
        loop    .make2
        pop     rcx
        add     rsi, 4
        loop    .cut2

        add     rsp, 0x20
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret
