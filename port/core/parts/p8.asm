; p8.asm - NASM x64 port of CODE/P8/P8.ASM  (part 8: viewer/object demo).
;
; Faithful port of P8: user-driveable camera + auto-rotating fusing of the
; "sw" + "ob" meshes into one object (p_len verts, f_len faces), textured with
; sw.inc/metal.inc via a custom fs/es texmapper, plus an animated sun sprite
; and a picture outtro with palette fades.
;
; Memory model: stored dwords are arena offsets; deref via `add r, Code32_addr`.
; The con table (con1..c6) is one arena array modified by prepare/co_prepare and
; read by the engine (con_addr) and the part (rotate/show) - single copy.
; src3..src5 = engine-read shape (arena). n_src/n_add/n_vert/n_rot/draw_tab are
; engine-written working arrays (arena). Everything else stays module .data
; (part-code-only: shape base, s2..s6, pkt, pts_*, rcalc, check).
;
; selectors: map1_sel/map2_sel = textures (fs), scr_sel = screen (es).
; `mov fs,X / fs:[bx]` texture reads and `mov es,scr_sel / es:[di]` screen
; writes become sel_base_table lookups (mirrors txtr.asm).
;
; ABI: prologue 8 pushes + sub 0x28 -> RSP%16==0 at every NASM->C++ call.

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

; engine surfaces
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
extern sort

p_len   EQU 40+33+114+128+128+40
f_len   EQU 40+48+224+256+256+40

x1_min  EQU -3400
x1_max  EQU 3400
y1_min  EQU -3400
y1_max  EQU 3400
z1_min  EQU -4200
z1_max  EQU 6100

x2_min  EQU 0
x2_max  EQU 320
y2_min  EQU 0
y2_max  EQU 200

zoom    EQU 160
ruchow  EQU 2497

; PC/AT scancode set-1 values (EOS.INC is not in the repo; KEYS.! used these)
UP    EQU 0x48
DOWN  EQU 0x50
LEFT  EQU 0x4B
RIGHT EQU 0x4D
KEY_C EQU 0x2E
KEY_X EQU 0x2D
KEY_W EQU 0x11
KEY_Q EQU 0x10
KEY_F1  EQU 0x3B
KEY_F2  EQU 0x3C
KEY_F3  EQU 0x3D
KEY_F4  EQU 0x3E
KEY_F5  EQU 0x3F
KEY_F6  EQU 0x40
KEY_F7  EQU 0x41
KEY_F8  EQU 0x42
KEY_F9  EQU 0x43
KEY_F10 EQU 0x44
KEY_F11 EQU 0x57
KEY_F12 EQU 0x58

; --------------------------------------------------------------------- .bss
section .bss align=16
global part8

scr_addr:   resd 1
scr_sel:    resw 1
map1_sel:   resw 1
map2_sel:   resw 1

map1:     resd 1
map2:     resd 1
last_pal: resd 1
last_pic: resd 1
sun:      resd 1
ruchy:    resd 1

ro_1: resd 1
ro_2: resd 1
ro_3: resd 1
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

pkt: resw 33*2

; arena offsets of engine-shared working arrays
shape_a8: resd 1      ; src3..src5 (ob_ verts) 370*6 bytes
con_a8:   resd 1      ; con1..c6 (all faces)   f_len*6 bytes
n_src_a:  resd 1
n_add_a:  resd 1
n_vert_a: resd 1
n_rot_a:  resd 1
draw_a8:  resd 1      ; draw_tab (f_len dwords)

; module .bss statics (part-code only)
pts_src:  resw (224+256+256)*3
pts_tab:  resw f_len*3
rcalc:    resw p_len*2
ile:      resd 1
check:    resw p_len

frames:    resd 1
ruchy_ptr: resd 1
mnoznik:   resd 1
ile_fade:  resd 1
shf:       resd 1
sin:       resd 1
cos:       resd 1
Key_Map:   resb 128

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

; --------------------------------------------------------------------- .data
section .data align=16

nazwa: db "p8.pal", 0

pal:    incbin "sw.pal"
        times 768-($-pal) db 0
mpal:   incbin "metal.pal"

src3:

%include "p8_ob_s_1.inc"   ; 114
src4:
%include "p8_ob_s_2.inc"   ; 128
src5:
%include "p8_ob_s_3.inc"   ; 128

shape:

%include "p8_sw_s_1.inc"   ; 40
s2:
%include "p8_sw_s_2.inc"   ; 33
s3:
%include "p8_ob_s_1.inc"   ; 114
s4:
%include "p8_ob_s_2.inc"   ; 128
s5:
%include "p8_ob_s_3.inc"   ; 128
s6:
%include "p8_sw_s_1.inc"   ; 40

con1:

%include "p8_sw_c_1.inc"   ; 40
c2:
%include "p8_sw_c_2.inc"   ; 48
c3:
%include "p8_ob_c_1.inc"   ; 224
c4:
%include "p8_ob_c_2.inc"   ; 256
c5:
%include "p8_ob_c_3.inc"   ; 256
c6:
%include "p8_sw_c_1.inc"   ; 40

con2:
        %rep (40+48)/8
        dw 0*2,1*2,2*2
        dw 0*2,2*2,3*2
        dw 4*2,5*2,6*2
        dw 4*2,6*2,7*2
        dw 8*2,9*2,10*2
        dw 8*2,10*2,11*2
        dw 12*2,13*2,14*2
        dw 12*2,14*2,15*2
        %endrep
        %rep (224+256+256+40)/8
        dw (0+16)*2,(1+16)*2,(2+16)*2
        dw (0+16)*2,(2+16)*2,(3+16)*2
        dw (4+16)*2,(5+16)*2,(6+16)*2
        dw (4+16)*2,(6+16)*2,(7+16)*2
        dw (8+16)*2,(9+16)*2,(10+16)*2
        dw (8+16)*2,(10+16)*2,(11+16)*2
        dw (12+16)*2,(13+16)*2,(14+16)*2
        dw (12+16)*2,(14+16)*2,(15+16)*2
        %endrep

con3:
        %rep 40/2
        dd 0
        db 0,0
        db 0,0
        dd 0
        dw 0
        db 0,0
        %endrep
        %rep 16/2
        dd 0
        db 128,1
        db 1,0
        dd 0
        db 128,1
        db 1,0
        %endrep
        %rep 32/2
        dd 0
        db 64,0
        db 1,0
        dd 0
        db 64,0
        db 1,0
        %endrep
        %rep 224/2
        dd 1
        db 192,0
        db 1,1
        dd 1
        db 192,0
        db 1,1
        %endrep
        %rep 256/2
        dd 1
        db 192,0
        db 1,1
        dd 1
        db 192,0
        db 1,1
        %endrep
        %rep 256/2
        dd 1
        db 192,0
        db 1,1
        dd 1
        db 192,0
        db 1,1
        %endrep
        %rep 40/2
        dd 0
        db 0,0
        db 0,0
        dd 0
        db 0,0
        db 0,0
        %endrep

pos:
        dw 10*256,8*256, 10*256,112*256, 63*256,112*256, 63*256,8*256
        dw 63*256,8*256, 63*256,112*256, 126*256,112*256, 126*256,8*256
        dw 126*256,8*256, 126*256,112*256, 189*256,112*256, 189*256,8*256
        dw 189*256,8*256, 189*256,112*256, 248*256,112*256, 248*256,8*256
        dw 10*256,112*256, 10*256,8*256, 63*256,8*256, 63*256,112*256
        dw 63*256,112*256, 63*256,8*256, 126*256,8*256, 126*256,112*256
        dw 126*256,112*256, 126*256,8*256, 189*256,8*256, 189*256,112*256
        dw 189*256,112*256, 189*256,8*256, 248*256,8*256, 248*256,112*256

tablica:
        dw 64-15 dup (0,0)
        dw 1,0
        dw 0,0
        dw 1,0
        dw 1,0
        dw 1,0
        dw 0,0
        dw 1,0
        dw 1,0
        dw 1,0
        dw 0,0
        dw 1,0
        dw 1,0
        dw 1,0
        dw 0,0
        dw 1,0
        dw 0,0

; --------------------------------------------------------------------- .text
section .text

