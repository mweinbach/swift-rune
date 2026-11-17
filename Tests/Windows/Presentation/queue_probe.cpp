#ifdef _WIN32
#include "../../../Sources/CRuneWin32/PresentQueue.hpp"
#include <dwmapi.h>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace {
constexpr UINT readyMessage = WM_APP + 271;
RunePresentQueue *queue;
int wakes;
LRESULT CALLBACK host(HWND window, UINT message, WPARAM w, LPARAM l) {
    if (message == readyMessage && queue && queue->awakened(w)) { wakes++; return 0; }
    return DefWindowProcW(window, message, w, l);
}
bool take() {
    ULONGLONG until = GetTickCount64() + 2500;
    while (!queue->take()) {
        if (GetTickCount64() >= until) return false;
        MsgWaitForMultipleObjects(0, nullptr, FALSE, 100, QS_ALLINPUT);
        MSG msg;
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);
    }
    return true;
}
bool displayed(HWND parent, LONG x, LONG y, COLORREF expected, int attempts = 15) {
    POINT at{x, y};
    ClientToScreen(parent, &at);
    COLORREF got = CLR_INVALID;
    for (int i = 0; i < attempts; ++i) {
        DwmFlush();
        HDC screen = GetDC(nullptr);
        got = GetPixel(screen, at.x, at.y);
        ReleaseDC(nullptr, screen);
        if (got == expected) return true;
        Sleep(15);
    }
    std::printf("expected visible pixel %06lx, got %06lx at window (%ld, %ld)\n", expected, got, x, y);
    return false;
}
void demand(bool condition, const char *stage) {
    if (!condition) { std::fprintf(stderr, "failed: %s\n", stage); std::exit(1); }
}

struct HandoffSample {
    POINT screenPoint;
    COLORREF cpu, gpu;
    HANDLE started;
};
DWORD WINAPI watchHandoff(void *argument) {
    const auto &probe = *static_cast<HandoffSample *>(argument);
    ULONGLONG deadline = GetTickCount64() + 2500;
    while (GetTickCount64() < deadline && SUCCEEDED(DwmFlush())) {
        HDC screen = GetDC(nullptr);
        COLORREF pixel = GetPixel(screen, probe.screenPoint.x, probe.screenPoint.y);
        ReleaseDC(nullptr, screen);
        if (pixel == probe.gpu) return 0;
        if (pixel != probe.cpu) {
            std::fprintf(stderr, "unexpected handoff pixel %06lx\n", pixel);
            return 1;
        }
        SetEvent(probe.started);
    }
    return 1;
}
}

