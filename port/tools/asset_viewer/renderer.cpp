// renderer.cpp - D3D11 flat-shaded 3D renderer (device/swapchain pattern
// follows platform/d3d11_present.cpp; shaders compiled at runtime).

#include "renderer.h"

#include <d3dcompiler.h>
#include <windows.h>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {

const float kClear[4] = {0.12f, 0.12f, 0.15f, 1.0f};

const char kVS[] =
    "cbuffer CB : register(b0) { row_major float4x4 vp; };\n"
    "struct VSIn  { float3 pos : POS; float3 norm : NORM; };\n"
    "struct VSOut { float4 pos : SV_Position; float3 norm : NORM; };\n"
    "VSOut main(VSIn v) {\n"
    "    VSOut o;\n"
    "    o.pos = mul(float4(v.pos, 1), vp);\n"
    "    o.norm = v.norm;\n"
    "    return o;\n"
    "}\n";

const char kPS[] =
    "struct PSIn { float4 pos : SV_Position; float3 norm : NORM; };\n"
    "float4 main(PSIn p) : SV_Target {\n"
    "    float3 light = normalize(float3(0.3, 1.0, 0.5));\n"
    "    float  ndl   = saturate(dot(normalize(p.norm), light));\n"
    "    float3 color = float3(0.25, 0.55, 0.95) * (0.25 + 0.75 * ndl);\n"
    "    return float4(color, 1);\n"
    "}\n";

// Row-major 4x4 helpers (float[16], m[row*4+col]) matching HLSL
// row_major float4x4 with mul(vector, matrix).
void matMul(const float* a, const float* b, float* out) {
    for (int r = 0; r < 4; ++r)
        for (int c = 0; c < 4; ++c) {
            float s = 0.0f;
            for (int k = 0; k < 4; ++k) s += a[r * 4 + k] * b[k * 4 + c];
            out[r * 4 + c] = s;
        }
}

}  // namespace

bool Renderer::init(HWND hwnd, int width, int height) {
    m_width = width;
    m_height = height;

    DXGI_SWAP_CHAIN_DESC sd{};
    sd.BufferCount = 2;
    sd.BufferDesc.Width = (UINT)width;
    sd.BufferDesc.Height = (UINT)height;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferDesc.RefreshRate.Numerator = 0;
    sd.BufferDesc.RefreshRate.Denominator = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    D3D_FEATURE_LEVEL lvl = D3D_FEATURE_LEVEL_11_0;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0,
        &lvl, 1, D3D11_SDK_VERSION, &sd, &m_sc, &m_dev, nullptr, &m_ctx);
    if (FAILED(hr)) {
        std::fprintf(stderr, "renderer: D3D11CreateDeviceAndSwapChain failed %08x\n",
                     (unsigned)hr);
        return false;
    }

    // ---- backbuffer RTV + depth buffer -------------------------------------
    ID3D11Texture2D* back = nullptr;
    if (FAILED(m_sc->GetBuffer(0, __uuidof(ID3D11Texture2D), (void**)&back))) {
        std::fprintf(stderr, "renderer: GetBuffer failed\n");
        return false;
    }
    if (FAILED(m_dev->CreateRenderTargetView(back, nullptr, &m_rtv))) {
        back->Release();
        return false;
    }
    back->Release();

    D3D11_TEXTURE2D_DESC dd{};
    dd.Width = (UINT)width;
    dd.Height = (UINT)height;
    dd.MipLevels = 1;
    dd.ArraySize = 1;
    dd.Format = DXGI_FORMAT_D24_UNORM_S8_UINT;
    dd.SampleDesc.Count = 1;
    dd.Usage = D3D11_USAGE_DEFAULT;
    dd.BindFlags = D3D11_BIND_DEPTH_STENCIL;
    ID3D11Texture2D* depth = nullptr;
    if (FAILED(m_dev->CreateTexture2D(&dd, nullptr, &depth))) {
        std::fprintf(stderr, "renderer: CreateTexture2D(depth) failed\n");
        return false;
    }
    if (FAILED(m_dev->CreateDepthStencilView(depth, nullptr, &m_dsv))) {
        depth->Release();
        return false;
    }
    depth->Release();

    if (!createShaders()) return false;

    // ---- rasterizer states -------------------------------------------------
    D3D11_RASTERIZER_DESC rd{};
    rd.FillMode = D3D11_FILL_SOLID;
    rd.CullMode = D3D11_CULL_NONE;       // show even miswound faces (debug tool)
    rd.DepthClipEnable = TRUE;
    if (FAILED(m_dev->CreateRasterizerState(&rd, &m_rsSolid))) return false;
    rd.FillMode = D3D11_FILL_WIREFRAME;
    if (FAILED(m_dev->CreateRasterizerState(&rd, &m_rsWire))) return false;

    // ---- constant buffer (VP matrix) ---------------------------------------
    D3D11_BUFFER_DESC cb{};
    cb.ByteWidth = sizeof(m_vp);
    cb.Usage = D3D11_USAGE_DYNAMIC;
    cb.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    cb.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    if (FAILED(m_dev->CreateBuffer(&cb, nullptr, &m_cb))) return false;

    for (int i = 0; i < 16; ++i) m_vp[i] = (i % 5 == 0) ? 1.0f : 0.0f;  // identity
    return true;
}

