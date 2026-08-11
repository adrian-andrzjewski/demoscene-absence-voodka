; p2draw.asm - native x64 port of OBJECTS.PM DrawObject / DrawZielonyLudek,
; the per-object rasterizer used by the swiatynia city (P2) (and torus ustep village (P5)) render loop.
;
; Object struct (21 dwords, base-relative) matches loader.asm:
;   +0 type +4 nov +8 nof ... +36 vertexes +40 faces +44 textures
;   +48 normals +52 wersory +60 copy-vert +64 copy-wersory +72 texsel(word)
;   +76 2d-pts (wsp2d) +80 order.
;
; DrawObject: persp(copy-vert -> wsp2d, nov) then DrawZielonyLudek.
;   type 0 (PIXELS): pixel2d over wsp2d (color 64, screen=backbuffer).
;   type 1 (TEXTURE): walk `order` (kolej) face indices; texel from
;       textures(+44), per-vertex stride 8 bytes, shl8 -> p_1/2/3.
;   type 2 (PHONG):   same walk; texel from copy-wersory(+64), per-vertex
;       stride 12 bytes, /2 + 128 -> p_1/2/3.
;   For each face (1/2): set x_1..3/y_1..3/p_1..3 from the 3 face vertex
;   indices, z-clip each against ZetVisible(=1) via copy-vert, then a 16-bit
;   backface test (isvisible); skip when visible==1; then tm_face.
;
; Records (trace): per order entry a 10-dword record
;   { drawn, x1,y1,x2,y2,x3,y3, p1,p2,p3 } = 40 bytes.
;
; ABI prologue: 7 pushes + sub 0x20 -> RSP%16==0 at call sites.

BITS 64
DEFAULT REL

%include "eos.inc"

extern vk_persp
extern x_1, y_1, x_2, y_2, x_3, y_3
extern p_1, p_2, p_3
extern tm_face
extern fs_sel, gs_sel
extern Code32_addr
extern addr_tab

section .bss align=16
pz_base:  resq 1
pz_rec:   resq 1          ; record cursor (0 = real mode)
pz_tex:   resq 1          ; real texel table ptr
pz_copy:  resq 1          ; real copy-vert ptr
pz_wsp:   resq 1          ; real wsp2d ptr
pz_mode:  resd 1          ; 1=texture(shl8), 0=phong(/2+128)
pz_skip:  resb 1          ; face abort flag (z-clip fail)
pz_vis:   resb 1          ; isvisible result
pz_cnt:   resq 1          ; face loop counter
pz_aface: resq 1          ; real aFaces ptr
pz_order: resq 1          ; real order ptr
pz_slen:  resd 16         ; pz_sort bucket counters

section .text

; ---------------------------------------------------------------------------
global vk_draw_object
; void vk_draw_object(uint8_t* base, uint32_t objOff)
vk_draw_object:
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0x28
        mov     qword [pz_rec], 0
        jmp     pz_common

global vk_draw_object_trace
; void vk_draw_object_trace(uint8_t* base, uint32_t objOff, int32_t* rec)
vk_draw_object_trace:
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0x28
        mov     [pz_rec], r8
        ; fall through

pz_common:
        mov     [pz_base], rcx
        mov     eax, edx
        lea     r13, [rcx + rax]        ; r13 = real object ptr

        ; ---- project copy-vert(nov) -> wsp2d ----
        ; vk_persp(src, dst, count): rcx=copy-vert real, rdx=wsp2d real, r8d=nov
        mov     rax, [pz_base]
        mov     ebx, [r13 + 60]         ; copy-vert offset
        lea     rcx, [rax + rbx]
        mov     ebx, [r13 + 76]         ; wsp2d offset
        lea     rdx, [rax + rbx]
        mov     r8d, [r13 + 4]          ; nov
        call    vk_persp

        ; ---- dispatch ----
        mov     eax, [r13 + 0]
        cmp     eax, 0
        je      pz_zpierniczkow
        cmp     eax, 1
        jne     .phong
        mov     dword [pz_mode], 1
        jmp     pz_walk
.phong:
        mov     dword [pz_mode], 0
        jmp     pz_walk

; ------------------------------------------------------------ type 0 --------
pz_zpierniczkow:
        mov     rdi, [pz_base]
        add     rdi, 0x10000            ; backbuffer screen base
        mov     esi, [r13 + 76]
        add     rsi, [pz_base]
        mov     ecx, [r13 + 4]          ; nov
        mov     al, 64                  ; colorPixla
        lea     r10, [rel pz_pom]
