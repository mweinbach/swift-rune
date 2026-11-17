#ifdef _WIN32
#include "PresentQueue.hpp"

namespace {
constexpr UINT swapFlags = DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;
volatile LONG nextToken = 0;
LRESULT CALLBACK presentationWindow(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_NCHITTEST) return HTTRANSPARENT;
    if (msg == WM_ERASEBKGND) return 1;
    return DefWindowProcW(hwnd, msg, wp, lp);
}

HWND makeChild(HWND owner, UINT width, UINT height) {
    // Flip-model and WGL presentation cannot alternate on one HWND. Keeping the DXGI
    // visual on a child lets a device loss return immediately to the parent's WGL surface.
    constexpr wchar_t name[] = L"RuneSwiftDXGIVisual";
    WNDCLASSW klass{};
    klass.lpfnWndProc = presentationWindow;
    klass.hInstance = GetModuleHandleW(nullptr);
    klass.lpszClassName = name;
    if (!RegisterClassW(&klass) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return nullptr;
    return CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_NOPARENTNOTIFY | WS_EX_TRANSPARENT, name, nullptr,
                           WS_CHILD | WS_DISABLED, 0, 0, width, height, owner, nullptr, klass.hInstance, nullptr);
}
}

HRESULT RunePresentQueue::openComposition(ID3D11Device *device, IDXGIDevice *dxgi, IDXGISwapChain1 *surface) {
    static const auto create = [] {
        HMODULE library = LoadLibraryExW(L"dcomp.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        return library ? reinterpret_cast<decltype(&DCompositionCreateDevice)>(
            GetProcAddress(library, "DCompositionCreateDevice")) : nullptr;
    }();
    if (!create) return E_NOINTERFACE;
    HRESULT hr = create(dxgi, IID_PPV_ARGS(&composition));
    if (FAILED(hr)) return hr;
    // The upper target belongs to promoted video. The lower target covers the GDI
    // redirection surface in one transaction only after a complete GPU frame is ready.
    if (FAILED(hr = composition->CreateTargetForHwnd(owner, FALSE, &target))) return hr;
    Microsoft::WRL::ComPtr<IDCompositionVisual> visual;
    if (FAILED(hr = composition->CreateVisual(&visual))) return hr;
    if (FAILED(hr = visual->SetContent(surface))) return hr;
    if (FAILED(hr = target->SetRoot(visual.Get()))) return hr;
    D3D11_QUERY_DESC completed{D3D11_QUERY_EVENT, 0};
    return device->CreateQuery(&completed, &firstCopy);
}

HRESULT RunePresentQueue::open(HWND window, UINT wakeMessage, ID3D11Device *device, UINT w, UINT h, bool overGdi) {
    using Microsoft::WRL::ComPtr;
    owner = window;
    wake = wakeMessage;
    token = static_cast<ULONG_PTR>(InterlockedIncrement(&nextToken));
    ComPtr<IDXGIDevice> dxgi;
    ComPtr<IDXGIAdapter> adapter;
    ComPtr<IDXGIFactory2> factory;
    HRESULT hr = device->QueryInterface(IID_PPV_ARGS(&dxgi));
    if (FAILED(hr)) return hr;
    if (FAILED(hr = dxgi->GetAdapter(&adapter))) return hr;
    if (FAILED(hr = adapter->GetParent(IID_PPV_ARGS(&factory)))) return hr;
    DXGI_SWAP_CHAIN_DESC1 desc{};
    desc.Width = w;
    desc.Height = h;
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.Scaling = DXGI_SCALING_STRETCH;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
    desc.Flags = swapFlags;
    ComPtr<IDXGISwapChain1> base;
    if (overGdi) {
        if (FAILED(hr = factory->CreateSwapChainForComposition(device, &desc, nullptr, &base))) return hr;
        if (FAILED(hr = openComposition(device, dxgi.Get(), base.Get()))) return hr;
    } else {
        child = makeChild(owner, w, h);
        if (!child) return HRESULT_FROM_WIN32(GetLastError());
        if (FAILED(hr = factory->CreateSwapChainForHwnd(device, child, &desc, nullptr, nullptr, &base))) return hr;
        factory->MakeWindowAssociation(owner, DXGI_MWA_NO_ALT_ENTER);
    }
    if (FAILED(hr = base.As(&chain))) return hr;
    if (FAILED(hr = chain->SetMaximumFrameLatency(1))) return hr;
    slot = chain->GetFrameLatencyWaitableObject();
    if (!slot) return E_HANDLE;
    device->GetImmediateContext(&context);
    width = w;
    height = h;
    return S_OK;
}

void RunePresentQueue::cancelWait() {
    if (!wait) return;
    UnregisterWaitEx(wait, INVALID_HANDLE_VALUE);
    wait = nullptr;
}

RunePresentQueue::~RunePresentQueue() {
    cancelWait();
    if (committed) hide();
    if (slot) CloseHandle(slot);
    chain.Reset();
    if (child && IsWindow(child)) DestroyWindow(child);
}

void RunePresentQueue::hide() {
    if (child) ShowWindow(child, SW_HIDE);
    if (target && committed) {
        if (SUCCEEDED(target->SetRoot(nullptr)) && SUCCEEDED(composition->Commit())) committed = false;
    }
}

HRESULT RunePresentQueue::resize(UINT w, UINT h) {
    if (w == width && h == height) return S_OK;
    cancelWait();
    token = static_cast<ULONG_PTR>(InterlockedIncrement(&nextToken));
    HRESULT hr = chain->ResizeBuffers(0, w, h, DXGI_FORMAT_UNKNOWN, swapFlags);
    if (FAILED(hr)) return hr;
    if (child && !SetWindowPos(child, nullptr, 0, 0, w, h, SWP_NOMOVE | SWP_NOACTIVATE | SWP_NOZORDER))
        return HRESULT_FROM_WIN32(GetLastError());
    width = w;
    height = h;
    owed = false;
    full = true;
    return S_OK;
}

VOID CALLBACK RunePresentQueue::notify(PVOID arg, BOOLEAN) {
    auto queue = static_cast<RunePresentQueue *>(arg);
    PostMessageW(queue->owner, queue->wake, queue->token, 0);
}

bool RunePresentQueue::take() {
    if (wait) return false;
    if (!owed) return true;
    HANDLE registered = nullptr;
    if (WaitForSingleObject(slot, 0) == WAIT_TIMEOUT &&
        RegisterWaitForSingleObject(&registered, slot, notify, this, 100, WT_EXECUTEONLYONCE | WT_EXECUTEINWAITTHREAD)) {
        wait = registered;
        return false;
    }
    owed = false;
    return true;
}

bool RunePresentQueue::awakened(ULONG_PTR messageToken) {
    if (!wait || messageToken != token) return false;
    cancelWait();
    owed = false;
    return true;
}

HRESULT RunePresentQueue::present(ID3D11Texture2D *source, const RECT *dirty, UINT count) {
    Microsoft::WRL::ComPtr<ID3D11Texture2D> back;
    HRESULT hr = chain->GetBuffer(0, IID_PPV_ARGS(&back));
    if (FAILED(hr)) return hr;
    DXGI_PRESENT_PARAMETERS parameters{};
    if (full || !count) {
        context->CopyResource(back.Get(), source);
    } else {
        for (UINT i = 0; i < count; ++i) {
            const RECT &r = dirty[i];
            if (r.left < 0 || r.top < 0 || r.right <= r.left || r.bottom <= r.top ||
                (UINT)r.right > width || (UINT)r.bottom > height) return E_INVALIDARG;
            D3D11_BOX box{(UINT)r.left, (UINT)r.top, 0, (UINT)r.right, (UINT)r.bottom, 1};
            context->CopySubresourceRegion(back.Get(), 0, box.left, box.top, 0, source, 0, &box);
        }
        parameters.DirtyRectsCount = count;
        parameters.pDirtyRects = const_cast<RECT *>(dirty);
    }
    if (firstCopy) {
        context->End(firstCopy.Get());
        context->Flush();
    }
    if (child && !(GetWindowLongPtrW(child, GWL_STYLE) & WS_VISIBLE)) ShowWindow(child, SW_SHOWNOACTIVATE);
    hr = chain->Present1(1, 0, &parameters);
    if (composition && hr != S_OK) return hr;
    if (firstCopy && FAILED(hr = reveal())) return hr;
    if (SUCCEEDED(hr)) {
        full = hr == DXGI_STATUS_OCCLUDED;
        owed = true;
    }
    return hr;
}

HRESULT RunePresentQueue::reveal() {
    // Present1 accepted the buffer. Keep the last CPU frame visible until the
    // GPU has completed its copy, including on a slow or removed adapter.
    ULONGLONG deadline = GetTickCount64() + 250;
    HRESULT hr;
    while ((hr = context->GetData(firstCopy.Get(), nullptr, 0, D3D11_ASYNC_GETDATA_DONOTFLUSH)) == S_FALSE) {
        if (GetTickCount64() >= deadline) return HRESULT_FROM_WIN32(WAIT_TIMEOUT);
        Sleep(1);
    }
    if (FAILED(hr)) return hr;
    if (FAILED(hr = composition->Commit())) return hr;
    committed = true;
    firstCopy.Reset();
    return S_OK;
}
#endif
