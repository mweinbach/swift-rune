// Checks that DWM uses the decoder's visual above an opaque child flip-window surrogate.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <d3d11.h>
#include <dwmapi.h>
#include <wrl/client.h>
#include <cstdio>
#include <thread>
#include "RuneWinVideoLayer.h"
using Microsoft::WRL::ComPtr;

static bool pixel(HWND owner, int x, int y, COLORREF expected) {
    POINT p{x, y};
    ClientToScreen(owner, &p);
    COLORREF last = CLR_INVALID;
    for (unsigned i = 0; i < 120; ++i) {
        MSG msg;
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);
        DwmFlush();
        HDC dc = GetDC(nullptr);
        last = GetPixel(dc, p.x, p.y);
        ReleaseDC(nullptr, dc);
        if (last == expected) return true;
        Sleep(6);
    }
    std::printf("DWM pixel (%d,%d) wanted %06lx got %06lx\n", x, y, expected, last);
    return false;
}

int main() {
    SetProcessDPIAware();
    HINSTANCE inst = GetModuleHandleW(nullptr);
    WNDCLASSW klass{};
    klass.lpfnWndProc = DefWindowProcW;
    klass.hInstance = inst;
    klass.lpszClassName = L"RuneVideoPlaneProbe";
    klass.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
    RegisterClassW(&klass);
    HWND window = CreateWindowExW(WS_EX_TOPMOST | WS_EX_NOACTIVATE, klass.lpszClassName, L"Rune video plane",
                                  WS_POPUP, 100, 120, 128, 128, nullptr, nullptr, inst, nullptr);
    HWND child = CreateWindowExW(0, klass.lpszClassName, L"", WS_CHILD | WS_VISIBLE,
                                  0, 0, 128, 128, window, nullptr, inst, nullptr);
    if (!window || !child) return 1;
    ShowWindow(window, SW_SHOWNOACTIVATE);
    UpdateWindow(window); UpdateWindow(child);
    if (!pixel(window, 30, 30, RGB(0, 0, 0))) return 2;

    ComPtr<ID3D11Device> dev;
    ComPtr<ID3D11DeviceContext> context;
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
                                  nullptr, 0, D3D11_SDK_VERSION, &dev, nullptr, &context);
    if (FAILED(hr)) hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                                          nullptr, 0, D3D11_SDK_VERSION, &dev, nullptr, &context);
    if (FAILED(hr)) return 3;
    RuneWinVideoWindow *host = rune_win_video_window(window);
    if (!host) return 4;
    UINT32 pixels[32 * 32];
    for (auto &p : pixels) p = 0xffff0000u;
    D3D11_TEXTURE2D_DESC d{};
    d.Width = 32; d.Height = 32; d.MipLevels = 1; d.ArraySize = 1;
    d.Format = DXGI_FORMAT_B8G8R8A8_UNORM; d.SampleDesc.Count = 1;
    d.Usage = D3D11_USAGE_DEFAULT; d.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    D3D11_SUBRESOURCE_DATA data{pixels, 128, 0};
    ComPtr<ID3D11Texture2D> tex;
    if (FAILED(dev->CreateTexture2D(&d, &data, &tex))) return 5;
    RuneWinVideoLayer *layer = nullptr;
    std::thread([&] {
        layer = rune_win_video_prepare(host, tex.Get(), 0, 32, 32, 16, 16, 32, 32, 7, 0, 26, 32, 0, 1);
    }).join();
    if (!layer || !pixel(window, 30, 30, RGB(0,0,0)) || !rune_win_video_attach(host, layer) || !pixel(window, 30, 30, RGB(255, 0, 0)) || !pixel(window, 20, 30, RGB(0, 0, 0)) || !pixel(window, 44, 30, RGB(0, 0, 0))) return 6;
    for (auto &p : pixels) p = 0xff00ff00u;
    int presented = 0;
    std::thread([&] {
        context->UpdateSubresource(tex.Get(), 0, nullptr, pixels, 128, 0);
        presented = rune_win_video_present(layer, tex.Get(), 0);
    }).join();
    if (!presented || !pixel(window, 30, 30, RGB(0, 255, 0))) return 7;
    rune_win_video_hide(host, layer);
    if (!pixel(window, 30, 30, RGB(0, 0, 0))) return 8;
    std::printf("PASS DComp two independently presented colors above child, clipped extent, and demotion\n");

    d.Format = DXGI_FORMAT_NV12;
    d.BindFlags = D3D11_BIND_DECODER;
    ComPtr<ID3D11Texture2D> nv12;
    BYTE yuv[32 * 32 * 3 / 2];
    for (int i = 0; i < 32 * 32; ++i) yuv[i] = 235;
    for (int i = 32 * 32; i < sizeof(yuv); ++i) yuv[i] = 128;
    D3D11_SUBRESOURCE_DATA planes{yuv, 32, 0};
    hr = dev->CreateTexture2D(&d, &planes, &nv12);
    auto *yuvLayer = SUCCEEDED(hr) ? rune_win_video_prepare(host, nv12.Get(), 0, 32, 32, 16, 16, 47, 57, 0, 0, 47, 57, 0, 1) : nullptr;
    if (yuvLayer) {
        if (!rune_win_video_attach(host, yuvLayer) || !pixel(window, 29, 30, RGB(255,255,255)) || !pixel(window, 64, 30, RGB(0,0,0))) return 9;
        rune_win_video_hide(host, yuvLayer);
        std::printf("PASS NV12 limited white to odd-sized 47x57 visual\n");
        // The interchange ring is shader-readable; some adapters require the
        // processor to use its own decoder-bindable copy of this texture.
        nv12.Reset();
        d.Width = 64; d.Height = 36;
        d.BindFlags = D3D11_BIND_SHADER_RESOURCE;
        BYTE ring[64 * 36 * 3 / 2];
        for (size_t i = 0; i < sizeof(ring); ++i) ring[i] = i < 64 * 36 ? 235 : 128;
        D3D11_SUBRESOURCE_DATA picture{ring, 64, 0};
        if (SUCCEEDED(dev->CreateTexture2D(&d, &picture, &nv12))) {
            yuvLayer = rune_win_video_prepare(host, nv12.Get(), 0, 64, 36, 0, 0, 128, 72, 0, 0, 128, 72, 0, 1);
            if (!yuvLayer || !pixel(window, 29, 30, RGB(0,0,0)) || !rune_win_video_attach(host, yuvLayer) ||
                !pixel(window, 29, 30, RGB(255,255,255))) return 11;
            rune_win_video_hide(host, yuvLayer);
            std::printf("PASS shader-readable decoder-ring texture on video visual\n");
        }
    } else {
        if (!pixel(window, 29, 30, RGB(0,0,0))) return 10;
        std::printf("NV12 video processor unavailable (texture HRESULT %08lx), UI pixel preserved\n", hr);
    }
    rune_win_video_window_free(host);
    DestroyWindow(window);
    return 0;
}
