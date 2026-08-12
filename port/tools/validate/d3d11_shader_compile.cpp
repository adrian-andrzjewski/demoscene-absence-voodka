// d3d11_shader_compile.cpp - host-side shader bytecode generator.
//
// The production presenter consumes the generated .cso blobs through NASM
// INCBIN. Keeping D3DCompile here makes shader compilation a build-time helper
// and removes the runtime compiler dependency from the assembly candidate.

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3dcompiler.h>

#include <cstdio>

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
    "    return PalTex.Sample(S0, float2((idx + 0.5) / 256.0, 0.5));\n"
    "}\n";

static bool compileToFile(const char* source, size_t sourceBytes,
                          const char* profile, const char* outputPath) {
    ID3DBlob* bytecode = nullptr;
    ID3DBlob* errors = nullptr;
    HRESULT hr = D3DCompile(source, sourceBytes, outputPath, nullptr, nullptr,
                            "main", profile, 0, 0, &bytecode, &errors);
    if (FAILED(hr)) {
        if (errors)
            std::fprintf(stderr, "%s: %.*s\n", outputPath,
                         static_cast<int>(errors->GetBufferSize()),
                         static_cast<const char*>(errors->GetBufferPointer()));
        if (errors) errors->Release();
        return false;
    }

    const size_t bytecodeBytes = bytecode->GetBufferSize();
    FILE* file = std::fopen(outputPath, "wb");
    if (!file) {
        std::fprintf(stderr, "cannot open %s for writing\n", outputPath);
        bytecode->Release();
        return false;
    }
    const size_t written = std::fwrite(bytecode->GetBufferPointer(), 1,
                                       bytecodeBytes, file);
    std::fclose(file);
    bytecode->Release();
    if (errors) errors->Release();
    return written == bytecodeBytes;
}

int main(int argc, char** argv) {
    if (argc != 3) {
        std::fprintf(stderr, "usage: d3d11_shader_compile <vs.cso> <ps.cso>\n");
        return 2;
    }
    if (!compileToFile(kVS, sizeof(kVS) - 1, "vs_4_0", argv[1])) return 1;
    if (!compileToFile(kPS, sizeof(kPS) - 1, "ps_4_0", argv[2])) return 1;
    return 0;
}