.pL:
        push    rcx
        mov     ebx, [rsi]
        mov     edx, [rsi + 4]
        cmp     ebx, 0
        jl      .skip
        cmp     ebx, 319
        jg      .skip
        cmp     edx, 0
        jl      .skip
        cmp     edx, 199
        jg      .skip
        mov     r11d, [r10 + rdx*4]
        add     r11d, ebx
        mov     byte [rdi + r11], al
.skip:
        pop     rcx
        add     rsi, 8
        dec     ecx
        jnz     .pL
        jmp     pz_end

; ----------------------------------------------- face walk (types 1/2) ------
pz_walk:
        ; resolve shared arena pointers
        mov     rax, [pz_base]
        mov     ebx, [r13 + 40]         ; aFaces
        lea     rsi, [rax + rbx]
        mov     [pz_aface], rsi
        mov     ebx, [r13 + 76]         ; wsp2d
        lea     rsi, [rax + rbx]
        mov     [pz_wsp], rsi
        mov     ebx, [r13 + 60]         ; copy-vert
        lea     rsi, [rax + rbx]
        mov     [pz_copy], rsi
        cmp     dword [pz_mode], 1
        jne     .ptex
        mov     ebx, [r13 + 44]         ; textures
        jmp     .ptab
.ptex:
        mov     ebx, [r13 + 64]         ; copy-wersory
.ptab:
        lea     rsi, [rax + rbx]
        mov     [pz_tex], rsi
        mov     ebx, [r13 + 80]         ; order
        lea     rsi, [rax + rbx]
        mov     [pz_order], rsi

        mov     eax, [r13 + 8]          ; nof
        mov     [pz_cnt], rax

        ; per-face painter's sort (BITSORT.PM Sort, called by DrawZielonyLudek
        ; for both texture and phong objects before walking the order table)
        call    pz_sort

.face_loop:
        mov     rax, [pz_cnt]
        test    rax, rax
        jz      pz_end
        dec     qword [pz_cnt]

        ; face index from order table
        mov     r15, [pz_order]
        mov     ebx, [r15]              ; = face index
        add     qword [pz_order], 4
        lea     edx, [rbx + rbx*2]      ; *3
        shl     edx, 2                  ; *12 byte offset into aFaces
        mov     r14, [pz_aface]
        mov     r12d, edx               ; keep face byte offset (callee-preserved r12)

        mov     byte [pz_skip], 0

        ; ---- vertex 0 ----
        mov     ebx, [r14 + r12]
        mov     rcx, 0
        call    pz_vertex
        ; ---- vertex 1 ----
        mov     ebx, [r14 + r12 + 4]
        mov     rcx, 1
        call    pz_vertex
        ; ---- vertex 2 ----
        mov     ebx, [r14 + r12 + 8]
        mov     rcx, 2
        call    pz_vertex

        mov     al, [pz_skip]
        test    al, al
        jnz     .notdrawn

        ; ---- backface (isvisible); skip when visible==1 ----
        call    pz_isvisible
        cmp     byte [pz_vis], 1
        je      .notdrawn

        ; ---- emit (record or tm_face) ----
        mov     rdi, [pz_rec]
        test    rdi, rdi
        jz      .dotm
        mov     dword [rdi + 0], 1
        mov     ecx, [x_1]
        mov     [rdi + 4], ecx
        mov     ecx, [y_1]
        mov     [rdi + 8], ecx
        mov     ecx, [x_2]
        mov     [rdi + 12], ecx
        mov     ecx, [y_2]
        mov     [rdi + 16], ecx
        mov     ecx, [x_3]
        mov     [rdi + 20], ecx
        mov     ecx, [y_3]
        mov     [rdi + 24], ecx
        mov     ecx, [p_1]
        mov     [rdi + 28], ecx
        mov     ecx, [p_2]
        mov     [rdi + 32], ecx
        mov     ecx, [p_3]
        mov     [rdi + 36], ecx
        add     rdi, 40
        mov     [pz_rec], rdi
        jmp     .next