bool Renderer::createShaders() {
    ID3DBlob* vsb = nullptr;
    ID3DBlob* psb = nullptr;
    HRESULT hvs = D3DCompile(kVS, sizeof kVS - 1, "vs", nullptr, nullptr, "main",
                             "vs_4_0", 0, 0, &vsb, nullptr);
    HRESULT hps = D3DCompile(kPS, sizeof kPS - 1, "ps", nullptr, nullptr, "main",
                             "ps_4_0", 0, 0, &psb, nullptr);
    if (FAILED(hvs) || FAILED(hps)) {
        if (vsb) {
            std::fprintf(stderr, "renderer: VS compile log:\n%.*s\n",
                         (int)vsb->GetBufferSize(), (const char*)vsb->GetBufferPointer());
        }
        std::fprintf(stderr, "renderer: shader compile failed vs=%08x ps=%08x\n",
                     (unsigned)hvs, (unsigned)hps);
        return false;
    }
    HRESULT hvsCreate = m_dev->CreateVertexShader(vsb->GetBufferPointer(), vsb->GetBufferSize(),
                                        nullptr, &m_vs);
    HRESULT hpsCreate = m_dev->CreatePixelShader(psb->GetBufferPointer(), psb->GetBufferSize(),
                                       nullptr, &m_ps);
    if (FAILED(hvsCreate) || FAILED(hpsCreate)) {
        vsb->Release();
        psb->Release();
        std::fprintf(stderr, "renderer: shader creation failed vs=%08x ps=%08x\n",
                     (unsigned)hvsCreate, (unsigned)hpsCreate);
        return false;
    }

    D3D11_INPUT_ELEMENT_DESC elems[] = {
        {"POS", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0},
        {"NORM", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 12, D3D11_INPUT_PER_VERTEX_DATA, 0},
    };
    HRESULT hil = m_dev->CreateInputLayout(elems, 2,
                                           vsb->GetBufferPointer(),
                                           vsb->GetBufferSize(), &m_il);
    vsb->Release();
    psb->Release();
    if (FAILED(hil)) {
        std::fprintf(stderr, "renderer: CreateInputLayout failed %08x\n", (unsigned)hil);
        return false;
    }
    return true;
}

void Renderer::shutdown() {
    if (m_il)      m_il->Release();
    if (m_ps)      m_ps->Release();
    if (m_vs)      m_vs->Release();
    if (m_vb)      m_vb->Release();
    if (m_cb)      m_cb->Release();
    if (m_rsWire)  m_rsWire->Release();
    if (m_rsSolid) m_rsSolid->Release();
    if (m_dsv)     m_dsv->Release();
    if (m_rtv)     m_rtv->Release();
    if (m_sc)      m_sc->Release();
    if (m_ctx)     m_ctx->Release();
    if (m_dev)     m_dev->Release();
    m_il = nullptr; m_ps = nullptr; m_vs = nullptr;
    m_vb = nullptr; m_cb = nullptr;
    m_rsWire = nullptr; m_rsSolid = nullptr;
    m_dsv = nullptr; m_rtv = nullptr;
    m_sc = nullptr; m_ctx = nullptr; m_dev = nullptr;
}

bool Renderer::setModel(const float* faceVerts, int faceCount) {
    if (faceCount <= 0 || !faceVerts) return false;
    const int vertCount = faceCount * 3;
    const size_t bytes = (size_t)vertCount * 6 * sizeof(float);

    if (!m_vb || vertCount > m_vbCap) {
        if (m_vb) { m_vb->Release(); m_vb = nullptr; }
        D3D11_BUFFER_DESC bd{};
        bd.ByteWidth = (UINT)bytes;
        bd.Usage = D3D11_USAGE_DYNAMIC;
        bd.BindFlags = D3D11_BIND_VERTEX_BUFFER;
        bd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
        if (FAILED(m_dev->CreateBuffer(&bd, nullptr, &m_vb))) {
            std::fprintf(stderr, "renderer: CreateBuffer(vb) failed\n");
            return false;
        }
        m_vbCap = vertCount;
    }

    D3D11_MAPPED_SUBRESOURCE ms{};
    if (FAILED(m_ctx->Map(m_vb, 0, D3D11_MAP_WRITE_DISCARD, 0, &ms))) {
        std::fprintf(stderr, "renderer: Map(vb) failed\n");
        return false;
    }
    std::memcpy(ms.pData, faceVerts, bytes);
    m_ctx->Unmap(m_vb, 0);
    m_vertCount = vertCount;
    return true;
}

void Renderer::setCamera(float eyeX, float eyeY, float eyeZ,
                         float tgtX, float tgtY, float tgtZ,
                         float fovDeg, float aspect,
                         float zn, float zf) {
    float up[3] = {0, 1, 0};

    // view (LH, row-major): f = normalize(target-eye); s = normalize(cross(f,up));
    // u = cross(s,f); rows = s, u, f; last row = -dot(s,eye), -dot(u,eye), -dot(f,eye)
    float fx = tgtX - eyeX, fy = tgtY - eyeY, fz = tgtZ - eyeZ;
    float fl = std::sqrt(fx * fx + fy * fy + fz * fz);
    fx /= fl; fy /= fl; fz /= fl;
    float sx = fy * up[2] - fz * up[1];
    float sy = fz * up[0] - fx * up[2];
    float sz = fx * up[1] - fy * up[0];
    float sl = std::sqrt(sx * sx + sy * sy + sz * sz);
    sx /= sl; sy /= sl; sz /= sl;
    float ux = sy * fz - sz * fy;
    float uy = sz * fx - sx * fz;
    float uz = sx * fy - sy * fx;

    float view[16] = {
        sx, ux, fx, 0,
        sy, uy, fy, 0,
        sz, uz, fz, 0,
        -(sx * eyeX + sy * eyeY + sz * eyeZ),
        -(ux * eyeX + uy * eyeY + uz * eyeZ),
        -(fx * eyeX + fy * eyeY + fz * eyeZ),
        1,
    };

    // perspective (LH, row-major, z -> [0,1]): focal = 1/tan(fov/2)
    float fovy = fovDeg * 3.14159265f / 180.0f;
    float yScale = 1.0f / std::tan(fovy * 0.5f);
    float xScale = yScale / aspect;
    float proj[16] = {
        xScale, 0, 0, 0,
        0, yScale, 0, 0,
        0, 0, zf / (zf - zn), 1,
        0, 0, -zn * zf / (zf - zn), 0,
    };

    matMul(view, proj, m_vp);

    D3D11_MAPPED_SUBRESOURCE ms{};
    if (FAILED(m_ctx->Map(m_cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &ms))) return;
    std::memcpy(ms.pData, m_vp, sizeof m_vp);
    m_ctx->Unmap(m_cb, 0);
}

void Renderer::setWireframe(bool enabled) { m_wireframe = enabled; }

void Renderer::resize(int width, int height) {
    if (!m_dev || width <= 0 || height <= 0) return;
    if (width == m_width && height == m_height) return;

    if (m_rtv) { m_rtv->Release(); m_rtv = nullptr; }
    if (m_dsv) { m_dsv->Release(); m_dsv = nullptr; }

    if (FAILED(m_sc->ResizeBuffers(0, (UINT)width, (UINT)height,
                                   DXGI_FORMAT_UNKNOWN, 0))) {
        std::fprintf(stderr, "renderer: ResizeBuffers failed\n");
        return;
    }
    ID3D11Texture2D* back = nullptr;
    if (FAILED(m_sc->GetBuffer(0, __uuidof(ID3D11Texture2D), (void**)&back))) {
        std::fprintf(stderr, "renderer: GetBuffer (resize) failed\n");
        return;
    }
    m_dev->CreateRenderTargetView(back, nullptr, &m_rtv);
    back->Release();

    D3D11_TEXTURE2D_DESC dd{};
    dd.Width = (UINT)width;
    dd.Height = (UINT)height;
    dd.MipLevels = 1;
    dd.ArraySize = 1;
    dd.Format = DXGI_FORMAT_D24_UNORM_S8_UINT;
    dd.SampleDesc.Count = 1;
    dd.Usage = D3D11_USAGE_DEFAULT;
    dd.BindFlags = D3D11_BIND_DEPTH_STENCIL;
    ID3D11Texture2D* depth = nullptr;
    if (SUCCEEDED(m_dev->CreateTexture2D(&dd, nullptr, &depth))) {
        m_dev->CreateDepthStencilView(depth, nullptr, &m_dsv);
        depth->Release();
    }
    m_width = width;
    m_height = height;
}

