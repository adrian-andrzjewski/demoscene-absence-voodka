; d3d11_asm_present.asm - assembly-owned indexed/palette D3D11 presenter.
;
; Phase 1B candidate. Window creation and host-side validation remain outside
; this file; all D3D11 objects, shader creation, uploads, draw calls, readback,
; Present, and COM Release calls are performed here through explicit vtables.

BITS 64
DEFAULT REL

%include "win64_abi.inc"
%include "d3d11_shader_paths.inc"

%define D3D_DRIVER_TYPE_HARDWARE        1
%define D3D_FEATURE_LEVEL_11_0          0xB000
%define D3D11_SDK_VERSION               7
%define DXGI_FORMAT_R8_UNORM            61
%define DXGI_FORMAT_R8G8B8A8_UNORM      28
%define DXGI_FORMAT_R32G32_FLOAT        16
%define DXGI_USAGE_RENDER_TARGET_OUTPUT 0x20
%define DXGI_SWAP_EFFECT_DISCARD        0
%define D3D11_USAGE_DEFAULT             0
%define D3D11_USAGE_DYNAMIC             2
%define D3D11_USAGE_STAGING             3
%define D3D11_BIND_VERTEX_BUFFER        0x1
%define D3D11_BIND_SHADER_RESOURCE      0x8
%define D3D11_CPU_ACCESS_WRITE          0x10000
%define D3D11_CPU_ACCESS_READ           0x20000
%define D3D11_FILTER_MIN_MAG_MIP_POINT  0
%define D3D11_TEXTURE_ADDRESS_CLAMP     3
%define D3D11_COMPARISON_NEVER          1
%define D3D11_FILL_SOLID                3
%define D3D11_CULL_NONE                 1
%define D3D11_MAP_WRITE_DISCARD         4
%define D3D11_MAP_READ                  1
%define D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST 4

; ID3D11Device slots. Device inherits IUnknown only, and its method order
; includes CreateUnorderedAccessView before CreateRenderTargetView and the
; geometry-shader-with-stream-output entry before CreatePixelShader.
%define DEVICE_CREATE_BUFFER            3
%define DEVICE_CREATE_TEXTURE2D         5
%define DEVICE_CREATE_SRV               7
%define DEVICE_CREATE_RTV               9
%define DEVICE_CREATE_INPUT_LAYOUT      11
%define DEVICE_CREATE_VERTEX_SHADER     12
%define DEVICE_CREATE_PIXEL_SHADER      15
%define DEVICE_CREATE_RASTERIZER        22
%define DEVICE_CREATE_SAMPLER           23

; ID3D11DeviceContext inherits ID3D11DeviceChild's four methods, so its first
; concrete method is slot 7.
%define CONTEXT_PS_SET_SHADER_RESOURCES 8
%define CONTEXT_PS_SET_SHADER           9
%define CONTEXT_PS_SET_SAMPLERS         10
%define CONTEXT_VS_SET_SHADER           11
%define CONTEXT_MAP                     14
%define CONTEXT_UNMAP                   15
%define CONTEXT_IA_SET_INPUT_LAYOUT     17
%define CONTEXT_IA_SET_VERTEX_BUFFERS   18
%define CONTEXT_IA_SET_TOPOLOGY         24
%define CONTEXT_OM_SET_TARGETS          33
%define CONTEXT_RS_SET_STATE            43
%define CONTEXT_RS_SET_VIEWPORTS        44
%define CONTEXT_COPY_RESOURCE           47
%define CONTEXT_CLEAR_RTV               50
%define CONTEXT_DRAW                    13

%define SWAPCHAIN_PRESENT               8
%define SWAPCHAIN_GETBUFFER             9
%define IUNKNOWN_RELEASE                2

%define DXGI_DESC_WIDTH                 0
%define DXGI_DESC_HEIGHT                4
%define DXGI_DESC_FORMAT                16
%define DXGI_DESC_SAMPLE_COUNT          28
%define DXGI_DESC_BUFFER_USAGE          36
%define DXGI_DESC_BUFFER_COUNT          40
%define DXGI_DESC_OUTPUT_WINDOW         48
%define DXGI_DESC_WINDOWED              56
%define DXGI_DESC_SWAP_EFFECT           60
%define DXGI_SWAP_CHAIN_DESC_BYTES      72

%define TEX_WIDTH                       0
%define TEX_HEIGHT                      4
%define TEX_MIP_LEVELS                  8
%define TEX_ARRAY_SIZE                  12
%define TEX_FORMAT                      16
%define TEX_SAMPLE_COUNT                20
%define TEX_SAMPLE_QUALITY              24
%define TEX_USAGE                       28
%define TEX_BIND_FLAGS                  32
%define TEX_CPU_ACCESS                  36
%define TEX_MISC_FLAGS                  40
%define TEXTURE2D_DESC_BYTES            44

%define BUFFER_BYTE_WIDTH               0
%define BUFFER_USAGE                    4
%define BUFFER_BIND_FLAGS               8
%define BUFFER_CPU_ACCESS               12
%define BUFFER_MISC_FLAGS               16
%define BUFFER_STRUCTURE_STRIDE         20
%define BUFFER_DESC_BYTES               24

%define SRD_SYS_MEM                     0
%define SRD_ROW_PITCH                   8
%define SRD_SLICE_PITCH                 12
%define SRD_BYTES                       16

%define SAMP_FILTER                     0
%define SAMP_ADDRESS_U                  4
%define SAMP_ADDRESS_V                  8
%define SAMP_ADDRESS_W                  12
%define SAMP_MIP_BIAS                   16
%define SAMP_MAX_ANISO                  20
%define SAMP_COMPARISON                 24
%define SAMP_BORDER                     28
%define SAMP_MIN_LOD                    44
%define SAMP_MAX_LOD                    48
%define SAMP_DESC_BYTES                 52

%define RAS_FILL                        0
%define RAS_CULL                        4
%define RAS_FRONT_CCW                   8
%define RAS_DEPTH_BIAS                  12
%define RAS_DEPTH_BIAS_CLAMP            16
%define RAS_SLOPE_BIAS                  20
%define RAS_DEPTH_CLIP                  24
%define RAS_SCISSOR                     28
%define RAS_MULTISAMPLE                 32
%define RAS_ANTIALIASED                 36
%define RAS_DESC_BYTES                  40

%define INPUT_SEMANTIC                  0
%define INPUT_SEMANTIC_INDEX             8
%define INPUT_FORMAT                    12
%define INPUT_SLOT                      16
%define INPUT_OFFSET                     20
%define INPUT_SLOT_CLASS                24
%define INPUT_STEP                      28
%define INPUT_ELEMENT_BYTES             32

%define VIEWPORT_WIDTH                  8
%define VIEWPORT_HEIGHT                 12
%define VIEWPORT_BYTES                  24

%define MAPPED_PDATA                    0
%define MAPPED_ROW_PITCH                8

extern D3D11CreateDeviceAndSwapChain

global asm_present_init
global asm_present_set_palette
global asm_present_draw
global asm_present_readback
global asm_present_present
global asm_present_shutdown

section .bss
align 8
pres_swap:              resq 1
pres_device:            resq 1
pres_context:           resq 1
pres_backbuffer:        resq 1
pres_index_texture:     resq 1
pres_index_srv:         resq 1
pres_palette_texture:   resq 1
pres_palette_srv:       resq 1
pres_vertex_buffer:     resq 1
pres_input_layout:      resq 1
pres_vertex_shader:     resq 1
pres_pixel_shader:      resq 1
pres_sampler:           resq 1
pres_rasterizer:        resq 1
pres_rtv:               resq 1
pres_staging:           resq 1

pres_swap_desc:         resb DXGI_SWAP_CHAIN_DESC_BYTES
pres_texture_desc:      resb TEXTURE2D_DESC_BYTES
pres_staging_desc:      resb TEXTURE2D_DESC_BYTES
pres_buffer_desc:       resb BUFFER_DESC_BYTES
pres_srd:               resb SRD_BYTES
pres_sampler_desc:      resb SAMP_DESC_BYTES
pres_rasterizer_desc:   resb RAS_DESC_BYTES
pres_mapped:            resb 16
pres_out_feature:       resd 1
pres_width:             resd 1
pres_height:            resd 1
pres_palette:           resb 768

section .data
align 4
pres_feature_levels:    dd D3D_FEATURE_LEVEL_11_0
pres_sem_pos:           db "POS",0
pres_sem_tex:           db "TEX",0

align 8
pres_vertices:
        dd 0xBF800000,0xBF800000,0x00000000,0x3F800000
        dd 0x3F800000,0xBF800000,0x3F800000,0x3F800000
        dd 0xBF800000,0x3F800000,0x00000000,0x00000000
        dd 0x3F800000,0x3F800000,0x3F800000,0x00000000
        dd 0x3F800000,0xBF800000,0x3F800000,0x3F800000
        dd 0xBF800000,0x3F800000,0x00000000,0x00000000

align 8
pres_input_elements:
        dq pres_sem_pos
        dd 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, 0, 0
        dq pres_sem_tex
        dd 0, DXGI_FORMAT_R32G32_FLOAT, 0, 8, 0, 0

align 4
pres_iid_texture2d:
        db 0xF2,0xAA,0x15,0x6F, 0x08,0xD2, 0x89,0x4E
        db 0x9A,0xB4,0x48,0x95,0x35,0xD3,0x4F,0x9C

align 4
pres_clear_color:
        dd 0, 0, 0, 0x3F800000

section .text

pres_vs_blob:
        incbin VOODKA_D3D11_VS_CSO
pres_vs_end:
pres_ps_blob:
        incbin VOODKA_D3D11_PS_CSO
pres_ps_end:
%define PRES_VS_BYTES (pres_vs_end - pres_vs_blob)
%define PRES_PS_BYTES (pres_ps_end - pres_ps_blob)

; Release every interface currently held by the candidate. Called with the
; caller's aligned frame still active; COM implementations preserve nonvolatile
; registers according to the same Win64 ABI as ordinary C++ calls.
pres_release_all:
        ; Entry is reached by CALL from an aligned frame, so the return
        ; address makes RSP%16==8 here. Align every COM Release call.
        sub     rsp, 0x28
        mov     rcx, [rel pres_staging]
        test    rcx, rcx
        jz      .staging_done
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.staging_done:
        mov     rcx, [rel pres_rtv]
        test    rcx, rcx
        jz      .rtv_done
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.rtv_done:
        mov     rcx, [rel pres_rasterizer]
        test    rcx, rcx
        jz      .ras_done
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.ras_done:
        mov     rcx, [rel pres_sampler]
        test    rcx, rcx
        jz      .samp_done
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.samp_done:
        mov     rcx, [rel pres_pixel_shader]
        test    rcx, rcx
        jz      .ps_done
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.ps_done:
        mov     rcx, [rel pres_vertex_shader]
        test    rcx, rcx
        jz      .vs_done
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.vs_done:
        mov     rcx, [rel pres_input_layout]
        test    rcx, rcx
        jz      .il_done
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.il_done:
        mov     rcx, [rel pres_vertex_buffer]
        test    rcx, rcx
        jz      .vb_done
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.vb_done:
        mov     rcx, [rel pres_palette_srv]
        test    rcx, rcx
        jz      .pal_srv_done
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.pal_srv_done:
        mov     rcx, [rel pres_palette_texture]
        test    rcx, rcx
        jz      .pal_tex_done
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.pal_tex_done:
        mov     rcx, [rel pres_index_srv]
        test    rcx, rcx
        jz      .idx_srv_done
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.idx_srv_done:
        mov     rcx, [rel pres_index_texture]
        test    rcx, rcx
        jz      .idx_tex_done
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.idx_tex_done:
        mov     rcx, [rel pres_backbuffer]
        test    rcx, rcx
        jz      .back_done
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.back_done:
        mov     rcx, [rel pres_context]
        test    rcx, rcx
        jz      .ctx_done
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.ctx_done:
        mov     rcx, [rel pres_device]
        test    rcx, rcx
        jz      .dev_done
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.dev_done:
        mov     rcx, [rel pres_swap]
        test    rcx, rcx
        jz      .swap_done
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.swap_done:
        lea     rdi, [rel pres_swap]
        xor     eax, eax
        mov     ecx, 16
        rep stosq
        add     rsp, 0x28
        ret

; uint32_t asm_present_init(HWND hwnd, uint32_t width, uint32_t height)
asm_present_init:
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

        mov     rsi, rcx
        mov     r14d, edx
        mov     r15d, r8d
        mov     r13d, 0
        mov     [rel pres_width], r14d
        mov     [rel pres_height], r15d

        call    pres_release_all

        lea     rdi, [rel pres_swap_desc]
        xor     eax, eax
        mov     ecx, DXGI_SWAP_CHAIN_DESC_BYTES / 8
        rep stosq
        mov     [rel pres_swap_desc + DXGI_DESC_WIDTH], r14d
        mov     [rel pres_swap_desc + DXGI_DESC_HEIGHT], r15d
        mov     dword [rel pres_swap_desc + DXGI_DESC_FORMAT], DXGI_FORMAT_R8G8B8A8_UNORM
        mov     dword [rel pres_swap_desc + DXGI_DESC_SAMPLE_COUNT], 1
        mov     dword [rel pres_swap_desc + DXGI_DESC_BUFFER_USAGE], DXGI_USAGE_RENDER_TARGET_OUTPUT
        mov     dword [rel pres_swap_desc + DXGI_DESC_BUFFER_COUNT], 2
        mov     qword [rel pres_swap_desc + DXGI_DESC_OUTPUT_WINDOW], rsi
        mov     dword [rel pres_swap_desc + DXGI_DESC_WINDOWED], 1
        mov     dword [rel pres_swap_desc + DXGI_DESC_SWAP_EFFECT], DXGI_SWAP_EFFECT_DISCARD

        lea     rax, [rel pres_feature_levels]
        mov     [rsp + 0x20], rax
        mov     qword [rsp + 0x28], 1
        mov     qword [rsp + 0x30], D3D11_SDK_VERSION
        lea     rax, [rel pres_swap_desc]
        mov     [rsp + 0x38], rax
        lea     rax, [rel pres_swap]
        mov     [rsp + 0x40], rax
        lea     rax, [rel pres_device]
        mov     [rsp + 0x48], rax
        lea     rax, [rel pres_out_feature]
        mov     [rsp + 0x50], rax
        lea     rax, [rel pres_context]
        mov     [rsp + 0x58], rax
        xor     ecx, ecx
        mov     edx, D3D_DRIVER_TYPE_HARDWARE
        xor     r8d, r8d
        xor     r9d, r9d
        call    D3D11CreateDeviceAndSwapChain
        test    eax, eax
        js      .init_fail
        ; Dynamic indexed texture.
        lea     rdi, [rel pres_texture_desc]
        xor     eax, eax
        mov     ecx, TEXTURE2D_DESC_BYTES / 4
        rep stosd
        mov     dword [rel pres_texture_desc + TEX_WIDTH], 320
        mov     dword [rel pres_texture_desc + TEX_HEIGHT], 200
        mov     dword [rel pres_texture_desc + TEX_MIP_LEVELS], 1
        mov     dword [rel pres_texture_desc + TEX_ARRAY_SIZE], 1
        mov     dword [rel pres_texture_desc + TEX_FORMAT], DXGI_FORMAT_R8_UNORM
        mov     dword [rel pres_texture_desc + TEX_SAMPLE_COUNT], 1
        mov     dword [rel pres_texture_desc + TEX_USAGE], D3D11_USAGE_DYNAMIC
        mov     dword [rel pres_texture_desc + TEX_BIND_FLAGS], D3D11_BIND_SHADER_RESOURCE
        mov     dword [rel pres_texture_desc + TEX_CPU_ACCESS], D3D11_CPU_ACCESS_WRITE
        mov     rcx, [rel pres_device]
        lea     rdx, [rel pres_texture_desc]
        xor     r8d, r8d
        lea     r9, [rel pres_index_texture]
        mov     rax, [rcx]
        call    qword [rax + DEVICE_CREATE_TEXTURE2D * 8]
        test    eax, eax
        js      .init_fail

        mov     rcx, [rel pres_device]
        mov     rdx, [rel pres_index_texture]
        xor     r8d, r8d
        lea     r9, [rel pres_index_srv]
        mov     rax, [rcx]
        call    qword [rax + DEVICE_CREATE_SRV * 8]
        test    eax, eax
        js      .init_fail
        ; Dynamic RGBA palette texture.
        mov     dword [rel pres_texture_desc + TEX_WIDTH], 256
        mov     dword [rel pres_texture_desc + TEX_HEIGHT], 1
        mov     dword [rel pres_texture_desc + TEX_FORMAT], DXGI_FORMAT_R8G8B8A8_UNORM
        mov     rcx, [rel pres_device]
        lea     rdx, [rel pres_texture_desc]
        xor     r8d, r8d
        lea     r9, [rel pres_palette_texture]
        mov     rax, [rcx]
        call    qword [rax + DEVICE_CREATE_TEXTURE2D * 8]
        test    eax, eax
        js      .init_fail
        mov     rcx, [rel pres_device]
        mov     rdx, [rel pres_palette_texture]
        xor     r8d, r8d
        lea     r9, [rel pres_palette_srv]
        mov     rax, [rcx]
        call    qword [rax + DEVICE_CREATE_SRV * 8]
        test    eax, eax
        js      .init_fail
        ; Vertex and pixel shaders from build-time generated bytecode.
        mov     rcx, [rel pres_device]
        lea     rdx, [rel pres_vs_blob]
        mov     r8d, PRES_VS_BYTES
        xor     r9d, r9d
        lea     rax, [rel pres_vertex_shader]
        mov     qword [rsp + 0x20], rax
        mov     rax, [rcx]
        call    qword [rax + DEVICE_CREATE_VERTEX_SHADER * 8]
        test    eax, eax
        js      .init_fail
        mov     rcx, [rel pres_device]
        lea     rdx, [rel pres_ps_blob]
        mov     r8d, PRES_PS_BYTES
        xor     r9d, r9d
        lea     rax, [rel pres_pixel_shader]
        mov     qword [rsp + 0x20], rax
        mov     rax, [rcx]
        call    qword [rax + DEVICE_CREATE_PIXEL_SHADER * 8]
        test    eax, eax
        js      .init_fail
        ; Input layout: POS float2 at byte 0, TEX float2 at byte 8.
        mov     rcx, [rel pres_device]
        lea     rdx, [rel pres_input_elements]
        mov     r8d, 2
        lea     r9, [rel pres_vs_blob]
        mov     qword [rsp + 0x20], PRES_VS_BYTES
        lea     rax, [rel pres_input_layout]
        mov     qword [rsp + 0x28], rax
        mov     rax, [rcx]
        call    qword [rax + DEVICE_CREATE_INPUT_LAYOUT * 8]
        test    eax, eax
        js      .init_fail

        ; Fullscreen quad vertex buffer.
        lea     rdi, [rel pres_buffer_desc]
        xor     eax, eax
        mov     ecx, BUFFER_DESC_BYTES / 4
        rep stosd
        mov     dword [rel pres_buffer_desc + BUFFER_BYTE_WIDTH], 96
        mov     dword [rel pres_buffer_desc + BUFFER_USAGE], D3D11_USAGE_DEFAULT
        mov     dword [rel pres_buffer_desc + BUFFER_BIND_FLAGS], D3D11_BIND_VERTEX_BUFFER
        lea     rdi, [rel pres_srd]
        xor     eax, eax
        mov     ecx, SRD_BYTES / 4
        rep stosd
        lea     rax, [rel pres_vertices]
        mov     [rel pres_srd + SRD_SYS_MEM], rax
        mov     rcx, [rel pres_device]
        lea     rdx, [rel pres_buffer_desc]
        lea     r8, [rel pres_srd]
        lea     r9, [rel pres_vertex_buffer]
        mov     rax, [rcx]
        call    qword [rax + DEVICE_CREATE_BUFFER * 8]
        test    eax, eax
        js      .init_fail
        ; Point sampler with clamp addressing.
        lea     rdi, [rel pres_sampler_desc]
        xor     eax, eax
        mov     ecx, SAMP_DESC_BYTES / 4
        rep stosd
        mov     dword [rel pres_sampler_desc + SAMP_FILTER], D3D11_FILTER_MIN_MAG_MIP_POINT
        mov     dword [rel pres_sampler_desc + SAMP_ADDRESS_U], D3D11_TEXTURE_ADDRESS_CLAMP
        mov     dword [rel pres_sampler_desc + SAMP_ADDRESS_V], D3D11_TEXTURE_ADDRESS_CLAMP
        mov     dword [rel pres_sampler_desc + SAMP_ADDRESS_W], D3D11_TEXTURE_ADDRESS_CLAMP
        mov     dword [rel pres_sampler_desc + SAMP_MAX_ANISO], 1
        mov     dword [rel pres_sampler_desc + SAMP_COMPARISON], D3D11_COMPARISON_NEVER
        mov     dword [rel pres_sampler_desc + SAMP_MIN_LOD], 0
        mov     dword [rel pres_sampler_desc + SAMP_MAX_LOD], 0x7F7FFFFF
        mov     rcx, [rel pres_device]
        lea     rdx, [rel pres_sampler_desc]
        lea     r8, [rel pres_sampler]
        xor     r9d, r9d
        mov     rax, [rcx]
        call    qword [rax + DEVICE_CREATE_SAMPLER * 8]
        test    eax, eax
        js      .init_fail

        ; Solid, unc culled rasterizer.
        lea     rdi, [rel pres_rasterizer_desc]
        xor     eax, eax
        mov     ecx, RAS_DESC_BYTES / 4
        rep stosd
        mov     dword [rel pres_rasterizer_desc + RAS_FILL], D3D11_FILL_SOLID
        mov     dword [rel pres_rasterizer_desc + RAS_CULL], D3D11_CULL_NONE
        mov     dword [rel pres_rasterizer_desc + RAS_DEPTH_CLIP], 1
        mov     rcx, [rel pres_device]
        lea     rdx, [rel pres_rasterizer_desc]
        lea     r8, [rel pres_rasterizer]
        xor     r9d, r9d
        mov     rax, [rcx]
        call    qword [rax + DEVICE_CREATE_RASTERIZER * 8]
        test    eax, eax
        js      .init_fail
        ; Window-sized staging texture used by the host-side diagnostics.
        lea     rdi, [rel pres_staging_desc]
        xor     eax, eax
        mov     ecx, TEXTURE2D_DESC_BYTES / 4
        rep stosd
        mov     dword [rel pres_staging_desc + TEX_WIDTH], r14d
        mov     dword [rel pres_staging_desc + TEX_HEIGHT], r15d
        mov     dword [rel pres_staging_desc + TEX_MIP_LEVELS], 1
        mov     dword [rel pres_staging_desc + TEX_ARRAY_SIZE], 1
        mov     dword [rel pres_staging_desc + TEX_FORMAT], DXGI_FORMAT_R8G8B8A8_UNORM
        mov     dword [rel pres_staging_desc + TEX_SAMPLE_COUNT], 1
        mov     dword [rel pres_staging_desc + TEX_USAGE], D3D11_USAGE_STAGING
        mov     dword [rel pres_staging_desc + TEX_CPU_ACCESS], D3D11_CPU_ACCESS_READ
        mov     rcx, [rel pres_device]
        lea     rdx, [rel pres_staging_desc]
        xor     r8d, r8d
        lea     r9, [rel pres_staging]
        mov     rax, [rcx]
        call    qword [rax + DEVICE_CREATE_TEXTURE2D * 8]
        test    eax, eax
        js      .init_fail
        ; Swap-chain backbuffer and render-target view.
        mov     rcx, [rel pres_swap]
        xor     edx, edx
        lea     r8, [rel pres_iid_texture2d]
        lea     r9, [rel pres_backbuffer]
        mov     rax, [rcx]
        call    qword [rax + SWAPCHAIN_GETBUFFER * 8]
        test    eax, eax
        js      .init_fail
        mov     rcx, [rel pres_device]
        mov     rdx, [rel pres_backbuffer]
        xor     r8d, r8d
        lea     r9, [rel pres_rtv]
        mov     rax, [rcx]
        call    qword [rax + DEVICE_CREATE_RTV * 8]
        test    eax, eax
        js      .init_fail
        xor     eax, eax
        jmp     .init_return
.init_fail:
        mov     r13d, 1
        call    pres_release_all
        mov     eax, r13d
.init_return:
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

; void asm_present_set_palette(const uint8_t* interleavedRgb6)
asm_present_set_palette:
        push    rsi
        push    rdi
        mov     rsi, rcx
        lea     rdi, [rel pres_palette]
        mov     ecx, 768
        cld
        rep movsb
        pop     rdi
        pop     rsi
        ret

; uint32_t asm_present_draw(const uint8_t* arenaBase, uint32_t framebufferOffset)
asm_present_draw:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15
        ; Map has two stack arguments; reserve through [rsp+0x2f] while
        ; keeping RSP%16==0 at the call site.
        sub     rsp, 0x38

        mov     r12, rcx
        mov     eax, edx
        add     r12, rax

        ; Upload indexed framebuffer row-by-row honoring RowPitch.
        mov     rcx, [rel pres_context]
        mov     rdx, [rel pres_index_texture]
        xor     r8d, r8d
        mov     r9d, D3D11_MAP_WRITE_DISCARD
        mov     qword [rsp + 0x20], 0
        lea     rax, [rel pres_mapped]
        mov     [rsp + 0x28], rax
        mov     rax, [rcx]
        call    qword [rax + CONTEXT_MAP * 8]
        test    eax, eax
        js      .draw_fail
        mov     rdi, [rel pres_mapped + MAPPED_PDATA]
        mov     ebx, [rel pres_mapped + MAPPED_ROW_PITCH]
        mov     rsi, r12
        mov     r13d, 200
        sub     ebx, 320
        cld
.index_row:
        mov     ecx, 320
        rep movsb
        add     rdi, rbx             ; RowPitch minus the copied row width.
        dec     r13d
        jnz     .index_row
        mov     rcx, [rel pres_context]
        mov     rdx, [rel pres_index_texture]
        xor     r8d, r8d
        mov     rax, [rcx]
        call    qword [rax + CONTEXT_UNMAP * 8]

        ; Upload raw VGA 6-bit palette as rounded RGBA8 values.
        mov     rcx, [rel pres_context]
        mov     rdx, [rel pres_palette_texture]
        xor     r8d, r8d
        mov     r9d, D3D11_MAP_WRITE_DISCARD
        mov     qword [rsp + 0x20], 0
        lea     rax, [rel pres_mapped]
        mov     [rsp + 0x28], rax
        mov     rax, [rcx]
        call    qword [rax + CONTEXT_MAP * 8]
        test    eax, eax
        js      .draw_fail
        mov     rdi, [rel pres_mapped + MAPPED_PDATA]
        lea     rsi, [rel pres_palette]
        mov     r13d, 256
        mov     r14d, 63
.palette_entry:
        movzx   eax, byte [rsi]
        imul    eax, 255
        add     eax, 31
        xor     edx, edx
        div     r14d
        mov     [rdi], al
        movzx   eax, byte [rsi + 1]
        imul    eax, 255
        add     eax, 31
        xor     edx, edx
        div     r14d
        mov     [rdi + 1], al
        movzx   eax, byte [rsi + 2]
        imul    eax, 255
        add     eax, 31
        xor     edx, edx
        div     r14d
        mov     [rdi + 2], al
        mov     byte [rdi + 3], 255
        add     rsi, 3
        add     rdi, 4
        dec     r13d
        jnz     .palette_entry
        mov     rcx, [rel pres_context]
        mov     rdx, [rel pres_palette_texture]
        xor     r8d, r8d
        mov     rax, [rcx]
        call    qword [rax + CONTEXT_UNMAP * 8]

        ; Bind the fullscreen indexed/palette draw state.
        mov     rcx, [rel pres_context]
        mov     edx, 1
        lea     r8, [rel pres_rtv]
        xor     r9d, r9d
        mov     rax, [rcx]
        call    qword [rax + CONTEXT_OM_SET_TARGETS * 8]
        mov     rcx, [rel pres_context]
        mov     rdx, [rel pres_rtv]
        lea     r8, [rel pres_clear_color]
        mov     rax, [rcx]
        call    qword [rax + CONTEXT_CLEAR_RTV * 8]

        mov     dword [rel pres_viewport + 0], 0
        mov     dword [rel pres_viewport + 4], 0
        mov     eax, [rel pres_width]
        cvtsi2ss xmm0, eax
        movss    [rel pres_viewport + VIEWPORT_WIDTH], xmm0
        mov     eax, [rel pres_height]
        cvtsi2ss xmm0, eax
        movss    [rel pres_viewport + VIEWPORT_HEIGHT], xmm0
        mov     dword [rel pres_viewport + 16], 0
        mov     dword [rel pres_viewport + 20], 0x3F800000
        mov     rcx, [rel pres_context]
        mov     edx, 1
        lea     r8, [rel pres_viewport]
        mov     rax, [rcx]
        call    qword [rax + CONTEXT_RS_SET_VIEWPORTS * 8]
        mov     rcx, [rel pres_context]
        xor     edx, edx
        mov     r8d, 1
        lea     r9, [rel pres_vertex_buffer]
        lea     rax, [rel pres_stride]
        mov     [rsp + 0x20], rax
        lea     rax, [rel pres_offset]
        mov     [rsp + 0x28], rax
        mov     rax, [rcx]
        call    qword [rax + CONTEXT_IA_SET_VERTEX_BUFFERS * 8]
        mov     rcx, [rel pres_context]
        mov     rdx, [rel pres_input_layout]
        mov     rax, [rcx]
        call    qword [rax + CONTEXT_IA_SET_INPUT_LAYOUT * 8]
        mov     rcx, [rel pres_context]
        mov     edx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST
        mov     rax, [rcx]
        call    qword [rax + CONTEXT_IA_SET_TOPOLOGY * 8]
        mov     rcx, [rel pres_context]
        mov     rdx, [rel pres_vertex_shader]
        xor     r8d, r8d
        xor     r9d, r9d
        mov     rax, [rcx]
        call    qword [rax + CONTEXT_VS_SET_SHADER * 8]
        mov     rcx, [rel pres_context]
        mov     rdx, [rel pres_pixel_shader]
        xor     r8d, r8d
        xor     r9d, r9d
        mov     rax, [rcx]
        call    qword [rax + CONTEXT_PS_SET_SHADER * 8]
        mov     rcx, [rel pres_context]
        mov     rdx, [rel pres_rasterizer]
        mov     rax, [rcx]
        call    qword [rax + CONTEXT_RS_SET_STATE * 8]
        mov     rcx, [rel pres_context]
        xor     edx, edx
        mov     r8d, 1
        lea     r9, [rel pres_index_srv]
        mov     rax, [rcx]
        call    qword [rax + CONTEXT_PS_SET_SHADER_RESOURCES * 8]
        mov     rcx, [rel pres_context]
        mov     edx, 1
        mov     r8d, 1
        lea     r9, [rel pres_palette_srv]
        mov     rax, [rcx]
        call    qword [rax + CONTEXT_PS_SET_SHADER_RESOURCES * 8]
        mov     rcx, [rel pres_context]
        xor     edx, edx
        mov     r8d, 1
        lea     r9, [rel pres_sampler]
        mov     rax, [rcx]
        call    qword [rax + CONTEXT_PS_SET_SAMPLERS * 8]
        mov     rcx, [rel pres_context]
        mov     edx, 6
        xor     r8d, r8d
        mov     rax, [rcx]
        call    qword [rax + CONTEXT_DRAW * 8]
        xor     eax, eax
        jmp     .draw_return
.draw_fail:
        mov     eax, 1
.draw_return:
        add     rsp, 0x38
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; uint32_t asm_present_readback(uint8_t* out, uint32_t capacity)
asm_present_readback:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15
        ; Map has two stack arguments; keep both inside this frame.
        sub     rsp, 0x38
        mov     r12, rcx
        mov     r13d, edx
        mov     eax, [rel pres_width]
        imul    eax, [rel pres_height]
        imul    eax, 4
        cmp     r13d, eax
        jb      .readback_fail

        mov     rcx, [rel pres_context]
        mov     rdx, [rel pres_staging]
        mov     r8, [rel pres_backbuffer]
        mov     rax, [rcx]
        call    qword [rax + CONTEXT_COPY_RESOURCE * 8]
        mov     rcx, [rel pres_context]
        mov     rdx, [rel pres_staging]
        xor     r8d, r8d
        mov     r9d, D3D11_MAP_READ
        mov     qword [rsp + 0x20], 0
        lea     rax, [rel pres_mapped]
        mov     [rsp + 0x28], rax
        mov     rax, [rcx]
        call    qword [rax + CONTEXT_MAP * 8]
        test    eax, eax
        js      .readback_fail
        mov     rsi, [rel pres_mapped + MAPPED_PDATA]
        mov     ebx, [rel pres_mapped + MAPPED_ROW_PITCH]
        mov     eax, [rel pres_width]
        imul    eax, 4
        mov     r15d, eax
        sub     ebx, r15d
        mov     rdi, r12
        mov     r14d, [rel pres_height]
.readback_row:
        mov     ecx, r15d
        rep movsb
        add     rsi, rbx
        dec     r14d
        jnz     .readback_row
        mov     rcx, [rel pres_context]
        mov     rdx, [rel pres_staging]
        xor     r8d, r8d
        mov     rax, [rcx]
        call    qword [rax + CONTEXT_UNMAP * 8]
        xor     eax, eax
        jmp     .readback_return
.readback_fail:
        mov     eax, 1
.readback_return:
        add     rsp, 0x38
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; int32_t asm_present_present(void)
asm_present_present:
        push    rbp
        mov     rbp, rsp
        sub     rsp, 0x20
        mov     rcx, [rel pres_swap]
        xor     edx, edx
        xor     r8d, r8d
        mov     rax, [rcx]
        call    qword [rax + SWAPCHAIN_PRESENT * 8]
        add     rsp, 0x20
        pop     rbp
        ret

; void asm_present_shutdown(void)
asm_present_shutdown:
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
        call    pres_release_all
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

section .data
align 4
pres_stride:            dd 16
pres_offset:            dd 0
pres_viewport:          times VIEWPORT_BYTES db 0
