#ifdef _WIN32
#include "PresentQueue.hpp"
#include "PresentDXGI.h"
#include "PresentInterop.h"
#include "include/RuneSharedTexture.h"
#include <cstdio>
#include <new>

using Microsoft::WRL::ComPtr;

struct RuneDXGIPresenter {
    HWND window;
    UINT width, height;
    bool overGdi;
    RunePresentQueue queue;
    RunePresentInterop *interop;
};

void rune_dxgi_report(const char *path, const char *detail, HRESULT result) {
    wchar_t enabled[2];
    if (GetEnvironmentVariableW(L"RUNE_GPU_INFO", enabled, 2) == 1 && enabled[0] == L'1') {
        std::fprintf(stderr, "[rune.gpu] windows_present=%s reason=%s hr=0x%08lx\n", path, detail,
                     static_cast<unsigned long>(result));
    }
}

namespace {
template<typename T> T entry(const wchar_t *dll, const char *name) {
    HMODULE lib = LoadLibraryExW(dll, nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    return lib ? reinterpret_cast<T>(GetProcAddress(lib, name)) : nullptr;
}
HRESULT createDevice(ComPtr<ID3D11Device> &device) {
    // The frame is rendered by WGL. Open a D3D device on its adapter, including on hybrid laptops.
    static auto factoryFn = entry<decltype(&CreateDXGIFactory1)>(L"dxgi.dll", "CreateDXGIFactory1");
    static auto deviceFn = entry<decltype(&D3D11CreateDevice)>(L"d3d11.dll", "D3D11CreateDevice");
    if (!factoryFn || !deviceFn) return E_NOINTERFACE;
    int32_t high;
    uint32_t low;
    if (!rune_win_shared_adapter(&high, &low)) return DXGI_ERROR_NOT_FOUND;
    ComPtr<IDXGIFactory1> factory;
    HRESULT hr = factoryFn(IID_PPV_ARGS(&factory));
    if (FAILED(hr)) return hr;
    for (UINT i = 0;; ++i) {
        ComPtr<IDXGIAdapter1> adapter;
        if (FAILED(hr = factory->EnumAdapters1(i, &adapter))) return hr;
        DXGI_ADAPTER_DESC1 desc{};
        if (FAILED(adapter->GetDesc1(&desc)) || desc.AdapterLuid.LowPart != low || desc.AdapterLuid.HighPart != high)
            continue;
        return deviceFn(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
                        D3D11_SDK_VERSION, &device, nullptr, nullptr);
    }
}
}

static RuneDXGIPresenter *openPresenter(HWND hwnd, UINT wake, bool overGdi) {
    if (!rune_win_shared_gl_available()) {
        rune_dxgi_report("WGL", "WGL_NV_DX_interop2 unavailable", E_NOINTERFACE);
        return nullptr;
    }
    RECT client{};
    if (!GetClientRect(hwnd, &client) || client.right <= 0 || client.bottom <= 0) return nullptr;
    auto out = new (std::nothrow) RuneDXGIPresenter{};
    if (!out) return nullptr;
    out->window = hwnd;
    out->overGdi = overGdi;
    out->width = static_cast<UINT>(client.right);
    out->height = static_cast<UINT>(client.bottom);
    rune_win_shared_note_window();
    ComPtr<ID3D11Device> device;
    HRESULT hr = createDevice(device);
    const char *stage = "matching D3D11 adapter";
    if (SUCCEEDED(hr)) {
        stage = "WGL/D3D11 shared render target";
        out->interop = rune_present_interop_create(device.Get());
        if (!out->interop || !rune_present_interop_resize(out->interop, client.right, client.bottom)) hr = E_FAIL;
    }
    if (SUCCEEDED(hr)) {
        stage = overGdi ? "uncommitted DirectComposition swap chain" : "waitable flip-sequential swap chain";
        hr = out->queue.open(hwnd, wake, device.Get(), out->width, out->height, overGdi);
    }
    if (FAILED(hr)) {
        rune_dxgi_report("WGL", stage, hr);
        rune_dxgi_close(out, true);
        return nullptr;
    }
    rune_dxgi_report("DXGI", "D3D11 flip sequential, latency 1, WGL_NV_DX_interop2", S_OK);
    return out;
}

RuneDXGIPresenter *rune_dxgi_open(HWND hwnd, UINT wake) { return openPresenter(hwnd, wake, false); }
RuneDXGIPresenter *rune_dxgi_open_cpu(HWND hwnd, UINT wake) { return openPresenter(hwnd, wake, true); }

void rune_dxgi_close(RuneDXGIPresenter *p, int current) {
    if (!p) return;
    if (p->interop) rune_present_interop_destroy(p->interop, current != 0);
    delete p;
}

int rune_dxgi_prepare(RuneDXGIPresenter *p) {
    RECT client{};
    if (!GetClientRect(p->window, &client)) return -1;
    if (client.right <= 0 || client.bottom <= 0) return 0;
    if ((UINT)client.right != p->width || (UINT)client.bottom != p->height) {
        HRESULT hr = p->queue.resize(client.right, client.bottom);
        if (FAILED(hr) || !rune_present_interop_resize(p->interop, client.right, client.bottom)) {
            rune_dxgi_report("WGL", "resize", FAILED(hr) ? hr : E_FAIL);
            return -1;
        }
        p->width = client.right;
        p->height = client.bottom;
    }
    if (!p->queue.take()) return 0;
    rune_present_interop_bind(p->interop);
    return 1;
}

int rune_dxgi_arm_next(RuneDXGIPresenter *p) { return p ? (p->queue.take() ? 1 : 0) : 1; }

int rune_dxgi_ready(RuneDXGIPresenter *p, ULONG_PTR token) { return p && p->queue.awakened(token); }

int rune_dxgi_present(RuneDXGIPresenter *p, int width, int height, const int32_t *rects, int count) {
    RECT dirty[4]{};
    UINT n = 0;
    if (!p->queue.needsWholeFrame() && (UINT)width == p->width && (UINT)height == p->height) {
        if (count == 0) {
            dirty[0] = {0, 0, 1, 1};
            n = 1;
        } else if (rects && count > 0 && count <= 4) {
            n = static_cast<UINT>(count);
            for (UINT i = 0; i < n; ++i) {
                const int32_t *r = rects + i * 4;
                if (r[0] < 0 || r[1] < 0 || r[2] <= r[0] || r[3] <= r[1] || r[2] > width || r[3] > height) {
                    n = 0;
                    break;
                }
                dirty[i] = {r[0], r[1], r[2], r[3]};
            }
        }
    }
    ID3D11Texture2D *source = rune_present_interop_copy(p->interop, dirty, n);
    HRESULT hr = source ? p->queue.present(source, dirty, n) : E_FAIL;
    if (p->overGdi ? hr == S_OK : SUCCEEDED(hr)) return 1;
    rune_dxgi_report(p->overGdi ? "GDI" : "WGL", source ? "DXGI presentation" : "shared GPU frame copy", hr);
    p->queue.hide();
    if (!p->overGdi) rune_present_interop_fallback(p->interop);
    return 0;
}
#endif