; ------------------------------------------------------------------- part8 --
global part8
part8:
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



        ; original .data initializers
        mov     dword [rel ro_1], 0
        mov     dword [rel ro_2], 160
        mov     dword [rel ro_3], -70
        mov     dword [rel o_z], 4400
        mov     dword [rel mnoznik], 1
        mov     dword [rel ile_fade], 64

        ; screen setup
        mov     ax, [_scrSel]
        mov     [rel scr_sel], ax
        mov     eax, [_scr_Addr]
        mov     [rel scr_addr], eax
        mov     [_screen], eax

        lea     rsi, [rel white]
        call    pal_set

        mov     edi, [rel scr_addr]
        add     rdi, qword [rel Code32_addr]
        xor     eax, eax
        mov     ecx, 16000
        rep stosd

        vodka   24, map1
        vodka   27, map2
        vodka   70, last_pal
        vodka   71, last_pic
        vodka   73, sun
        vodka   75, ruchy


        ; len = 80 for the engine normalize
        extern len
        mov     dword [rel len], 80

        ; --- arena copies ------------------------------------------------
        ; con (con1..c6, f_len*6 bytes) - the ONE shared con table
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, f_len*6
        call    eos_dispatch
        mov     [rel con_a8], edx
        mov     rdi, rdx
        add     rdi, qword [rel Code32_addr]
        lea     rsi, [rel con1]
        mov     ecx, (f_len*6)>>2
        rep movsd

        ; shape (src3..src5, (114+128+128)*6 bytes) - engine-read
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, (114+128+128)*6
        call    eos_dispatch
        mov     [rel shape_a8], edx
        mov     rdi, rdx
        add     rdi, qword [rel Code32_addr]
        lea     rsi, [rel src3]
        mov     ecx, ((114+128+128)*6)>>2
        rep movsd

        ; n_src
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, (114+128+128)*6
        call    eos_dispatch
        mov     [rel n_src_a], edx
        ; n_add
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, 128*2
        call    eos_dispatch
        mov     [rel n_add_a], edx
        ; n_vert
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, (114+128+128)*6
        call    eos_dispatch
        mov     [rel n_vert_a], edx
        ; n_rot
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, (114+128+128)*4
        call    eos_dispatch
        mov     [rel n_rot_a], edx
        ; draw_tab (f_len dwords)
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, f_len*4
        call    eos_dispatch
        mov     [rel draw_a8], edx


        ; selectors
        mov     eax, EOS_ALLOCATE_SELECTOR
        mov     esi, [rel map1]
        add     rsi, qword [rel Code32_addr]
        mov     edi, 320*200
        call    eos_dispatch
        mov     [rel map1_sel], ax

        mov     eax, EOS_ALLOCATE_SELECTOR
        mov     esi, [rel map2]
        add     rsi, qword [rel Code32_addr]
        mov     edi, 320*200
        call    eos_dispatch
        mov     [rel map2_sel], ax

        mov     eax, EOS_ALLOCATE_SELECTOR
        mov     esi, [rel scr_addr]
        add     rsi, qword [rel Code32_addr]
        mov     edi, 320*200
        call    eos_dispatch
        mov     [rel scr_sel], ax


        ; engine sort uses sort_addr (arena draw_tab) + faces
        mov     eax, [rel draw_a8]
        mov     [rel sort_addr], eax

        call    make_pos
        call    prepare

        ; sort_addr stays draw_tab; faces set per n_calc below; sort needs it
        mov     eax, [rel shape_a8]
        mov     [shape_addr], eax
        mov     eax, [rel n_src_a]
        mov     [n_addr], eax
        mov     eax, [rel n_add_a]
        mov     [inc_addr], eax
        mov     eax, [rel con_a8]
        add     eax, (40+48)*6            ; c3
        mov     [con_addr], eax
        mov     dword [rel points], 114
        mov     dword [rel faces], 224
        call    n_calc

        mov     eax, [rel shape_a8]
        add     eax, 114*6
        mov     [shape_addr], eax
        mov     eax, [rel n_src_a]
        add     eax, 114*6
        mov     [n_addr], eax
        mov     eax, [rel con_a8]
        add     eax, (40+48)*6 + 224*6   ; c4
        mov     [con_addr], eax
        mov     dword [rel points], 128
        mov     dword [rel faces], 256
        call    n_calc

        mov     eax, [rel shape_a8]
        add     eax, (114+128)*6
        mov     [shape_addr], eax
        mov     eax, [rel n_src_a]
        add     eax, (114+128)*6
        mov     [n_addr], eax
        mov     eax, [rel con_a8]
        add     eax, (40+48+224)*6 + 256*6 ; c5
        mov     [con_addr], eax
        mov     dword [rel points], 128
        mov     dword [rel faces], 256
        call    n_calc

        mov     dword [rel points], 114+128+128
        mov     eax, [rel n_vert_a]
        mov     [n_addr], eax
        mov     eax, [rel n_rot_a]
        mov     [nrot_addr], eax

        call    co_prepare
        call    make_pts

        ; build the working palette
        lea     rsi, [rel pal]
        lea     rdi, [rel pal+64*3]
        mov     bh, -2
        mov     bl, 4
        mov     dl, 6
        call    make_pal

        lea     rsi, [rel pal]
        lea     rdi, [rel pal+128*3]
        mov     bh, 1
        mov     bl, -1
        mov     dl, 3
        call    make_pal

        lea     rsi, [rel mpal]
        lea     rdi, [rel pal+192*3]
        mov     ecx, 64*3
        rep movsb

        ; snapshot platform keymap
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20
        extern vk_key_map_copy
        lea     rcx, [rel Key_Map]
        call    vk_key_map_copy
        mov     rsp, rbp
        pop     rbp

