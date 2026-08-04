section .text

; ===================== prepare ================================================
prepare:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        sub     rsp, 0x20
        ; con1 (40*3): double each word
        mov     eax, [rel con_a8]
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        mov     rdi, rax
        mov     ecx, 40*3
.pr_lo1:
        lodsw
        add     ax, ax
        stosw
        loop    .pr_lo1
        ; c2 (48*3)
        mov     eax, [rel con_a8]
        add     eax, 40*6
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        mov     rdi, rax
        mov     ecx, 48*3
.pr_lo2:
        lodsw
        add     ax, 40
        add     ax, ax
        stosw
        loop    .pr_lo2
        ; c3..c5 (224+256+256)*3
        mov     eax, [rel con_a8]
        add     eax, (40+48)*6
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        mov     rdi, rax
        mov     ecx, (224+256+256)*3
.pr_lo3:
        lodsw
        add     ax, ax
        stosw
        loop    .pr_lo3
        ; c6 (40*3)
        mov     eax, [rel con_a8]
        add     eax, (40+48+224+256+256)*6
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        mov     rdi, rax
        mov     ecx, 40*3
.pr_lo4:
        lodsw
        add     ax, 40+33+114+128+128
        add     ax, ax
        stosw
        loop    .pr_lo4
        ; s6 (module static): 40 verts, y -= 1620
        lea     rsi, [rel s6]
        mov     rdi, rsi
        mov     ecx, 40
.as:
        movsw
        lodsw
        sub     ax, 1620
        stosw
        movsw
        loop    .as
        add     rsp, 0x20
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ===================== co_prepare ============================================
co_prepare:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        sub     rsp, 0x20
        ; c3 (224*3)
        mov     eax, [rel con_a8]
        add     eax, (40+48)*6
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        mov     rdi, rax
        mov     ecx, 224*3
.copr_lo1:
        lodsw
        add     ax, (40+33)*2
        stosw
        loop    .copr_lo1
        ; c4 (256*3)
        mov     eax, [rel con_a8]
        add     eax, (40+48+224)*6
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        mov     rdi, rax
        mov     ecx, 256*3
.copr_lo2:
        lodsw
        add     ax, (40+33+114)*2
        stosw
        loop    .copr_lo2
        ; c5 (256*3)
        mov     eax, [rel con_a8]
        add     eax, (40+48+224+256)*6
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        mov     rdi, rax
        mov     ecx, 256*3
.copr_lo3:
        lodsw
        add     ax, (40+33+114+128)*2
        stosw
        loop    .copr_lo3
        ; s3 (module static): 114 verts, y -= 640
        lea     rsi, [rel s3]
        mov     rdi, rsi
        mov     ecx, 114
.copr_lo4:
        movsw
        lodsw
        add     ax, -640
        stosw
        movsw
        loop    .copr_lo4
        add     rsp, 0x20
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ===================== make_pts ==============================================
make_pts:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        sub     rsp, 0x20
        ; con1 (all faces, arena) ; pts_tab
        mov     eax, [rel con_a8]
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
        lea     rdi, [rel pts_tab]
        mov     bx, 3
        mov     ecx, f_len
