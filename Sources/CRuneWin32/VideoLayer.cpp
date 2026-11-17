#ifdef _WIN32
#include "include/RuneWinVideoLayer.h"
#include <windows.h>
#include <d3d11_1.h>
#include <dxgi1_4.h>
#include <dcomp.h>
#include <wrl/client.h>
#include <cstdio>
#include <memory>
#include <new>

using Microsoft::WRL::ComPtr;

namespace {
struct Composition {
    HMODULE library = LoadLibraryExW(L"dcomp.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    decltype(&DCompositionCreateDevice) device = load<decltype(device)>("DCompositionCreateDevice");
    decltype(&DCompositionCreateSurfaceHandle) surface = load<decltype(surface)>("DCompositionCreateSurfaceHandle");
    template<class T> T load(const char *name) const {
        return library ? reinterpret_cast<T>(GetProcAddress(library, name)) : nullptr;
    }
    ~Composition() { if (library) FreeLibrary(library); }
};

Composition &composition() {
    static Composition instance;
    return instance;
}

bool logVideo() {
    static const bool enabled = [] {
        WCHAR value[2]{};
        DWORD size = GetEnvironmentVariableW(L"RUNE_VIDEO_LOG", value, 2);
        return size != 0 && (size != 1 || value[0] != L'0');
    }();
    return enabled;
}

bool failed(const char *phase, HRESULT status) {
    if (SUCCEEDED(status)) return false;
    if (logVideo()) std::fprintf(stderr, "rune video layer: %s failed (HRESULT 0x%08lx)\n", phase, static_cast<unsigned long>(status));
    return true;
}

constexpr UINT videoFlags = DXGI_SWAP_CHAIN_FLAG_YUV_VIDEO | DXGI_SWAP_CHAIN_FLAG_FULLSCREEN_VIDEO;
UINT even(UINT value) { return (value + 1) & ~1u; }
}

struct RuneWinVideoWindow {
    ComPtr<IDCompositionDevice> device;
    ComPtr<IDCompositionTarget> target;
    ComPtr<IDCompositionVisual> root;
};

struct RuneWinVideoLayer {
    HANDLE handle = nullptr;
    ComPtr<IDCompositionVisual> visual;
    ComPtr<IDXGISwapChain1> swap;
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<ID3D11VideoDevice> video;
    ComPtr<ID3D11VideoContext1> processorContext;
    ComPtr<ID3D11VideoProcessorEnumerator> enumerator;
    ComPtr<ID3D11VideoProcessor> processor;
    ComPtr<ID3D11Texture2D> back;
    ComPtr<ID3D11VideoProcessorOutputView> output;
    ComPtr<ID3D11Texture2D> processorInput;
    ComPtr<ID3D11VideoProcessorInputView> processorInputView;
    UINT sourceWidth = 0, sourceHeight = 0;
    DXGI_FORMAT inputFormat = DXGI_FORMAT_UNKNOWN;
    bool copyRGB = false, attached = false;
    struct Input {
        ID3D11Texture2D *texture = nullptr; // kept alive by view
        UINT slice = 0;
        ComPtr<ID3D11VideoProcessorInputView> view;
    } inputs[6];
    unsigned nextInput = 0;

    ~RuneWinVideoLayer() {
        visual.Reset();
        output.Reset();
        back.Reset();
        swap.Reset();
        if (handle) CloseHandle(handle);
    }

    HRESULT makeChain(IDXGIFactory2 *factory, UINT width, UINT height, DXGI_FORMAT format,
                      ComPtr<IUnknown> &content, RuneWinVideoWindow *host) {
        DXGI_SWAP_CHAIN_DESC1 desc{};
        desc.Width = width;
        desc.Height = height;
        desc.Format = format;
        desc.SampleDesc.Count = 1;
        desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        desc.BufferCount = 2;
        desc.Scaling = DXGI_SCALING_STRETCH;
        desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
        desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
        HRESULT hr;
        if (format == DXGI_FORMAT_NV12) {
            desc.Flags = videoFlags;
            ComPtr<IDXGIFactoryMedia> media;
            if (!composition().surface) return E_NOINTERFACE;
            if (FAILED(hr = factory->QueryInterface(IID_PPV_ARGS(&media)))) return hr;
            if (FAILED(hr = composition().surface(COMPOSITIONOBJECT_READ | COMPOSITIONOBJECT_WRITE, nullptr, &handle))) return hr;
            if (FAILED(hr = media->CreateSwapChainForCompositionSurfaceHandle(device.Get(), handle, &desc, nullptr, &swap))) return hr;
            ComPtr<IDXGISwapChain3> color;
            if (FAILED(hr = swap.As(&color))) return hr;
            if (FAILED(hr = color->SetColorSpace1(DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P709))) return hr;
            return host->device->CreateSurfaceFromHandle(handle, &content);
        }
        if (FAILED(hr = factory->CreateSwapChainForComposition(device.Get(), &desc, nullptr, &swap))) return hr;
        return swap.As(&content);
    }

