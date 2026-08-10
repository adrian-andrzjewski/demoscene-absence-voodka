; d3d11_asm_probe.asm - direct Win64 D3D11/COM feasibility probe.
;
; This is Phase 1 validation code. It deliberately owns the D3D11 calls in
; NASM instead of forwarding them through C++. The existing C++ presenter is
; still the production reference until the complete presenter gate passes.
;
; The probe creates a hardware D3D11 device and swap chain, obtains the
; backbuffer through IDXGISwapChain::GetBuffer, creates an RTV, clears it,
; copies it into a staging texture, maps the staging texture, presents once,
; and releases every acquired interface. The C++ host only supplies an HWND
; and receives fixed-width diagnostics.

BITS 64
DEFAULT REL

%include "win64_abi.inc"

; D3D11/DXGI constants used by this probe.
%define D3D_DRIVER_TYPE_HARDWARE       1
%define D3D_FEATURE_LEVEL_11_0         0xB000
%define D3D11_SDK_VERSION              7
%define DXGI_FORMAT_R8G8B8A8_UNORM     28
%define DXGI_USAGE_RENDER_TARGET_OUTPUT 0x20
%define DXGI_SWAP_EFFECT_DISCARD       0
%define D3D11_USAGE_STAGING            3
%define D3D11_CPU_ACCESS_READ          0x20000
%define D3D11_MAP_READ                 1

; COM vtable slots. IUnknown occupies slots 0..2. ID3D11DeviceContext also
; inherits ID3D11DeviceChild (GetDevice/GetPrivateData/SetPrivateData/
; SetPrivateDataInterface), so its first concrete context method starts at 7.
%define IDXGISWAPCHAIN_PRESENT         8
%define IDXGISWAPCHAIN_GETBUFFER       9
%define ID3D11DEVICE_CREATETEXTURE2D   5
%define ID3D11DEVICE_CREATE_RTV        9
%define ID3D11CONTEXT_MAP              14
%define ID3D11CONTEXT_UNMAP            15
%define ID3D11CONTEXT_OMSETTARGETS     33
%define ID3D11CONTEXT_COPYRESOURCE     47
%define ID3D11CONTEXT_CLEAR_RTV        50
%define IUNKNOWN_RELEASE               2

; DXGI_SWAP_CHAIN_DESC offsets and size on Win64. The HWND field is naturally
; aligned at offset 48 after the two 4-byte-aligned descriptor structures.
%define DXGI_DESC_WIDTH                0
%define DXGI_DESC_HEIGHT               4
%define DXGI_DESC_FORMAT               16
%define DXGI_DESC_SAMPLE_COUNT         28
%define DXGI_DESC_BUFFER_USAGE         36
%define DXGI_DESC_BUFFER_COUNT         40
%define DXGI_DESC_OUTPUT_WINDOW        48
%define DXGI_DESC_WINDOWED             56
%define DXGI_DESC_SWAP_EFFECT          60
%define DXGI_SWAP_CHAIN_DESC_BYTES     72

; D3D11_TEXTURE2D_DESC offsets and size.
%define D3D11_TEX_WIDTH                0
%define D3D11_TEX_HEIGHT               4
%define D3D11_TEX_MIP_LEVELS           8
%define D3D11_TEX_ARRAY_SIZE           12
%define D3D11_TEX_FORMAT               16
%define D3D11_TEX_SAMPLE_COUNT         20
%define D3D11_TEX_SAMPLE_QUALITY       24
%define D3D11_TEX_USAGE                28
%define D3D11_TEX_BIND_FLAGS           32
%define D3D11_TEX_CPU_ACCESS           36
%define D3D11_TEX_MISC_FLAGS           40
%define D3D11_TEXTURE2D_DESC_BYTES     44

; D3D11_MAPPED_SUBRESOURCE is { void*, UINT RowPitch, UINT DepthPitch }.
%define MAPPED_PDATA                   0
%define MAPPED_ROW_PITCH               8

