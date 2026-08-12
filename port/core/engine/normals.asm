; normals.asm - native x64 port of CODE/INC/NORMALS.PM (calcNormals), the
; Phong per-face normal generation + per-vertex normal aggregation. Exposed as
; a clean Win64 C ABI that takes a pointer-carrying struct (rcx):
;
;   struct EvilObj {
;     int32_t* vertexes;  int nverts;      // 0x00 / 0x08
;     int32_t* faces;     int nfaces;      // 0x10 / 0x18
;     int32_t* normals;                   // 0x20  per-face out (nfaces*3)
;     int32_t* wersory;                   // 0x28  per-vertex out (nverts*3)
;     int32_t* count;                     // 0x30  per-vertex scratch (nverts)
;   };
;
; Algorithm (mirrors the original):
;   1) for each face: n = (v2-v1) x (v3-v1), normalize (sqrt, then
;      nor*250/len; zero if len==0), store 3 dwords.
;   2) aggregate: count[v]++ and wersory[v]+=normal for each vertex of each face.
;   3) per vertex: if count==0 zero wersory[v] else wersory[v]/=count.
;
; The original patches immediates (NormalneECX/AdrNormals1/2) - illegal under
; DEP -> explicit loop counters/object pointers used instead. Intermediate
; cross-product terms are held in bss globals exactly like the original.

BITS 64
DEFAULT REL

section .bss align=16
nrm_x1: resd 1
nrm_y1: resd 1
nrm_z1: resd 1
nrm_x2: resd 1
nrm_y2: resd 1
nrm_z2: resd 1
nrm_x3: resd 1
nrm_y3: resd 1
nrm_z3: resd 1
nrm_v1x: resd 1
nrm_v1y: resd 1
nrm_v1z: resd 1
nrm_v2x: resd 1
nrm_v2y: resd 1
nrm_v2z: resd 1
nrm_len: resd 1

%define CN_VERTEXES  0x00
%define CN_NVERTS    0x08
%define CN_FACES     0x10
%define CN_NFACES    0x18
%define CN_NORMALS   0x20
%define CN_WERSORY   0x28
%define CN_COUNT     0x30

section .text

global vk_calc_normals
; void vk_calc_normals(EvilObj* o)  [rcx]
vk_calc_normals:
        push    rbx
        push    rsi
        push    rdi
        push    rbp
        push    r12
        push    r13
        push    r14
        push    r15
        ; r8 = obj pointer-free fields
        mov     r12, [rcx + CN_VERTEXES]
        mov     r13d, [rcx + CN_NVERTS]
        mov     r14, [rcx + CN_FACES]
        mov     r15d, [rcx + CN_NFACES]
        mov     rbx, [rcx + CN_NORMALS]
        mov     rbp, [rcx + CN_WERSORY]
        mov     r11, [rcx + CN_COUNT]

        ; ---- part 1: per-face normalized normals ----
        mov     rsi, r14                ; faces
        mov     rdi, rbx                ; normals out
        mov     r10d, r15d              ; nfaces (loop counter)
.faceLoop:
        mov     eax, [rsi]              ; v0
        mov     r8d, [rsi + 4]          ; v1
        mov     ecx, [rsi + 8]          ; v2
        lea     rax, [rax*2 + rax]      ; v0*3
        lea     r8, [r8*2 + r8]         ; v1*3
        lea     rcx, [rcx*2 + rcx]      ; v2*3

        mov     edx, [r12 + rax*4]
        mov     [nrm_x1], edx
        mov     edx, [r12 + rax*4 + 4]
        mov     [nrm_y1], edx
        mov     edx, [r12 + rax*4 + 8]
        mov     [nrm_z1], edx
        mov     edx, [r12 + r8*4]
        mov     [nrm_x2], edx
        mov     edx, [r12 + r8*4 + 4]
        mov     [nrm_y2], edx
        mov     edx, [r12 + r8*4 + 8]
        mov     [nrm_z2], edx
        mov     edx, [r12 + rcx*4]
        mov     [nrm_x3], edx
        mov     edx, [r12 + rcx*4 + 4]
        mov     [nrm_y3], edx
        mov     edx, [r12 + rcx*4 + 8]
        mov     [nrm_z3], edx

        ; v1 = vertex2 - vertex1 ; v2 = vertex3 - vertex1
        mov     eax, [nrm_x2]
        sub     eax, [nrm_x1]
        mov     [nrm_v1x], eax
        mov     eax, [nrm_y2]
        sub     eax, [nrm_y1]
        mov     [nrm_v1y], eax
        mov     eax, [nrm_z2]
        sub     eax, [nrm_z1]
        mov     [nrm_v1z], eax
        mov     eax, [nrm_x3]
        sub     eax, [nrm_x1]
        mov     [nrm_v2x], eax
        mov     eax, [nrm_y3]
        sub     eax, [nrm_y1]
        mov     [nrm_v2y], eax
        mov     eax, [nrm_z3]
        sub     eax, [nrm_z1]
        mov     [nrm_v2z], eax

        ; norX = v1y*v2z - v1z*v2y
        mov     eax, [nrm_v1y]
        imul    dword [nrm_v2z]
        mov     r9d, [nrm_v1z]
        imul    r9d, dword [nrm_v2y]
        sub     eax, r9d
        mov     [rdi], eax
        ; norY = v1z*v2x - v1x*v2z
        mov     eax, [nrm_v1z]
        imul    dword [nrm_v2x]
        mov     r9d, [nrm_v1x]
        imul    r9d, dword [nrm_v2z]
        sub     eax, r9d
        mov     [rdi + 4], eax
        ; norZ = v1x*v2y - v1y*v2x
        mov     eax, [nrm_v1x]
        imul    dword [nrm_v2y]
        mov     r9d, [nrm_v1y]
        imul    r9d, dword [nrm_v2x]
        sub     eax, r9d
        mov     [rdi + 8], eax

        ; length = sqrt(norX^2+norY^2+norZ^2)
        fild    dword [rdi]
        fimul   dword [rdi]
        fild    dword [rdi + 4]
        fimul   dword [rdi + 4]
        fadd    st0, st1
        fild    dword [rdi + 8]
        fimul   dword [rdi + 8]
        fadd    st0, st1
        fsqrt
        fistp   dword [nrm_len]
        fstp    st0
        fstp    st0
        mov     r9d, [nrm_len]
        or      r9d, r9d
        jne     .normit
        mov     dword [rdi], 0
        mov     dword [rdi + 4], 0
        mov     dword [rdi + 8], 0
        jmp     .normdone
