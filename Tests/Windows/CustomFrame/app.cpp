// From the Windows build directory, run beside rune-custom-titlebar.exe and its resources.
// Exercise the Swift example's normal window, accessibility provider and GPU-painted caption.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <ole2.h>
#include <uiautomation.h>
#include <wrl/client.h>
#include <cstdio>
using Microsoft::WRL::ComPtr;

struct Target { DWORD pid; HWND hwnd; };

static BOOL CALLBACK find_window(HWND hwnd, LPARAM arg) {
    Target *target = reinterpret_cast<Target *>(arg);
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    wchar_t title[64] = {};
    if (pid != target->pid || !IsWindowVisible(hwnd) || !GetWindowTextW(hwnd, title, 64) ||
        wcscmp(title, L"Custom titlebar") != 0) return TRUE;
    target->hwnd = hwnd;
    return FALSE;
}

static ComPtr<IUIAutomationElement> caption_button(IUIAutomation *uia, IUIAutomationElement *root, const wchar_t *id) {
    VARIANT v{};
    v.vt = VT_BSTR; v.bstrVal = SysAllocString(id);
    ComPtr<IUIAutomationCondition> condition;
    HRESULT hr = uia->CreatePropertyCondition(UIA_AutomationIdPropertyId, v, &condition);
    VariantClear(&v);
    ComPtr<IUIAutomationElement> result;
    if (SUCCEEDED(hr)) root->FindFirst(TreeScope_Descendants, condition.Get(), &result);
    return result;
}

static bool named(IUIAutomationElement *button, const wchar_t *label) {
    BSTR name = nullptr;
    bool match = button && SUCCEEDED(button->get_CurrentName(&name)) && name && wcscmp(name, label) == 0;
    SysFreeString(name);
    return match;
}

static bool invoke(IUIAutomationElement *button) {
    ComPtr<IUIAutomationInvokePattern> pattern;
    return button && SUCCEEDED(button->GetCurrentPatternAs(UIA_InvokePatternId, IID_PPV_ARGS(&pattern))) &&
           pattern && SUCCEEDED(pattern->Invoke());
}

static bool exercise(HDESK desktop, PROCESS_INFORMATION proc) {
    Target target{proc.dwProcessId, nullptr};
    ULONGLONG deadline = GetTickCount64() + 20000;
    while (GetTickCount64() < deadline && WaitForSingleObject(proc.hProcess, 30) == WAIT_TIMEOUT) {
        EnumDesktopWindows(desktop, find_window, (LPARAM)&target);
        if (target.hwnd) break;
    }
    if (!target.hwnd) { std::fprintf(stderr, "No Swift window\n"); return false; }
    ComPtr<IUIAutomation> uia;
    if (FAILED(CoCreateInstance(CLSID_CUIAutomation, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&uia)))) return false;
    ComPtr<IUIAutomationElement> root;
    if (FAILED(uia->ElementFromHandle(target.hwnd, &root)) || !root) return false;
    ComPtr<IUIAutomationElement> maxi, mini, close;
    while (GetTickCount64() < deadline) {
        maxi = caption_button(uia.Get(), root.Get(), L"rune-caption-maximize");
        if (named(maxi.Get(), L"Maximize")) break;
        Sleep(70);
    }
    mini = caption_button(uia.Get(), root.Get(), L"rune-caption-minimize");
    close = caption_button(uia.Get(), root.Get(), L"rune-caption-close");
    if (!named(mini.Get(), L"Minimize") || !named(maxi.Get(), L"Maximize") || !named(close.Get(), L"Close")) {
        std::fprintf(stderr, "Missing caption UIA names\n"); return false;
    }
    RECT bounds;
    if (FAILED(maxi->get_CurrentBoundingRectangle(&bounds))) return false;
    POINT center{(bounds.left + bounds.right)/2, (bounds.top + bounds.bottom)/2};
    DWORD_PTR hit = 0;
    if (!SendMessageTimeoutW(target.hwnd, WM_NCHITTEST, 0, MAKELPARAM(center.x, center.y),
                             SMTO_ABORTIFHUNG, 2000, &hit) || (LRESULT)hit != HTMAXBUTTON) {
        std::fprintf(stderr, "Caption layout and HWND disagree: bounds %ld,%ld,%ld,%ld hit %lld\n",
                     bounds.left,bounds.top,bounds.right,bounds.bottom,(long long)hit); return false;
    }
    if (!invoke(maxi.Get())) return false;
    deadline = GetTickCount64() + 7000;
    while (GetTickCount64() < deadline) {
        maxi = caption_button(uia.Get(), root.Get(), L"rune-caption-maximize");
        if (IsZoomed(target.hwnd) && named(maxi.Get(), L"Restore")) break;
        Sleep(70);
    }
    if (!IsZoomed(target.hwnd) || !named(maxi.Get(), L"Restore")) {
        std::fprintf(stderr, "Missing native maximize and updated Swift restore label\n"); return false;
    }
    close = caption_button(uia.Get(), root.Get(), L"rune-caption-close");
    if (!invoke(close.Get()) || WaitForSingleObject(proc.hProcess, 6000) != WAIT_OBJECT_0) return false;
    DWORD exit_code = 1;
    GetExitCodeProcess(proc.hProcess, &exit_code);
    if (exit_code != 0) return false;
    std::printf("PASS Swift rune-custom-titlebar, three UIA controls, HTMAXBUTTON at Swift layout center, UIA maximize/restore label and clean close; bounds %ld,%ld,%ld,%ld\n",
                bounds.left,bounds.top,bounds.right,bounds.bottom);
    return true;
}

int main() {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    WCHAR name[80];
    swprintf_s(name, L"RuneCaptionSwift-%lu", GetCurrentProcessId());
    HDESK desktop = CreateDesktopW(name, nullptr, nullptr, 0, GENERIC_ALL, nullptr);
    if (!desktop || !SetThreadDesktop(desktop) || FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) return 1;
    STARTUPINFOW start{}; start.cb = sizeof(start); start.lpDesktop = name;
    PROCESS_INFORMATION proc{};
    wchar_t cmd[] = L"rune-custom-titlebar.exe";
    bool passed = false;
    if (CreateProcessW(nullptr, cmd, nullptr, nullptr, TRUE, 0, nullptr, nullptr, &start, &proc)) {
        passed = exercise(desktop, proc);
        if (WaitForSingleObject(proc.hProcess, 0) == WAIT_TIMEOUT) {
            TerminateProcess(proc.hProcess, 2); WaitForSingleObject(proc.hProcess, 3000);
        }
        CloseHandle(proc.hThread); CloseHandle(proc.hProcess);
    }
    CoUninitialize();
    CloseDesktop(desktop);
    return passed ? 0 : 1;
}