    HRESULT prepare(ID3D11Texture2D *source, UINT sw, UINT sh, int x, int y, UINT w, UINT h,
                    bool full, bool bt709, RuneWinVideoWindow *host, const D2D_RECT_F &clip) {
        source->GetDevice(&device);
        device->GetImmediateContext(&context);
        ComPtr<IDXGIDevice> dxgi;
        ComPtr<IDXGIAdapter> adapter;
        ComPtr<IDXGIFactory2> factory;
        HRESULT hr;
        if (FAILED(hr = device.As(&dxgi)) || FAILED(hr = dxgi->GetAdapter(&adapter)) ||
            FAILED(hr = adapter->GetParent(IID_PPV_ARGS(&factory)))) return hr;

        D3D11_TEXTURE2D_DESC src{};
        source->GetDesc(&src);
        if (!sw || !sh || !w || !h || sw > src.Width || sh > src.Height || w > 16384 || h > 16384) return E_INVALIDARG;
        if (src.Format != DXGI_FORMAT_NV12 && src.Format != DXGI_FORMAT_B8G8R8A8_UNORM) return E_INVALIDARG;
        sourceWidth = sw;
        sourceHeight = sh;
        inputFormat = src.Format;
        ComPtr<IUnknown> content;
        // DWM can promote a YUV media chain to a display overlay. Drivers without
        // a YUV chain can still scale and convert into an independent RGB visual.
        DXGI_FORMAT format = src.Format;
        UINT bw = w, bh = h;
        if (format == DXGI_FORMAT_NV12) {
            bw = even(w); bh = even(h);
        }
        hr = makeChain(factory.Get(), bw, bh, format, content, host);
        if (FAILED(hr) && format == DXGI_FORMAT_NV12) {
            if (logVideo()) std::fprintf(stderr, "rune video layer: NV12 chain unavailable (HRESULT 0x%08lx), trying BGRA\n",
                                         static_cast<unsigned long>(hr));
            swap.Reset();
            if (handle) { CloseHandle(handle); handle = nullptr; }
            content.Reset();
            format = DXGI_FORMAT_B8G8R8A8_UNORM;
            bw = w; bh = h;
            hr = makeChain(factory.Get(), bw, bh, format, content, host);
        }
        if (FAILED(hr)) return hr;
        if (FAILED(hr = swap->GetBuffer(0, IID_PPV_ARGS(&back)))) return hr;

        copyRGB = src.Format == DXGI_FORMAT_B8G8R8A8_UNORM && sw == bw && sh == bh;
        if (!copyRGB) {
            if (FAILED(hr = device.As(&video)) || FAILED(hr = context.As(&processorContext))) return hr;
            D3D11_VIDEO_PROCESSOR_CONTENT_DESC info{};
            info.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
            info.InputFrameRate = {60, 1}; info.OutputFrameRate = info.InputFrameRate;
            info.InputWidth = src.Width; info.InputHeight = src.Height;
            info.OutputWidth = bw; info.OutputHeight = bh;
            info.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
            if (FAILED(hr = video->CreateVideoProcessorEnumerator(&info, &enumerator))) return hr;
            if (FAILED(hr = video->CreateVideoProcessor(enumerator.Get(), 0, &processor))) return hr;
            D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC out{};
            out.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
            if (FAILED(hr = video->CreateVideoProcessorOutputView(back.Get(), enumerator.Get(), &out, &output))) return hr;
            auto *p = processor.Get();
            processorContext->VideoProcessorSetStreamFrameFormat(p, 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
            processorContext->VideoProcessorSetStreamAutoProcessingMode(p, 0, FALSE);
            auto encoding = bt709 ? (full ? DXGI_COLOR_SPACE_YCBCR_FULL_G22_LEFT_P709 : DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P709)
                                  : (full ? DXGI_COLOR_SPACE_YCBCR_FULL_G22_LEFT_P601 : DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P601);
            processorContext->VideoProcessorSetStreamColorSpace1(p, 0, src.Format == DXGI_FORMAT_NV12 ? encoding : DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709);
            processorContext->VideoProcessorSetOutputColorSpace1(p, format == DXGI_FORMAT_NV12 ? DXGI_COLOR_SPACE_YCBCR_STUDIO_G22_LEFT_P709
                                                                                               : DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709);
            RECT sourceRect{0, 0, LONG(sw), LONG(sh)}, destination{0, 0, LONG(w), LONG(h)};
            processorContext->VideoProcessorSetStreamSourceRect(p, 0, TRUE, &sourceRect);
            processorContext->VideoProcessorSetStreamDestRect(p, 0, TRUE, &destination);
            processorContext->VideoProcessorSetOutputTargetRect(p, TRUE, &destination);
        }
        if (FAILED(hr = host->device->CreateVisual(&visual))) return hr;
        if (FAILED(hr = visual->SetContent(content.Get())) ||
            FAILED(hr = visual->SetOffsetX(float(x))) || FAILED(hr = visual->SetOffsetY(float(y)))) return hr;
        if (logVideo()) std::fprintf(stderr, "rune video layer: %s %ux%u composition swap chain\n",
                                     format == DXGI_FORMAT_NV12 ? "NV12" : "BGRA", bw, bh);
        return visual->SetClip(clip);
    }

    HRESULT blit(ID3D11VideoProcessorInputView *input) {
        D3D11_VIDEO_PROCESSOR_STREAM stream{};
        stream.Enable = TRUE;
        stream.pInputSurface = input;
        return processorContext->VideoProcessorBlt(processor.Get(), output.Get(), 0, 1, &stream);
    }

    // Some drivers allow shader sampling a decoder-ring texture but reject it as a
    // video-processor input. Copy to one reusable input on the same immediate context.
    HRESULT blitCompatible(ID3D11Texture2D *texture, UINT slice, const D3D11_TEXTURE2D_DESC &source) {
        if (!processorInput) {
            D3D11_TEXTURE2D_DESC desc{};
            desc.Width = source.Width;
            desc.Height = source.Height;
            desc.Format = source.Format;
            desc.MipLevels = desc.ArraySize = desc.SampleDesc.Count = 1;
            desc.Usage = D3D11_USAGE_DEFAULT;
            desc.BindFlags = source.Format == DXGI_FORMAT_NV12 ? D3D11_BIND_DECODER : D3D11_BIND_RENDER_TARGET;
            ComPtr<ID3D11Texture2D> compatible;
            HRESULT hr = device->CreateTexture2D(&desc, nullptr, &compatible);
            if (failed("create compatible video-processor texture", hr)) return hr;
            D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC in{};
            in.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
            hr = video->CreateVideoProcessorInputView(compatible.Get(), enumerator.Get(), &in, &processorInputView);
            if (failed("create compatible video-processor view", hr)) return hr;
            processorInput = std::move(compatible);
            if (logVideo()) std::fprintf(stderr, "rune video layer: copying decoder pictures to a compatible GPU input\n");
        }
        D3D11_BOX box{0, 0, 0, sourceWidth, sourceHeight, 1};
        context->CopySubresourceRegion(processorInput.Get(), 0, 0, 0, 0, texture,
                                       D3D11CalcSubresource(0, slice, source.MipLevels), &box);
        auto hr = blit(processorInputView.Get());
        failed("compatible video-processor blit", hr);
        return hr;
    }

    HRESULT present(ID3D11Texture2D *texture, UINT slice) {
        ComPtr<ID3D11Device> owner;
        texture->GetDevice(&owner);
        if (owner.Get() != device.Get()) return E_INVALIDARG;
        D3D11_TEXTURE2D_DESC src{};
        texture->GetDesc(&src);
        if (src.Format != inputFormat || slice >= src.ArraySize || src.Width < sourceWidth || src.Height < sourceHeight) return E_INVALIDARG;
        if (copyRGB) {
            if (src.Format != DXGI_FORMAT_B8G8R8A8_UNORM) return E_INVALIDARG;
            D3D11_BOX box{0, 0, 0, sourceWidth, sourceHeight, 1};
            context->CopySubresourceRegion(back.Get(), 0, 0, 0, 0, texture, D3D11CalcSubresource(0, slice, src.MipLevels), &box);
        } else if (processorInput) {
            HRESULT hr = blitCompatible(texture, slice, src);
            if (FAILED(hr)) return hr;
        } else {
            ID3D11VideoProcessorInputView *view = nullptr;
            for (const auto &slot : inputs)
                if (slot.texture == texture && slot.slice == slice) { view = slot.view.Get(); break; }
            HRESULT hr = S_OK;
            if (!view) {
                D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC in{};
                in.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
                in.Texture2D.ArraySlice = slice;
                ComPtr<ID3D11VideoProcessorInputView> newView;
                hr = video->CreateVideoProcessorInputView(texture, enumerator.Get(), &in, &newView);
                if (!failed("decoder video-processor input view", hr)) {
                    view = newView.Get();
                    inputs[nextInput] = {texture, slice, std::move(newView)};
                    nextInput = (nextInput + 1) % 6;
                }
            }
            if (view) {
                hr = blit(view);
                failed("decoder video-processor blit", hr);
            }
            if (FAILED(hr) && FAILED(hr = blitCompatible(texture, slice, src))) return hr;
        }
        auto hr = swap->Present(1, 0);
        failed("composition swap-chain present", hr);
        return hr;
    }
};

RuneWinVideoWindow *rune_win_video_window(void *hwnd) {
    if (!hwnd || !composition().device) return nullptr;
    std::unique_ptr<RuneWinVideoWindow> window(new(std::nothrow) RuneWinVideoWindow);
    if (!window) return nullptr;
    // The UI remains opaque. Swift promotes only video with no overlapping UI.
    if (failed("create composition device", composition().device(nullptr, IID_PPV_ARGS(&window->device))) ||
        failed("create window target", window->device->CreateTargetForHwnd(static_cast<HWND>(hwnd), TRUE, &window->target)) ||
        failed("create visual root", window->device->CreateVisual(&window->root)) ||
        failed("bind visual root", window->target->SetRoot(window->root.Get()))) return nullptr;
    return window.release();
}

void rune_win_video_window_free(RuneWinVideoWindow *window) {
    if (window) {
        window->target->SetRoot(nullptr);
        window->device->Commit();
        delete window;
    }
}

uintptr_t rune_win_video_device_id(void *texture) {
    if (!texture) return 0;
    ComPtr<ID3D11Device> device;
    static_cast<ID3D11Texture2D *>(texture)->GetDevice(&device);
    return reinterpret_cast<uintptr_t>(device.Get());
}

RuneWinVideoLayer *rune_win_video_prepare(RuneWinVideoWindow *window, void *texture, uint32_t slice,
    uint32_t sw, uint32_t sh, int32_t x, int32_t y, uint32_t w, uint32_t h, int32_t l, int32_t t, int32_t r, int32_t b, int full, int bt709) {
    if (!window || !texture || l < 0 || t < 0 || r <= l || b <= t || unsigned(r) > w || unsigned(b) > h) return nullptr;
    std::unique_ptr<RuneWinVideoLayer> layer(new(std::nothrow) RuneWinVideoLayer);
    auto *source = static_cast<ID3D11Texture2D *>(texture);
    if (!layer || failed("prepare decoder swap chain", layer->prepare(source, sw, sh, x, y, w, h, full != 0, bt709 != 0, window,
                                                                       {float(l), float(t), float(r), float(b)}))) return nullptr;
    HRESULT primed = layer->present(source, slice);
    if (failed("prime decoder swap chain", primed) || primed != S_OK) return nullptr;
    return layer.release();
}

int rune_win_video_attach(RuneWinVideoWindow *window, RuneWinVideoLayer *layer) {
    if (!window || !layer || layer->attached) return 0;
    if (FAILED(window->root->AddVisual(layer->visual.Get(), TRUE, nullptr))) return 0;
    if (FAILED(window->device->Commit()) || FAILED(window->device->WaitForCommitCompletion())) {
        window->root->RemoveVisual(layer->visual.Get());
        window->device->Commit();
        return 0;
    }
    layer->attached = true;
    if (logVideo()) std::fprintf(stderr, "rune video layer: independently presenting %ux%u source\n", layer->sourceWidth, layer->sourceHeight);
    return 1;
}

int rune_win_video_present(RuneWinVideoLayer *layer, void *texture, uint32_t slice) {
    return layer && texture && layer->present(static_cast<ID3D11Texture2D *>(texture), slice) == S_OK;
}

void rune_win_video_hide(RuneWinVideoWindow *window, RuneWinVideoLayer *layer) {
    if (window && layer && layer->attached) {
        if (logVideo()) std::fprintf(stderr, "rune video layer: returning pictures to UI\n");
        window->root->RemoveVisual(layer->visual.Get());
        if (SUCCEEDED(window->device->Commit())) window->device->WaitForCommitCompletion();
    }
    delete layer;
}
#endif
