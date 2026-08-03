; vvis.asm - native x64 port of CalculateVisiblating + VirSort (painter sort).
;
;   vk_calc_visibility(const int32_t* worldXYZ, int count,   [rcx, edx]
;                      int32_t* zetOut, uint8_t* visOut)     [r8, r9]
;     camera-space z = (x-camX)*m13 + (y-camY)*m23 + (z-camZ)*m33 (each shrd15)
;     -> zetOut; visOut = zet >= 1. Camera pos + matrix from unit 2 globals.
;
;   vk_virsort(const int32_t* zet, int count, int32_t* orderOut) [rcx, edx, r8]
;     Stable painter's sort of the low 16 bits of zet, ascending (far->near);
;     orderOut = object indices in draw order. (Worlds are small, <=255 objects,
;     so a simple stable insertion sort is used; semantics match VirSort's.)

BITS 64
DEFAULT REL

section .bss align=64
vvis_order: resd 4096

section .text
extern cam_cameraX
extern cam_cameraY
extern cam_cameraZ
extern cam_matrix

global vk_calc_visibility
vk_calc_visibility:
        push    rbp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15
        mov     rsi, rcx            ; worldXYZ
        mov     ecx, edx            ; count
        mov     rdi, r8             ; zetOut
        mov     r12, r9             ; visOut
        lea     r13, [rel cam_matrix]
        mov     r14d, [cam_cameraX]
        mov     r15d, [cam_cameraY]
        mov     ebx, [cam_cameraZ]
.next:
        mov     eax, [rsi]
        sub     eax, r14d
        imul    dword [r13 + 8]     ; m13
        shrd    eax, edx, 15
        mov     ebp, eax
        mov     eax, [rsi + 4]
        sub     eax, r15d
        imul    dword [r13 + 24]    ; m23
        shrd    eax, edx, 15
        add     ebp, eax
        mov     eax, [rsi + 8]
        sub     eax, ebx
        imul    dword [r13 + 40]    ; m33
        shrd    eax, edx, 15
        add     ebp, eax
        mov     [rdi], ebp
        xor     eax, eax
        cmp     ebp, 1
        setge   al
        mov     [r12], al
        add     rsi, 12
        add     rdi, 4
        inc     r12
        dec     ecx
        jnz     .next
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

global vk_virsort
vk_virsort:
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15
        mov     r12, rcx            ; zet
        lea     r13, [rel vvis_order]
        mov     r14d, edx           ; n
        ; order[i] = i
        xor     ecx, ecx
.init:
        mov     [r13 + rcx*4], ecx
        inc     ecx
        cmp     ecx, edx
        jne     .init
        ; stable insertion sort by low16(zet)
        mov     r15, 1              ; i (64-bit)
.outer:
        cmp     r15, r14
        jae     .done
        mov     ebx, [r13 + r15*4]      ; key = order[i]
        mov     edx, [r12 + rbx*4]
        and     edx, 0xFFFF             ; key zet
        mov     rsi, r15
        dec     rsi                     ; j = i-1  (signed 64-bit)
.inner:
        cmp     rsi, 0
        jl      .place                  ; j<0 -> insert at front
        mov     eax, [r13 + rsi*4]      ; order[j]
        mov     eax, [r12 + rax*4]
        and     eax, 0xFFFF
        cmp     eax, edx
        jle     .place                  ; order[j] <= key: stop (stable)
        mov     eax, [r13 + rsi*4]
        mov     [r13 + rsi*4 + 4], eax  ; order[j+1] = order[j]
        dec     rsi
        jmp     .inner
.place:
        mov     [r13 + rsi*4 + 4], ebx  ; order[j+1] = key (rsi=-1 wraps to 0)
        inc     r15
        jmp     .outer
.done:
        mov     rdi, r8
        mov     ecx, r14d
        lea     rsi, [rel vvis_order]
        rep movsd
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        ret