.dotm:
        ; NOTE: fs_sel was already set by the caller (vk_vr_world_render_frame sets it
        ; from the world record's type -> textury[type]). The original
        ; DrawObject does not set fs here; the render loop does, per object.
        ; We must NOT override it with the object's own +72 tex-sel, or the
        ; texture selector chosen by the world type would be lost.
        call    tm_face
        jmp     .next
.notdrawn:
        mov     rdi, [pz_rec]
        test    rdi, rdi
        jz      .next
        mov     dword [rdi + 0], 0
        mov     dword [rdi + 4], 0
        mov     dword [rdi + 8], 0
        mov     dword [rdi + 12], 0
        mov     dword [rdi + 16], 0
        mov     dword [rdi + 20], 0
        mov     dword [rdi + 24], 0
        mov     dword [rdi + 28], 0
        mov     dword [rdi + 32], 0
        mov     dword [rdi + 36], 0
        add     rdi, 40
        mov     [pz_rec], rdi
.next:
        jmp     .face_loop

; ------------------------------------------------- per-face painter sort ----
; Faithful port of BITSORT.PM Sort (DrawZielonyLudek calls it for texture and
; phong objects alike): per face,
;   sumz16 = lo16(z1>>4)+lo16(z2>>4)+lo16(z3>>4) + 15000 (SortAdd), z from
;   copy-vert[face*12+8]; pack (faceIdx<<16)|sumz16 into the order table
;   (+80); radix sort DESCENDING by sumz16 (4 x 4-bit passes, buckets gathered
;   15..0 = far->near); then NaGut (shr eax,16 in place) leaves plain face
;   indices far->near. Uses the engine's addr_tab/sort_mem scratch, so
;   prep_sort must have run at part init (P2.AS^ calls SortMem likewise).
%macro PZ_SORT_PASS 1
        lea     rdi, [rel pz_slen]
        xor     eax, eax
        mov     ecx, 16
        rep stosd
        mov     esi, [r13 + 80]         ; order offset
        add     rsi, qword [rel Code32_addr]
        mov     ecx, [r13 + 8]          ; nof
        lea     r14, [rel pz_slen]
        lea     r15, [rel addr_tab]
%%scatter:
        lodsd
        mov     ebx, eax
        shr     ebx, %1
        and     ebx, 0x0f
        mov     edx, [r14 + rbx*4]
        inc     dword [r14 + rbx*4]
        mov     rdi, [r15 + rbx*8]
        mov     [rdi + rdx*4], eax
        dec     ecx
        jnz     %%scatter
        ; gather buckets 15..0 back into the order table (descending keys)
        mov     edi, [r13 + 80]
        add     rdi, qword [rel Code32_addr]
        mov     r12d, 15
%%gather:
        lea     rax, [rel pz_slen]
        mov     ecx, [rax + r12*4]
        or      ecx, ecx
        jz      %%gnext
        lea     rax, [rel addr_tab]
        mov     rsi, [rax + r12*8]
        rep movsd
%%gnext:
        dec     r12d
        jns     %%gather
%endmacro

pz_sort:
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r14
        push    r15

        ; ---- SumZ packing (BITSORT SumZ): entry = (i<<16) | sumz16 ----
        mov     rsi, [pz_aface]         ; faces
        mov     rdx, [pz_copy]          ; copy-vert
        mov     rdi, [pz_order]         ; order/sumZ buffer (+80)
        mov     ecx, [r13 + 8]          ; nof
        xor     ebx, ebx
.sumz:
        mov     eax, [rsi]              ; face[0]
        lea     eax, [eax*2 + eax]
        mov     r8d, [rdx + rax*4 + 8]
        sar     r8d, 4
        mov     bx, r8w                 ; low16(z1>>4)
        mov     eax, [rsi + 4]          ; face[1]
        lea     eax, [eax*2 + eax]
        mov     r8d, [rdx + rax*4 + 8]
        sar     r8d, 4
        add     bx, r8w
        mov     eax, [rsi + 8]          ; face[2]
        lea     eax, [eax*2 + eax]
        mov     r8d, [rdx + rax*4 + 8]
        sar     r8d, 4
        add     bx, r8w
        add     bx, 15000               ; SortAdd
        mov     [rdi], ebx
        add     rdi, 4
        add     rsi, 12
        add     ebx, 010000h            ; next face index in the high word
        dec     ecx
        jnz     .sumz

        PZ_SORT_PASS 0
        PZ_SORT_PASS 4
        PZ_SORT_PASS 8
        PZ_SORT_PASS 12

        ; ---- NaGut: plain face indices far->near ----
        mov     esi, [r13 + 80]
        add     rsi, qword [rel Code32_addr]
        mov     rdi, rsi
        mov     ecx, [r13 + 8]
.nagut:
        lodsd
        shr     eax, 16
        stosd
        dec     ecx
        jnz     .nagut

        pop     r15
        pop     r14
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        ret

; ------------------------------------------------- single vertex ------------
; in: ebx = vertex index, rcx = slot (0/1/2), pz_wsp/pz_tex/pz_copy set.
; Sets the matching x_?/y_? from wsp2d[v*8], p_? from texel table,
; z-clips copy-vert[v*12+8] < 1 -> sets pz_skip.
;
; NOTE: txtr.asm's globals are NOT uniformly laid out (x_1,x_s,y_1,p_1,
; x_2,y_2,p_2,x_3,y_3,p_3), so each slot uses explicit label targets.
pz_vertex:
        push    rbx
        push    rsi
        push    rdi
        push    r8
        push    r9
        push    rcx
        cmp     rcx, 1
        je      .v1
        cmp     rcx, 2
        je      .v2
        lea     rsi, [rel x_1]
        lea     rdi, [rel y_1]
        lea     r8, [rel p_1]
        jmp     .have