void Renderer::render() {
    m_ctx->ClearRenderTargetView(m_rtv, kClear);
    m_ctx->ClearDepthStencilView(m_dsv, D3D11_CLEAR_DEPTH, 1.0f, 0);
    m_ctx->OMSetRenderTargets(1, &m_rtv, m_dsv);

    D3D11_VIEWPORT vp{};
    vp.Width = (FLOAT)m_width;
    vp.Height = (FLOAT)m_height;
    vp.MaxDepth = 1.0f;
    m_ctx->RSSetViewports(1, &vp);

    m_ctx->IASetInputLayout(m_il);
    m_ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    m_ctx->VSSetShader(m_vs, nullptr, 0);
    m_ctx->PSSetShader(m_ps, nullptr, 0);
    m_ctx->VSSetConstantBuffers(0, 1, &m_cb);
    m_ctx->RSSetState(m_wireframe ? m_rsWire : m_rsSolid);

    if (m_vb && m_vertCount > 0) {
        UINT stride = 24, offset = 0;
        m_ctx->IASetVertexBuffers(0, 1, &m_vb, &stride, &offset);
        m_ctx->Draw((UINT)m_vertCount, 0);
    }
    HRESULT pr = m_sc->Present(1, 0);
    if (FAILED(pr)) {
        static bool s_logged = false;
        if (!s_logged) {
            std::fprintf(stderr, "renderer: Present failed %08x\n", (unsigned)pr);
            s_logged = true;
        }
    }

    // ---- diagnostic: dump the presented frame once (VOODKA_VIEWER_READBACK) -
    static int s_presented = 0;
    static int s_rbAt = -1;   // latching default: env VOODKA_VIEWER_READBACK_AT
    if (s_rbAt < 0) {
        s_rbAt = 10;
        const char* at = getenv("VOODKA_VIEWER_READBACK_AT");
        if (at && at[0]) s_rbAt = std::atoi(at);
    }
    if (++s_presented == s_rbAt) {
        const char* rb = getenv("VOODKA_VIEWER_READBACK");
        if (rb && rb[0]) {
            ID3D11Texture2D* back = nullptr;
            if (SUCCEEDED(m_sc->GetBuffer(0, __uuidof(ID3D11Texture2D),
                                           (void**)&back))) {
                D3D11_TEXTURE2D_DESC bd{};
                back->GetDesc(&bd);
                D3D11_TEXTURE2D_DESC sd = bd;
                sd.Usage = D3D11_USAGE_STAGING;
                sd.BindFlags = 0;
                sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
                ID3D11Texture2D* staging = nullptr;
                if (SUCCEEDED(m_dev->CreateTexture2D(&sd, nullptr, &staging))) {
                    m_ctx->CopyResource(staging, back);
                    D3D11_MAPPED_SUBRESOURCE ms{};
                    if (SUCCEEDED(m_ctx->Map(staging, 0, D3D11_MAP_READ, 0, &ms))) {
                        const uint8_t* p = (const uint8_t*)ms.pData;
                        auto px = [&](int x, int y) {
                            const uint8_t* q = p + (size_t)y * ms.RowPitch + (size_t)x * 4;
                            return (int)q[0] | ((int)q[1] << 8) |
                                   ((int)q[2] << 16) | ((int)q[3] << 24);
                        };
                        FILE* f = fopen(rb, "w");
                        if (f) {
                            fprintf(f, "backbuffer %ux%u rowpitch %zu\n",
                                    bd.Width, bd.Height, (size_t)ms.RowPitch);
                            fprintf(f, "center %08x tl %08x tr %08x bl %08x br %08x\n",
                                    px(bd.Width / 2, bd.Height / 2),
                                    px(1, 1), px(bd.Width - 2, 1),
                                    px(1, bd.Height - 2),
                                    px(bd.Width - 2, bd.Height - 2));
                            fclose(f);
                        }
                        m_ctx->Unmap(staging, 0);
                    }
                    staging->Release();
                }
                back->Release();
            }
        }
    }
}