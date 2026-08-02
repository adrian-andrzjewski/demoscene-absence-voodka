; eos.inc - Flat-model replacement for the missing Borland EOS.INC.
;
; The original demo called EOS services via "int_eos" (software interrupt,
; ah = service id, register-based args). EOS.INC is not part of this repo,
; so the port defines its OWN service ids and routes every call through a
; single dispatcher:
;
;       mov eax, EOS_ALLOCATE_MEMORY
;       mov edx, <bytes>
;       call eos_dispatch
;
; eos_dispatch.asm adapts the EOS register convention to the C++ platform
; layer (Microsoft x64 ABI) and copies results back, so the ported code
; stays as close to the original as possible.
;
; == pointer model (IMPORTANT) ==
;   The arena base lives in the qword  Code32_addr  (== platform arena base).
;   All stored "addresses" are 32-bit OFFSETS into that arena (kept in dd/dw
;   variables, exactly like the original).  Convert offset->pointer with:
;       add r64, qword [rel Code32_addr]
;   (the original `add esi,Code32_addr` becomes a 64-bit add in the port).
;
; == selector model ==
;   fs/gs/es "segment selectors" are emulated with a small table in
;   eos_dispatch.asm mapping a 16-bit handle -> 64-bit base.  Site code that
;   used mov fs,sel / fs:[...] becomes base-register + index.  The texture
;   mappers (tm_face / face) are the only users and are rewritten to load
;   the base pointer up front.

%ifndef EOS_INC
%define EOS_INC

; ---------------------------------------------------------------------------
; EOS service ids (own numbering).  Convention: eax = service id in; the
; dispatcher preserves rbx/rsi/rdi unless they carry args or results.
; ---------------------------------------------------------------------------
%define EOS_QUERY_MEMORY        0x01  ; edx=0xFFFFFFFF -> eax=free bytes
%define EOS_ALLOCATE_MEMORY     0x02  ; edx=bytes -> edx=offset (zeroed)
%define EOS_DEALLOCATE_MEMORY   0x03  ; edx=offset (no-op)
%define EOS_ALLOCATE_SELECTOR   0x04  ; rsi=real ptr, edi=limit -> bx=handle
%define EOS_DEALLOCATE_SELECTOR 0x05  ; bx=handle
%define EOS_WAIT_VBL            0x06  ; -> eax = frame counter
%define EOS_GET_INFO            0x07  ; -> bl  = song position (ModPos)
%define EOS_LOAD_INTERNAL_FILE  0x08  ; edx = name ptr -> eax = arena offset
%define EOS_QUERY_SOUNDCARD     0x09  ; -> eax = 1 (present)
%define EOS_LOAD_MODULE         0x0A  ; al=1, edx=name ptr
%define EOS_SET_PATTERN         0x0B  ; bx=pos
%define EOS_PLAY_MODULE         0x0C
%define EOS_STOP_MODULE         0x0D
%define EOS_CLEAR_MODULE        0x0E
%define EOS_USE_INT_08          0x0F  ; bx=On/Off (timer chain) - no-op
%define EOS_USE_INT_09          0x10  ; bx=On/Off (keyboard)  - no-op
%define EOS_WRITE_EXTERNAL_FILE 0x11  ; dev-only, disabled

%define On      1
%define Off     0

; ---------------------------------------------------------------------------
; Convenience macros mimicking the original SYSTEM.PM / VIDEO.PM helpers.
; All route through eos_dispatch; results follow the notes above.
; ---------------------------------------------------------------------------

%macro AllocateMemory 2           ; AllocateMemory <bytes>, <storage>
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, %1
        call    eos_dispatch
        mov     [%2], edx
%endmacro

%macro AllocateMemoryFree 2       ; same, but zero-fills the block
        mov     eax, EOS_ALLOCATE_MEMORY
        mov     edx, %1
        call    eos_dispatch
        mov     [%2], edx
        mov     edi, edx
        add     rdi, qword [rel Code32_addr]   ; real pointer
        xor     eax, eax
        mov     ecx, %1
        shr     ecx, 2
        rep stosd
%endmacro

%macro LoadFile 2                 ; LoadFile "name", <storage>
        mov     eax, EOS_LOAD_INTERNAL_FILE
        lea     edx, [rel %%fname]
        call    eos_dispatch
        mov     [%2], eax
        jmp     short %%done
%%fname db %1, 0
%%done:
%endmacro

%macro WaitVbl 0
        mov     eax, EOS_WAIT_VBL
        call    eos_dispatch
%endmacro

%macro GetModPos 0
        mov     eax, EOS_GET_INFO
        call    eos_dispatch
        movzx   eax, bl
%endmacro

%endif ; EOS_INC
