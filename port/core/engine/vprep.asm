; vprep.asm - native x64 port of the VR object-PREPARE pipeline
; (VIRTUAL.INC PrepareObjectVirtual + RotateObjectVirtual + PrepareVirtualPoints).
; Glues units 1/7 (mrotate, rotate_object, transform) over the LoadObject
; object struct (unit 6) + a World entry + the camera (unit 2).
;
; Win64 C ABI:
;     void vk_prepare_object(uint8_t* base,               [rcx]
;                            uint32_t objOff,             [edx]  object struct off
;                            const int32_t* worldXYZ,     [r8]   (x,y,z)
;                            const int32_t* worldAngles)  [r9]   (ax,ay,az)
;
; Steps (matches the original):
;   1) copy source vertexes (obj+36)  -> copy vertexes (obj+60)
;      copy wersory normals (obj+52)  -> copy wersory (obj+64)   [PHONG only]
;   2) obj angles (obj+12/16/20) = worldAngles, then rotate (unit 7)
;      the working vertexes (+ normals for PHONG)
;   3) per working vertex: += worldXYZ, -= CameraXYZ (globals, unit 2)
;   4) transform by cam_matrix (unit 2) via vk_transform
;
; The camera (cam_matrix + cam_cameraX/Y/Z) must already be set by the caller.

BITS 64
DEFAULT REL

section .bss align=16
vp_base: resq 1
vp_obj:  resq 1

section .text
extern vk_rotate_object
extern vk_transform
extern cam_cameraX
extern cam_cameraY
extern cam_cameraZ

global vk_prepare_object
vk_prepare_object:
        push    rbp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15
        mov     [vp_base], rcx
        mov     r12, rcx
        mov     r13, r8                 ; worldXYZ
        mov     r14, r9                 ; worldAngles
        movsxd  rax, edx
        lea     r15, [r12 + rax]        ; object real ptr

        ; ---- 1) copy source vertexes -> copy vertexes (nov*3 dwords) ----
        mov     ecx, [r15 + 4]          ; nov
        lea     ecx, [ecx*2 + ecx]      ; nov*3
        mov     eax, [r15 + 36]
        lea     rsi, [r12 + rax]        ; source
        mov     eax, [r15 + 60]
        lea     rdi, [r12 + rax]        ; copy vertexes
        rep movsd
        ; ---- copy wersory -> copy wersory (PHONG only) ----
        cmp     dword [r15], 2
        jne     .skipNorm
        mov     ecx, [r15 + 4]
        lea     ecx, [ecx*2 + ecx]      ; nov*3
        mov     eax, [r15 + 52]
        lea     rsi, [r12 + rax]
        mov     eax, [r15 + 64]
        lea     rdi, [r12 + rax]
        rep movsd
.skipNorm:
        ; ---- 2) angles from world, rotate ----
        mov     eax, [r14]
        mov     [r15 + 12], eax
        mov     eax, [r14 + 4]
        mov     [r15 + 16], eax
        mov     eax, [r14 + 8]
        mov     [r15 + 20], eax
        mov     rbx, r15                ; keep obj in rbx across the call
        ; vk_rotate_object(copyVert, nov, copyWersory, ax, ay, az)
        mov     eax, [r15 + 60]
        lea     rcx, [r12 + rax]
        mov     edx, [r15 + 4]
        xor     r8, r8
        cmp     dword [r15], 2
        jne     .noNorm
        mov     eax, [r15 + 64]
        lea     r8, [r12 + rax]
.noNorm:
        mov     r9d, [r14]              ; ax
        mov     eax, [r14 + 4]
        mov     [rsp + 32], eax         ; ay (async at vk_rotate_object [rsp+40+24])
        mov     eax, [r14 + 8]
        mov     [rsp + 40], eax         ; az (at vk_rotate_object [rsp+48+24])
        call    vk_rotate_object
        mov     r15, rbx

        ; ---- 3) prepare points: += worldXYZ, -= CameraXYZ ----
        mov     rcx, r12
        mov     eax, [r15 + 60]
        lea     rsi, [rcx + rax]        ; working vertexes
        mov     ecx, [r15 + 4]          ; nov
        mov     r8d, [cam_cameraX]
        mov     r9d, [cam_cameraY]
        mov     r10d, [cam_cameraZ]
        ; world offsets
        mov     edi, [r13 + 0]
        mov     ebx, [r13 + 4]
        mov     ebp, [r13 + 8]
.ppNext:
        add     edi, [rsi]
        sub     edi, r8d
        mov     [rsi], edi
        mov     edi, ebx
        add     edi, [rsi + 4]
        sub     edi, r9d
        mov     [rsi + 4], edi
        mov     edi, ebp
        add     edi, [rsi + 8]
        sub     edi, r10d
        mov     [rsi + 8], edi
        mov     edi, [r13 + 0]          ; re-prime worldX for next vertex
        add     rsi, 12
        dec     ecx
        jnz     .ppNext

        ; ---- 4) camera-space transform ----
        mov     rcx, r12
        mov     eax, [r15 + 60]
        lea     rcx, [rcx + rax]
        mov     edx, [r15 + 4]
        call    vk_transform

        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret
