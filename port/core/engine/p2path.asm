; p2path.asm - swiatynia city (P2) camera-path data + selection logic (swiatynia city (P2) teardown unit 3).
;
; The packed dword tables are the byte-for-byte data from swiatynia city (P2)'s TRASA! and
; WIDOKI (camera path + scripted camera views):
;   vk_swiatynia_city_trasa  : N nodes of 6 int32 (x,y,z,ax,ay,az), 24 bytes each
;   vk_swiatynia_city_widoki : M entries of 7 int32 (x,y,z,ax,ay,az,visible), 28 bytes each
;   vk_swiatynia_city_trasa_nodes / vk_swiatynia_city_widoki_entries : the counts.
;
;     void vk_swiatynia_city_camera(int modpos, int trasaRuch, int32_t out[6])  [ecx,edx,r8]
;       replicates swiatynia city (P2)'s Main camera selection:
;         modpos <= 0x63f  -> camera = trasa[trasaRuch mod N]
;         modpos >  0x63f  -> camera = widoki[modpos & 0x3f]
;       out = {x,y,z,ax,ay,az}

BITS 64
DEFAULT REL

section .data align=16
global vk_swiatynia_city_trasa
vk_swiatynia_city_trasa:
%include "p2trasa.inc"
global vk_swiatynia_city_trasa_nodes
vk_swiatynia_city_trasa_nodes: dd ($ - vk_swiatynia_city_trasa) / 24

global vk_swiatynia_city_widoki
vk_swiatynia_city_widoki:
%include "p2widoki.inc"
global vk_swiatynia_city_widoki_entries
vk_swiatynia_city_widoki_entries: dd ($ - vk_swiatynia_city_widoki) / 28
global vk_swiatynia_city_camera_flash_flag
vk_swiatynia_city_camera_flash_flag: dd 0

section .text

global vk_swiatynia_city_camera
vk_swiatynia_city_camera:
        push    rbx
        push    rsi
        push    rdi
        push    r12
        xor     r12d, r12d
        cmp     ecx, 0x63f
        jle     .trasa
        ; --- widoki: idx = modpos & 0x3f ; node = widoki[idx*28] ---
        mov     eax, ecx
        and     eax, 0x3f
        imul    eax, 28
        movsxd  rsi, eax
        lea     rdi, [rel vk_swiatynia_city_widoki]
        add     rsi, rdi
        mov     r12d, [rsi + 24]
        jmp     .read
.trasa:
        ; --- trasa: idx = trasaRuch mod N ; node = trasa[idx*24] ---
        mov     eax, edx
        mov     ecx, [rel vk_swiatynia_city_trasa_nodes]
        xor     edx, edx
        div     ecx
        mov     eax, edx              ; idx = remainder (edx)
        imul    eax, 24
        movsxd  rsi, eax
        lea     rdi, [rel vk_swiatynia_city_trasa]
        add     rsi, rdi
.read:
        ; copy 6 dwords x,y,z,ax,ay,az -> r8
        mov     rdi, r8
        mov     ecx, 6
        rep movsd
        ; WIDOKI carries a seventh dword: the original `flashFlag` used by
        ; swiatynia city (P2)'s plum/lampa camera-cut flash guard.  TRASA leaves it zero.
        mov     [rel vk_swiatynia_city_camera_flash_flag], r12d
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        ret
