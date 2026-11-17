#pragma once
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <d3d11.h>
#include <dcomp.h>
#include <dxgi1_3.h>
#include <wrl/client.h>

// One flip-sequential surface. The UI thread owns this object. A registered wait can
// only post its wake message; it never draws or touches any COM object.
class RunePresentQueue {
    using Chain = Microsoft::WRL::ComPtr<IDXGISwapChain2>;
    Chain chain;
    Microsoft::WRL::ComPtr<ID3D11DeviceContext> context;
    Microsoft::WRL::ComPtr<IDCompositionDevice> composition;
    Microsoft::WRL::ComPtr<IDCompositionTarget> target;
    Microsoft::WRL::ComPtr<ID3D11Query> firstCopy;
    HWND owner = nullptr, child = nullptr;
    HANDLE slot = nullptr, wait = nullptr;
    UINT wake = 0;
    ULONG_PTR token = 0;
    bool owed = false, full = true, committed = false;
    UINT width = 0, height = 0;
    void cancelWait();
    HRESULT openComposition(ID3D11Device *device, IDXGIDevice *dxgi, IDXGISwapChain1 *surface);
    HRESULT reveal();
    static VOID CALLBACK notify(PVOID arg, BOOLEAN timedOut);
public:
    RunePresentQueue() = default;
    RunePresentQueue(const RunePresentQueue&) = delete;
    RunePresentQueue &operator=(const RunePresentQueue&) = delete;
    ~RunePresentQueue();
    HRESULT open(HWND window, UINT wakeMessage, ID3D11Device *device, UINT w, UINT h, bool overGdi = false);
    HRESULT resize(UINT w, UINT h);
    bool needsWholeFrame() const { return full; }
    void hide();
    bool take();
    bool awakened(ULONG_PTR messageToken);
    HRESULT present(ID3D11Texture2D *source, const RECT *dirty, UINT count);
};
#endif