.calc_pts:
        movzx   ebp, word [rsi]
        lea     r12d, [ebp*2+ebp]
        lea     r13, [rel shape]
        mov     ax, word [r13+r12]
        movzx   ebp, word [rsi+2]
        lea     r12d, [ebp*2+ebp]
        add     ax, word [r13+r12]
        movzx   ebp, word [rsi+4]
        lea     r12d, [ebp*2+ebp]
        add     ax, word [r13+r12]
        cwd
        idiv    bx
        stosw
        movzx   ebp, word [rsi]
        lea     r12d, [ebp*2+ebp]
        mov     ax, word [r13+r12+2]
        movzx   ebp, word [rsi+2]
        lea     r12d, [ebp*2+ebp]
        add     ax, word [r13+r12+2]
        movzx   ebp, word [rsi+4]
        lea     r12d, [ebp*2+ebp]
        add     ax, word [r13+r12+2]
        cwd
        idiv    bx
        stosw
        movzx   ebp, word [rsi]
        lea     r12d, [ebp*2+ebp]
        mov     ax, word [r13+r12+4]
        movzx   ebp, word [rsi+2]
        lea     r12d, [ebp*2+ebp]
        add     ax, word [r13+r12+4]
        movzx   ebp, word [rsi+4]
        lea     r12d, [ebp*2+ebp]
        add     ax, word [r13+r12+4]
        cwd
        idiv    bx
        stosw
        add     rsi, 6
        dec     ecx
        jnz     .calc_pts
        ; pts_src = pts_tab + ((40+48)*6)
        lea     rsi, [rel pts_tab+((40+48)*6)]
        lea     rdi, [rel pts_src]
        mov     ecx, (224+256+256)*3
        rep movsw
        add     rsp, 0x20
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ===================== bit_sort ==============================================
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

; ===================== show ==================================================
; Iterates the sorted faces; for each sets x_1..3/y_1..3 + p_1..3 then calls
; face (which needs the resolved screen/texture bases in globals esq/fsq).

section .bss
esq:   resq 1        ; screen (scr) base pointer
fsq:   resq 1        ; current texture base pointer

section .text
show:
        cmp     dword [rel ile], 0
        je      .zexit
        ; es = scr_sel : resolve screen base once
        lea     rbx, [rel sel_base_table]
        movzx   eax, word [rel scr_sel]
        and     eax, 0x1ff
        mov     r12, [rbx + rax*8]
        mov     [rel esq], r12
        ; con base in r13 (arena)
        mov     eax, [rel con_a8]
        add     rax, qword [rel Code32_addr]
        mov     r13, rax
        ; rsi = draw_tab (arena)
        mov     eax, [rel draw_a8]
        add     rax, qword [rel Code32_addr]
        mov     rsi, rax
.lop:
        push    rsi
        movzx   eax, word [rsi+2]
        mov     ebx, 6
        xor     edx, edx
        div     ebx
        shl     eax, 3
        ; con3[eax] : map idx (dd), col (+4, w), vis (+6), phong (+7)
        lea     rbx, [rel con3]
        mov     eax, [rbx+rax]            ; map index 0/1
        lea     rdx, [rel map1_sel]
        movzx   eax, word [rdx + rax*2]
        lea     rbx, [rel sel_base_table]
        and     eax, 0x1ff
        mov     r14, [rbx + rax*8]        ; texture base (fs)
        mov     [rel fsq], r14
        lea     r15, [rel rcalc]          ; rcalc module base
        lea     rbp, [rel pkt]            ; pkt module base
        movzx   edi, word [rsi+2]         ; face index (byte offset into con)
.als:
        ; vis/phong from con3 once more (idempotent per record)
        movzx   eax, word [rsi+2]
        mov     ebx, 6
        xor     edx, edx
        div     ebx
        shl     eax, 3
        lea     rbx, [rel con3]
        movzx   edx, word [rbx+rax+4]
        mov     [rel col], dx
        movzx   ecx, byte [rbx+rax+6]
        mov     r9, rcx                   ; vis
        movzx   edx, byte [rbx+rax+7]
        mov     r10, rdx                  ; phong
        or      r9b, r9b
        jz      .no_plane
        ; ---- plane (sw object, map via pkt) ----
        movzx   ebx, word [r15+rdi]
        movsx   eax, word [r15 + rbx*2]
        mov     [rel x_1], eax
        movsx   eax, word [r15 + rbx*2 + 2]
        mov     [rel y_1], eax
        sub     ebx, 40*2
        mov     eax, dword [rbp + rbx*2]
        mov     [rel p_1], eax
        movzx   ebx, word [r15+rdi+2]
        movsx   eax, word [r15 + rbx*2]
        mov     [rel x_2], eax
        movsx   eax, word [r15 + rbx*2 + 2]
        mov     [rel y_2], eax
        sub     ebx, 40*2
        mov     eax, dword [rbp + rbx*2]
        mov     [rel p_2], eax
        movzx   ebx, word [r15+rdi+4]
        movsx   eax, word [r15 + rbx*2]
        mov     [rel x_3], eax
        movsx   eax, word [r15 + rbx*2 + 2]
        mov     [rel y_3], eax
        sub     ebx, 40*2
        mov     eax, dword [rbp + rbx*2]
        mov     [rel p_3], eax
        jmp     .drawing
