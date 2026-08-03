; loader.asm - native x64 port of OBJECTS.PM Load_Object / LoadObject macro's
; object-file parsing. Builds the runtime object struct + working buffers.
;
; Win64 C ABI:
;     void vk_load_object(
;         uint8_t*  base,       ; rcx - memory base (Code32_addr equivalent)
;         uint32_t  fileOff,    ; edx - arena offset of the object file data
;         uint16_t  textureSel) ; r8w - object's texture selector handle
;
; File layout (offsets base-relative): +0 type(0=PIX/1=TEX/2=PHONG), +4 nov,
;   +8 nof, +12/16/20 addAX/Y/Z, +36 vertexes(nov*3 dd), faces(nof*3 dd),
;   textures(nof*3 dd, TEX only).
;
; Struct (21 dwords, base-relative) matches OBJECTS.PM:
;   +0 type +4 nov +8 nof .. +24/28/32 adders +36 vertexes +40 faces +44 tex
;   +48 normals +52 wersory +56 adders-color +60 copy-vert +64 copy-wersory
;   +68 normals-copy +72 tex-sel(word) +76 2d-pts +80 order
;
; Working buffers use a bump allocator over `base` seeded by global lo_bump.
; PHONG objects call unit-5 vk_calc_normals; vertexes are scaled x16 in place.

BITS 64
DEFAULT REL

section .bss align=16
global lo_base
lo_base: resq 1
global lo_bump
lo_bump: resd 1
global lo_objects
lo_objects: resd 10
global lo_number
lo_number: resd 1

section .text

global vk_load_object
vk_load_object:
        push    rbx
        push    rsi
        push    rdi
        push    rbp
        push    r12
        push    r13
        push    r14
        push    r15
        mov     [lo_base], rcx
        mov     r12, rcx                ; base (kept across all calcs)

        ; ---- allocate + zero 21-dword header; register object ----
        mov     eax, [lo_bump]
        mov     ebx, [lo_number]
        lea     r10, [rel lo_objects]   ; REL32-safe base for indexed store
        mov     [r10 + rbx*4], eax
        inc     dword [lo_number]
        add     eax, 21*4
        mov     [lo_bump], eax
        ; rdi = real object struct pointer = base + header()
        mov     eax, [r10 + rbx*4]
        lea     rdi, [r12 + rax]
        xor     eax, eax
        mov     ecx, 21
        rep stosd
        ; rewind: rdi is now past the header; reset to object base
        mov     eax, [r10 + rbx*4]
        lea     rdi, [r12 + rax]

        ; ---- object file header -> struct ----
        mov     rsi, rdx
        add     rsi, r12                ; real file data ptr
        mov     eax, [rsi]              ; type
        mov     [rdi], eax
        mov     eax, [rsi + 4]          ; nov
        mov     [rdi + 4], eax
        mov     eax, [rsi + 8]          ; nof
        mov     [rdi + 8], eax
        mov     eax, [rsi + 12]
        mov     [rdi + 24], eax
        mov     eax, [rsi + 16]
        mov     [rdi + 28], eax
        mov     eax, [rsi + 20]
        mov     [rdi + 32], eax
        mov     ax, r8w
        mov     [rdi + 72], ax          ; tex-sel
        ; vertexes offset = fileOff+36
        lea     eax, [edx + 36]
        mov     [rdi + 36], eax
        ; faces = vertexes + nov*12
        mov     ecx, [rdi + 4]
        lea     ecx, [ecx*2 + ecx]
        shl     ecx, 2
        add     eax, ecx
        mov     [rdi + 40], eax
        ; textures (TEX)
        cmp     dword [rdi], 1
        jne     .noTex
        mov     ecx, [rdi + 8]
        lea     ecx, [ecx*2 + ecx]
        shl     ecx, 2
        add     eax, ecx
        mov     [rdi + 44], eax
.noTex:

        ; ---- block 1: normals region (alloc nof*32) ----
        mov     ebp, [lo_bump]          ; base1
        mov     esi, [rdi + 8]          ; nof
        mov     eax, esi
        shl     eax, 5                  ; nof*32
        lea     ebx, [ebp + eax]
        mov     [lo_bump], ebx          ; lo_bump = base1 + nof*32
        mov     [rdi + 48], ebp         ; +48 normals
        mov     eax, esi
        lea     eax, [eax*2 + eax]
        shl     eax, 2                  ; nof*12
        lea     ebx, [ebp + eax]
        mov     [rdi + 68], ebx         ; +68 normals-copy (base1+12n)
        add     ebx, eax
        mov     [rdi + 56], ebx         ; +56 adders-color (base1+24n)
        mov     eax, esi
        shl     eax, 2                  ; nof*4
        add     ebx, eax
        mov     [rdi + 80], ebx         ; +80 order (base1+28n)

        ; ---- block 2: wersory region (alloc nov*44) ----
        mov     ebp, [lo_bump]          ; base2
        mov     esi, [rdi + 4]          ; nov
        mov     eax, esi
        shl     eax, 3                  ; nov*8
        lea     ebx, [eax*4 + eax]      ; nov*40
        mov     ecx, esi
        shl     ecx, 2                  ; nov*4
        add     ebx, ecx                ; nov*44
        lea     ecx, [ebp + ebx]
        mov     [lo_bump], ecx          ; lo_bump = base2 + nov*44
        mov     [rdi + 52], ebp         ; +52 wersory
        mov     eax, esi
        lea     eax, [eax*2 + eax]
        shl     eax, 2                  ; nov*12
        lea     ebx, [ebp + eax]
        mov     [rdi + 60], ebx         ; +60 copy-vert (base2+12n)
        add     ebx, eax
        mov     [rdi + 64], ebx         ; +64 copy-wersory (base2+24n)
        add     ebx, eax
        mov     [rdi + 76], ebx         ; +76 2d-pts (base2+36n)

        ; ---- PHONG: build normals via unit 5 ----
        cmp     dword [rdi], 2
        jne     .noNorm
        sub     rsp, 56
        ; EvilObj: vertexes,nverts,faces,nfaces,normals,wersory,count (CN_*)
        mov     rcx, r12
        mov     eax, [rdi + 36]
        add     rcx, rax
        mov     [rsp], rcx
        mov     ecx, [rdi + 4]
        mov     [rsp + 8], rcx
        mov     rcx, r12
        mov     eax, [rdi + 40]
        add     rcx, rax
        mov     [rsp + 16], rcx
        mov     ecx, [rdi + 8]
        mov     [rsp + 24], rcx
        mov     rcx, r12
        mov     eax, [rdi + 48]
        add     rcx, rax
        mov     [rsp + 32], rcx
        mov     rcx, r12
        mov     eax, [rdi + 52]
        add     rcx, rax
        mov     [rsp + 40], rcx
        mov     rcx, r12
        mov     eax, [rdi + 60]
        add     rcx, rax
        mov     [rsp + 48], rcx
        mov     rcx, rsp
        extern vk_calc_normals
        call    vk_calc_normals
        add     rsp, 56
.noNorm:

        ; ---- scale vertexes x16 in place ----
        mov     esi, [rdi + 36]
        add     rsi, r12
        mov     ecx, [rdi + 4]          ; nov
.scale:
        mov     eax, [rsi]
        shl     eax, 4
        mov     [rsi], eax
        mov     eax, [rsi + 4]
        shl     eax, 4
        mov     [rsi + 4], eax
        mov     eax, [rsi + 8]
        shl     eax, 4
        mov     [rsi + 8], eax
        add     rsi, 12
        dec     ecx
        jnz     .scale

        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbp
        pop     rdi
        pop     rsi
        pop     rbx
        ret
