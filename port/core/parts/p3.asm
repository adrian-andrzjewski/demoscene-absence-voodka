; p3.asm - NASM x64 port of CODE/P3/P3.ASM  (part 3: twisted landscape + tunnel).
;
; Faithful port. P3 is a P1-style ENGINE part: same engine.asm reuse (shape/
; con/n_calc/rotate_shape/rotate_normals/bit_sort/sort + a textured-triangle
; show/face).  Two extras:
;   - tooneling : the background tunnel, sampling the shared _tableToonel u/v
;     table (built in boot) into the _yayo texture, scrolled by licznik+_mulek.
;   - copy      : vertical scroll of the rolling scr_tab screens into skrin,
;     modulated by sinus of `step`, scaled by p_x/p_y.
;   - sloneczko : the sun sprite.
;   - face      : DUAL-texture rasterizer - shades a face from BOTH `map`
;     (fs) and `lgmap` (es), summed per pixel.  Carries an extra coordinate
;     channel m_1..m_3 (Pos coords) alongside p_1..p_3 (n_rot coords).
;
; The original face patches instruction immediates (v1..v4 span steps and the
; a1/a2 screen-base).  W^X forbids that; ported as explicit globals
; f_pstep/f_estep + resolved register bases (identical arithmetic).
;
; face() keeps BOTH raster paths like the original: draw_1 (middle vertex left
; of the long edge, span right->left) and draw_2 (middle vertex right of the
; long edge, span left->right, virtual-scanned off-left edge).  A previous port
; only had draw_1 and routed the positive-span case into it, so `sub bp,di` was
; negative every row and roughly half of all faces never rendered (the hero
; "A" object looked full of holes).  Edge integer reads are signed 16-bit
; (movsx), matching `mov di/bp, w ..+2` - movzx dropped off-screen-left rows.
;
; Memory model (matches p1.asm): all engine-visible working tables (n_vert,
; n_add, rcalc, n_rot, plane, pos, zet_tab) are ARENA OFFSETS (dd); every
; routine adds Code32_addr before dereferencing.  shape/con statics are copied
; into the arena by p3_engine_set.
;
; Timeline (ModPos): P3 spans 0x0B40..0x0D3E (tunnel flashes near the end).
;
; ABI: 8-push prologue + sub 0x28 -> RSP%16==0 at call sites.

BITS 64
DEFAULT REL

%include "eos.inc"
%include "video.inc"
%include "pal.inc"
%include "vodka.inc"

extern _screen
extern _scr_Addr
extern ModPos
extern GetModPos
extern Code32_addr
extern eos_dispatch
extern white
extern sel_base_table
extern len

; engine surfaces (engine.asm) - same globals P1/P2 use
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
extern sinus

; shared tunnel coord table (boot.asm builds it, 128000 bytes)
extern _tableToonel

ile      EQU 32
step_1   EQU 3
step_2   EQU 24
p_num    EQU 341
f_num    EQU 646
zoom     EQU 216
x2_min   EQU 0
x2_max   EQU 320
y2_min   EQU 0
y2_max   EQU 200

; ------------------------------------------------------------ swap macro ----
; swap two vertices' (y, x, p, m) when sorting by Y.
%macro p3_yswap 8   ; y_a,y_b,x_a,x_b,p_a,p_b,m_a,m_b
        mov     eax, [%1]
        push    rax
        mov     eax, [%2]
        mov     [%1], eax
        pop     rax
        mov     [%2], eax
        mov     eax, [%3]
        push    rax
        mov     eax, [%4]
        mov     [%3], eax
        pop     rax
        mov     [%4], eax
        mov     edx, dword [%6]
        mov     eax, dword [%5]
        mov     dword [%5], edx
        mov     dword [%6], eax
        mov     edx, dword [%8]
        mov     eax, dword [%7]
        mov     dword [%7], edx
        mov     dword [%8], eax
%endmacro

section .data align=16
global part3

map_sel:   dw 0
lgmap_sel: dw 0

spal:      incbin "jup.pal"
tunel_pal: incbin "tn.pal"
mypal:     times 256*3 db 0

sh_x: dw 160
sh_y: dw 100
or_x: dw 0
or_y: dw 0
or_z: dw 0

; static geometry tables (copied to arena by p3_engine_set)
shape:
%include "log_s.inc"
con:
%include "log_c.inc"

flesze:
        times 32 dd 0,0
        dd 1,0                         ; 20h
        dd 1,0                         ; 21h
        dd 0,0
        dd 0,0
        dd 1,0                         ; 24h
        dd 0,0
        dd 1,0                         ; 26h
        dd 0,0
        dd 1,0                         ; 28h
        dd 1,0                         ; 29h
        dd 1,0                         ; 2ah
        dd 0,0
        dd 1,0                         ; 2ch
        dd 1,0                         ; 2dh
        dd 1,0                         ; 2eh
        dd 0,0
        times 16 dd 1,0                ; 30h..3fh

tablica:
        times 4  dd 0,0,1,0
        times 8  dd 80,20,-1,0
        times 8  dd -60,-30,1,0
        times 8  dd -30,20,-1,0
        times 8  dd 40,70,1,0
        times 8  dd -80,-20,-1,0
        times 8  dd -20,30,1,0
        times 8  dd 50,-50,-1,0
        times 4  dd -80,80,1,0

