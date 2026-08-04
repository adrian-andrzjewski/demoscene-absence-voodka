; p8_rot.asm - P8 rotation / transform routines (included by p8.asm before p8_more).

section .text

; ===================== make_pos ==============================================
make_pos:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        sub     rsp, 0x20
        push    rax
        pop     rax
        mov     word [r_x], 256
        call    prep_rot1
        push    rax
        pop     rax
        mov     word [r_x], 0
        lea     rsi, [rel s2]
        lea     rdi, [rel pkt]
        mov     ecx, 33
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

; ===================== make_pal ==============================================
make_pal:
        mov     ecx, 64
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

; ===================== swap ==================================================
swap:
        push    rbp
        mov     rbp, rsp
        push    rsi
        push    rdi
        push    rcx
        sub     rsp, 0x28        ; entry%16==8 +4pushes(32)+40=80 ? 8+40=48? keep 16-aligned at call
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

; ===================== sub_rot ===============================================
sub_rot:
        push    rbx
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20
.sr_loop:
        movsx   eax, word [rsi]
        imul    dword [rel cos]
        sar     eax, 15
        mov     ebp, eax
        movsx   eax, word [rsi+2]
        imul    dword [rel sin]
        sar     eax, 15
        sub     ebp, eax
        mov     [rdi], bp
        movsx   eax, word [rsi]
        imul    dword [rel sin]
        sar     eax, 15
        mov     ebp, eax
        movsx   eax, word [rsi+2]
        imul    dword [rel cos]
        sar     eax, 15
        add     ebp, eax
        add     ebp, [rel shf]
        mov     [rdi+2], bp
        mov     ax, [rsi+4]
        mov     [rdi+4], ax
        add     rsi, 6
        add     rdi, 6
        loop    .sr_loop
        add     rsp, 0x20
        pop     rbp
        pop     rbx
        ret

section .data
section .text

; ===================== make_phong ============================================
make_phong:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        sub     rsp, 0x20
        lea     r12, [rel sinus]
        ; group 1: ro_1
        mov     ebx, [rel ro_1]
        and     ebx, 3ffh
        movsx   eax, word [r12 + rbx*2]
        mov     [rel sin], eax
        movsx   eax, word [r12 + rbx*2 + 512]
        mov     [rel cos], eax
        lea     rsi, [rel src3]
        lea     rdi, [rel s3]
        mov     dword [rel shf], -640
        mov     ecx, 114
        call    sub_rot
        lea     rsi, [rel pts_src]
        lea     rdi, [rel pts_tab+((40+48)*6)]
        mov     ecx, 224
        call    sub_rot
        mov     esi, [rel n_src_a]
        add     rsi, qword [rel Code32_addr]
        mov     edi, [rel n_vert_a]
        add     rdi, qword [rel Code32_addr]
        mov     dword [rel shf], 0
        mov     ecx, 114
        call    sub_rot
        ; group 2: ro_2
        mov     ebx, [rel ro_2]
        and     ebx, 3ffh
        movsx   eax, word [r12 + rbx*2]
        mov     [rel sin], eax
        movsx   eax, word [r12 + rbx*2 + 512]
        mov     [rel cos], eax
        lea     rsi, [rel src4]
        lea     rdi, [rel s4]
        mov     dword [rel shf], -640
        mov     ecx, 128
        call    sub_rot
        lea     rsi, [rel pts_src+(224*6)]
        lea     rdi, [rel pts_tab+((40+48+224)*6)]
        mov     ecx, 256
        call    sub_rot
        mov     esi, [rel n_src_a]
        add     rsi, qword [rel Code32_addr]
        add     rsi, 114*6
        mov     edi, [rel n_vert_a]
        add     rdi, qword [rel Code32_addr]
        add     rdi, 114*6
        mov     dword [rel shf], 0
        mov     ecx, 128
        call    sub_rot
        ; group 3: ro_3
        mov     ebx, [rel ro_3]
        and     ebx, 3ffh
        movsx   eax, word [r12 + rbx*2]
        mov     [rel sin], eax
        movsx   eax, word [r12 + rbx*2 + 512]
        mov     [rel cos], eax
        lea     rsi, [rel src5]
        lea     rdi, [rel s5]
        mov     dword [rel shf], -640
        mov     ecx, 128
        call    sub_rot
        lea     rsi, [rel pts_src+((224+256)*6)]
        lea     rdi, [rel pts_tab+((40+48+224+256)*6)]
        mov     ecx, 256
        call    sub_rot
        mov     esi, [rel n_src_a]
        add     rsi, qword [rel Code32_addr]
        add     rsi, (114+128)*6
        mov     edi, [rel n_vert_a]
        add     rdi, qword [rel Code32_addr]
        add     rdi, (114+128)*6
        mov     dword [rel shf], 0
        mov     ecx, 128
        call    sub_rot
        add     rsp, 0x20
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; ===================== prep_rot1 =============================================
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
        ; ob1..ob9
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

