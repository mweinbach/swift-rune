#pragma once
#include <d3d11.h>
#include <wrl/client.h>

namespace rune_video {
using Microsoft::WRL::ComPtr;
struct NV12Image {
    ID3D11Texture2D *texture;
    UINT width, height;
    D3D11_TEXTURE2D_DESC desc{};
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    bool open() {
        if (!texture || !width || !height || ((width | height) & 1)) return false;
        texture->GetDesc(&desc);
        if (desc.Format != DXGI_FORMAT_NV12 || desc.Width < width || desc.Height < height
            || desc.ArraySize != 1 || desc.MipLevels != 1 || desc.SampleDesc.Count != 1) return false;
        texture->GetDevice(&device);
        device->GetImmediateContext(&context);
        return true;
    }
};

struct SplitPlanes {
    ComPtr<ID3D11ComputeShader> shader;
    ComPtr<ID3D11DeviceContext> commands;
    ComPtr<ID3D11Texture2D> readable;
    ComPtr<ID3D11Texture2D> planes[2];
    ComPtr<ID3D11UnorderedAccessView> targets[2];

    HRESULT run(const NV12Image &image);
private:
    struct SourceViews {
        ComPtr<ID3D11Texture2D> source;
        ComPtr<ID3D11ShaderResourceView> y, uv;
    };
    // The decoder alternates among six ring slots. Each immutable resource layout needs its views only once.
    SourceViews sources[6];
    unsigned nextSource = 0;
    HRESULT viewsFor(ID3D11Device *device, ID3D11Texture2D *source, ID3D11ShaderResourceView *(&out)[2]);
};
} // namespace rune_video
