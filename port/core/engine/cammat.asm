; cammat.asm - native x64 port of VIRTUAL.INC MakeCameraMatrix + ZeroMatrix
; (camera rotation matrix from the eye angles). Exposed as a clean Win64 C ABI:
;
;     void vk_make_camera_matrix(int eyeAX, int eyeAY, int eyeAZ)  [rcx,rdx,r8d]
;
; Builds the 16-dword MatrixCamera (cam_matrix) from the eye angles, exactly
; like the original: 3x3 rotation part at offsets {0,4,8,12,16,20,24,28,32,36,40}
; with all other entries zeroed, using `sar` (arithmetic) on the low 32 bits of
; each 64-bit imul product (NOT shrd - unlike PrepareRotationMatrix).
;
; The original patches instruction immediates (_sin3_sin1 etc.) at runtime; that
; is self-modifying and illegal under DEP, so those intermediate low-32 products
; are held in explicit bss variables with identical arithmetic.

BITS 64
DEFAULT REL

section .bss align=16
global cam_eyeAX
global cam_eyeAY
global cam_eyeAZ
cam_eyeAX: resd 1
cam_eyeAY: resd 1
cam_eyeAZ: resd 1
global cam_cameraX
global cam_cameraY
global cam_cameraZ
cam_cameraX: resd 1
cam_cameraY: resd 1
cam_cameraZ: resd 1

global cam_matrix
cam_matrix: resd 16

cam_sin1: resd 1
cam_cos1: resd 1
cam_sin2: resd 1
cam_cos2: resd 1
cam_sin3: resd 1
cam_cos3: resd 1
cam_s3c1: resd 1
cam_c3s1: resd 1
cam_s3s1: resd 1
cam_c3c1: resd 1

section .text
extern vkSin

zeroMatrix:
        xor     eax, eax
        mov     ecx, 16
        rep stosd
        ret

MakeCameraMatrix:
        lea     rdi, [rel cam_matrix]
        call    zeroMatrix
        lea     r10, [rel vkSin]

        mov     eax, [cam_eyeAX]
        and     eax, 03ffh
        mov     ebx, [r10 + rax*4]
        mov     [cam_sin1], ebx
        add     eax, 256
        and     eax, 03ffh
        mov     ebx, [r10 + rax*4]
        mov     [cam_cos1], ebx

        mov     eax, [cam_eyeAY]
        and     eax, 03ffh
        mov     ebx, [r10 + rax*4]
        mov     [cam_sin2], ebx
        add     eax, 256
        and     eax, 03ffh
        mov     ebx, [r10 + rax*4]
        mov     [cam_cos2], ebx

        mov     eax, [cam_eyeAZ]
        and     eax, 03ffh
        mov     ebx, [r10 + rax*4]
        mov     [cam_sin3], ebx
        add     eax, 256
        and     eax, 03ffh
        mov     ebx, [r10 + rax*4]
        mov     [cam_cos3], ebx

        ; mx11 = (cos2*cos3)>>15
        mov     eax, [cam_cos2]
        imul    dword [cam_cos3]
        sar     eax, 15
        mov     [cam_matrix+0], eax

        ; _sin3_cos1 = low(sin3*cos1);  _cos3_sin1 = low(cos3*sin1)
        mov     eax, [cam_sin3]
        imul    dword [cam_cos1]
        mov     [cam_s3c1], eax
        mov     ebx, [cam_cos3]
        imul    ebx, [cam_sin1]
        mov     [cam_c3s1], ebx
        ; mx21 = ( -s3c1 - low((c3s1>>15)*sin2) ) >> 15
        sar     ebx, 15
        imul    ebx, [cam_sin2]
        neg     eax
        sub     eax, ebx
        sar     eax, 15
        mov     [cam_matrix+16], eax

        ; _sin3_sin1 = low(sin3*sin1);  _cos3_cos1 = low(cos3*cos1)
        mov     ebx, [cam_sin3]
        imul    ebx, [cam_sin1]
        mov     [cam_s3s1], ebx
        neg     ebx
        mov     eax, [cam_cos3]
        imul    dword [cam_cos1]
        mov     [cam_c3c1], eax
        ; mx31 = ( -s3s1 + low((c3c1>>15)*sin2) ) >> 15
        sar     eax, 15
        imul    dword [cam_sin2]
        add     eax, ebx
        sar     eax, 15
        mov     [cam_matrix+32], eax

        ; mx12 = (sin3*cos2)>>15
        mov     eax, [cam_sin3]
        imul    dword [cam_cos2]
        sar     eax, 15
        mov     [cam_matrix+4], eax

        ; mx22 = ( c3c1 - low((s3s1>>15)*sin2) ) >> 15
        mov     eax, [cam_s3s1]
        sar     eax, 15
        imul    dword [cam_sin2]
        mov     ebx, [cam_c3c1]
        sub     ebx, eax
        sar     ebx, 15
        mov     [cam_matrix+20], ebx

        ; mx32 = ( c3s1 + low((s3c1>>15)*sin2) ) >> 15
        mov     eax, [cam_s3c1]
        sar     eax, 15
        imul    dword [cam_sin2]
        add     eax, [cam_c3s1]
        sar     eax, 15
        mov     [cam_matrix+36], eax

        ; mx13 = -sin2
        mov     eax, [cam_sin2]
        neg     eax
        mov     [cam_matrix+8], eax

        ; mx23 = -( (cos2*sin1)>>15 )
        mov     eax, [cam_cos2]
        imul    dword [cam_sin1]
        sar     eax, 15
        neg     eax
        mov     [cam_matrix+24], eax

        ; mx33 = (cos2*cos1)>>15
        mov     eax, [cam_cos2]
        imul    dword [cam_cos1]
        sar     eax, 15
        mov     [cam_matrix+40], eax
        ret

global vk_make_camera_matrix
; void vk_make_camera_matrix(int eyeAX, int eyeAY, int eyeAZ)  [rcx,rdx,r8d]
vk_make_camera_matrix:
        push    rbx
        push    rdi
        mov     [cam_eyeAX], ecx
        mov     [cam_eyeAY], edx
        mov     [cam_eyeAZ], r8d
        call    MakeCameraMatrix
        pop     rdi
        pop     rbx
        ret