_count:  dd ile
step:    dd 0

skrin:   dq 0
rollbuf: dq 0    ; base of the ile-screen rolling ring (scr_tab[i] = rollbuf+i*64000);
                 ; kept SEPARATE from skrin (the composite screen), like the original
                 ; P3.ASM (anonymous ring alloc vs `skrin` screen at P3.ASM:205-208).
sun:     dq 0
sun_step: dd 0
ramki:   dd 0
_mulek:  dd 0
znacznik: dd 0
znacznik2: dd 0
licznik: dw 0
_yayo:   dq 0
map:     dq 0
lgmap:   dq 0

p_x: dd 0
p_y: dd 0
_size: dd 0
_skip1: dd 0
_skip2: dd 0

; arena offsets of working tables (stored as qwords so [x] qword loads stay clean;
; AllocateMemory writes the low 32 bits, high stay 0)
n_vert_a: dq 0
n_add_a:  dq 0
rcalc_a:  dq 0
n_rot_a:  dq 0
plane_a:  dq 0
pos_a:    dq 0
zet_a:    dq 0
shape_a:  dq 0
con_a:    dq 0

section .bss align=16
scr_tab: resd ile

; face globals (module; not arena)
x_1: resd 1
x_s: resd 1
y_1: resd 1
p_1: resw 2
m_1: resw 2
x_2: resd 1
y_2: resd 1
p_2: resw 2
m_2: resw 2
x_3: resd 1
y_3: resd 1
p_3: resw 2
m_3: resw 2
dx_1: resd 1
dy_1: resd 1
dx_2: resd 1
dy_2: resd 1
dy_3: resd 1
pd_1: resw 2
md_1: resw 2
pd_2: resw 2
md_2: resw 2
pom:  resw 1
mem:  resw 8

; resolved bases for face + span steps
esq: resq 1    ; screen base (real)
fsq: resq 1    ; map texture base (real)
gsq: resq 1    ; lgmap texture base (real)
f_pstep: resd 1 ; edx (p) span step
f_estep: resd 1 ; ecx (m) span step

section .data align=16

section .bss align=16

section .text

; ================================================================== PART3 ===
global part3
part3:
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

        mov     eax, [rel _scr_Addr]
        mov     [rel _screen], eax

        v_sync
        lea     rsi, [rel white]
        call    pal_set

        AllocateMemory 320*200, skrin

        vodka   22, _yayo
        vodka   23, sun

        ; brightness-boost _yayo by adding 256-16
        mov     rsi, [rel _yayo]
        add     rsi, qword [rel Code32_addr]
        xor     rdi, rdi
        mov     ecx, 256*256
.makl:
        movzx   eax, byte [rsi + rdi]
        add     eax, 256-16
        mov     byte [rsi + rdi], al
        inc     rdi
        dec     ecx
        jnz     .makl

        ; engine tables + texture selectors + anim pre-roll
        call    prepare_twist

        ; orientation from or_*
        mov     ax, [rel or_x]
        mov     word [rel r_x], ax
        mov     ax, [rel or_y]
        mov     word [rel r_y], ax
        mov     ax, [rel or_z]
        mov     word [rel r_z], ax

        mov     dword [rel len], 32
        call    n_calc
        call    prep_pos
        mov     dword [rel len], 72
        call    n_calc

        mov     dword [rel znacznik], 0
        mov     dword [rel znacznik2], 0

.main_loop:
        WaitVbl
        mov     [rel ramki], eax

        cmp     dword [rel znacznik2], 1
        je      .noz
        cmp     dword [rel znacznik], 1
        jne     .noz
        v_sync
        lea     rsi, [rel mypal]
        mov     byte [rsi], 0
        mov     byte [rsi+1], 0
        mov     byte [rsi+2], 0
        set_pal mypal, 0, 256
        set_pal tunel_pal, 256-16, 16
        mov     dword [rel znacznik2], 1
