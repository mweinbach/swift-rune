#ifdef _WIN32
#include "WGLHandover.h"
#include <d3d11.h>
#include <dxgi1_2.h>
#include <dcomp.h>
#include <wrl/client.h>
#include <memory>
#include <new>

using Microsoft::WRL::ComPtr;

namespace {
struct CoverAPI {
    HMODULE d3d = LoadLibraryExW(L"d3d11.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    HMODULE dcomp = LoadLibraryExW(L"dcomp.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    decltype(&D3D11CreateDevice) createD3D = d3d ?
        reinterpret_cast<decltype(createD3D)>(GetProcAddress(d3d, "D3D11CreateDevice")) : nullptr;
    decltype(&DCompositionCreateDevice) createComposition = dcomp ?
        reinterpret_cast<decltype(createComposition)>(GetProcAddress(dcomp, "DCompositionCreateDevice")) : nullptr;
    ~CoverAPI() {
        if (dcomp) FreeLibrary(dcomp);
        if (d3d) FreeLibrary(d3d);
    }
};

HRESULT upload(IDCompositionSurface *surface, ID3D11DeviceContext *context,
               const void *pixels, UINT width, UINT height, UINT stride) {
    POINT offset{};
    ComPtr<IDXGISurface> update;
    HRESULT hr = surface->BeginDraw(nullptr, IID_PPV_ARGS(&update), &offset);
    if (FAILED(hr)) return hr;
    // DirectComposition can place the update inside a larger texture.
    ComPtr<IDXGISurface2> subresource;
    ComPtr<ID3D11Texture2D> texture;
    UINT index = 0;
    if (SUCCEEDED(hr = update.As(&subresource)) &&
        SUCCEEDED(hr = subresource->GetResource(IID_PPV_ARGS(&texture), &index))) {
        UINT x = static_cast<UINT>(offset.x), y = static_cast<UINT>(offset.y);
        D3D11_BOX destination{x, y, 0, x + width, y + height, 1};
        context->UpdateSubresource(texture.Get(), index, &destination, pixels, stride, 0);
    }
    HRESULT end = surface->EndDraw();
    return FAILED(hr) ? hr : end;
}
}

struct RuneWGLCover {
    ComPtr<IDCompositionDevice> device;
    ComPtr<IDCompositionTarget> target;
    ComPtr<IDCompositionVisual> visual;
    ComPtr<IDCompositionSurface> snapshot;
};

RuneWGLCover *rune_wgl_cover(HWND child, const void *bgra, int width, int height, int stride_bytes) {
    RECT bounds{};
    if (!child || !bgra || width <= 0 || height <= 0 || width > stride_bytes / 4 ||
        !GetClientRect(child, &bounds) || width != bounds.right || height != bounds.bottom) return nullptr;
    static CoverAPI api;
    if (!api.createD3D || !api.createComposition) return nullptr;

    // This one-time upload needs only the Windows software device. It also
    // works when the WGL ICD cannot share textures with Direct3D.
    ComPtr<ID3D11Device> d3d;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<IDXGIDevice> dxgi;
    if (FAILED(api.createD3D(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                             nullptr, 0, D3D11_SDK_VERSION, &d3d, nullptr, &context)) ||
        FAILED(d3d.As(&dxgi))) return nullptr;
    std::unique_ptr<RuneWGLCover> cover(new (std::nothrow) RuneWGLCover);
    if (!cover || FAILED(api.createComposition(dxgi.Get(), IID_PPV_ARGS(&cover->device))) ||
        FAILED(cover->device->CreateTargetForHwnd(child, FALSE, &cover->target)) ||
        FAILED(cover->device->CreateVisual(&cover->visual)) ||
        FAILED(cover->device->CreateSurface(width, height, DXGI_FORMAT_B8G8R8A8_UNORM,
                                            DXGI_ALPHA_MODE_IGNORE, &cover->snapshot)) ||
        FAILED(upload(cover->snapshot.Get(), context.Get(), bgra, width, height, stride_bytes)) ||
        FAILED(cover->visual->SetContent(cover->snapshot.Get())) ||
        FAILED(cover->target->SetRoot(cover->visual.Get())) ||
        FAILED(cover->device->Commit()) || FAILED(cover->device->WaitForCommitCompletion())) return nullptr;
    return cover.release();
}

int rune_wgl_uncover(RuneWGLCover *cover) {
    return cover && SUCCEEDED(cover->target->SetRoot(nullptr)) &&
           SUCCEEDED(cover->device->Commit()) && SUCCEEDED(cover->device->WaitForCommitCompletion());
}

void rune_wgl_cover_free(RuneWGLCover *cover) { delete cover; }
#endif