.v1:
        lea     rsi, [rel x_2]
        lea     rdi, [rel y_2]
        lea     r8, [rel p_2]
        jmp     .have
.v2:
        lea     rsi, [rel x_3]
        lea     rdi, [rel y_3]
        lea     r8, [rel p_3]
.have:
        ; x,y from wsp2d[v*8]
        mov     r9, [pz_wsp]
        movsxd  rcx, ebx
        lea     rcx, [rcx*8]            ; v*8 bytes
        mov     eax, [r9 + rcx]
        mov     [rsi], eax
        mov     eax, [r9 + rcx + 4]
        mov     [rdi], eax

        ; ---- texel ----
        mov     r9, [pz_tex]
        cmp     dword [pz_mode], 1
        je      .tex_t
        ; phong: stride 12, /2+128; each <<8 kept as 16-bit (mov w [p],cx)
        movsxd  rcx, ebx
        lea     rcx, [rcx + rcx*2]      ; v*3
        shl     rcx, 2                  ; v*12
        mov     eax, [r9 + rcx]
        sar     eax, 1
        add     eax, 128
        shl     eax, 8
        movzx   edx, ax                 ; low word (u)
        mov     eax, [r9 + rcx + 4]
        sar     eax, 1
        add     eax, 128
        shl     eax, 8
        and     eax, 0xffff
        shl     eax, 16
        or      edx, eax
        mov     [r8], edx
        jmp     .zclip
.tex_t:
        ; texture: stride 8, shl8; each component 16-bit
        movsxd  rcx, ebx
        lea     rcx, [rcx*2]            ; v*2
        shl     rcx, 2                  ; v*8
        mov     eax, [r9 + rcx]
        shl     eax, 8
        movzx   edx, ax                 ; low word (u)
        mov     eax, [r9 + rcx + 4]
        shl     eax, 8
        and     eax, 0xffff
        shl     eax, 16
        or      edx, eax
        mov     [r8], edx
.zclip:
        ; copy-vert[v*12 + 8] < 1 -> skip
        mov     r9, [pz_copy]
        movsxd  rcx, ebx
        lea     rcx, [rcx + rcx*2]
        shl     rcx, 2                  ; v*12
        mov     eax, [r9 + rcx + 8]     ; z
        cmp     eax, 1
        jge     .keep
        mov     byte [pz_skip], 1
.keep:
        pop     rcx
        pop     r9
        pop     r8
        pop     rdi
        pop     rsi
        pop     rbx
        ret

; --------------------------------------------------------- backface ----------
; 16-bit isvisible: reads x_1..y_3 (word), sets pz_vis=1 when not culled.
pz_isvisible:
        push    rbx
        push    rcx
        mov     byte [pz_vis], 0
        mov     ax, word [y_2]
        sub     ax, word [y_1]
        mov     bx, word [x_3]
        sub     bx, word [x_1]
        imul    ax, bx
        mov     cx, ax
        mov     ax, word [y_3]
        sub     ax, word [y_1]
        mov     bx, word [x_2]
        sub     bx, word [x_1]
        imul    ax, bx
        sub     cx, ax
        neg     cx
        js      .novis
        mov     byte [pz_vis], 1
.novis:
        pop     rcx
        pop     rbx
        ret

pz_end:
        add     rsp, 0x28
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        ret

section .data align=16
pz_pom:
%assign t 0
%rep 200
        dd t
        %assign t t+320
%endrep

section .note.GNU-stack noalloc noexec nowrite progbits