.noz:

        call    GetModPos
        movzx   eax, word [rel ModPos]
        and     eax, 0x3f
        add     eax, eax
        lea     rbx, [rel tablica]
        mov     ecx, [rbx + rax*8]
        mov     [rel p_x], ecx
        mov     ecx, [rbx + rax*8 + 4]
        mov     [rel p_y], ecx
        mov     ecx, [rbx + rax*8 + 8]
        mov     [rel _mulek], ecx

        call    tooneling
        call    copy
        call    sloneczko

        ; NOTE: the original P3.ASM main loop calls wait_vbl THEN v_sync
        ; (VGA retrace poll). The port forwards BOTH to EOS_WAIT_VBL (a full
        ; 70 Hz QPC wait), which waited twice per frame and halved the frame
        ; rate (~35 fps instead of the original's ~70 fps). Since wait_vbl at
        ; the top of this loop already lands on the frame boundary, v_sync is
        ; dropped here so the object's per-frame rotation stays in sync with
        ; the original (the whole P3 object phase cycle, including the solid
        ; cog pose, is then reached).
        ; skrin -> framebuffer
        mov     esi, [rel skrin]
        add     rsi, qword [rel Code32_addr]
        mov     edi, [rel framebuffer_off]
        add     rdi, qword [rel Code32_addr]
        mov     ecx, 16000
        rep movsd
        ; present the just-blitted frame
        extern vk_present_frame
        sub     rsp, 0x20
        call    vk_present_frame
        add     rsp, 0x20
        call    clear

        call    rotate_shape
        neg     word [rel r_x]
        neg     word [rel r_y]
        neg     word [rel r_z]
        call    rotate_normals
        neg     word [rel r_x]
        neg     word [rel r_y]
        neg     word [rel r_z]
        call    bit_sort
        call    p_calc
        call    show
        call    roll

        mov     dword [rel znacznik], 1

        mov     eax, [rel ramki]
        add     word [rel r_z], ax
        add     word [rel r_y], ax
        add     word [rel r_x], ax
        add     dword [rel step], step_2

        call    GetModPos
        movzx   eax, word [rel ModPos]
        cmp     eax, 0xd3e
        jg      .done
        cmp     eax, 0xd19
        jle     .bez_fleszy
        movzx   eax, ax
        and     eax, 0x3f
        lea     rbx, [rel flesze]
        cmp     dword [rbx + rax*8], 0
        je      .bez_fleszy
        cmp     dword [rbx + rax*8 + 4], 0
        jne     .bez_fleszy
        mov     dword [rbx + rax*8 + 4], 0
        mov     ebx, 1
        lea     rsi, [rel white]
        call    pal_flash_current
.bez_fleszy:
        jmp     .main_loop

.done:
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

; ------------------------------------------------------- prepare_twist -------
global prepare_twist
prepare_twist:
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

        vodka   20, map
        vodka   21, lgmap

        AllocateMemory 320*200*ile, rollbuf
        lea     r12, [rel scr_tab]
        xor     edi, edi
        mov     ecx, ile
        mov     edx, [rel rollbuf]
.alloc_scr:
        mov     [r12 + rdi], edx
        add     edx, 320*200
        add     edi, 4
        dec     ecx
        jnz     .alloc_scr

        ; zero roll block
        mov     edi, [rel rollbuf]
        add     rdi, qword [rel Code32_addr]
        xor     eax, eax
        mov     ecx, 16000*ile
        rep stosd

        ; selectors for map / lgmap
        mov     eax, EOS_ALLOCATE_SELECTOR
        mov     rsi, [rel map]
        add     rsi, qword [rel Code32_addr]
        mov     edi, 0xffff
        call    eos_dispatch
        mov     [rel map_sel], ax
        mov     eax, EOS_ALLOCATE_SELECTOR
        mov     rsi, [rel lgmap]
        add     rsi, qword [rel Code32_addr]
        mov     edi, 0xffff
        call    eos_dispatch
        mov     [rel lgmap_sel], ax

        call    p3_engine_set
        call    make_pal
        call    p3_prepare

        mov     dword [rel len], 42
        call    n_calc
        call    prep_pos
        mov     dword [rel len], 72
        call    n_calc

        ; make_anim: ile frames pre-roll
        mov     ecx, [rel _count]
.make_anim:
        call    rotate_shape
        neg     word [rel r_x]
        neg     word [rel r_y]
        neg     word [rel r_z]
        call    rotate_normals
        neg     word [rel r_x]
        neg     word [rel r_y]
        neg     word [rel r_z]
        call    bit_sort
        call    p_calc
        call    show
        call    roll

        WaitVbl
        mov     edx, eax
        add     word [rel r_z], dx
        add     word [rel r_y], dx
        add     word [rel r_x], dx
        add     dword [rel step], step_2

        dec     dword [rel _count]
        jnz     .make_anim

        mov     ax, word [rel r_x]
        mov     [rel or_x], ax
        mov     ax, word [rel r_y]
        mov     [rel or_y], ax
        mov     ax, word [rel r_z]
        mov     [rel or_z], ax

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

; ------------------------------------------------------------ make_pal ------
make_pal:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    rcx
        sub     rsp, 0x20
        lea     rsi, [rel spal]
        lea     rdi, [rel mypal]
        mov     bl, 63
        mov     ecx, 16
.f_lo1:
        push    rcx
        push    rsi
        xor     r12, r12
        mov     ecx, 16*3
.f_lo2:
        ; 8-bit add exactly like the original (P3.ASM make_pal): the byte wraps
        ; mod 256 and `jns` tests bit 7, so any sum that lands negative as a
        ; signed BYTE clamps to 0. (A 32-bit add here made bit 31 the sign and
        ; let wrapped bytes 128..255 through - bright where the original is
        ; black.)
        movzx   eax, byte [rsi + r12]
        add     al, bl
        jns     .pa1
        xor     al, al
.pa1:
        cmp     al, 63
        jle     .pa2
        mov     al, 63
.pa2:
        mov     [rdi], al
        inc     rdi
        inc     r12
        dec     ecx
        jnz     .f_lo2
        sub     bl, 11
        pop     rsi
        pop     rcx
        loop    .f_lo1
        add     rsp, 0x20
        pop     rcx
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ------------------------------------------------------------ p3_prepare -----
p3_prepare:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        sub     rsp, 0x20

        ; double every con word (in arena copy)
        mov     rsi, [rel con_a]
        add     rsi, qword [rel Code32_addr]
        mov     rdi, rsi
        xor     r12, r12
        mov     ecx, f_num*3
.pr_lo1:
        movzx   eax, word [rsi + r12]
        add     eax, eax
        mov     word [rdi + r12], ax
        add     r12, 2
        dec     ecx
        jnz     .pr_lo1

        ; shl lgmap bytes << 4 (in place, real buffer)
        mov     rsi, [rel lgmap]
        add     rsi, qword [rel Code32_addr]
        mov     rdi, rsi
        xor     r12, r12
        mov     ecx, 256*199
.pr_lo2:
        movzx   eax, byte [rsi + r12]
        shl     eax, 4
        mov     byte [rdi + r12], al
        add     r12, 1
        dec     ecx
        jnz     .pr_lo2

        add     rsp, 0x20
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ------------------------------------------------------------- prep_pos -----
prep_pos:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        sub     rsp, 0x20
        mov     r12, [rel n_vert_a]
        add     r12, qword [rel Code32_addr]   ; n_vert base (64-bit)
        mov     r13, [rel pos_a]
        add     r13, qword [rel Code32_addr]   ; pos base (64-bit)
        xor     rsi, rsi                       ; vertex index
        mov     ecx, p_num
.prep:
        ; n_vert: x @ v*6, y @ v*6+2 (3 words/vertex). pos: 2 words/vertex.
        lea     rax, [rsi + rsi*2]             ; v*3
        add     rax, rax                       ; v*6 (bytes)
        movzx   ebx, word [r12 + rax]          ; nx
        add     ebx, 128
        shl     bx, 8
        lea     rdi, [r13 + rsi*4]             ; pos byte offset v*4 (2 words/vertex)
        mov     [rdi], bx
        movzx   ebx, word [r12 + rax + 2]      ; ny
        add     ebx, 96
        shl     bx, 8
        mov     [rdi+2], bx
        inc     rsi
        dec     ecx
        jnz     .prep
        add     rsp, 0x20
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ------------------------------------------------------------ tooneling ------
tooneling:
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

        mov     edi, [rel skrin]
        add     rdi, qword [rel Code32_addr]
        mov     r12, [rel _yayo]
        add     r12, qword [rel Code32_addr]
        mov     edx, [rel _tableToonel]     ; dword arena offset -> zero-extend
        add     rdx, qword [rel Code32_addr]
        movzx   r14d, word [rel licznik]
        mov     esi, 32000
.Spier:
        movzx   ecx, word [rdx + rsi*2 - 2]
        movzx   ebx, word [rdx + 64000 + rsi*2 - 2]
        mov     r13d, ebx
        add     r13d, r14d
        and     r13d, 0xffff        ; 16-bit wrap like the original's bx (64KB tex)
        mov     r15d, ecx
        add     r15d, r14d
        and     r15d, 0xffff        ; 16-bit wrap like the original's cx
        movzx   eax, byte [r12 + r13]
        movzx   ebx, byte [r12 + r15]
        mov     ah, bl              ; ax = (u-texel<<8) | v-texel, like [edi],ax
        mov     [rdi], ax
        add     rdi, 2
        dec     esi
        jnz     .Spier

        mov     eax, [rel ramki]
        movsxd  rbx, eax
        mov     eax, [rel _mulek]
        shl     eax, 1
        add     eax, 256
        imul    ebx, eax
        add     [rel licznik], ax       ; original: add licznik,ax (accumulates)

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

; ---------------------------------------------------------------- copy ------
; vertical scroll copy: for each screen row, copy _size bytes from the rolling
; scr_tab screen (selected by (-sinus[step]*ebp)>>16 + ile/2) into skrin.
copy:
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

        mov     dword [rel _size], 320
        mov     eax, [rel p_x]
        cmp     eax, 0
        jge     .p1
        add     [rel _size], eax
        neg     eax
        mov     [rel _skip1], eax
        mov     dword [rel _skip2], 0
        jmp     .cp1
.p1:
        sub     [rel _size], eax
        mov     dword [rel _skip1], 0
        mov     [rel _skip2], eax
.cp1:
        ; rows: ecx = 200 - p_y when p_y >= 0, else 200 (P3.ASM:535-547)
        mov     ecx, 200
        mov     eax, [rel p_y]
        cmp     eax, 0
        jl      .p2
        sub     ecx, eax
.p2:
        ; dst = skrin + p_y*320 + p_x (running pointer, advances per row)
        mov     r15, [rel Code32_addr]
        mov     rdi, [rel skrin]
        add     rdi, r15
        mov     eax, [rel p_y]
        imul    eax, 320
        add     eax, [rel p_x]
        movsxd  rax, eax
        add     rdi, rax
        mov     ebx, [rel step]
        and     ebx, 0x3ff
        mov     ebp, ile-4
        lea     r12, [rel scr_tab]
        lea     r11, [rel sinus]
        xor     r13, r13            ; running src row offset (row*320)
        mov     r8d, [rel p_y]      ; running p_y (inc per row, like the original)
.c_lop:
        test    ecx, ecx
        jle     .ret
        cmp     r8d, 0
        jge     .gosp
        add     rdi, 320            ; p_y < 0: skip dst row, no draw (P3.ASM:571-574)
        jmp     .cosp
.gosp:
        ; src = scr_tab[ ((-sinus[ebx]*ebp)>>16) + ile/2 ] + row*320 + _skip1
        movsx   eax, word [r11 + rbx*2]
        neg     eax
        imul    ebp
        sar     eax, 16
        add     eax, ile/2
        mov     eax, [r12 + rax*4]  ; scr_tab[sel] (arena offset, already absolute)
        add     rax, r13
        mov     edx, [rel _skip1]
        movsxd  rdx, edx
        add     rax, rdx
        lea     rsi, [rax + r15]    ; src real
        mov     r14, rdi            ; dst cursor = rdi + _skip1
        add     r14, rdx
        mov     edx, [rel _size]
        ; copy row, skipping zeros
.cprow:
        mov     al, byte [rsi]
        or      al, al
        jz      .zu
        mov     byte [r14], al
.zu:
        inc     rsi
        inc     r14
        dec     edx
        jnz     .cprow
        ; dst advance: _skip1 + _size + _skip2 (= 320) (P3.ASM:584-594)
        mov     eax, [rel _skip1]
        add     eax, [rel _size]
        add     eax, [rel _skip2]
        movsxd  rax, eax
        add     rdi, rax
.cosp:
        add     ebx, step_1
        and     ebx, 0x3ff
        add     r13, 320
        inc     r8d
        dec     ecx
        jmp     .c_lop
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

; ---------------------------------------------------------------- clear -----
; clears the ring's head screen (scr_tab[0]) for the next 3D draw (P3.ASM:606)
clear:
        push    rbp
        mov     rbp, rsp
        push    rdi
        push    rcx
        sub     rsp, 0x20
        mov     edi, [rel scr_tab]
        add     rdi, qword [rel Code32_addr]
        xor     eax, eax
        mov     ecx, 16000
        rep stosd
        add     rsp, 0x20
        pop     rcx
        pop     rdi
        pop     rbp
        ret

; ------------------------------------------------------------ bit_sort ------
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

        mov     r12, [rel con_a]
        add     r12, qword [rel Code32_addr]
        mov     r13, [rel zet_a]
        add     r13, qword [rel Code32_addr]
        mov     r14, [rel rcalc_a]
        add     r14, qword [rel Code32_addr]

        mov     ecx, [rel faces]
        xor     esi, esi               ; con byte offset (0,6,12,..)
        xor     edi, edi               ; zet_tab byte offset
        xor     ebx, ebx               ; high-word accumulator (face*6<<16)
.make_tab:
        movzx   eax, word [r12 + rsi]
        lea     eax, [rax*2 + rax + 4]
        mov     ax, word [r14 + rax]
        movzx   edx, word [r12 + rsi + 2]
        lea     edx, [rdx*2 + rdx + 4]
        add     ax, word [r14 + rdx]
        movzx   edx, word [r12 + rsi + 4]
        lea     edx, [rdx*2 + rdx + 4]
        add     ax, word [r14 + rdx]
        add     ax, 16000
        ; form dword: low16 = zet (ax), high16 = face*6 (ebx hi)
        mov     [r13 + rdi], ebx       ; store high (face*6<<16) first
        mov     [r13 + rdi], ax        ; then low (overwrites low16, keeps high)
        add     edi, 4
        add     esi, 6
        add     ebx, 0x60000           ; next face*6
        dec     ecx
        jnz     .make_tab

        call    sort

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

; ---------------------------------------------------------------- p_calc -----
p_calc:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        sub     rsp, 0x20
        mov     rsi, [rel rcalc_a]
        add     rsi, qword [rel Code32_addr]
        mov     rdi, [rel plane_a]
        add     rdi, qword [rel Code32_addr]
        mov     ecx, p_num
.p_lop:
        movsx   ebx, word [rsi+4]       ; z
        sub     bx, 6200
        movsx   ebx, bx                 ; signed 16-bit divisor for idiv ebx
        movsx   eax, word [rsi]
        imul    eax, zoom+32
        cdq
        idiv    ebx
        add     ax, word [rel sh_x]
        mov     [rdi], ax
        add     rdi, 2
        movsx   eax, word [rsi+2]
        imul    eax, zoom
        cdq
        idiv    ebx
        add     ax, word [rel sh_y]
        mov     [rdi], ax
        add     rdi, 2
        add     rsi, 6
        dec     ecx
        jnz     .p_lop
        add     rsp, 0x20
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ---------------------------------------------------------------- show ------
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

        ; resolve selector bases
        ; draw target = the rolling ring's head screen (scr_tab[0]); the
        ; original patches scr_tab into face's store (P3.ASM:1007/1122).
        mov     r15, [rel Code32_addr]
        mov     eax, [rel scr_tab]
        lea     rdi, [rax + r15]
        mov     [rel esq], rdi
        lea     rbx, [rel sel_base_table]
        movzx   eax, word [rel map_sel]
        and     eax, 0x1ff
        mov     rdi, [rbx + rax*8]
        mov     [rel fsq], rdi
        movzx   eax, word [rel lgmap_sel]
        and     eax, 0x1ff
        mov     rdi, [rbx + rax*8]
        mov     [rel gsq], rdi

        ; arena bases for tables
        mov     rbx, [rel con_a]
        add     rbx, r15
        mov     [rel .conB], rbx
        mov     rbx, [rel plane_a]
        add     rbx, r15
        mov     [rel .plB], rbx
        mov     rbx, [rel n_rot_a]
        add     rbx, r15
        mov     [rel .nrB], rbx
        mov     rbx, [rel pos_a]
        add     rbx, r15
        mov     [rel .posB], rbx

        mov     rsi, [rel zet_a]
        add     rsi, r15
        mov     ecx, [rel faces]
.lop:
        push    rcx
        push    rsi
        movzx   edi, word [rsi+2]      ; face byte offset

        mov     r12, [rel .conB]
        mov     r13, [rel .plB]
        mov     r14, [rel .nrB]
        mov     r15, [rel .posB]

        movzx   ebx, word [r12 + rdi]
        movsx   eax, word [r13 + rbx*2]
        mov     [rel x_1], eax
        movsx   eax, word [r13 + rbx*2 + 2]
        mov     [rel y_1], eax
        mov     ax, word [r14 + rbx*2]
        add     ax, 128
        shl     ax, 8
        mov     [rel p_1], ax
        mov     ax, word [r14 + rbx*2 + 2]
        add     ax, 108
        shl     ax, 8
        mov     [rel p_1+2], ax
        mov     eax, dword [r15 + rbx*2]
        mov     [rel m_1], eax

        movzx   ebx, word [r12 + rdi + 2]
        movsx   eax, word [r13 + rbx*2]
        mov     [rel x_2], eax
        movsx   eax, word [r13 + rbx*2 + 2]
        mov     [rel y_2], eax
        mov     ax, word [r14 + rbx*2]
        add     ax, 128
        shl     ax, 8
        mov     [rel p_2], ax
        mov     ax, word [r14 + rbx*2 + 2]
        add     ax, 108
        shl     ax, 8
        mov     [rel p_2+2], ax
        mov     eax, dword [r15 + rbx*2]
        mov     [rel m_2], eax

        movzx   ebx, word [r12 + rdi + 4]
        movsx   eax, word [r13 + rbx*2]
        mov     [rel x_3], eax
        movsx   eax, word [r13 + rbx*2 + 2]
        mov     [rel y_3], eax
        mov     ax, word [r14 + rbx*2]
        add     ax, 128
        shl     ax, 8
        mov     [rel p_3], ax
        mov     ax, word [r14 + rbx*2 + 2]
        add     ax, 108
        shl     ax, 8
        mov     [rel p_3+2], ax
        mov     eax, dword [r15 + rbx*2]
        mov     [rel m_3], eax

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
        jge     .hide
        call    face
.hide:
        pop     rsi
        pop     rcx
        add     rsi, 4
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
; temp table bases for show (module .data)
section .data
.conB: dq 0
.plB: dq 0
.nrB: dq 0
.posB: dq 0

section .text

; ---------------------------------------------------------------- face ------
; Dual-texture rasterizer. Port of P3's face with self-modifying steps ->
; explicit f_pstep/f_estep and resolved register bases.
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

        mov     r9,  [rel esq]     ; screen base
        mov     r13, [rel fsq]     ; map base
        mov     r14, [rel gsq]     ; lgmap base

        mov     word [rel pom], 0
        ; ---- Y-sort (inline swap) ----
        mov     eax, [rel y_1]
        cmp     eax, [rel y_2]
        jle     .pr1
        p3_yswap y_1,y_2,x_1,x_2,p_1,p_2,m_1,m_2
.pr1:
        mov     eax, [rel y_1]
        cmp     eax, [rel y_3]
        jle     .pr2
        p3_yswap y_1,y_3,x_1,x_3,p_1,p_3,m_1,m_3
.pr2:
        mov     eax, [rel y_2]
        cmp     eax, [rel y_3]
        jle     .pr3
        p3_yswap y_2,y_3,x_2,x_3,p_2,p_3,m_2,m_3
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
        movzx   ebx, word [rel m_1]
        movzx   eax, word [rel m_3]
        sub     eax, ebx
        cdq
        idiv    dword [rel dy_3]
        mov     [rel md_1], ax
        movzx   ebx, word [rel m_1+2]
        movzx   eax, word [rel m_3+2]
        sub     eax, ebx
        cdq
        idiv    dword [rel dy_3]
        mov     [rel md_2], ax

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
        mov     eax, dword [rel m_1]
        mov     [rel mem+4], eax
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
        mov     eax, [rel dy_1]
        imul    dword [rel md_1]
        add     ax, word [rel m_1]
        mov     [rel mem+4], ax
        mov     eax, [rel dy_1]
        imul    dword [rel md_2]
        add     ax, word [rel m_1+2]
        mov     [rel mem+6], ax
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
        mov     ax, word [rel m_1]
        xchg    ax, word [rel m_1+2]
        mov     word [rel m_1], ax

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
        neg     bx
        call    p3_slope
        jmp     .draw_1
.norm:
        ; x_2 > pom: middle vertex is RIGHT of the long edge -> the span runs
        ; left->right (draw_2). The original has a second raster path here
        ; (draw_2 with its own a2/v3/v4 patch); the port used to fall back to
        ; draw_1, which misreads x_1 as the left edge and x_s as the right,
        ; so `sub ebp,edi` came out negative and EVERY row of these faces was
        ; skipped (roughly half the hero object's faces never drew).
        call    p3_slope
        jmp     .draw_2

.draw_1:
        mov     r12, [rel esq]     ; screen base (reload)
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
        ; signed 16-bit edge reads like the original `mov di,w x_1+2` /
        ; `mov bp,w x_s+2` (movsx, not movzx): a left edge off-screen-LEFT has
        ; a negative integer part, which the signed compare keeps in the row
        ; (clamped to 0 below); movzx turned it into ~65000 and `je .go_1`
        ; dropped the whole row - visible missing geometry on the left side.
        movsx   edi, word [rel x_1+2]
        movsx   ebp, word [rel x_s+2]
        cmp     edi, x2_max
        jge     .go_1
        cmp     ebp, x2_min
        jl      .go_1
        mov     edx, dword [rel p_1]
        mov     ecx, dword [rel m_1]
        cmp     ebp, x2_max-1
        jl      .no_c3
.add_2:
        add     edx, [rel f_pstep]
        add     ecx, [rel f_estep]
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
        ; original fo_1/fo_2 (P3.ASM:1055/1168): al = lgmap[edx>>16] (es),
        ; ah = map[ecx>>16] (fs), sum -> screen. The port had these swapped
        ; (map sampled by the p/n_rot coordinate, lgmap by the m/pos
        ; coordinate), which changed the color of every shaded tunnel face.
        ; es = lgmap base is r14 (gsq), fs = map base is r13 (fsq).
        mov     bl, dh
        shld    ebx, edx, 8
        movzx   ebx, bx
        movzx   r8d, byte [r14 + rbx]    ; lgmap (es) sampled by p (edx)
        mov     bl, ch
        shld    ebx, ecx, 8
        movzx   ebx, bx
        movzx   eax, byte [r13 + rbx]    ; map (fs) sampled by m (ecx)
        add     al, r8b
        mov     r10, rdi
        mov     byte [r9 + r10], al
        dec     edi
        add     edx, [rel f_pstep]
        add     ecx, [rel f_estep]
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
        mov     ax, word [rel md_2]
        add     word [rel m_1], ax
        mov     ax, word [rel md_1]
        add     word [rel m_1+2], ax
        add     dword [rel y_1], 320
        dec     dword [rel dy_3]
        jne     .draw_1
        jmp     .sk

; -------------------------------------------------------------- draw_2 ------
; Positive-span path (x_2 > pom): middle vertex is right of the long edge.
; Faithful port of the original draw_2 (P3.ASM:1106-1167). Here the LEFT edge
; is the v1->v3 interpolant x_s and the RIGHT edge is x_1 (v1->v2->v3), so:
;   .add_1  virtually scans the left edge inward while it is off-screen left,
;           stepping the texture so it stays aligned at x=0;
;   .fo_2   fills the span left->right (inc edi) from x_s to x_1.
; Both draw paths share the slope computed by p3_slope (f_pstep/f_estep) and
; the same per-row interpolant advance; the original kept two code copies only
; because the slope immediates/screen base were self-modifying.
; ABI: same 8-push prologue as face - so .sk (shared exit) is reachable.
.draw_2:
        mov     r12, [rel esq]     ; screen base (reload; keep in sync w/ draw_1)
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
        movsx   ebp, word [rel x_1+2]
        cmp     edi, x2_max
        jge     .go_2
        cmp     ebp, x2_min
        jl      .go_2
        mov     edx, dword [rel p_1]
        mov     ecx, dword [rel m_1]
        cmp     edi, x2_min
        jge     .no_c1
.add_1:
        ; virtual scan: step texture while the left edge is off-screen left
        add     edx, [rel f_pstep]
        add     ecx, [rel f_estep]
        inc     edi
        cmp     edi, x2_min
        jl      .add_1
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
        ; fo_2 (P3.ASM:1168): same sample order as fo_1 -
        ; al = lgmap[edx>>16] (es/r14), ah = map[ecx>>16] (fs/r13), sum -> screen.
        mov     bl, dh
        shld    ebx, edx, 8
        movzx   ebx, bx
        movzx   r8d, byte [r14 + rbx]    ; lgmap (es) sampled by p (edx)
        mov     bl, ch
        shld    ebx, ecx, 8
        movzx   ebx, bx
        movzx   eax, byte [r13 + rbx]    ; map (fs) sampled by m (ecx)
        add     al, r8b
        mov     r10, rdi
        mov     byte [r9 + r10], al
        inc     edi
        add     edx, [rel f_pstep]
        add     ecx, [rel f_estep]
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
        mov     ax, word [rel md_2]
        add     word [rel m_1], ax
        mov     ax, word [rel md_1]
        add     word [rel m_1+2], ax
        add     dword [rel y_1], 320
        dec     dword [rel dy_3]
        jne     .draw_2
        jmp     .sk
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

; p3_slope: compute f_pstep/f_estep from mem vs p_2/m_2 (ebx = span diff)
p3_slope:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r9
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
        ; the original packs (first_slope<<16) | second_slope here; the port
        ; had an extra `shl esi,16` + `or esi,edi` that dropped the first
        ; slope and ORed a stale face offset into the sub-pixel step.
        mov     [rel f_pstep], esi
        movzx   ecx, word [rel mem+4]
        movzx   eax, word [rel m_2]
        sub     eax, ecx
        cdq
        idiv    ebx
        mov     bp, ax
        shl     ebp, 16
        movzx   ecx, word [rel mem+6]
        movzx   eax, word [rel m_2+2]
        sub     eax, ecx
        cdq
        idiv    ebx
        mov     bp, ax
        ; same packing fix as f_pstep above.
        mov     [rel f_estep], ebp
        add     rsp, 0x20
        pop     r9
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ---------------------------------------------------------------- roll ------
roll:
        push    rbp
        mov     rbp, rsp
        push    rcx
        push    rdx
        push    rsi
        push    rdi
        sub     rsp, 0x20
        lea     rsi, [rel scr_tab]
        ; first = scr_tab[0]
        mov     eax, [rsi]
        ; shift down: scr_tab[i] = scr_tab[i+1], for i in 0..ile-2
        xor     edi, edi
        mov     ecx, ile-1
.roll_loop:
        mov     edx, [rsi + rdi + 4]
        mov     [rsi + rdi], edx
        add     edi, 4
        dec     ecx
        jnz     .roll_loop
        ; last = first
        mov     [rsi + (ile-1)*4], eax
        add     rsp, 0x20
        pop     rdi
        pop     rsi
        pop     rdx
        pop     rcx
        pop     rbp
        ret

; ------------------------------------------------------- sloneczko ----------
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
        cmp     eax, 36
        jl      .ok1
        sub     eax, 35
.ok1:
        cmp     eax, 0
        jg      .ok2
        add     eax, 35
.ok2:
        mov     [rel sun_step], eax
        mov     eax, [rel sun_step]
        shl     eax, 12
        mov     esi, [rel sun]
        add     esi, eax
        add     rsi, qword [rel Code32_addr]
        mov     edi, [rel skrin]
        add     rdi, qword [rel Code32_addr]
        add     rdi, ((206-64)*320)+254
        mov     r14, 64
.ep1:
        mov     r13, 64
.ep2:
        movzx   eax, byte [rsi]
        inc     rsi
        cmp     al, 0x60
        je      .sun_sk
        mov     [rdi], al
.sun_sk:
        inc     rdi
        dec     r13
        jnz     .ep2
        add     rdi, 320-64
        dec     r14
        jnz     .ep1
        mov     eax, [rel ramki]
        cmp     eax, 4
        jle     .plo
        shr     eax, 2
        jmp     .doit
.plo:
        mov     eax, 1
.doit:
        add     [rel sun_step], eax
        ; re-clamp (avoid huge overflow on large ramki)
        mov     eax, [rel sun_step]
        cmp     eax, 35
        jg      .wrap
        cmp     eax, 0
        jge     .ret
.wrap:
        xor     edx, edx
        mov     ecx, 36
        idiv    ecx
        mov     [rel sun_step], edx
.ret:
        add     rsp, 0x20
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; -------------------------------------------------------- engine setup ------
p3_engine_set:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    rcx
        sub     rsp, 0x20

        AllocateMemory p_num*3*2, shape_a
        mov     rdi, [rel shape_a]
        add     rdi, qword [rel Code32_addr]
        lea     rsi, [rel shape]
        mov     ecx, (p_num*3*2)>>2
        rep movsd

        AllocateMemory f_num*3*2, con_a
        mov     rdi, [rel con_a]
        add     rdi, qword [rel Code32_addr]
        lea     rsi, [rel con]
        mov     ecx, (f_num*3*2)>>2
        rep movsd

        AllocateMemory p_num*3*2, rcalc_a
        ; n_rot is 2 words per vertex (rotate_normals writes 4 bytes/vertex),
        ; so it needs p_num*4 bytes. p_num*2 under-allocated it, letting
        ; rotate_normals overflow into n_vert every frame and corrupt the
        ; first ~114 vertices' normals (scrambled texture coordinates).
        AllocateMemory p_num*4, n_rot_a
        AllocateMemory p_num*3*2, n_vert_a
        AllocateMemory p_num*2, n_add_a
        AllocateMemory p_num*4, plane_a
        AllocateMemory p_num*4, pos_a
        AllocateMemory f_num*4, zet_a

        mov     eax, [rel shape_a]
        mov     [rel shape_addr], eax
        mov     eax, [rel rcalc_a]
        mov     [rel srot_addr], eax
        mov     eax, [rel n_vert_a]
        mov     [rel n_addr], eax
        mov     eax, [rel n_rot_a]
        mov     [rel nrot_addr], eax
        mov     eax, [rel n_add_a]
        mov     [rel inc_addr], eax
        mov     eax, [rel con_a]
        mov     [rel con_addr], eax
        mov     eax, [rel zet_a]
        mov     [rel sort_addr], eax
        mov     dword [rel points], p_num
        mov     dword [rel faces], f_num

        call    prep_sort

        add     rsp, 0x20
        pop     rcx
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

