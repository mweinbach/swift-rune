#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
#include "LazyGL.h"
#include <cstdio>
#include <cstring>
#include <new>
#include <utility>
#include "D3DTextureBlit.h"
#include "D3DVideoPlanes.h"
#include "include/RuneDecodedPlanes.h"

using Microsoft::WRL::ComPtr;

namespace {
using namespace rune_video;

template<class Reader>
HRESULT readRows(const NV12Image &image, ComPtr<ID3D11Texture2D> &staging, Reader reader) {
    if (!staging) {
        auto desc = image.desc;
        desc.Usage = D3D11_USAGE_STAGING;
        desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        desc.BindFlags = 0;
        desc.MiscFlags = 0;
        HRESULT hr = image.device->CreateTexture2D(&desc, nullptr, &staging);
        if (FAILED(hr)) return hr;
    }
    image.context->CopyResource(staging.Get(), image.texture);
    D3D11_MAPPED_SUBRESOURCE map{};
    HRESULT hr = image.context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &map);
    if (FAILED(hr)) return hr;
    if (map.RowPitch < image.width) hr = E_UNEXPECTED;
    else {
        auto *y = static_cast<const uint8_t *>(map.pData);
        // NV12 chroma begins after every coded luma row, including padded rows the view crops.
        const auto *uv = y + size_t(map.RowPitch) * image.desc.Height;
        hr = reader(y, uv, map.RowPitch);
    }
    image.context->Unmap(staging.Get(), 0);
    return hr;
}

HRESULT splitShader(ID3D11Device *device, ID3D11ComputeShader **result) {
    static const auto compile = [] {
        HMODULE compiler = LoadLibraryExW(L"d3dcompiler_47.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        return compiler ? reinterpret_cast<decltype(&D3DCompile)>(GetProcAddress(compiler, "D3DCompile")) : nullptr;
    }();
    if (!compile) return E_NOINTERFACE;
    // Preserve encoded NV12 sample values. The GL surface shader applies range,
    // matrix, transfer and premultiplication once, after plane sampling.
    static constexpr char code[] = R"(
Texture2D<float> y : register(t0);
Texture2D<float2> uv : register(t1);
RWTexture2D<unorm float> outY : register(u0);
RWTexture2D<unorm float2> outUV : register(u1);
[numthreads(8,8,1)] void split(uint3 pos : SV_DispatchThreadID) {
    uint w, h; outY.GetDimensions(w, h);
    if (pos.x < w && pos.y < h) outY[pos.xy] = y.Load(int3(pos.xy, 0));
    if (pos.x < w/2 && pos.y < h/2) outUV[pos.xy] = uv.Load(int3(pos.xy, 0));
})";
    static const ComPtr<ID3DBlob> bytecode = [] {
        ComPtr<ID3DBlob> shader;
        compile(code, sizeof(code) - 1, nullptr, nullptr, nullptr, "split", "cs_5_0",
                D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &shader, nullptr);
        return shader;
    }();
    return bytecode ? device->CreateComputeShader(bytecode->GetBufferPointer(), bytecode->GetBufferSize(), nullptr, result) : E_FAIL;
}

// Used only when the production WGL context exposes NV_DX_interop2. Cache the
// scratch textures, device shader and deferred context across pictures of a stream.
} // namespace

HRESULT rune_video::SplitPlanes::viewsFor(ID3D11Device *device, ID3D11Texture2D *source,
                                          ID3D11ShaderResourceView *(&out)[2]) {
    for (const auto &slot : sources) {
        if (slot.source.Get() == source) {
            out[0] = slot.y.Get();
            out[1] = slot.uv.Get();
            return S_OK;
        }
    }
    SourceViews slot;
    slot.source = source;
    D3D11_SHADER_RESOURCE_VIEW_DESC view{};
    view.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
    view.Texture2D.MipLevels = 1;
    view.Format = DXGI_FORMAT_R8_UNORM;
    HRESULT hr = device->CreateShaderResourceView(source, &view, &slot.y);
    if (FAILED(hr)) return hr;
    view.Format = DXGI_FORMAT_R8G8_UNORM;
    hr = device->CreateShaderResourceView(source, &view, &slot.uv);
    if (FAILED(hr)) return hr;
    out[0] = slot.y.Get();
    out[1] = slot.uv.Get();
    sources[nextSource] = std::move(slot);
    nextSource = (nextSource + 1) % 6;
    return S_OK;
}

HRESULT rune_video::SplitPlanes::run(const NV12Image &image) {
    const DXGI_FORMAT formats[2] = { DXGI_FORMAT_R8_UNORM, DXGI_FORMAT_R8G8_UNORM };
    HRESULT hr;
    if (!shader && FAILED(hr = splitShader(image.device.Get(), &shader))) return hr;
    if (!commands && FAILED(hr = image.device->CreateDeferredContext(0, &commands))) return hr;
    ID3D11Texture2D *source = image.texture;
    if (!(image.desc.BindFlags & D3D11_BIND_SHADER_RESOURCE)) {
        if (!readable) {
            auto desc = image.desc;
            desc.Usage = D3D11_USAGE_DEFAULT;
            desc.CPUAccessFlags = desc.MiscFlags = 0;
            desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
            if (FAILED(hr = image.device->CreateTexture2D(&desc, nullptr, &readable))) return hr;
        }
        source = readable.Get();
    }
    ID3D11ShaderResourceView *inputs[2]{};
    if (FAILED(hr = viewsFor(image.device.Get(), source, inputs))) return hr;
    for (UINT i = 0; i < 2; i++) {
        if (!targets[i]) {
            D3D11_TEXTURE2D_DESC desc{};
            desc.Width = image.width >> i;
            desc.Height = image.height >> i;
            desc.MipLevels = desc.ArraySize = desc.SampleDesc.Count = 1;
            desc.Format = formats[i];
            desc.Usage = D3D11_USAGE_DEFAULT;
            desc.BindFlags = D3D11_BIND_UNORDERED_ACCESS | D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
            if (FAILED(hr = image.device->CreateTexture2D(&desc, nullptr, &planes[i]))) return hr;
            if (FAILED(hr = image.device->CreateUnorderedAccessView(planes[i].Get(), nullptr, &targets[i]))) return hr;
        }
    }
    if (source != image.texture) commands->CopyResource(source, image.texture);
    ID3D11UnorderedAccessView *outputs[] = { targets[0].Get(), targets[1].Get() };
    commands->CSSetShader(shader.Get(), nullptr, 0);
    commands->CSSetShaderResources(0, 2, inputs);
    commands->CSSetUnorderedAccessViews(0, 2, outputs, nullptr);
    commands->Dispatch((image.width + 7) / 8, (image.height + 7) / 8, 1);
    ComPtr<ID3D11CommandList> list;
    if (FAILED(hr = commands->FinishCommandList(FALSE, &list))) return hr;
    image.context->ExecuteCommandList(list.Get(), TRUE);
    return S_OK;
}

struct RuneWinPlaneUploader {
    ComPtr<ID3D11Device> device;
    UINT storageW = 0, storageH = 0, width = 0, height = 0;
    bool tryInterop = true;
    SplitPlanes split;
    ComPtr<ID3D11Texture2D> staging;
};

RuneWinPlaneUploader *rune_win_plane_uploader_create() { return new(std::nothrow) RuneWinPlaneUploader; }
void rune_win_plane_uploader_destroy(RuneWinPlaneUploader *uploader) { delete uploader; }

int rune_win_plane_copy_gl(void *opaque, uint32_t yTexture, uint32_t uvTexture) {
    auto *copy = static_cast<RuneWinPlaneCopy *>(opaque);
    if (!copy || !copy->uploader || !yTexture || !uvTexture) return 0;
    copy->transferred_on_gpu = 0;
    NV12Image image{static_cast<ID3D11Texture2D *>(copy->texture), copy->width, copy->height};
    if (!image.open()) return 0;
    auto &saved = *copy->uploader;
    if (saved.device.Get() != image.device.Get() || saved.storageW != image.desc.Width || saved.storageH != image.desc.Height
        || saved.width != image.width || saved.height != image.height) {
        saved = {};
        saved.device = image.device;
        saved.storageW = image.desc.Width;
        saved.storageH = image.desc.Height;
        saved.width = image.width;
        saved.height = image.height;
    }
    if (copy->interop && saved.tryInterop) {
        RuneWinD3DBlit blits[2] = {
            {saved.split.planes[0].Get(), image.width, image.height, yTexture},
            {saved.split.planes[1].Get(), image.width / 2, image.height / 2, uvTexture},
        };
        if (SUCCEEDED(saved.split.run(image))) {
            blits[0].texture = saved.split.planes[0].Get();
            blits[1].texture = saved.split.planes[1].Get();
            if (rune_win_blit_d3d_textures(image.device.Get(), blits, 2)) {
                copy->transferred_on_gpu = 1;
                return 1;
            }
        }
        saved.tryInterop = false;
        saved.split = {};
    }
    // Drivers without interop upload both encoded planes directly from a single mapped staging texture.
    return SUCCEEDED(readRows(image, saved.staging, [&](const uint8_t *y, const uint8_t *uv, UINT stride) {
        constexpr GLenum red = 0x1903, rg = 0x8227, rowLength = 0x0cf2;
        if (stride % 2) return E_UNEXPECTED;
        rune_lazy_glPixelStorei(rowLength, (GLint)stride);
        rune_lazy_glBindTexture(GL_TEXTURE_2D, yTexture);
        rune_lazy_glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, image.width, image.height, red, GL_UNSIGNED_BYTE, y);
        rune_lazy_glPixelStorei(rowLength, (GLint)(stride / 2));
        rune_lazy_glBindTexture(GL_TEXTURE_2D, uvTexture);
        rune_lazy_glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, image.width / 2, image.height / 2, rg, GL_UNSIGNED_BYTE, uv);
        rune_lazy_glPixelStorei(rowLength, 0);
        return rune_lazy_glGetError() == GL_NO_ERROR ? S_OK : E_FAIL;
    }));
}

int rune_win_plane_read(void *texture, uint32_t width, uint32_t height,
                        uint8_t *luma, size_t lumaBytes, uint8_t *chroma, size_t chromaBytes,
                        char *error, size_t capacity) {
    NV12Image image{static_cast<ID3D11Texture2D *>(texture), width, height};
    HRESULT hr = E_INVALIDARG;
    if (luma && chroma && image.open() && lumaBytes == size_t(width) * height && chromaBytes == lumaBytes / 2) {
        ComPtr<ID3D11Texture2D> staging;
        hr = readRows(image, staging, [&](const uint8_t *y, const uint8_t *uv, UINT stride) {
            for (UINT row = 0; row < height; row++)
                std::memcpy(luma + size_t(row) * width, y + size_t(row) * stride, width);
            for (UINT row = 0; row < height / 2; row++)
                std::memcpy(chroma + size_t(row) * width, uv + size_t(row) * stride, width);
            return S_OK;
        });
    }
    if (FAILED(hr) && error && capacity)
        std::snprintf(error, capacity, "Read D3D11 NV12 planes (HRESULT 0x%08lx)", (unsigned long)hr);
    return SUCCEEDED(hr);
}
#endif