int main() {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    constexpr COLORREF cpuColor = RGB(178, 23, 191);
    WNDCLASSW cls{};
    cls.hInstance = GetModuleHandleW(nullptr); cls.lpfnWndProc = host; cls.lpszClassName = L"RuneDXGIProbe";
    cls.hbrBackground = CreateSolidBrush(cpuColor);
    RegisterClassW(&cls);
    RECT work{};
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
    HWND window = CreateWindowExW(WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, cls.lpszClassName, L"Rune DXGI probe",
                                  WS_POPUP, (work.right + work.left) / 2, (work.bottom + work.top) / 2, 160, 100,
                                  nullptr, nullptr, cls.hInstance, nullptr);
    demand(window != nullptr, "parent HWND");
    ShowWindow(window, SW_SHOWNOACTIVATE);
    using Microsoft::WRL::ComPtr;
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> dc;
    demand(SUCCEEDED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                                       nullptr, 0, D3D11_SDK_VERSION, &device, nullptr, &dc)), "hardware D3D11 device");
    for (bool composition : {false, true}) {
        SetWindowPos(window, nullptr, 0, 0, 160, 100, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        RedrawWindow(window, nullptr, nullptr, RDW_ERASE | RDW_INVALIDATE | RDW_UPDATENOW);
        if (composition) demand(displayed(window, 100, 70, cpuColor), "GDI before creating GPU target");
        RunePresentQueue q;
        queue = &q;
        wakes = 0;
        HRESULT hr = q.open(window, readyMessage, device.Get(), 160, 100, composition);
        std::printf("%s waitable flip-sequential open hr=0x%08lx\n",
                    composition ? "DirectComposition" : "child HWND", (unsigned long)hr);
        demand(SUCCEEDED(hr), "create waitable flip chain");
        if (composition) {
            // The second candidate fails because each HWND has only one lower composition target.
            {
                RunePresentQueue competing;
                demand(FAILED(competing.open(window, readyMessage, device.Get(), 160, 100, true)),
                       "competing lower composition target rejected");
            }
            for (int i = 0; i < 4; ++i)
                demand(displayed(window, 100, 70, cpuColor, 1), "GDI remained visible before first GPU frame");
        }
        auto makeTexture = [&](int w, int h, uint32_t outside, uint32_t patch) {
            std::vector<uint32_t> data(w * h, outside);
            for (int y = 20; y < 40; ++y) for (int x = 21; x < 44; ++x) data[y*w+x] = patch;
            D3D11_TEXTURE2D_DESC desc{};
            desc.Width = w; desc.Height = h; desc.ArraySize = desc.MipLevels = desc.SampleDesc.Count = 1;
            desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM; desc.Usage = D3D11_USAGE_DEFAULT;
            D3D11_SUBRESOURCE_DATA texels{data.data(), UINT(w * 4), 0};
            ComPtr<ID3D11Texture2D> texture;
            demand(SUCCEEDED(device->CreateTexture2D(&desc, &texels, &texture)), "source allocation");
            return texture;
        };
        constexpr uint32_t red = 0xff0000ff, blue = 0xffff0000, green = 0xff00ff00;
        RECT rect{21, 20, 44, 40};
        auto first = makeTexture(160, 100, red, blue);
        HandoffSample handoff{{100, 70}, cpuColor, RGB(255, 0, 0), nullptr};
        HANDLE watcher = nullptr;
        if (composition) {
            ClientToScreen(window, &handoff.screenPoint);
            handoff.started = CreateEventW(nullptr, TRUE, FALSE, nullptr);
            watcher = CreateThread(nullptr, 0, watchHandoff, &handoff, 0, nullptr);
            demand(watcher && WaitForSingleObject(handoff.started, 3000) == WAIT_OBJECT_0, "sample GDI as GPU handoff begins");
        }
        demand(take() && q.present(first.Get(), composition ? &rect : nullptr, composition ? 1 : 0) == S_OK,
               "full presentation");
        if (watcher) {
            DWORD result;
            demand(WaitForSingleObject(watcher, 3000) == WAIT_OBJECT_0 && GetExitCodeThread(watcher, &result) && result == 0,
                   "observed only GDI and completed GPU colors during handoff");
            CloseHandle(watcher);
            CloseHandle(handoff.started);
        }
        demand(displayed(window, 100, 70, RGB(255,0,0)) && displayed(window, 30, 30, RGB(0,0,255)), "full DWM pixel colors");
        auto second = makeTexture(160, 100, blue, green);
        demand(take() && SUCCEEDED(q.present(second.Get(), &rect, 1)), "dirty Present1");
        demand(displayed(window, 30, 30, RGB(0,255,0)) && displayed(window, 100, 70, RGB(255,0,0)), "dirty Present1 kept outside pixels");
        for (int i = 0; i < 24; i++) demand(take() && SUCCEEDED(q.present(second.Get(), &rect, 1)), "one-slot paced burst");
        SetWindowPos(window, nullptr, 0, 0, 180, 140, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        demand(SUCCEEDED(q.resize(180,140)) && q.needsWholeFrame(), "resize resets retained pixels");
        auto third = makeTexture(180, 140, blue, red);
        demand(take() && SUCCEEDED(q.present(third.Get(), &rect, 1)), "first post-resize whole presentation");
        demand(displayed(window, 150, 120, RGB(0,0,255)) && displayed(window, 30, 30, RGB(255,0,0)), "resize DWM pixel colors");
        std::printf("DWM whole/dirty/resize colors verified, 27 frames, %d thread-pool slot wakes\n", wakes);
        if (composition) {
            q.hide();
            demand(displayed(window, 100, 70, cpuColor), "detaching GPU visual revealed the GDI surface");
            std::puts("GDI pixels verified before GPU commit and after rollback");
        }
        queue = nullptr;
    }
    DestroyWindow(window);
    UnregisterClassW(cls.lpszClassName, cls.hInstance);
    return 0;
}
#endif
