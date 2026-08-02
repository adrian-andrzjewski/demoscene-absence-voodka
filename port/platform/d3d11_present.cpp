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
#include <cstdio>
#include <cstring>
#include <string>

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
ID3D11RasterizerState*  g_ras = nullptr;
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
    "    // center each texel: index N -> palette texel N exactly\n"
    "    return PalTex.Sample(S0, float2((idx + 0.5) / 256.0, 0.5));\n"
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

    // Fullscreen quad is a plain 2D pass - disable back-face culling. Without
    // this, the counter-clockwise triangle of the quad is culled by D3D's
    // default (CW front) winding, so only half the frame is ever drawn.
    D3D11_RASTERIZER_DESC rd{};
    rd.FillMode = D3D11_FILL_SOLID;
    rd.CullMode = D3D11_CULL_NONE;
    rd.DepthClipEnable = TRUE;
    g_dev->CreateRasterizerState(&rd, &g_ras);

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

// ---- presentation self-test -------------------------------------------------
// Writes a known 8-color quadrant pattern into the arena framebuffer and a
// matching palette. After selfTestPattern() + presentFrame, the GPU readback
// must show exactly these colors in the right quadrants/positions - any
// deviation pinpoints an upload/sampling/present bug.
void selfTestPattern() {
    uint8_t* fb = arena() + kFramebufferOffset;
    // palette: 8 entries -> red,green,blue,yellow,cyan,magenta,white,gray
    static const uint8_t pal[8][3] = {
        {63,0,0},{0,63,0},{0,0,63},{63,63,0},
        {0,63,63},{63,0,63},{63,63,63},{31,31,31}
    };
    for (int i = 0; i < 256; i++) {
        g_pal[i*3+0] = pal[i&7][0];
        g_pal[i*3+1] = pal[i&7][1];
        g_pal[i*3+2] = pal[i&7][2];
    }
    // fill 320x200 with pattern:
    //   index = ((x/80) + ((y/50)*2)) & 7   -> 4x4 grid of 8 colors
    for (int y = 0; y < kScreenH; y++)
        for (int x = 0; x < kScreenW; x++)
            fb[y * kScreenW + x] = (uint8_t)(((x / 80) + (y / 50) * 2) & 7);
    logPrint("[d3d] selfTestPattern: wrote 4x4 8-color grid to framebuffer\n");
}

// ---- deterministic frame recorder (validation) ------------------------------
// When VOODKA_RECORD_DIR is set, every presented frame's raw 320x200x8
// framebuffer + 768-byte palette is appended to {dir}/{frame}.raw (index
// bytes, 768 bytes) for offline diffing against the original.
static FILE* g_rec = nullptr;

// ---- presentation readback diagnostic --------------------------------------
// Copies the rendered swapchain back buffer back to CPU and saves it next to
// the assembly framebuffer + palette so the full path can be validated.
static FILE*  g_diagIn = nullptr;
static FILE*  g_diagSrc = nullptr;
static FILE*  g_diagPal = nullptr;
static ID3D11Texture2D* g_diagStaging = nullptr;
static int    g_diagCaptured = 0;
static bool   g_diagInit = false;
static int    g_diagCount = 0;

void diagReadbackInit(const char* dir) {
    g_diagInit = dir != nullptr;
    if (!g_diagInit) return;
    std::string base = std::string(dir);
    g_diagIn   = fopen((base + "\\frame_gpu.raw").c_str(), "wb");
    g_diagSrc  = fopen((base + "\\frame_src.raw").c_str(), "wb");
    g_diagPal  = fopen((base + "\\frame_pal.raw").c_str(), "wb");
    // staging texture matching the swapchain (R8G8B8A8)
    auto td = [](UINT w, UINT h) {
        D3D11_TEXTURE2D_DESC d{}; d.Width = w; d.Height = h;
        d.MipLevels = 1; d.ArraySize = 1; d.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        d.SampleDesc.Count = 1; d.Usage = D3D11_USAGE_STAGING;
        d.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        return d;
    };
    if (g_swap) {
        DXGI_SWAP_CHAIN_DESC sd;
        if (SUCCEEDED(g_swap->GetDesc(&sd)))
            g_dev->CreateTexture2D(&td(sd.BufferDesc.Width, sd.BufferDesc.Height), nullptr, &g_diagStaging);
    }
    if (g_diagIn && g_diagSrc && g_diagPal) logPrint("[d3d] readback diagnostics on -> %s\n", dir);
}
void diagReadbackShutdown() {
    if (g_diagIn) fclose(g_diagIn);
    if (g_diagSrc) fclose(g_diagSrc);
    if (g_diagPal) fclose(g_diagPal);
    if (g_diagStaging) g_diagStaging->Release();
    g_diagInit = false;
}
bool diagReadbackEnabled() { return g_diagInit; }

static void diagCapture(const uint8_t* srcFrame) {
    if (!g_diagInit || !g_diagStaging || g_diagCaptured >= 4) return;
    g_diagCaptured++;
    // dump source framebuffer + palette
    fwrite(srcFrame, 1, kFramebufferBytes, g_diagSrc);
    fwrite(g_pal, 1, kPaletteBytes, g_diagPal);
    fflush(g_diagSrc); fflush(g_diagPal);
    // read back the presented swapchain back buffer
    ID3D11Texture2D* back = nullptr;
    if (SUCCEEDED(g_swap->GetBuffer(0, __uuidof(ID3D11Texture2D), (void**)&back))) {
        g_ctx->CopyResource(g_diagStaging, back);
        D3D11_MAPPED_SUBRESOURCE m{};
        if (SUCCEEDED(g_ctx->Map(g_diagStaging, 0, D3D11_MAP_READ, 0, &m))) {
            uint32_t w = 0, h = 0;
            D3D11_TEXTURE2D_DESC d; g_diagStaging->GetDesc(&d);
            w = d.Width; h = d.Height;
            for (UINT y = 0; y < h; y++)
                fwrite((uint8_t*)m.pData + (size_t)y * m.RowPitch, 1, w * 4, g_diagIn);
            g_ctx->Unmap(g_diagStaging, 0);
        }
        back->Release();
    }
    fflush(g_diagIn);
}

void recInit(const char* dir) {
    if (!dir) return;
    std::string path = std::string(dir) + "\\frames.raw";
    g_rec = fopen(path.c_str(), "wb");
    if (g_rec) logPrint("[rec] recording frames to %s\n", path.c_str());
}
void recClose() { if (g_rec) { fclose(g_rec); g_rec = nullptr; } }
static void recPush(const uint8_t* frame) {
    if (!g_rec) return;
    fwrite(frame, 1, kFramebufferBytes, g_rec);
    fwrite(g_pal, 1, kPaletteBytes, g_rec);
    fflush(g_rec);
}

void presentFrame() {
    if (!g_ctx) return;
    static long cnt = 0;
    if ((cnt++ & 0x3fff) == 0) logPrint("[d3d] presentFrame #%ld\n", cnt);
    // Pump Win32 messages so the window stays responsive and input (keyboard)
    // reaches the demo. The assembly loop never touches Windows itself, so this
    // is the single per-frame opportunity to service the message queue.
    vk::updateInput();
    const uint8_t* frame = arena() + kFramebufferOffset;
    recPush(frame);

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
    g_ctx->RSSetState(g_ras);
    g_ctx->PSSetShaderResources(0, 1, &g_indexSrv);
    g_ctx->PSSetShaderResources(1, 1, &g_palSrv);
    g_ctx->PSSetSamplers(0, 1, &g_samp);
    g_ctx->Draw(6, 0);

    diagCapture(frame);          // read back GPU output before presenting

    g_swap->Present(1, 0);   // vsync lock
}

}  // namespace vk
