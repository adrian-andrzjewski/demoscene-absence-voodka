; p2path.asm - P2 camera-path data + selection logic (P2 teardown unit 3).
;
; The packed dword tables are the byte-for-byte data from P2's TRASA! and
; WIDOKI (camera path + scripted camera views):
;   vk_p2_trasa  : N nodes of 6 int32 (x,y,z,ax,ay,az), 24 bytes each
;   vk_p2_widoki : M entries of 7 int32 (x,y,z,ax,ay,az,visible), 28 bytes each
;   vk_p2_trasa_nodes / vk_p2_widoki_entries : the counts.
;
;     void vk_p2_camera(int modpos, int trasaRuch, int32_t out[6])  [ecx,edx,r8]
;       replicates P2's Main camera selection:
;         modpos <= 0x63f  -> camera = trasa[trasaRuch mod N]
;         modpos >  0x63f  -> camera = widoki[modpos & 0x3f]
;       out = {x,y,z,ax,ay,az}

BITS 64
DEFAULT REL

section .data align=16
global vk_p2_trasa
vk_p2_trasa:
%include "p2trasa.inc"
global vk_p2_trasa_nodes
vk_p2_trasa_nodes: dd ($ - vk_p2_trasa) / 24

global vk_p2_widoki
vk_p2_widoki:
%include "p2widoki.inc"
global vk_p2_widoki_entries
vk_p2_widoki_entries: dd ($ - vk_p2_widoki) / 28

section .text

global vk_p2_camera
vk_p2_camera:
        push    rbx
        push    rsi
        push    rdi
        push    r12
        cmp     ecx, 0x63f
        jle     .trasa
        ; --- widoki: idx = modpos & 0x3f ; node = widoki[idx*28] ---
        mov     eax, ecx
        and     eax, 0x3f
        imul    eax, 28
        movsxd  rsi, eax
        lea     rdi, [rel vk_p2_widoki]
        add     rsi, rdi
        jmp     .read
.trasa:
        ; --- trasa: idx = trasaRuch mod N ; node = trasa[idx*24] ---
        mov     eax, edx
        mov     ecx, [rel vk_p2_trasa_nodes]
        xor     edx, edx
        div     ecx
        mov     eax, edx              ; idx = remainder (edx)
        imul    eax, 24
        movsxd  rsi, eax
        lea     rdi, [rel vk_p2_trasa]
        add     rsi, rdi
.read:
        ; copy 6 dwords x,y,z,ax,ay,az -> r8
        mov     rdi, r8
        mov     ecx, 6
        rep movsd
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        ret
