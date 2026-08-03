; mrotate.asm - native x64 port of CODE/INC/MROTATE.PM (fixed-point 3D
; rotation), exposed as a clean Win64 C ABI so the demo and the unit test can
; both call it:
;
;     PrepareRotationMatrix()          ; from mrot_angleX/Y/Z globals
;     mrotate(vecs, count)             ; rotate 3*count int32 vertices in place
;     mrotateNormals(vecs, count)      ; rotate 2*count int32 vectors in place
;
;     void vk_prep_rot_matrix(int ax,int ay,int az)   ; set angles + build
;     void vk_mrotate(int32_t* vecs, int count)
;     void vk_mrotate_normals(int32_t* vecs, int count)
;
; All arithmetic is 32-bit fixed-point, 15 fractional bits, mirroring the
; original bit-for-bit:  1-operand imul -> 64-bit edx:eax product, then
; `shrd eax,edx,15` (logical) in PrepareRotationMatrix and `sar eax,15`
; (arithmetic) for the z*m terms in mrotate. Sine values come from vkSin
; (1024 x dd, round(sin(2*pi*i/1024)*32767)).

BITS 64
DEFAULT REL

section .bss align=16
global mrot_angleX
global mrot_angleY
global mrot_angleZ
mrot_angleX: resd 1
mrot_angleY: resd 1
mrot_angleZ: resd 1

global mrot_matrix
mrot_matrix: resd 9          ; 3x3 rotation matrix (offsets 0..32)

mrot_sin1: resd 1
mrot_cos1: resd 1
mrot_sin2: resd 1
mrot_cos2: resd 1
mrot_sin3: resd 1
mrot_cos3: resd 1
mrot_s3c1: resd 1
mrot_s3s1: resd 1
mrot_c3s2: resd 1
global mrot_ab1
global mrot_ab2
global mrot_ab3
mrot_ab1: resd 1
mrot_ab2: resd 1
mrot_ab3: resd 1
mrot_xy:  resd 1

section .text
extern vkSin

