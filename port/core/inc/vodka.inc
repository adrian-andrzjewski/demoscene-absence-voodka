; vodka.inc - NASM port of CODE/INC/VODKA (packed-archive index resolution).
;
;   vodka <index>, <dwordDestVar>
;     _file_addr : dword arena offset of the packed archive's offset table.
;       table entry n = [2 dwords] at byte n*8: file_offset, file_size
;     vodka computes the arena offset of file <index> and stores it into
;     dwordDestVar.  (Stored dword "addresses" are arena offsets; the ported
;     parts resolve them to real 64-bit pointers at deref time by adding the
;     qword Code32_addr.)

%ifndef VODKA_INC
%define VODKA_INC

%include "eos.inc"

extern Code32_addr
extern _file_addr

section .text
%macro vodka 2
        mov     esi, [rel _file_addr]        ; archive table arena offset
        add     rsi, qword [rel Code32_addr] ; real pointer to table
        mov     eax, [rsi + (%1)*8]          ; file offset relative to table
        add     rsi, rax
        sub     rsi, qword [rel Code32_addr] ; back to arena offset
        mov     [%2], esi                    ; store dword arena offset
%endmacro

%endif ; VODKA_INC