.no_plane:
        or      r10b, r10b
        jz      .nshading
        ; ---- phong shading (ob object, n_rot) ----
        mov     eax, [rel n_rot_a]
        add     rax, qword [rel Code32_addr]
        mov     rbp, rax
        movzx   ebx, word [r15+rdi]
        movsx   eax, word [r15 + rbx*2]
        mov     [rel x_1], eax
        movsx   eax, word [r15 + rbx*2 + 2]
        mov     [rel y_1], eax
        sub     ebx, (40+33)*2
        movzx   eax, word [rbp + rbx*2]
        add     ax, 128
        shl     ax, 8
        mov     [rel p_1], ax
        movzx   eax, word [rbp + rbx*2 + 2]
        add     ax, 108
        shl     ax, 8
        mov     [rel p_1+2], ax
        movzx   ebx, word [r15+rdi+2]
        movsx   eax, word [r15 + rbx*2]
        mov     [rel x_2], eax
        movsx   eax, word [r15 + rbx*2 + 2]
        mov     [rel y_2], eax
        sub     ebx, (40+33)*2
        movzx   eax, word [rbp + rbx*2]
        add     ax, 128
        shl     ax, 8
        mov     [rel p_2], ax
        movzx   eax, word [rbp + rbx*2 + 2]
        add     ax, 108
        shl     ax, 8
        mov     [rel p_2+2], ax
        movzx   ebx, word [r15+rdi+4]
        movsx   eax, word [r15 + rbx*2]
        mov     [rel x_3], eax
        movsx   eax, word [r15 + rbx*2 + 2]
        mov     [rel y_3], eax
        sub     ebx, (40+33)*2
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
        ; flat shading (con2 + pos)
        movzx   ebx, word [r15+rdi]
        movsx   eax, word [r15 + rbx*2]
        mov     [rel x_1], eax
        movsx   eax, word [r15 + rbx*2 + 2]
        mov     [rel y_1], eax
        lea     r10, [rel con2]
movzx   ebx, word [r10 + rdi]
        lea     r11, [rel pos]
mov     eax, dword [r11 + rbx*2]
        mov     [rel p_1], eax
        movzx   ebx, word [r15+rdi+2]
        movsx   eax, word [r15 + rbx*2]
        mov     [rel x_2], eax
        movsx   eax, word [r15 + rbx*2 + 2]
        mov     [rel y_2], eax
        lea     r10, [rel con2]
movzx   ebx, word [r10 + rdi+2]
        lea     r11, [rel pos]
mov     eax, dword [r11 + rbx*2]
        mov     [rel p_2], eax
        movzx   ebx, word [r15+rdi+4]
        movsx   eax, word [r15 + rbx*2]
        mov     [rel x_3], eax
        movsx   eax, word [r15 + rbx*2 + 2]
        mov     [rel y_3], eax
        lea     r10, [rel con2]
movzx   ebx, word [r10 + rdi+4]
        lea     r11, [rel pos]
mov     eax, dword [r11 + rbx*2]
        mov     [rel p_3], eax
.drawing:
        or      r9b, r9b
        jz      .draw
        ; backface cull (w x_1..y_3, 16-bit math)
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
        jle     .hide
