; p2loop.asm - native x64 port of the P2 per-frame render loop
; (P2.AS^ Main / Main2): CalculateVisiblating -> VirSort -> WorldKol walk ->
; prepareObjectVirtual + drawObject.
;
; Composition over already-verified units:
;   - vk_calc_visibility (vvis.asm): packs each World record's XYZ, computes
;     camera-space z from cam_matrix + cam_cameraX/Y/Z, fills worldZet and
;     sets the record's +0 visible flag.
;   - vk_virsort (vvis.asm): stable sort of zet low16 -> WorldKol of record
;     indices far->near.
;   - per WorldKol entry: skip invisible; dispatch obj# (+16) and fs texture
;     via record +44 type -> textury[type] selector, then
;     vk_prepare_object(base, objects[obj], &rec[+4], &rec[+20]) and
;     vk_draw_object(base, objects[obj]).
;
; Win64 C ABI:
;   void vk_p2_render_frame(
;       uint8_t* base,                [rcx]    arena base
;       const int32_t* world,         [rdx]    World records (48B each, real ptr)
;       int count,                    [r8d]    number of records
;       int32_t* worldZet,            [r9]     4B/record z output
;       int32_t* worldKol,            [rbp+0x10]  sorted index output
;       const uint32_t* objects,      [rbp+0x18]  object struct offset table
;       const uint16_t* textury,      [rbp+0x20]  type -> texture-sel table
;       int32_t* trace)               [rbp+0x28]  0 = real render, else record
;
; Trace (trace != 0): per record in WorldKol order writes 3 dwords
;   { drawn(0/1), recordIndex, objNumber } so the CTest can verify the
;   visibility gate + dispatch order deterministically without rasterizing.
;
; Real mode additionally sets fs_sel (texture) and calls prepare + draw, which
; write into the loaded object structs (gs_sel must be set by the caller).
;
; Frame: push rbp (frame) + 7 pushes + sub 0x28 -> RSP%16==0 at call sites.
; Loop state kept in callee-saved regs (all helpers preserve them):
;   r15 = WorldKol ptr, r14 = loop counter, r13 = record ptr, rbx = record idx.

BITS 64
DEFAULT REL

%include "eos.inc"

extern vk_calc_visibility
extern vk_virsort
extern vk_prepare_object
extern vk_draw_object
extern fs_sel
extern gs_sel

section .bss align=16
pl_base:    resq 1
pl_world:   resq 1
pl_zet:     resq 1
pl_kol:     resq 1
pl_objects: resq 1
pl_textury: resq 1
pl_trace:   resq 1
pl_count:   resd 1
pl_xyz:     resd 768         ; packed xyz scratch (255*3)
pl_vis:     resb 256         ; visibility flags scratch
pl_recno:   resd 1           ; obj# for the current record
pl_typ:     resd 1           ; type for the current record

section .text

global vk_p2_render_frame
vk_p2_render_frame:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0x28

        mov     [pl_base], rcx
        mov     [pl_world], rdx
        mov     [pl_count], r8d
        mov     [pl_zet], r9
        mov     rax, [rbp + 0x30]      ; worldKol
        mov     [pl_kol], rax
        mov     rax, [rbp + 0x38]      ; objects
        mov     [pl_objects], rax
        mov     rax, [rbp + 0x40]      ; textury
        mov     [pl_textury], rax
        mov     rax, [rbp + 0x48]      ; trace
        mov     [pl_trace], rax

        ; ---- pack World records (48B) -> contiguous xyz (12B) ----
        mov     r12, [pl_world]
        lea     r13, [rel pl_xyz]
        xor     ecx, ecx
.pack:
        cmp     ecx, [pl_count]
        jae     .packdone
        mov     eax, [r12 + 4]          ; X
        mov     [r13 + 0*4], eax
        mov     eax, [r12 + 8]          ; Y
        mov     [r13 + 1*4], eax
        mov     eax, [r12 + 12]         ; Z
        mov     [r13 + 2*4], eax
        add     r12, 48
        add     r13, 12
        inc     ecx
        jmp     .pack
.packdone:

        ; ---- visibility: zet + vis flags ----
        lea     rcx, [rel pl_xyz]
        mov     edx, [pl_count]
        mov     r8, [pl_zet]
        lea     r9, [rel pl_vis]
        call    vk_calc_visibility

        ; ---- write visible flag into each World record +0 ----
        mov     r12, [pl_world]
        lea     r13, [rel pl_vis]
        xor     ecx, ecx
.visback:
        cmp     ecx, [pl_count]
        jae     .visdone
        movzx   eax, byte [r13 + rcx]
        mov     [r12], eax              ; record +0
        add     r12, 48
        inc     ecx
        jmp     .visback
.visdone:

        ; ---- VirSort -> WorldKol (record indices far->near, descending zet) ----
        mov     rcx, [pl_zet]
        mov     edx, [pl_count]
        mov     r8, [pl_kol]
        call    vk_virsort

        ; ---- walk WorldKol ----
        mov     r15, [pl_kol]           ; r15 = WorldKol
        xor     r14, r14                ; loop counter (32-bit)
.walk:
        cmp     r14d, [pl_count]        ; pl_count is a dword (32-bit compare!)
        jae     .done
        mov     ebx, [r15 + r14*4]      ; record index
        inc     r14
        lea     rdx, [rbx + rbx*2]      ; *3
        shl     rdx, 4                  ; *48
        mov     r12, [pl_world]
        lea     r13, [r12 + rdx]        ; r13 = this record (48B)

        ; visible flag at +0
        mov     eax, [r13]
        test    eax, eax
        je      .skip

        ; dispatch obj# / type
        mov     eax, [r13 + 16]         ; obj#
        mov     [pl_recno], eax
        mov     eax, [r13 + 44]         ; type
        mov     [pl_typ], eax
        test    eax, eax
        js      .skip                   ; negative type guard

        mov     rax, [pl_trace]
        test    rax, rax
        jnz     .trace

        ; ---- real render ----
        ; fs_sel = textury[type]
        mov     rdi, [pl_textury]
        mov     ecx, [pl_typ]
        movzx   ecx, word [rdi + rcx*2]
        mov     [fs_sel], ecx
        ; vk_prepare_object(base, objects[obj], &rec[+4], &rec[+20])
        mov     r12, [pl_objects]
        mov     ecx, [pl_recno]
        mov     edx, [r12 + rcx*4]      ; objects[obj] = arena offset
        ; r8 = &rec[+4], r9 = &rec[+20]
        lea     r8, [r13 + 4]
        lea     r9, [r13 + 20]
        mov     rcx, [pl_base]
        call    vk_prepare_object
        ; vk_draw_object(base, objects[obj])
        mov     r12, [pl_objects]
        mov     ecx, [pl_recno]
        mov     edx, [r12 + rcx*4]
        mov     rcx, [pl_base]
        call    vk_draw_object
        jmp     .next

.trace:
        mov     dword [rax + 0], 1
        mov     dword [rax + 4], ebx
        mov     ecx, [pl_recno]
        mov     [rax + 8], ecx
        add     rax, 12
        mov     [pl_trace], rax
        jmp     .next
.skip:
        mov     rax, [pl_trace]
        test    rax, rax
        jz      .next
        mov     dword [rax + 0], 0
        mov     dword [rax + 4], ebx
        mov     dword [rax + 8], 0
        add     rax, 12
        mov     [pl_trace], rax
.next:
        jmp     .walk
.done:
        add     rsp, 0x28
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret
