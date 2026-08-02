// d3d11_present.cpp - faithful 320x200x256 palette presentation.
//
// The NASM core renders into an 8-bit indexed framebuffer living in the arena
// at kFramebufferOffset and calls setPalette(r,g,b) whenever the VGA palette
// changes. presentFrame() uploads both to D3D11 (R8 index texture + palette
// lookup texture), nearest-neighbour upscales to the window and presents,
// pacing the 70Hz retrace as part of the swapchain vblank.

#include "platform_abi.h"
#include <d3d11.h>
#include <d3dcompiler.h>
#include <windows.h>
#include <cstring>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "d3dcompiler.lib")

namespace vk {

namespace {
ID3D11Device*           g_dev = nullptr;
ID3D11DeviceContext*    g_ctx = nullptr;
IDXGISwapChain*         g_swap = nullptr;
ID3D11Texture2D*        g_indexTex = nullptr;
ID3D11ShaderResourceView* g_indexSrv = nullptr;
ID3D11Texture2D*        g_palTex = nullptr;
ID3D11ShaderResourceView* g_palSrv = nullptr;
ID3D11Buffer*           g_vb = nullptr;
ID3D11InputLayout*      g_il = nullptr;
ID3D11VertexShader*     g_vs = nullptr;
ID3D11PixelShader*      g_ps = nullptr;
ID3D11SamplerState*     g_samp = nullptr;
ID3D11RenderTargetView* g_rtv = nullptr;
D3D11_VIEWPORT          g_vp{};

// platform-side copy of the 256-entry palette (fades update it constantly)
uint8_t g_pal[768] = {};
}

static const char kVS[] =
    "struct VSIn { float2 pos : POS; float2 uv : TEX; };\n"
    "struct VSOut { float4 pos : SV_Position; float2 uv : TEX; };\n"
    "VSOut main(VSIn i) { VSOut o; o.pos = float4(i.pos,0,1); o.uv = i.uv; return o; }\n";

static const char kPS[] =
    "Texture2D IndexTex : register(t0);\n"
    "Texture2D PalTex  : register(t1);\n"
    "SamplerState S0 : register(s0);\n"
    "struct VSOut { float4 pos : SV_Position; float2 uv : TEX; };\n"
    "float4 main(VSOut i) : SV_Target {\n"
    "    float idx = IndexTex.Sample(S0, i.uv).r * 255.0;\n"
    "    return PalTex.Sample(S0, float2(idx / 255.0, 0.0));\n"
    "}\n";

struct Vertex { float x, y, u, v; };

bool initPresent(void* hwnd, int winW, int winH) {
    logPrint("[d3d] initPresent(%p,%d,%d)\n", hwnd, winW, winH);
    g_vp.Width = (FLOAT)winW;
    g_vp.Height = (FLOAT)winH;
    g_vp.MinDepth = 0.0f;
    g_vp.MaxDepth = 1.0f;

    DXGI_SWAP_CHAIN_DESC sd{};
    sd.BufferCount = 2;
    sd.BufferDesc.Width = (UINT)winW;
    sd.BufferDesc.Height = (UINT)winH;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = (HWND)hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    D3D_FEATURE_LEVEL lvl = D3D_FEATURE_LEVEL_11_0;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0,
        &lvl, 1, D3D11_SDK_VERSION, &sd, &g_swap, &g_dev, nullptr, &g_ctx);
    if (FAILED(hr)) { logPrint("[d3d] CreateDeviceAndSwapChain failed %08x\n", (unsigned)hr); return false; }
    logPrint("[d3d] device+swapchain OK\n");

    // ---- R8 index texture 320x200 --------------------------------------
    D3D11_TEXTURE2D_DESC td{};
    td.Width = kScreenW; td.Height = kScreenH;
    td.MipLevels = 1; td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DYNAMIC;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    if (FAILED(g_dev->CreateTexture2D(&td, nullptr, &g_indexTex))) return false;
    if (FAILED(g_dev->CreateShaderResourceView(g_indexTex, nullptr, &g_indexSrv))) return false;

    // ---- palette texture 256x1 RGBA ------------------------------------
    td.Width = 256; td.Height = 1;
    td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    if (FAILED(g_dev->CreateTexture2D(&td, nullptr, &g_palTex))) return false;
    if (FAILED(g_dev->CreateShaderResourceView(g_palTex, nullptr, &g_palSrv))) return false;

    // ---- shaders ---------------------------------------------------------
    ID3DBlob *vsb = nullptr, *psb = nullptr;
    HRESULT hvs = D3DCompile(kVS, sizeof kVS - 1, "vs", nullptr, nullptr, "main",
                             "vs_4_0", 0, 0, &vsb, nullptr);
    HRESULT hps = D3DCompile(kPS, sizeof kPS - 1, "ps", nullptr, nullptr, "main",
                             "ps_4_0", 0, 0, &psb, nullptr);
    if (FAILED(hvs) || FAILED(hps)) {
        logPrint("[d3d] shader compile failed vs=%08x ps=%08x\n", (unsigned)hvs, (unsigned)hps);
        return false;
    }
    g_dev->CreateVertexShader(vsb->GetBufferPointer(), vsb->GetBufferSize(), nullptr, &g_vs);
    g_dev->CreatePixelShader(psb->GetBufferPointer(), psb->GetBufferSize(), nullptr, &g_ps);

    D3D11_INPUT_ELEMENT_DESC elems[] = {
        {"POS", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0},
        {"TEX", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 8, D3D11_INPUT_PER_VERTEX_DATA, 0},
    };
    g_dev->CreateInputLayout(elems, 2, vsb->GetBufferPointer(), vsb->GetBufferSize(), &g_il);

    Vertex verts[6] = {
        {-1,-1,0,1}, { 1,-1,1,1}, {-1, 1,0,0},
        { 1, 1,1,0}, { 1,-1,1,1}, {-1, 1,0,0},
    };
    D3D11_BUFFER_DESC bd{};
    bd.ByteWidth = sizeof verts;
    bd.Usage = D3D11_USAGE_DEFAULT;
    bd.BindFlags = D3D11_BIND_VERTEX_BUFFER;
    D3D11_SUBRESOURCE_DATA srd{};
    srd.pSysMem = verts;
    if (FAILED(g_dev->CreateBuffer(&bd, &srd, &g_vb))) return false;

    D3D11_SAMPLER_DESC smd{};
    smd.Filter = D3D11_FILTER_MIN_MAG_MIP_POINT;
    smd.AddressU = smd.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
    g_dev->CreateSamplerState(&smd, &g_samp);

    ID3D11Texture2D* back = nullptr;
    if (FAILED(g_swap->GetBuffer(0, __uuidof(ID3D11Texture2D), (void**)&back))) {
        logPrint("[d3d] GetBuffer for RTV failed\n");
        return false;
    }
    g_dev->CreateRenderTargetView(back, nullptr, &g_rtv);
    back->Release();
    logPrint("[d3d] present pipeline ready\n");
    return true;
}

void setPalette(const uint8_t r[256], const uint8_t g[256], const uint8_t b[256]) {
    // store RAW VGA values (0..63) - the demo's fade math works in 6-bit
    // space exactly like the original; scaling happens at upload time.
    for (int i = 0; i < 256; i++) {
        g_pal[i * 3 + 0] = r[i] & 63;
        g_pal[i * 3 + 1] = g[i] & 63;
        g_pal[i * 3 + 2] = b[i] & 63;
    }
}

void currentPalette(uint8_t out[768]) {
    memcpy(out, g_pal, 768);
}

void presentFrame() {
    if (!g_ctx) return;
    const uint8_t* frame = arena() + kFramebufferOffset;

    // upload index texture from the arena framebuffer
    D3D11_MAPPED_SUBRESOURCE m{};
    if (SUCCEEDED(g_ctx->Map(g_indexTex, 0, D3D11_MAP_WRITE_DISCARD, 0, &m))) {
        for (int y = 0; y < kScreenH; y++) {
            memcpy((uint8_t*)m.pData + (size_t)y * m.RowPitch,
                   frame + (size_t)y * kScreenW, kScreenW);
        }
        g_ctx->Unmap(g_indexTex, 0);
    }
    // upload palette (raw 6-bit -> 8-bit at present time, like the VGA DAC)
    if (SUCCEEDED(g_ctx->Map(g_palTex, 0, D3D11_MAP_WRITE_DISCARD, 0, &m))) {
        uint8_t* pd = (uint8_t*)m.pData;
        for (int i = 0; i < 256; i++) {
            int rr = (g_pal[i * 3 + 0] * 255) / 63;
            int gg = (g_pal[i * 3 + 1] * 255) / 63;
            int bb = (g_pal[i * 3 + 2] * 255) / 63;
            pd[i * 4 + 0] = (uint8_t)(rr > 255 ? 255 : rr);
            pd[i * 4 + 1] = (uint8_t)(gg > 255 ? 255 : gg);
            pd[i * 4 + 2] = (uint8_t)(bb > 255 ? 255 : bb);
            pd[i * 4 + 3] = 255;
        }
        g_ctx->Unmap(g_palTex, 0);
    }

    // render quad
    float clear[4] = {0, 0, 0, 1};
    g_ctx->OMSetRenderTargets(1, &g_rtv, nullptr);
    g_ctx->RSSetViewports(1, &g_vp);
    g_ctx->ClearRenderTargetView(g_rtv, clear);
    UINT stride = sizeof Vertex, off = 0;
    g_ctx->IASetVertexBuffers(0, 1, &g_vb, &stride, &off);
    g_ctx->IASetInputLayout(g_il);
    g_ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    g_ctx->VSSetShader(g_vs, nullptr, 0);
    g_ctx->PSSetShader(g_ps, nullptr, 0);
    g_ctx->PSSetShaderResources(0, 1, &g_indexSrv);
    g_ctx->PSSetShaderResources(1, 1, &g_palSrv);
    g_ctx->PSSetSamplers(0, 1, &g_samp);
    g_ctx->Draw(6, 0);

    g_swap->Present(1, 0);   // vsync lock
}

}  // namespace vk