; ---------------------------------------------------------------------------
; PrepareRotationMatrix - build mrot_matrix + mrot_ab1..3 from the angles.
PrepareRotationMatrix:
        push    rdx
        lea     r10, [rel vkSin]          ; REL32-safe base; [r10+eax*4] = no ADDR32
        mov     eax, [mrot_angleX]
        and     eax, 03ffh
        mov     ebx, [r10 + rax*4]
        mov     [mrot_sin1], ebx
        add     eax, 256
        and     eax, 03ffh
        mov     ebx, [r10 + rax*4]
        mov     [mrot_cos1], ebx
        mov     eax, [mrot_angleY]
        and     eax, 03ffh
        mov     ebx, [r10 + rax*4]
        mov     [mrot_sin2], ebx
        add     eax, 256
        and     eax, 03ffh
        mov     ebx, [r10 + rax*4]
        mov     [mrot_cos2], ebx
        mov     eax, [mrot_angleZ]
        and     eax, 03ffh
        mov     ebx, [r10 + rax*4]
        mov     [mrot_sin3], ebx
        add     eax, 256
        and     eax, 03ffh
        mov     ebx, [r10 + rax*4]
        mov     [mrot_cos3], ebx

        ; matrix[0] = cos3*cos2 >> 15
        mov     eax, [mrot_cos3]
        imul    dword [mrot_cos2]
        shrd    eax, edx, 15
        mov     [mrot_matrix+0], eax
        ; matrix[6] = -sin2
        mov     eax, [mrot_sin2]
        neg     eax
        mov     [mrot_matrix+24], eax
        ; matrix[3] = sin3*cos2 >> 15
        mov     eax, [mrot_sin3]
        imul    dword [mrot_cos2]
        shrd    eax, edx, 15
        mov     [mrot_matrix+12], eax
        ; s3c1 = sin3*cos1 >> 15
        mov     eax, [mrot_sin3]
        imul    dword [mrot_cos1]
        shrd    eax, edx, 15
        mov     [mrot_s3c1], eax
        ; s3s1 = sin3*sin1 >> 15
        mov     eax, [mrot_sin3]
        imul    dword [mrot_sin1]
        shrd    eax, edx, 15
        mov     [mrot_s3s1], eax
        ; c3s2 = cos3*sin2 >> 15
        mov     eax, [mrot_cos3]
        imul    dword [mrot_sin2]
        shrd    eax, edx, 15
        mov     [mrot_c3s2], eax
        ; matrix[1] = -(c3s2*sin1 >> 15) - s3c1
        mov     eax, [mrot_c3s2]
        imul    dword [mrot_sin1]
        shrd    eax, edx, 15
        neg     eax
        sub     eax, [mrot_s3c1]
        mov     [mrot_matrix+4], eax
        ; matrix[2] = (c3s2*cos1 >> 15) - s3s1
        mov     eax, [mrot_c3s2]
        imul    dword [mrot_cos1]
        shrd    eax, edx, 15
        sub     eax, [mrot_s3s1]
        mov     [mrot_matrix+8], eax
        ; matrix[4] = (cos3*cos1 >> 15) - (s3s1*sin2 >> 15)
        mov     eax, [mrot_s3s1]
        imul    dword [mrot_sin2]
        shrd    eax, edx, 15
        mov     ebx, eax
        mov     eax, [mrot_cos3]
        imul    dword [mrot_cos1]
        shrd    eax, edx, 15
        sub     eax, ebx
        mov     [mrot_matrix+16], eax
        ; matrix[7] = -(cos2*sin1 >> 15)
        mov     eax, [mrot_cos2]
        imul    dword [mrot_sin1]
        shrd    eax, edx, 15
        neg     eax
        mov     [mrot_matrix+28], eax
        ; matrix[8] = cos2*cos1 >> 15
        mov     eax, [mrot_cos2]
        imul    dword [mrot_cos1]
        shrd    eax, edx, 15
        mov     [mrot_matrix+32], eax
        ; matrix[5] = (s3c1*sin2 >> 15) + (cos3*sin1 >> 15)
        mov     eax, [mrot_s3c1]
        imul    dword [mrot_sin2]
        shrd    eax, edx, 15
        mov     ebx, eax
        mov     eax, [mrot_cos3]
        imul    dword [mrot_sin1]
        shrd    eax, edx, 15
        add     eax, ebx
        mov     [mrot_matrix+20], eax

        ; ab1..3 = low32 of element products (unshifted)
        mov     eax, [mrot_matrix+0]
        imul    dword [mrot_matrix+4]
        mov     [mrot_ab1], eax
        mov     eax, [mrot_matrix+12]
        imul    dword [mrot_matrix+16]
        mov     [mrot_ab2], eax
        mov     eax, [mrot_matrix+24]
        imul    dword [mrot_matrix+28]
        mov     [mrot_ab3], eax
        pop     rdx
        ret

; ---------------------------------------------------------------------------
; mrotate - rotate 3-component (xyz) int32 vertices in place.
;   esi = vertex array (12 bytes each), ecx = count
mrotate:
        push    rbp
        push    rdx