.draw:
        call    face
.hide:
        pop     rsi
        add     rsi, 4
        dec     dword [rel ile]
        jne     .lop
.zexit:
        ret

; ===================== face ==================================================
; Textured triangle rasterizer.  n_* / p_* come from show; fsq = texture base,
; esq = screen base.  Uses bp (16-bit) as span counter, si = texel step (16.16),
; di = screen offset, cx = col like the original TASM.
; NOTE: original did `mov es,scr_sel` once in show and per-face `mov fs,[bx]` -
; we keep resolved bases in esq/fsq globals set by show.
face:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        sub     rsp, 0x20
        mov     r12, [rel esq]          ; screen base (es)
        mov     r13, [rel fsq]          ; texture base (fs)
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
        mov     word [rel pom], ax
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
        mov     word [rel pom], ax
        mov     eax, [rel dy_1]
        imul    dword [rel pd_1]
        add     ax, word [rel p_1]
        mov     word [rel mem], ax
        mov     eax, [rel dy_1]
        imul    dword [rel pd_2]
        add     ax, word [rel p_1+2]
        mov     word [rel mem+2], ax
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
        xchg    word [rel p_1+2], ax
        mov     word [rel p_1], ax
        cmp     dword [rel y_3], y2_max-1
        jl      .no_da
        sub     dword [rel y_3], y2_max-1
        mov     eax, [rel y_3]
        sub     [rel dy_3], eax
.no_da:
        xor     ebx, ebx
        mov     bx, word [rel x_2]
        sub     bx, word [rel pom]
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
        movzx   edi, word [rel x_1+2]
        movzx   r14d, word [rel x_s+2]
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
        mov     ax, word [rel pd_2]
        add     word [rel p_1], ax
        mov     ax, word [rel pd_1]
        add     word [rel p_1+2], ax
        add     dword [rel y_1], 320
        dec     dword [rel dy_3]
        jne     .draw_1
.sk:
        add     rsp, 0x20
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
        movzx   edi, word [rel x_s+2]
        movzx   r14d, word [rel x_1+2]
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
        jl      .add_1
.no_c1:
        cmp     r14d, x2_max-1
        jl      .no_c2
        mov     r14d, x2_max-1
.no_c2:
        sub     r14d, edi
        jl      .go_2
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
        mov     ax, word [rel pd_2]
        add     word [rel p_1], ax
        mov     ax, word [rel pd_1]
        add     word [rel p_1+2], ax
        add     dword [rel y_1], 320
        dec     dword [rel dy_3]
        jne     .draw_2
        add     rsp, 0x20
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ===================== control ===============================================
speed   EQU 64
rot     EQU 8

control:
        cmp     byte [rel Key_Map + UP], On
        jne     .co_1
        add     dword [rel o_y], speed
.co_1:
        cmp     byte [rel Key_Map + DOWN], On
        jne     .co_2
        sub     dword [rel o_y], speed
.co_2:
        cmp     byte [rel Key_Map + LEFT], On
        jne     .co_3
        add     dword [rel o_x], speed
.co_3:
        cmp     byte [rel Key_Map + RIGHT], On
        jne     .co_4
        sub     dword [rel o_x], speed
.co_4:
        cmp     byte [rel Key_Map + KEY_C], On
        jne     .co_5
        add     dword [rel o_z], speed
.co_5:
        cmp     byte [rel Key_Map + KEY_X], On
        jne     .co_6
        sub     dword [rel o_z], speed
.co_6:
        cmp     byte [rel Key_Map + KEY_W], On
        jne     .co_7
        add     dword [rel o_z], speed
.co_7:
        cmp     byte [rel Key_Map + KEY_Q], On
        jne     .co_8
        sub     dword [rel o_z], speed
.co_8:
        cmp     byte [rel Key_Map + KEY_F1], On
        jne     .co_9
        sub     word [r_x], rot