; ===================== prep_rot2 =============================================
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

; ===================== rotate ================================================
rotate:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        sub     rsp, 0x20
        mov     edi, [rel check_a8]
        add     rdi, qword [rel Code32_addr]
        xor     ax, ax
        mov     ecx, p_len
        rep stosw
        mov     dword [rel ile], 0
        lea     rsi, [rel pts_tab]
        mov     eax, [rel draw_a8]
        add     rax, qword [rel Code32_addr]
        mov     rdi, rax
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
        ; camera-transform
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
        ; bounds
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
        add     bp, 8000
        mov     [rdi], bp
        mov     [rdi+2], bx
        add     rdi, 4
        inc     dword [rel ile]
        ; per-vertex processing (3 verts)
        push    rsi
        push    rdi
        push    rbx
        push    rcx
        mov     ecx, 3
.lo:
        mov     eax, [rel con_a8]
        add     rax, qword [rel Code32_addr]
        movzx   esi, word [rax+rbx]
        mov     r14d, [rel check_a8]
        add     r14, qword [rel Code32_addr]
cmp     word [r14+rsi*2], 0
        jne     .skip
        mov     r14d, [rel check_a8]
        add     r14, qword [rel Code32_addr]
inc     word [r14+rsi*2]
        mov     r14d, [rel rcalc_a8]
        add     r14, qword [rel Code32_addr]
lea     rdi, [r14+rsi*4]
        lea     r13, [rel shape]
        lea     r12d, [esi*2+esi]
        movsx   eax, word [r13+r12]
        imul    dword [rel ob1]
        sar     eax, 15
        mov     ebp, eax
        movsx   eax, word [r13+r12+2]
        imul    dword [rel ob2]
        sar     eax, 15
        add     ebp, eax
        movsx   eax, word [r13+r12+4]
        imul    dword [rel ob3]
        sar     eax, 15
        add     ebp, eax
        mov     [rel t_x], ebp
        movsx   eax, word [r13+r12]
        imul    dword [rel ob4]
        sar     eax, 15
        mov     ebp, eax
        movsx   eax, word [r13+r12+2]
        imul    dword [rel ob5]
        sar     eax, 15
        add     ebp, eax
        movsx   eax, word [r13+r12+4]
        imul    dword [rel ob6]
        sar     eax, 15
        add     ebp, eax
        mov     [rel t_y], ebp
        movsx   eax, word [r13+r12]
        imul    dword [rel ob7]
        sar     eax, 15
        mov     ebp, eax
        movsx   eax, word [r13+r12+2]
        imul    dword [rel ob8]
        sar     eax, 15
        add     ebp, eax
        movsx   eax, word [r13+r12+4]
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
        sub     ebp, 7600
        mov     eax, zoom+32
        imul    dword [rel p_x]
        idiv    ebp
        add     ax, 160
        mov     [rdi], ax
        mov     eax, -zoom
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
        add     rbx, 6
        dec     ecx
        jnz     .ro
        add     rsp, 0x20
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret
