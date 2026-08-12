; engine.asm - NASM x64 port of CODE/INC/ENGINE.ASM.
;
; Faithful port of the EOS vector engine: n_calc, sqrt, rotate_shape,
; rotate_normals, prep_sort, sort. All integer math keeps 32-bit operand
; widths so overflow/truncation semantics match the original exactly.
;
; Pointer model: the original stored "linear" addresses in 32-bit globals
; (shape_addr, srot_addr, n_addr, nrot_addr, inc_addr, con_addr) and added
; Code32_addr when dereferencing. Here those globals hold arena offsets and
; the routines add the qword Code32_addr base before use.
;
; ABI: callee-saved rbx,rsi,rdi,r12-r15,rbp preserved; all routines are
; called from NASM only (no C) so register use is per the original where
; practical. Only EOS dispatch goes through eos_dispatch (MS x64 ABI) and
; must keep RSP%16==0 at that call.

BITS 64
DEFAULT REL

%include "eos.inc"

%define drawers 1200

extern Code32_addr
extern sinus          ; 1024-entry word sine (generated sin8.asm)
extern len
extern eos_dispatch

section .bss align=16
; exports (mirror the original PUBLIC surface)
global shape_addr
global srot_addr
global n_addr
global nrot_addr
global inc_addr
global con_addr
global sort_addr
global points
global faces
global r_x
global r_y
global r_z

shape_addr:  resd 1
srot_addr:   resd 1
n_addr:      resd 1
nrot_addr:   resd 1
inc_addr:    resd 1
con_addr:    resd 1
sort_addr:   resd 1
points:      resd 1
faces:       resd 1
r_x:         resw 1
r_y:         resw 1
r_z:         resw 1

x1: resd 1
y1: resd 1
z1: resd 1
x2: resd 1
y2: resd 1
z2: resd 1
x3: resd 1
y3: resd 1
z3: resd 1
n_x: resd 1
n_y: resd 1
n_z: resd 1
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

sort_mem: resd 1
global addr_tab
global sort_mem
addr_tab: resq 16           ; 64-bit pointers into the sort scratch
tab_len:  resd 16

section .text

; ======================================================================= sqrt
; in:  eax
; out: ecx = floor(sqrt(eax))
global sqrt
sqrt:
        push    rbp
        mov     rbp, rsp
        push    rbx
        sub     rsp, 0x20
        mov     ebp, eax
        bsr     ecx, eax
        shr     cl, 1
        shr     eax, cl
        mov     ecx, eax
        xor     edx, edx
        mov     eax, ebp
        div     ecx
        add     ecx, eax
        shr     ecx, 1
        xor     edx, edx
        mov     eax, ebp
        div     ecx
        add     ecx, eax
        shr     ecx, 1
        xor     edx, edx
        mov     eax, ebp
        div     ecx
        add     ecx, eax
        shr     ecx, 1
        add     rsp, 0x20
        pop     rbx
        pop     rbp
        ret

; ===================================================================== n_calc
; n_calc - compute per-vertex normals by accumulating per-face cross products.
; Uses shape_addr / con_addr / n_addr / inc_addr / points / faces.
global n_calc
n_calc:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15
        ; n_calc decrements the points/faces globals in its loops (mirroring
        ; the original `push points faces` / `pop faces points`); stash them
        ; in r15 + a stack slot (r10/r11/r8/r9 are clobbered by the normalize
        ; step below, so they can't hold the saved values).
        mov     r15d, dword [rel points]
        mov     eax, dword [rel faces]
        push    rax                     ; saved faces (16 bytes below rbp area)
        sub     rsp, 0x28

        ; inc_addr (word counts) = 0
        mov     eax, [rel inc_addr]
        add     rax, qword [rel Code32_addr]
        mov     rdi, rax
        xor     eax, eax
        mov     ecx, [rel points]
        rep stosw

        ; rsi = con_addr (6-byte faces)
        mov     eax, [rel con_addr]
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        ; r14 = shape_addr real
        mov     eax, [rel shape_addr]
        add     rax, qword [rel Code32_addr]
        mov     r14, rax
        ; r13 = n_addr real
        mov     eax, [rel n_addr]
        add     rax, qword [rel Code32_addr]
        mov     r13, rax
        ; r12 = inc_addr real
        mov     eax, [rel inc_addr]
        add     rax, qword [rel Code32_addr]
        mov     r12, rax

.calc_1:
        ; ---- face vertex 1 ----
        movzx   eax, word [rsi]
        lea     ebx, [rax*2+rax]
        add     rbx, r14
        movsx   eax, word [rbx]
        sar     eax, 4
        mov     [rel x1], eax
        movsx   eax, word [rbx+2]
        sar     eax, 4
        mov     [rel y1], eax
        movsx   eax, word [rbx+4]
        sar     eax, 4
        mov     [rel z1], eax

        ; ---- face vertex 2 ----
        movzx   eax, word [rsi+2]
        lea     ebx, [rax*2+rax]
        add     rbx, r14
        movsx   eax, word [rbx]
        sar     eax, 4
        mov     [rel x2], eax
        movsx   eax, word [rbx+2]
        sar     eax, 4
        mov     [rel y2], eax
        movsx   eax, word [rbx+4]
        sar     eax, 4
        mov     [rel z2], eax

        ; ---- face vertex 3 ----
        movzx   eax, word [rsi+4]
        lea     ebx, [rax*2+rax]
        add     rbx, r14
        movsx   eax, word [rbx]
        sar     eax, 4
        mov     [rel x3], eax
        movsx   eax, word [rbx+2]
        sar     eax, 4
        mov     [rel y3], eax
        movsx   eax, word [rbx+4]
        sar     eax, 4
        mov     [rel z3], eax

        ; ---- cross product (matches original arithmetic exactly) ----
        mov     eax, [rel y2]
        sub     eax, [rel y1]
        mov     ebp, [rel z3]
        sub     ebp, [rel z1]
        imul    ebp                     ; edx:eax = (y2-y1)(z3-z1)
        mov     ebx, eax
        mov     eax, [rel y3]
        sub     eax, [rel y1]
        mov     ebp, [rel z2]
        sub     ebp, [rel z1]
        imul    ebp
        sub     ebx, eax
        neg     ebx
        mov     [rel n_x], ebx

        mov     eax, [rel x2]
        sub     eax, [rel x1]
        mov     ebp, [rel z3]
        sub     ebp, [rel z1]
        imul    ebp
        mov     ebx, eax
        mov     eax, [rel x3]
        sub     eax, [rel x1]
        mov     ebp, [rel z2]
        sub     ebp, [rel z1]
        imul    ebp
        sub     ebx, eax
        mov     [rel n_y], ebx

        mov     eax, [rel y2]
        sub     eax, [rel y1]
        mov     ebp, [rel x3]
        sub     ebp, [rel x1]
        imul    ebp
        mov     ebx, eax
        mov     eax, [rel y3]
        sub     eax, [rel y1]
        mov     ebp, [rel x2]
        sub     ebp, [rel x1]
        imul    ebp
        sub     ebx, eax
        neg     ebx
        mov     [rel n_z], ebx

        ; ---- normalize ----
        mov     eax, [rel n_x]
        imul    eax, eax
        mov     ebx, [rel n_y]
        imul    ebx, ebx
        mov     ecx, [rel n_z]
        imul    ecx, ecx
        add     eax, ebx
        add     eax, ecx
        jnz     .skip
        mov     ecx, [rel len]
        jmp     .cont
.skip:
        call    sqrt                    ; ecx = sqrt(...)
.cont:
        mov     ebx, [rel len]
        mov     eax, [rel n_x]
        imul    ebx
        idiv    ecx
        mov     [rel n_x], ax
        mov     eax, [rel n_y]
        imul    ebx
        idiv    ecx
        mov     [rel n_y], ax
        mov     eax, [rel n_z]
        imul    ebx
        idiv    ecx
        mov     [rel n_z], ax

        ; ---- accumulate into the three vertices ----
        ; keep the normalized normal (signed 16-bit) in r8w/r9w/r10w
        movzx   r8d, word [rel n_x]
        movzx   r9d, word [rel n_y]
        movzx   r10d, word [rel n_z]

        %macro ACCUM 1          ; ACCUM face_word_offset (0/2/4)
        movzx   ebp, word [rsi + %1]
        inc     word [r12 + rbp]        ; original: byte-offset inc table
        lea     ebx, [rbp*2+rbp]
        add     rbx, r13
        add     [rbx], r8w
        add     [rbx+2], r9w
        add     [rbx+4], r10w
        %endmacro
        ACCUM 0
        ACCUM 2
        ACCUM 4

        add     rsi, 6
        dec     dword [rel faces]
        jne     .calc_1

        ; ---- finalize: divide each normal sum by its count ----
        mov     ecx, [rel points]       ; vertex count
.fin_loop:
        mov     bx, [r12]               ; incidence
        or      bx, bx
        jz      .zero
        mov     ax, [r13]
        cwd
        idiv    bx
        mov     [r13], ax
        mov     ax, [r13+2]
        cwd
        idiv    bx
        mov     [r13+2], ax
        mov     ax, [r13+4]
        cwd
        idiv    bx
        mov     [r13+4], ax
.zero:
        add     r12, 2
        add     r13, 6
        dec     ecx
        jne     .fin_loop

        ; restore the points/faces globals (see prologue)
        mov     [rel points], r15d
        mov     eax, [rsp+0x28]         ; saved faces (right above our frame)
        mov     [rel faces], eax

        add     rsp, 0x28
        pop     rax                     ; saved faces slot
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ================================================================== rot-matrix
; Build the 3x3 rotation matrix in ob1..ob9 from r_x/r_y/r_z (16-bit angles,
; masked to 0..1023) using the word sine table. Mirrors the original exactly.
build_matrix:
        ; rsi = sinus
        lea     rsi, [rel sinus]

        movsx   ebx, word [rel r_x]
        and     ebx, 0x3ff
        movsx   eax, word [rsi + rbx*2]
        mov     [rel s_x], eax
        movsx   eax, word [rsi + 512 + rbx*2]
        mov     [rel c_x], eax

        movsx   ebx, word [rel r_y]
        and     ebx, 0x3ff
        movsx   eax, word [rsi + rbx*2]
        mov     [rel s_y], eax
        movsx   eax, word [rsi + 512 + rbx*2]
        mov     [rel c_y], eax

        movsx   ebx, word [rel r_z]
        and     ebx, 0x3ff
        movsx   eax, word [rsi + rbx*2]
        mov     [rel s_z], eax
        movsx   eax, word [rsi + 512 + rbx*2]
        mov     [rel c_z], eax

        ; ob1 = c_y * c_z >> 15
        mov     eax, [rel c_y]
        imul    dword [rel c_z]
        sar     eax, 15
        mov     [rel ob1], eax
        ; ob2 = (c_x*s_z - s_x*s_y*c_z) >> 15
        mov     eax, [rel c_x]
        imul    dword [rel s_z]
        mov     ebx, [rel s_x]
        imul    ebx, dword [rel s_y]
        sar     ebx, 15
        imul    ebx, dword [rel c_z]
        sub     ebx, eax
        sar     ebx, 15
        mov     [rel ob2], ebx
        ; ob3 = (s_x*s_z + c_x*s_y*c_z) >> 15
        mov     eax, [rel s_x]
        imul    dword [rel s_z]
        mov     ebx, [rel c_x]
        imul    ebx, dword [rel s_y]
        sar     ebx, 15
        imul    ebx, dword [rel c_z]
        add     ebx, eax
        sar     ebx, 15
        mov     [rel ob3], ebx
        ; ob4 = c_y * s_z >> 15
        mov     eax, [rel c_y]
        imul    dword [rel s_z]
        sar     eax, 15
        mov     [rel ob4], eax
        ; ob5 = (c_x*c_z + s_x*s_y*s_z) >> 15
        mov     eax, [rel c_x]
        imul    dword [rel c_z]
        mov     ebx, [rel s_x]
        imul    ebx, dword [rel s_y]
        sar     ebx, 15
        imul    ebx, dword [rel s_z]
        add     ebx, eax
        sar     ebx, 15
        mov     [rel ob5], ebx
        ; ob6 = (s_x*c_z - c_x*s_y*s_z) >> 15
        mov     eax, [rel s_x]
        imul    dword [rel c_z]
        mov     ebx, [rel c_x]
        imul    ebx, dword [rel s_y]
        sar     ebx, 15
        imul    ebx, dword [rel s_z]
        sub     ebx, eax
        sar     ebx, 15
        mov     [rel ob6], ebx
        ; ob7 = -s_y
        mov     eax, [rel s_y]
        neg     eax
        mov     [rel ob7], eax
        ; ob8 = s_x * c_y >> 15
        mov     eax, [rel s_x]
        imul    dword [rel c_y]
        sar     eax, 15
        mov     [rel ob8], eax
        ; ob9 = c_x * c_y >> 15
        mov     eax, [rel c_x]
        imul    dword [rel c_y]
        sar     eax, 15
        mov     [rel ob9], eax
        ret

; ============================================================== rotate_shape
; rotate_shape - rotate vertex table (6 bytes/vertex) -> srot_addr,
;               points vertices. Uses shape_addr/srot_addr/points.
global rotate_shape
rotate_shape:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        sub     rsp, 0x20
        call    build_matrix
        mov     eax, [rel shape_addr]
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        mov     eax, [rel srot_addr]
        add     rax, qword [rel Code32_addr]
        mov     rdi, rax
        mov     ecx, [rel points]
.ro_1:
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
        mov     [rdi+4], bp

        add     rsi, 6
        add     rdi, 6
        dec     ecx
        jnz     .ro_1

        add     rsp, 0x20
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; =========================================================== rotate_normals
; rotate_normals - rotate normals (4 bytes/vertex) -> nrot_addr,
;                  using ob1..ob6. Uses n_addr/nrot_addr/points.
global rotate_normals
rotate_normals:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        sub     rsp, 0x20
        call    build_matrix
        mov     eax, [rel n_addr]
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        mov     eax, [rel nrot_addr]
        add     rax, qword [rel Code32_addr]
        mov     rdi, rax
        mov     ecx, [rel points]
.ro_2:
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
        jnz     .ro_2

        add     rsp, 0x20
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ========================================================= prep_sort / sort

; prep_sort - allocate sort scratch (16 * drawers dwords via EOS memory) and
; build addr_tab (the original did both inside prep_sort).
global prep_sort
prep_sort:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rdi
        sub     rsp, 0x20
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, drawers*16*4
        call    eos_dispatch
        mov     [rel sort_mem], edx
        ; build addr_tab: each entry = sort_mem + k*drawers*4
        lea     rdi, [rel addr_tab]
        mov     eax, [rel sort_mem]
        add     rax, qword [rel Code32_addr]
        mov     ecx, 16
.make_addr:
        mov     [rdi], rax
        add     rdi, 8
        add     rax, drawers*4
        dec     ecx
        jnz     .make_addr
        add     rsp, 0x20
        pop     rdi
        pop     rbx
        pop     rbp
        ret

; sort - radix sort of `faces` values at sort_addr using 4 passes of 4 bits.
; Each pass is emitted as a macro so its local labels are unique per pass.
%macro SORT_PASS 1          ; %1 = bit shift
        ; clear tab_len
        lea     rdi, [rel tab_len]
        xor     eax, eax
        mov     ecx, 16
        rep stosd
        ; first pass: count + scatter
        ; (tab_len/addr_tab are .bss data - use register bases, not [sym+index],
        ;  to avoid ADDR32 relocations to high VA .bss)
        lea     r14, [rel tab_len]
        lea     r15, [rel addr_tab]
        mov     eax, [rel sort_addr]
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        mov     ecx, [rel faces]
%%main_sort_loop:
        lodsd
        mov     ebx, eax
        shr     ebx, %1
        and     ebx, 0x0f
        mov     edx, [r14 + rbx*4]
        inc     dword [r14 + rbx*4]
        mov     rdi, [r15 + rbx*8]
        mov     [rdi + rdx*4], eax
        dec     ecx
        jnz     %%main_sort_loop
        ; distribute back
        lea     rbx, [rel tab_len]
        mov     eax, [rel sort_mem]
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        mov     eax, [rel sort_addr]
        add     rax, qword [rel Code32_addr]
        mov     rdi, rax
        mov     bp, 16
%%norm:
        push    rsi
        mov     ecx, [rbx]
        or      cx, cx
        jz      %%skip
        rep movsd
%%skip:
        pop     rsi
        add     rbx, 4
        add     rsi, drawers*4
        dec     bp
        jnz     %%norm
%endmacro

global sort
sort:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r14
        push    r15
        sub     rsp, 0x30
        SORT_PASS 0
        SORT_PASS 4
        SORT_PASS 8
        SORT_PASS 12
        add     rsp, 0x30
        pop     r15
        pop     r14
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