.rotloop:
        mov     eax, [rsi]
        mov     ebx, [rsi+4]
        imul    ebx                       ; edx:eax = x*y
        mov     [mrot_xy], eax
        mov     eax, [rsi]
        mov     ebx, [rsi+4]
        add     eax, [mrot_matrix+4]
        add     ebx, [mrot_matrix+0]
        imul    ebx
        sub     eax, [mrot_xy]
        sub     eax, [mrot_ab1]
        sar     eax, 15
        mov     ebx, eax                  ; xr
        mov     eax, [rsi+8]
        imul    dword [mrot_matrix+8]
        sar     eax, 15
        add     ebx, eax
        mov     eax, [rsi]
        mov     ebp, [rsi+4]
        add     eax, [mrot_matrix+16]
        add     ebp, [mrot_matrix+12]
        imul    ebp
        sub     eax, [mrot_xy]
        sub     eax, [mrot_ab2]
        sar     eax, 15
        mov     ebp, eax                  ; yr
        mov     eax, [rsi+8]
        imul    dword [mrot_matrix+20]
        sar     eax, 15
        add     ebp, eax
        mov     eax, [rsi]
        mov     edi, [rsi+4]
        add     eax, [mrot_matrix+28]
        add     edi, [mrot_matrix+24]
        imul    edi
        sub     eax, [mrot_xy]
        sub     eax, [mrot_ab3]
        sar     eax, 15
        mov     edi, eax                  ; zr
        mov     eax, [rsi+8]
        imul    dword [mrot_matrix+32]
        sar     eax, 15
        add     edi, eax
        mov     [rsi], ebx
        mov     [rsi+4], ebp
        mov     [rsi+8], edi
        add     rsi, 12
        dec     ecx
        jnz     .rotloop
        pop     rdx
        pop     rbp
        ret

; ---------------------------------------------------------------------------
; mrotateNormals - rotate 2-component (xy) int32 vectors in place.
;   esi = vector array (8 bytes each), ecx = count
mrotateNormals:
        push    rbp
        push    rdx
.rotloop2:
        mov     eax, [rsi]
        mov     ebx, [rsi+4]
        imul    ebx
        mov     [mrot_xy], eax
        mov     eax, [rsi]
        mov     ebx, [rsi+4]
        add     eax, [mrot_matrix+4]
        add     ebx, [mrot_matrix+0]
        imul    ebx
        sub     eax, [mrot_xy]
        sub     eax, [mrot_ab1]
        sar     eax, 15
        mov     ebx, eax                  ; xr
        mov     eax, [rsi+8]
        imul    dword [mrot_matrix+8]
        sar     eax, 15
        add     ebx, eax
        mov     eax, [rsi]
        mov     ebp, [rsi+4]
        add     eax, [mrot_matrix+16]
        add     ebp, [mrot_matrix+12]
        imul    ebp
        sub     eax, [mrot_xy]
        sub     eax, [mrot_ab2]
        sar     eax, 15
        mov     ebp, eax                  ; yr
        mov     eax, [rsi+8]
        imul    dword [mrot_matrix+20]
        sar     eax, 15
        add     ebp, eax
        mov     [rsi], ebx
        mov     [rsi+4], ebp
        add     rsi, 12
        dec     ecx
        jnz     .rotloop2
        pop     rdx
        pop     rbp
        ret

; ---------------------------------------------------------------------------
; C ABI wrappers (Win64). Preserve callee-saved regs.
global vk_prep_rot_matrix
; void vk_prep_rot_matrix(int ax, int ay, int az)  [rcx, rdx, r8d]
vk_prep_rot_matrix:
        push    rbx
        mov     [mrot_angleX], ecx
        mov     [mrot_angleY], edx
        mov     [mrot_angleZ], r8d
        call    PrepareRotationMatrix
        pop     rbx
        ret

global vk_mrotate
; void vk_mrotate(int32_t* vecs, int count)  [rcx, edx]
vk_mrotate:
        push    rbx
        push    rsi
        push    rdi
        mov     rsi, rcx
        mov     ecx, edx
        call    mrotate
        pop     rdi
        pop     rsi
        pop     rbx
        ret

global vk_mrotate_normals
; void vk_mrotate_normals(int32_t* vecs, int count)  [rcx, edx]
vk_mrotate_normals:
        push    rbx
        push    rsi
        push    rdi
        mov     rsi, rcx
        mov     ecx, edx
        call    mrotateNormals
        pop     rdi
        pop     rsi
        pop     rbx
        ret
