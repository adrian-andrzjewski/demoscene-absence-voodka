; audio_ring.asm - bounded lock-free SPSC PCM/timeline ring.
;
; The producer writes PCM and markers, then publishes its write index. The
; consumer reads only published bytes, then publishes its read index. Each
; side owns one index, so no compare/exchange loop is required; mfence gives
; the cross-thread release/acquire ordering needed by the ABI.

BITS 64
DEFAULT REL

%define RING_SAMPLES                  0
%define RING_CAPACITY                 8
%define RING_MASK                    12
%define RING_READ                    16
%define RING_WRITE                   20
%define RING_CLOSED                  24
%define RING_OVERRUN                 28
%define RING_UNDERRUN                32
%define RING_MARKERS                 36
%define RING_MARKER_CAP              44
%define RING_MARKER_MASK             48
%define RING_MARKER_READ             52
%define RING_MARKER_WRITE            56
%define RING_MARKER_OVERRUN          60

global asm_audio_ring_init
global asm_audio_ring_push
global asm_audio_ring_pop
global asm_audio_ring_push_marker
global asm_audio_ring_pop_marker
global asm_audio_ring_close

section .text

; uint32_t asm_audio_ring_init(AudioPcmRing* ring,
;                              int16_t* samples, uint32_t capacityFrames,
;                              AudioRingMarker* markers,
;                              uint32_t markerCapacity)
asm_audio_ring_init:
        mov     r10d, dword [rsp + 0x28]   ; fifth Win64 argument
        test    rcx, rcx
        jz      .init_bad
        test    rdx, rdx
        jz      .init_bad
        test    r8d, r8d
        jz      .init_bad
        mov     eax, r8d
        dec     eax
        test    eax, r8d
        jnz     .init_bad                  ; both capacities are powers of 2
        test    r9, r9
        jz      .init_bad
        test    r10d, r10d
        jz      .init_bad
        mov     eax, r10d
        dec     eax
        test    eax, r10d
        jnz     .init_bad

        mov     [rcx + RING_SAMPLES], rdx
        mov     dword [rcx + RING_CAPACITY], r8d
        mov     eax, r8d
        dec     eax
        mov     dword [rcx + RING_MASK], eax
        mov     dword [rcx + RING_READ], 0
        mov     dword [rcx + RING_WRITE], 0
        mov     dword [rcx + RING_CLOSED], 0
        mov     dword [rcx + RING_OVERRUN], 0
        mov     dword [rcx + RING_UNDERRUN], 0
        mov     [rcx + RING_MARKERS], r9
        mov     dword [rcx + RING_MARKER_CAP], r10d
        mov     eax, r10d
        dec     eax
        mov     dword [rcx + RING_MARKER_MASK], eax
        mov     dword [rcx + RING_MARKER_READ], 0
        mov     dword [rcx + RING_MARKER_WRITE], 0
        mov     dword [rcx + RING_MARKER_OVERRUN], 0
        mfence
        xor     eax, eax
        ret

.init_bad:
        mov     eax, 1
        ret

; uint32_t asm_audio_ring_push(AudioPcmRing* ring,
;                              const int16_t* frames, uint32_t frameCount)
asm_audio_ring_push:
        push    rsi
        push    rdi
        test    rcx, rcx
        jz      .push_none
        mov     r11, rcx                    ; preserve ring pointer
        mov     rsi, rdx                    ; source PCM
        mov     r9d, r8d                    ; requested count
        test    r9d, r9d
        jz      .push_none
        test    rsi, rsi
        jz      .push_none
        cmp     dword [r11 + RING_CLOSED], 0
        jne     .push_none
        mfence

        mov     eax, dword [r11 + RING_WRITE]
        mov     r10d, dword [r11 + RING_READ]
        mfence
        mov     edx, eax
        sub     edx, r10d                   ; used = write - read
        mov     r10d, dword [r11 + RING_CAPACITY]
        cmp     edx, r10d
        jae     .push_full
        sub     r10d, edx                   ; free frames
        cmp     r9d, r10d
        jbe     .push_count_ready
        mov     r8d, r10d
        inc     dword [r11 + RING_OVERRUN]
        mov     r9d, r8d
.push_count_ready:
        test    r9d, r9d
        jz      .push_none
        mov     r10d, r9d                   ; accepted count

        mov     rdi, [r11 + RING_SAMPLES]
        mov     edx, dword [r11 + RING_WRITE]
        mov     eax, edx
        and     eax, dword [r11 + RING_MASK]
        lea     rdi, [rdi + rax * 4]        ; one stereo frame = dword
        mov     ecx, dword [r11 + RING_CAPACITY]
        sub     ecx, eax                    ; frames until physical wrap
        cmp     r9d, ecx
        ja      .push_first_ready
        mov     ecx, r9d
.push_first_ready:
        mov     r8d, ecx
        call    .push_copy_dwords
        sub     r9d, r8d
        jz      .push_publish

        mov     rdi, [r11 + RING_SAMPLES]
        mov     ecx, r9d
        call    .push_copy_dwords

.push_publish:
        mfence
        mov     eax, dword [r11 + RING_WRITE]
        add     eax, r10d
        mov     dword [r11 + RING_WRITE], eax
        mov     eax, r10d
        pop     rdi
        pop     rsi
        ret

.push_full:
        inc     dword [r11 + RING_OVERRUN]
.push_none:
        xor     eax, eax
        pop     rdi
        pop     rsi
        ret

.push_copy_dwords:
        test    ecx, ecx
        jz      .push_copy_done
.push_copy_loop:
        mov     eax, dword [rsi]
        mov     dword [rdi], eax
        add     rsi, 4
        add     rdi, 4
        dec     ecx
        jnz     .push_copy_loop
.push_copy_done:
        ret

; uint32_t asm_audio_ring_pop(AudioPcmRing* ring,
;                             int16_t* frames, uint32_t frameCapacity)
asm_audio_ring_pop:
        push    rsi
        push    rdi
        test    rcx, rcx
        jz      .pop_none
        mov     r11, rcx                    ; preserve ring pointer
        mov     rsi, rdx                    ; destination PCM
        mov     r9d, r8d                    ; requested count
        test    r9d, r9d
        jz      .pop_none
        test    rsi, rsi
        jz      .pop_none
        mfence

        mov     eax, dword [r11 + RING_READ]
        mov     r10d, dword [r11 + RING_WRITE]
        mfence
        sub     r10d, eax                   ; available = write - read
        test    r10d, r10d
        jz      .pop_empty
        cmp     r9d, r10d
        jbe     .pop_count_ready
        inc     dword [r11 + RING_UNDERRUN]
        mov     r9d, r10d
.pop_count_ready:
        mov     r10d, r9d                   ; accepted count

        mov     rdi, [r11 + RING_SAMPLES]
        mov     edx, dword [r11 + RING_READ]
        mov     eax, edx
        and     eax, dword [r11 + RING_MASK]
        lea     rdi, [rdi + rax * 4]
        mov     ecx, dword [r11 + RING_CAPACITY]
        sub     ecx, eax
        cmp     r9d, ecx
        ja      .pop_first_ready
        mov     ecx, r9d
.pop_first_ready:
        mov     r8d, ecx
        call    .pop_copy_dwords
        sub     r9d, r8d
        jz      .pop_publish

        mov     rdi, [r11 + RING_SAMPLES]
        mov     ecx, r9d
        call    .pop_copy_dwords

.pop_publish:
        mfence
        mov     eax, dword [r11 + RING_READ]
        add     eax, r10d
        mov     dword [r11 + RING_READ], eax
        mov     eax, r10d
        pop     rdi
        pop     rsi
        ret

.pop_empty:
        inc     dword [r11 + RING_UNDERRUN]
.pop_none:
        xor     eax, eax
        pop     rdi
        pop     rsi
        ret

.pop_copy_dwords:
        test    ecx, ecx
        jz      .pop_copy_done
.pop_copy_loop:
        mov     eax, dword [rdi]
        mov     dword [rsi], eax
        add     rsi, 4
        add     rdi, 4
        dec     ecx
        jnz     .pop_copy_loop
.pop_copy_done:
        ret

; uint32_t asm_audio_ring_push_marker(AudioPcmRing* ring,
;                                      uint32_t frame, uint32_t modpos)
asm_audio_ring_push_marker:
        mov     r10d, edx                   ; preserve frame
        mov     r11d, r8d                   ; preserve ModPos
        test    rcx, rcx
        jz      .marker_push_none
        cmp     dword [rcx + RING_CLOSED], 0
        jne     .marker_push_none
        mfence
        mov     eax, dword [rcx + RING_MARKER_WRITE]
        mov     r9d, dword [rcx + RING_MARKER_READ]
        mov     edx, eax
        sub     edx, r9d
        mov     r9d, dword [rcx + RING_MARKER_CAP]
        cmp     edx, r9d
        jae     .marker_push_full
        mov     r9, [rcx + RING_MARKERS]
        mov     edx, eax
        and     edx, dword [rcx + RING_MARKER_MASK]
        lea     r9, [r9 + rdx * 8]
        mov     dword [r9], r10d
        mov     dword [r9 + 4], r11d
        mfence
        inc     eax
        mov     dword [rcx + RING_MARKER_WRITE], eax
        mov     eax, 1
        ret

.marker_push_full:
        inc     dword [rcx + RING_MARKER_OVERRUN]
.marker_push_none:
        xor     eax, eax
        ret

; uint32_t asm_audio_ring_pop_marker(AudioPcmRing* ring,
;                                     uint32_t consumedFrame,
;                                     AudioRingMarker* marker)
asm_audio_ring_pop_marker:
        mov     r10d, edx                   ; consumed frame threshold
        test    rcx, rcx
        jz      .marker_pop_none
        test    r8, r8
        jz      .marker_pop_none
        mfence
        mov     eax, dword [rcx + RING_MARKER_READ]
        mov     r9d, dword [rcx + RING_MARKER_WRITE]
        cmp     eax, r9d
        je      .marker_pop_none
        mfence
        mov     r9, [rcx + RING_MARKERS]
        mov     edx, eax
        and     edx, dword [rcx + RING_MARKER_MASK]
        lea     r9, [r9 + rdx * 8]
        cmp     dword [r9], r10d
        ja      .marker_pop_none
        mov     rdx, [r9]
        mov     [r8], rdx
        mfence
        inc     eax
        mov     dword [rcx + RING_MARKER_READ], eax
        mov     eax, 1
        ret

.marker_pop_none:
        xor     eax, eax
        ret

; void asm_audio_ring_close(AudioPcmRing* ring)
asm_audio_ring_close:
        test    rcx, rcx
        jz      .close_done
        mfence
        mov     dword [rcx + RING_CLOSED], 1
        mfence
.close_done:
        ret