.normit:
        mov     eax, [rdi]
        imul    eax, 250
        cdq
        idiv    r9d
        mov     [rdi], eax
        mov     eax, [rdi + 4]
        imul    eax, 250
        cdq
        idiv    r9d
        mov     [rdi + 4], eax
        mov     eax, [rdi + 8]
        imul    eax, 250
        cdq
        idiv    r9d
        mov     [rdi + 8], eax
.normdone:
        add     rsi, 12
        add     rdi, 12
        dec     r10d
        jnz     .faceLoop

        ; ---- part 2: aggregate into wersory using count ----
        ; zero count (nverts) and wersory (nverts*3)
        mov     rdi, r11
        xor     eax, eax
        mov     ecx, r13d
        rep stosd
        mov     rdi, rbp
        mov     edx, r13d
        lea     ecx, [edx*2 + edx]
        rep stosd

        mov     rsi, r14                ; faces
        mov     rdi, rbx                ; normals
        mov     r10d, r15d              ; nfaces
.aggLoop:
        mov     eax, [rsi]
        inc     dword [r11 + rax*4]
        lea     rax, [rax*2 + rax]
        mov     ebx, [rdi]
        add     [rbp + rax*4], ebx
        mov     ebx, [rdi + 4]
        add     [rbp + rax*4 + 4], ebx
        mov     ebx, [rdi + 8]
        add     [rbp + rax*4 + 8], ebx

        mov     eax, [rsi + 4]
        inc     dword [r11 + rax*4]
        lea     rax, [rax*2 + rax]
        mov     ebx, [rdi]
        add     [rbp + rax*4], ebx
        mov     ebx, [rdi + 4]
        add     [rbp + rax*4 + 4], ebx
        mov     ebx, [rdi + 8]
        add     [rbp + rax*4 + 8], ebx

        mov     eax, [rsi + 8]
        inc     dword [r11 + rax*4]
        lea     rax, [rax*2 + rax]
        mov     ebx, [rdi]
        add     [rbp + rax*4], ebx
        mov     ebx, [rdi + 4]
        add     [rbp + rax*4 + 4], ebx
        mov     ebx, [rdi + 8]
        add     [rbp + rax*4 + 8], ebx

        add     rsi, 12
        add     rdi, 12
        dec     r10d
        jnz     .aggLoop

        ; ---- part 3: per-vertex divide / zero ----
        mov     rsi, rbp                ; wersory
        mov     rdi, r11                ; count
        mov     ecx, r13d               ; nverts
.divLoop:
        mov     ebx, [rdi]
        or      ebx, ebx
        jnz     .divok
        mov     dword [rsi], 0
        mov     dword [rsi + 4], 0
        mov     dword [rsi + 8], 0
        jmp     .divdone
.divok:
        mov     eax, [rsi]
        cdq
        idiv    ebx
        mov     [rsi], eax
        mov     eax, [rsi + 4]
        cdq
        idiv    ebx
        mov     [rsi + 4], eax
        mov     eax, [rsi + 8]
        cdq
        idiv    ebx
        mov     [rsi + 8], eax
.divdone:
        add     rsi, 12
        add     rdi, 4
        loop    .divLoop

        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbp
        pop     rdi
        pop     rsi
        pop     rbx
        ret