.main_loop:
        mov     eax, EOS_WAIT_VBL
        call    eos_dispatch
        mov     [rel frames], eax

        call    GetModPos

        cmp     word [rel ModPos], 2630h
        jl      .spad
        call    brum
.spad:
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
        ; load movement record: esi = ruchy + ruchy_ptr*36
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
        call    make_phong
        call    prep_rot1
        call    prep_rot2
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
        call    sloneczko
        call    control

        mov     eax, [rel frames]
        shl     eax, 2
        add     [rel ro_1], eax

        add     eax, [rel frames]
        add     eax, [rel frames]
        add     eax, [rel frames]
        add     [rel ro_2], eax

        mov     eax, [rel frames]
        shl     eax, 3
        sub     [rel ro_3], eax

        call    fade

        cmp     word [rel ModPos], 2700h
        jl      .main_loop

section .data
section .text

; ---- outtro -----------------------------------------------------------------
        lea     rsi, [rel white]
        call    pal_set

        mov     edi, [rel framebuffer_off]
        add     rdi, qword [rel Code32_addr]
        xor     eax, eax
        mov     ecx, 16000
        rep stosd

        mov     esi, [rel last_pic]
        add     rsi, qword [rel Code32_addr]
        mov     edi, [rel framebuffer_off]
        add     rdi, qword [rel Code32_addr]
        mov     ecx, (320*100)/4
        rep movsd

        mov     esi, [rel last_pal]
        add     rsi, qword [rel Code32_addr]
        call    pal_set

.wa1:
        call    GetModPos
        cmp     word [rel ModPos], 2705h
        jl      .wa1

        lea     rsi, [rel white]
        call    pal_set

        mov     esi, [rel last_pic]
        add     rsi, qword [rel Code32_addr]
        add     esi, 320*100
        mov     edi, [rel framebuffer_off]
        add     rdi, qword [rel Code32_addr]
        add     edi, 320*100
        mov     ecx, (320*60)/4
        rep movsd

        call    VSynch
        call    VSynch

        mov     esi, [rel last_pal]
        add     rsi, qword [rel Code32_addr]
        call    pal_set

.wa2:
        call    GetModPos
        cmp     word [rel ModPos], 2708h
        jl      .wa2

        lea     rsi, [rel white]
        call    pal_set

        mov     esi, [rel last_pic]
        add     rsi, qword [rel Code32_addr]
        add     esi, 320*160
        mov     edi, [rel framebuffer_off]
        add     rdi, qword [rel Code32_addr]
        add     edi, 320*160
        mov     ecx, (320*39)/4
        rep movsd

        mov     dword [rel ile_fade], 64

.lopa:
        mov     esi, [rel last_pal]
        add     rsi, qword [rel Code32_addr]
        lea     rdi, [rel white]
        mov     ebx, [rel ile_fade]
        mov     ecx, 768
.astroPIC:
        lodsb
        add     al, bl
        cmp     al, 0
        jge     .azxA
        xor     al, al
        jmp     .noaX
.azxA:
        cmp     al, 3fh
        jle     .noaX
        mov     al, 3fh
.noaX:
        stosb
        loop    .astroPIC

        lea     rsi, [rel white]
        call    pal_set

        dec     dword [rel ile_fade]
        cmp     dword [rel ile_fade], -4
        jge     .lopa

        mov     eax, EOS_STOP_MODULE
        call    eos_dispatch

        mov     dword [rel ile_fade], 0
.wait:
        mov     eax, EOS_WAIT_VBL
        call    eos_dispatch
        inc     dword [rel ile_fade]
        cmp     dword [rel ile_fade], 274
        jl      .wait

        mov     dword [rel ile_fade], 0
.hopla:
        mov     esi, [rel last_pal]
        add     rsi, qword [rel Code32_addr]
        lea     rdi, [rel white]
        mov     ebx, [rel ile_fade]
        mov     ecx, 768
.astroPIC2:
        lodsb
        sub     al, bl
        or      al, al
        jns     .bres
        xor     al, al
.bres:
        stosb
        loop    .astroPIC2

        lea     rsi, [rel white]
        call    pal_set

        inc     dword [rel ile_fade]
        cmp     dword [rel ile_fade], 64
        jle     .hopla

        mov     eax, EOS_DEALLOCATE_SELECTOR
        movzx   ebx, word [rel map1_sel]
        call    eos_dispatch
        mov     eax, EOS_DEALLOCATE_SELECTOR
        movzx   ebx, word [rel map2_sel]
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

%include "p8_rot.asm"
%include "p8_more.asm"
