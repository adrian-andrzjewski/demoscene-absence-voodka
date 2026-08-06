// renderer.h - D3D11 flat-shaded 3D renderer for the asset viewer.

#pragma once

#include <d3d11.h>
#include <windows.h>

class Renderer {
public:
    bool init(HWND hwnd, int width, int height);
    void shutdown();

    // Upload a new model's face data. faceVerts is a flat list of
    // faceCount*3 vertices, each 6 floats (x,y,z,nx,ny,nz) — 18 floats per
    // face.
    bool setModel(const float* faceVerts, int faceCount);

    // Orbit camera: eye position + look-at target + vertical FOV + aspect +
    // depth planes (viewer scales them from the model's bounding sphere).
    void setCamera(float eyeX, float eyeY, float eyeZ,
                   float tgtX, float tgtY, float tgtZ,
                   float fovDeg, float aspect,
                   float znear = 0.1f, float zfar = 10000.0f);
    void setWireframe(bool enabled);
    void resize(int width, int height);

    void render();

    IDXGISwapChain* swapchain() const { return m_sc; }
    bool valid() const { return m_dev != nullptr; }

private:
    bool createShaders();

    ID3D11Device*           m_dev = nullptr;
    ID3D11DeviceContext*    m_ctx = nullptr;
    IDXGISwapChain*         m_sc = nullptr;
    ID3D11RenderTargetView* m_rtv = nullptr;
    ID3D11DepthStencilView* m_dsv = nullptr;
    ID3D11VertexShader*     m_vs = nullptr;
    ID3D11PixelShader*      m_ps = nullptr;
    ID3D11InputLayout*      m_il = nullptr;
    ID3D11Buffer*           m_vb = nullptr;
    int                     m_vbCap = 0;    // vertex capacity of m_vb
    int                     m_vertCount = 0;
    ID3D11Buffer*           m_cb = nullptr; // view-projection matrix
    ID3D11RasterizerState*  m_rsSolid = nullptr;
    ID3D11RasterizerState*  m_rsWire = nullptr;
    bool                    m_wireframe = false;
    float                   m_vp[16];       // row-major 4x4 view*proj
    int                     m_width = 0;
    int                     m_height = 0;
};