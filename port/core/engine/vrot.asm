; vrot.asm - native x64 port of the VR rotation/transform glue:
;   Transform  (INC/PLE2)  - camera-space matrix-vector multiply
;   RotateObj  (OBJECTS.PM) - rotate an object's working vertices (+ normals)
;
; Win64 C ABI:
;     void vk_transform(int32_t* vecs, int count)              [rcx, edx]
;       per axis: sum(x*m1 + y*m2 + z*m3), each product >>15 (arith), int32.
;     void vk_rotate_object(int32_t* vertices, int nverts,     [rcx, edx]
;                           int32_t* normals,                  [r8  (or 0)]
;                           int ax, int ay, int az)            [r9d, rsp+40, rsp+48]
;       builds rotation matrix (unit 1) from ax/ay/az, rotates vertices in
;       place; rotates normals too when normals != 0.

BITS 64
DEFAULT REL

section .text
extern cam_matrix
extern vk_prep_rot_matrix
extern vk_mrotate
extern vk_mrotate_normals

global vk_transform
vk_transform:
        push    rbx
        push    rsi
        push    rdi
        push    rbp
        push    r12
        mov     rsi, rcx
        mov     ecx, edx
        lea     r12, [rel cam_matrix]
.loop:
        mov     ebx, [rsi]              ; x
        mov     edi, [rsi + 4]          ; y
        mov     ebp, [rsi + 8]          ; z
        ; x'
        mov     eax, ebx
        imul    dword [r12 + 0]
        sar     eax, 15
        mov     r9d, eax
        mov     eax, edi
        imul    dword [r12 + 16]
        sar     eax, 15
        add     r9d, eax
        mov     eax, ebp
        imul    dword [r12 + 32]
        sar     eax, 15
        add     r9d, eax
        mov     [rsi], r9d
        ; y'
        mov     eax, ebx
        imul    dword [r12 + 4]
        sar     eax, 15
        mov     r9d, eax
        mov     eax, edi
        imul    dword [r12 + 20]
        sar     eax, 15
        add     r9d, eax
        mov     eax, ebp
        imul    dword [r12 + 36]
        sar     eax, 15
        add     r9d, eax
        mov     [rsi + 4], r9d
        ; z'
        mov     eax, ebx
        imul    dword [r12 + 8]
        sar     eax, 15
        mov     r9d, eax
        mov     eax, edi
        imul    dword [r12 + 24]
        sar     eax, 15
        add     r9d, eax
        mov     eax, ebp
        imul    dword [r12 + 40]
        sar     eax, 15
        add     r9d, eax
        mov     [rsi + 8], r9d
        add     rsi, 12
        dec     ecx
        jnz     .loop
        pop     r12
        pop     rbp
        pop     rdi
        pop     rsi
        pop     rbx
        ret

global vk_rotate_object
vk_rotate_object:
        push    rbx
        push    rsi
        push    rdi
        mov     rbx, rcx                ; vertices
        mov     esi, edx                ; nverts
        mov     rdi, r8                 ; normals (or 0)
        ; vk_prep_rot_matrix(ax=r9d, ay=[rsp+40], az=[rsp+48], +24 pushes)
        mov     ecx, r9d
        mov     edx, [rsp + 40 + 24]
        mov     r8d, [rsp + 48 + 24]
        call    vk_prep_rot_matrix
        mov     rcx, rbx
        mov     edx, esi
        call    vk_mrotate
        test    rdi, rdi
        jz      .done
        mov     rcx, rdi
        mov     edx, esi
        call    vk_mrotate_normals
.done:
        pop     rdi
        pop     rsi
        pop     rbx
        ret