.co_9:
        cmp     byte [rel Key_Map + KEY_F2], On
        jne     .co_10
        add     word [r_x], rot
.co_10:
        cmp     byte [rel Key_Map + KEY_F3], On
        jne     .co_11
        sub     word [r_y], rot
.co_11:
        cmp     byte [rel Key_Map + KEY_F4], On
        jne     .co_12
        add     word [r_y], rot
.co_12:
        cmp     byte [rel Key_Map + KEY_F5], On
        jne     .co_13
        sub     word [r_z], rot
.co_13:
        cmp     byte [rel Key_Map + KEY_F6], On
        jne     .co_14
        add     word [r_z], rot
.co_14:
        cmp     byte [rel Key_Map + KEY_F7], On
        jne     .co_15
        sub     word [rel cm_x], rot
.co_15:
        cmp     byte [rel Key_Map + KEY_F8], On
        jne     .co_16
        add     word [rel cm_x], rot
.co_16:
        cmp     byte [rel Key_Map + KEY_F9], On
        jne     .co_17
        sub     word [rel cm_y], rot
.co_17:
        cmp     byte [rel Key_Map + KEY_F10], On
        jne     .co_18
        add     word [rel cm_y], rot
.co_18:
        cmp     byte [rel Key_Map + KEY_F11], On
        jne     .co_19
        sub     word [rel cm_z], rot
.co_19:
        cmp     byte [rel Key_Map + KEY_F12], On
        jne     .exit
        add     word [rel cm_z], rot
.exit:
        ret

; ===================== fade ==================================================
fade:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    rcx
        sub     rsp, 0x20
        cmp     dword [rel ile_fade], 0
        jle     .plum
        lea     rsi, [rel pal]
        lea     rdi, [rel white]
        mov     ebx, [rel ile_fade]
        mov     ecx, 768
.astro:
        lodsb
        add     al, bl
        cmp     al, 3fh
        jle     .noa
        mov     al, 3fh
.noa:
        stosb
        loop    .astro
        lea     rsi, [rel white]
        call    pal_set
        mov     eax, [rel frames]
        sub     [rel ile_fade], eax
.plum:
        add     rsp, 0x20
        pop     rcx
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ===================== brum ==================================================
brum:
        push    rbp
        mov     rbp, rsp
        push    rsi
        sub     rsp, 0x20
        mov     ax, [rel ModPos]
        and     eax, 03fh
        lea     r8, [rel tablica]
cmp     word [r8 + rax*4], 0
        je      .no_flash
        lea     r8, [rel tablica]
cmp     word [r8 + rax*4 + 2], 1
        je      .no_flash
        lea     r8, [rel tablica]
mov     word [r8 + rax*4 + 2], 1
        lea     rsi, [rel white]
        call    pal_set
        lea     rsi, [rel white]
        call    pal_set
.no_flash:
        add     rsp, 0x20
        pop     rsi
        pop     rbp
        ret

; ===================== sloneczko =============================================
sloneczko:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    rcx
        sub     rsp, 0x20
        ; (module var sun_step)
        cmp     dword [rel sun_step], 19
        jl      .sun_ok1
        sub     dword [rel sun_step], 18
.sun_ok1:
        cmp     dword [rel sun_step], 0
        jg      .sun_ok2
        add     dword [rel sun_step], 18
.sun_ok2:
        mov     esi, [rel sun_step]
        shl     esi, 12
        add     esi, [rel sun]
        add     rsi, qword [rel Code32_addr]
        mov     edi, [rel scr_addr]
        add     rdi, qword [rel Code32_addr]
        add     rdi, (-2*320)+254
        mov     ecx, 64
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
        cmp     eax, 4
        jle     .plo
        shr     eax, 2
        jmp     .doit
.plo:
        mov     eax, 1
.doit:
        add     [rel sun_step], eax
        add     rsp, 0x20
        pop     rcx
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

section .bss
sun_step: resd 1
