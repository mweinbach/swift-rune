// Out-of-process UIA check. Only Win32 window APIs run while waiting for the host to settle.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <ole2.h>
#include <uiautomation.h>
#include <wrl/client.h>
#include <cstdio>
#include <cwchar>

using Microsoft::WRL::ComPtr;

struct Target {
    DWORD pid;
    HWND window = nullptr;
    int y = 0, height = 0;
};

static BOOL CALLBACK findReady(HWND window, LPARAM opaque) {
    auto &target = *reinterpret_cast<Target *>(opaque);
    DWORD pid = 0;
    GetWindowThreadProcessId(window, &pid);
    wchar_t name[64]{}, caption[96]{};
    if (pid != target.pid || !GetClassNameW(window, name, 64) ||
        std::wcscmp(name, L"RuneSwiftOpenGLWindow") || !GetWindowTextW(window, caption, 96)) return TRUE;
    if (swscanf_s(caption, L"Rune accessibility ready %d %d", &target.y, &target.height) != 2) return TRUE;
    target.window = window;
    return FALSE;
}

static int inspect(Target target) {
    const auto deadline = GetTickCount64() + 60000;
    while (!target.window && GetTickCount64() < deadline) {
        EnumWindows(findReady, reinterpret_cast<LPARAM>(&target));
        if (!target.window) Sleep(20);
    }
    if (!target.window || target.height <= 0) return 2;
    // Exercise a non-client request between the passive commits and the first requested root.
    DWORD_PTR ignored{};
    if (!SendMessageTimeoutW(target.window, WM_GETOBJECT, 0, static_cast<LPARAM>(OBJID_TITLEBAR),
                             SMTO_ABORTIFHUNG, 5000, &ignored)) return 3;
    POINT origin{};
    if (!ClientToScreen(target.window, &origin)) return 4;

    ComPtr<IUIAutomation> uia;
    if (FAILED(CoCreateInstance(CLSID_CUIAutomation8, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&uia)))) return 5;
    ComPtr<IUIAutomationElement> root, row;
    HRESULT hr = uia->ElementFromHandle(target.window, &root);
    if (FAILED(hr) || !root) return 6;
    VARIANT identity{};
    identity.vt = VT_BSTR;
    identity.bstrVal = SysAllocString(L"demand-target");
    ComPtr<IUIAutomationCondition> wanted;
    hr = uia->CreatePropertyCondition(UIA_AutomationIdPropertyId, identity, &wanted);
    VariantClear(&identity);
    if (FAILED(hr)) return 7;
    // This lookup is deliberately never retried, so a placeholder tree fails the test.
    hr = root->FindFirst(TreeScope_Descendants, wanted.Get(), &row);
    if (FAILED(hr) || !row) return 8;
    BSTR name = nullptr;
    hr = row->get_CurrentName(&name);
    const bool renamed = SUCCEEDED(hr) && name && std::wcscmp(name, L"Demand revision 6") == 0;
    SysFreeString(name);
    if (!renamed) return 9;
    RECT bounds{};
    if (FAILED(row->get_CurrentBoundingRectangle(&bounds))) return 10;
    const int relativeY = bounds.top - origin.y;
    const int height = bounds.bottom - bounds.top;
    std::printf("FindFirst calls=1 revision=6 expected_client_y=%d actual_client_y=%d "
                "expected_height=%d actual_height=%d\n", target.y, relativeY, target.height, height);
    return relativeY == target.y && height == target.height ? 0 : 11;
}

int wmain(int argc, wchar_t **argv) {
    if (argc != 2) { std::fprintf(stderr, "Usage: DemandClient.exe RuneDemandFixturePID\n"); return 1; }
    wchar_t *end = nullptr;
    const unsigned long pid = std::wcstoul(argv[1], &end, 10);
    if (!pid || *end) return 1;
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) return 1;
    const int result = inspect(Target{pid});
    CoUninitialize();
    if (result) std::fprintf(stderr, "Demand client failed at step %d\n", result);
    return result;
}