; D3DAsmProbeReport: nine uint32_t fields, no pointers or ABI-dependent types.
%define REPORT_INIT_HR                 0
%define REPORT_GETBUFFER_HR            4
%define REPORT_RTV_HR                  8
%define REPORT_STAGING_HR              12
%define REPORT_MAP_HR                  16
%define REPORT_PRESENT_HR              20
%define REPORT_ROW_PITCH               24
%define REPORT_FIRST_PIXEL             28
%define REPORT_FEATURE_LEVEL           32
%define REPORT_BYTES                   36

extern D3D11CreateDeviceAndSwapChain

global asm_d3d11_probe

section .bss
align 8
probe_swap:             resq 1
probe_device:           resq 1
probe_context:          resq 1
probe_backbuffer:       resq 1
probe_rtv:              resq 1
probe_staging:          resq 1

probe_swap_desc:        resb DXGI_SWAP_CHAIN_DESC_BYTES
probe_staging_desc:     resb D3D11_TEXTURE2D_DESC_BYTES
probe_mapped:           resb 16
probe_out_feature:      resd 1

section .data
align 4
probe_feature_levels:   dd D3D_FEATURE_LEVEL_11_0

; Clear color is R=1.0, G=0.25, B=0.5, A=1.0. For an UNORM readback the
; expected byte sequence is FF 40 80 FF (uint32_t 0xFF8040FF on little endian).
align 4
probe_clear_color:      dd 0x3F800000, 0x3E800000, 0x3F000000, 0x3F800000

; IID_ID3D11Texture2D = {6F15AAF2-D208-4E89-9AB4-489535D34F9C}.
align 4
probe_iid_texture2d:    db 0xF2,0xAA,0x15,0x6F, 0x08,0xD2, 0x89,0x4E
                        db 0x9A,0xB4,0x48,0x95,0x35,0xD3,0x4F,0x9C

; ---------------------------------------------------------------------------
; uint32_t asm_d3d11_probe(HWND hwnd, uint32_t width, uint32_t height,
;                          D3DAsmProbeReport* report)
;
; The function is called by a normal C++ caller. Eight saved registers leave
; RSP%16==8; reserving 0x68 bytes changes it to zero and provides the 32-byte
; home area plus all eight stack arguments required by
; D3D11CreateDeviceAndSwapChain.
; ---------------------------------------------------------------------------
section .text
asm_d3d11_probe:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0x68

        mov     rsi, rcx                    ; HWND
        mov     r14d, edx                   ; width
        mov     r15d, r8d                   ; height
        mov     r12, r9                     ; report pointer
        xor     r13d, r13d                  ; success unless a gate fails

        ; Clear report and resource slots so repeated probes cannot inherit
        ; stale COM pointers from a prior attempt.
        lea     rdi, [rel probe_swap]
        xor     eax, eax
        mov     ecx, 6
        rep stosq
        lea     rdi, [rel probe_swap_desc]
        xor     eax, eax
        mov     ecx, DXGI_SWAP_CHAIN_DESC_BYTES / 8
        rep stosq
        lea     rdi, [rel probe_staging_desc]
        xor     eax, eax
        mov     ecx, D3D11_TEXTURE2D_DESC_BYTES / 4
        rep stosd
        lea     rdi, [rel probe_mapped]
        xor     eax, eax
        mov     ecx, 4
        rep stosd
        mov     dword [rel probe_out_feature], 0
        mov     rdi, r12
        xor     eax, eax
        mov     ecx, REPORT_BYTES / 4
        rep stosd

        ; Fill DXGI_SWAP_CHAIN_DESC.
        mov     dword [rel probe_swap_desc + DXGI_DESC_WIDTH], r14d
        mov     dword [rel probe_swap_desc + DXGI_DESC_HEIGHT], r15d
        mov     dword [rel probe_swap_desc + DXGI_DESC_FORMAT], DXGI_FORMAT_R8G8B8A8_UNORM
        mov     dword [rel probe_swap_desc + DXGI_DESC_SAMPLE_COUNT], 1
        mov     dword [rel probe_swap_desc + DXGI_DESC_BUFFER_USAGE], DXGI_USAGE_RENDER_TARGET_OUTPUT
        mov     dword [rel probe_swap_desc + DXGI_DESC_BUFFER_COUNT], 2
        mov     qword [rel probe_swap_desc + DXGI_DESC_OUTPUT_WINDOW], rsi
        mov     dword [rel probe_swap_desc + DXGI_DESC_WINDOWED], 1
        mov     dword [rel probe_swap_desc + DXGI_DESC_SWAP_EFFECT], DXGI_SWAP_EFFECT_DISCARD

        ; D3D11CreateDeviceAndSwapChain(adapter, driverType, software, flags,
        ; featureLevels, featureLevelCount, sdkVersion, desc, ppSwap,
        ; ppDevice, pFeatureLevel, ppImmediateContext).
        lea     rax, [rel probe_feature_levels]
        mov     [rsp + 0x20], rax
        mov     qword [rsp + 0x28], 1
        mov     qword [rsp + 0x30], D3D11_SDK_VERSION
        lea     rax, [rel probe_swap_desc]
        mov     [rsp + 0x38], rax
        lea     rax, [rel probe_swap]
        mov     [rsp + 0x40], rax
        lea     rax, [rel probe_device]
        mov     [rsp + 0x48], rax
        lea     rax, [rel probe_out_feature]
        mov     [rsp + 0x50], rax
        lea     rax, [rel probe_context]
        mov     [rsp + 0x58], rax
        xor     ecx, ecx                    ; default adapter
        mov     edx, D3D_DRIVER_TYPE_HARDWARE
        xor     r8d, r8d                     ; no software rasterizer
        xor     r9d, r9d                     ; no creation flags
        call    D3D11CreateDeviceAndSwapChain
        mov     dword [r12 + REPORT_INIT_HR], eax
        test    eax, eax
        js      .fail
        mov     eax, [rel probe_out_feature]
        mov     dword [r12 + REPORT_FEATURE_LEVEL], eax

        ; IDXGISwapChain::GetBuffer(0, IID_ID3D11Texture2D, &backbuffer).
        mov     rcx, [rel probe_swap]
        xor     edx, edx
        lea     r8, [rel probe_iid_texture2d]
        lea     r9, [rel probe_backbuffer]
        mov     rax, [rcx]
        call    qword [rax + IDXGISWAPCHAIN_GETBUFFER * 8]
        mov     dword [r12 + REPORT_GETBUFFER_HR], eax
        test    eax, eax
        js      .fail

        ; ID3D11Device::CreateRenderTargetView(backbuffer, NULL, &rtv).
        mov     rcx, [rel probe_device]
        mov     rdx, [rel probe_backbuffer]
        xor     r8d, r8d
        lea     r9, [rel probe_rtv]
        mov     rax, [rcx]
        call    qword [rax + ID3D11DEVICE_CREATE_RTV * 8]
        mov     dword [r12 + REPORT_RTV_HR], eax
        test    eax, eax
        js      .fail

        ; Bind and clear the render target through ID3D11DeviceContext.
        mov     rcx, [rel probe_context]
        mov     edx, 1
        lea     r8, [rel probe_rtv]
        xor     r9d, r9d
        mov     rax, [rcx]
        call    qword [rax + ID3D11CONTEXT_OMSETTARGETS * 8]

        mov     rcx, [rel probe_context]
        mov     rdx, [rel probe_rtv]
        lea     r8, [rel probe_clear_color]
        mov     rax, [rcx]
        call    qword [rax + ID3D11CONTEXT_CLEAR_RTV * 8]

        ; Create a CPU-readable staging texture for a deterministic GPU
        ; readback. Its dimensions and format match the swap chain.
        mov     dword [rel probe_staging_desc + D3D11_TEX_WIDTH], r14d
        mov     dword [rel probe_staging_desc + D3D11_TEX_HEIGHT], r15d
        mov     dword [rel probe_staging_desc + D3D11_TEX_MIP_LEVELS], 1
        mov     dword [rel probe_staging_desc + D3D11_TEX_ARRAY_SIZE], 1
        mov     dword [rel probe_staging_desc + D3D11_TEX_FORMAT], DXGI_FORMAT_R8G8B8A8_UNORM
        mov     dword [rel probe_staging_desc + D3D11_TEX_SAMPLE_COUNT], 1
        mov     dword [rel probe_staging_desc + D3D11_TEX_SAMPLE_QUALITY], 0
        mov     dword [rel probe_staging_desc + D3D11_TEX_USAGE], D3D11_USAGE_STAGING
        mov     dword [rel probe_staging_desc + D3D11_TEX_BIND_FLAGS], 0
        mov     dword [rel probe_staging_desc + D3D11_TEX_CPU_ACCESS], D3D11_CPU_ACCESS_READ
        mov     dword [rel probe_staging_desc + D3D11_TEX_MISC_FLAGS], 0

        mov     rcx, [rel probe_device]
        lea     rdx, [rel probe_staging_desc]
        xor     r8d, r8d
        lea     r9, [rel probe_staging]
        mov     rax, [rcx]
        call    qword [rax + ID3D11DEVICE_CREATETEXTURE2D * 8]
        mov     dword [r12 + REPORT_STAGING_HR], eax
        test    eax, eax
        js      .fail

        ; CopyResource(staging, backbuffer) and Map(staging, READ, ...).
        mov     rcx, [rel probe_context]
        mov     rdx, [rel probe_staging]
        mov     r8, [rel probe_backbuffer]
        mov     rax, [rcx]
        call    qword [rax + ID3D11CONTEXT_COPYRESOURCE * 8]

        mov     rcx, [rel probe_context]
        mov     rdx, [rel probe_staging]
        xor     r8d, r8d                    ; subresource 0
        mov     r9d, D3D11_MAP_READ
        mov     qword [rsp + 0x20], 0       ; Map flags
        lea     rax, [rel probe_mapped]
        mov     [rsp + 0x28], rax
        mov     rax, [rcx]
        call    qword [rax + ID3D11CONTEXT_MAP * 8]
        mov     dword [r12 + REPORT_MAP_HR], eax
        test    eax, eax
        js      .fail

        mov     eax, dword [rel probe_mapped + MAPPED_ROW_PITCH]
        mov     dword [r12 + REPORT_ROW_PITCH], eax
        mov     rax, [rel probe_mapped + MAPPED_PDATA]
        mov     eax, dword [rax]
        mov     dword [r12 + REPORT_FIRST_PIXEL], eax

        ; Unmap before Present and cleanup.
        mov     rcx, [rel probe_context]
        mov     rdx, [rel probe_staging]
        xor     r8d, r8d
        mov     rax, [rcx]
        call    qword [rax + ID3D11CONTEXT_UNMAP * 8]

        ; IDXGISwapChain::Present(0, 0).
        mov     rcx, [rel probe_swap]
        xor     edx, edx
        xor     r8d, r8d
        mov     rax, [rcx]
        call    qword [rax + IDXGISWAPCHAIN_PRESENT * 8]
        mov     dword [r12 + REPORT_PRESENT_HR], eax
        test    eax, eax
        js      .fail

        xor     r13d, r13d
        jmp     .cleanup

.fail:
        mov     r13d, 1

.cleanup:
        ; Release in dependency order. IUnknown::Release is vtable slot 2.
        mov     rcx, [rel probe_staging]
        test    rcx, rcx
        jz      .no_staging
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.no_staging:
        mov     rcx, [rel probe_rtv]
        test    rcx, rcx
        jz      .no_rtv
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.no_rtv:
        mov     rcx, [rel probe_backbuffer]
        test    rcx, rcx
        jz      .no_backbuffer
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.no_backbuffer:
        mov     rcx, [rel probe_context]
        test    rcx, rcx
        jz      .no_context
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.no_context:
        mov     rcx, [rel probe_device]
        test    rcx, rcx
        jz      .no_device
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.no_device:
        mov     rcx, [rel probe_swap]
        test    rcx, rcx
        jz      .no_swap
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.no_swap:
        mov     qword [rel probe_staging], 0
        mov     qword [rel probe_rtv], 0
        mov     qword [rel probe_backbuffer], 0
        mov     qword [rel probe_context], 0
        mov     qword [rel probe_device], 0
        mov     qword [rel probe_swap], 0

        mov     eax, r13d
        add     rsp, 0x68
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret
