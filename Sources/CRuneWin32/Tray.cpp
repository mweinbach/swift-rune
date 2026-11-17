#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <shellapi.h>
#include <algorithm>
#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include "RuneWinShellItems.h"

namespace {
constexpr UINT trayEvent = WM_APP + 1, trayUpdate = WM_APP + 2, trayClose = WM_APP + 3;
constexpr UINT iconID = 1;
const wchar_t trayClass[] = L"RuneSwift.Tray";
std::mutex liveLock;
std::vector<HWND> liveWindows;
struct Item { bool action, enabled; std::wstring id, label; };
const wchar_t *wide(const uint16_t *s) { return reinterpret_cast<const wchar_t *>(s); }

HICON makeIcon(const uint8_t *rgba, uint32_t w, uint32_t h) {
    if (!rgba) return CopyIcon(LoadIconW(nullptr, MAKEINTRESOURCEW(32512)));
    if (!w || !h || w > 4096 || h > 4096) return nullptr;
    BITMAPINFO info = {};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = static_cast<LONG>(w);
    info.bmiHeader.biHeight = -static_cast<LONG>(h);
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    void *bits = nullptr;
    HBITMAP color = CreateDIBSection(nullptr, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
    if (!color) return nullptr;
    size_t stride = ((w + 15) / 16) * 2;
    std::vector<uint8_t> andMask(stride * h, 0);
    auto *dst = static_cast<uint8_t *>(bits);
    for (uint32_t y = 0; y < h; ++y) {
        for (uint32_t x = 0; x < w; ++x, dst += 4, rgba += 4) {
            const uint32_t a = rgba[3];
            dst[0] = uint8_t((rgba[2] * a + 127) / 255);
            dst[1] = uint8_t((rgba[1] * a + 127) / 255);
            dst[2] = uint8_t((rgba[0] * a + 127) / 255);
            dst[3] = uint8_t(a);
            if (!a) andMask[y * stride + x / 8] |= uint8_t(0x80 >> (x % 8));
        }
    }
    HBITMAP mask = CreateBitmap(w, h, 1, 1, andMask.data());
    ICONINFO ii = {};
    ii.fIcon = TRUE;
    ii.hbmMask = mask;
    ii.hbmColor = color;
    HICON icon = mask ? CreateIconIndirect(&ii) : nullptr;
    DeleteObject(color);
    if (mask) DeleteObject(mask);
    return icon;
}

NOTIFYICONDATAW iconData(HWND hwnd) {
    NOTIFYICONDATAW data = {};
    data.cbSize = sizeof(data);
    data.hWnd = hwnd;
    data.uID = iconID;
    return data;
}
}

struct TrayImage {
    explicit TrayImage(HICON value) : handle(value) {}
    const HICON handle;
    ~TrayImage() { DestroyIcon(handle); }
};

struct RuneWinTraySpec {
    std::wstring tooltip;
    std::vector<Item> menu;
    std::shared_ptr<TrayImage> icon;
};

struct RuneWinTray {
    std::atomic<int> refs{2};  // Application handle and worker; close is allowed in an event callback.
    std::atomic<bool> closing{false};
    std::mutex lock;
    std::shared_ptr<RuneWinTraySpec> model;
    HWND window = nullptr;
    HANDLE ready = nullptr, worker = nullptr;
    DWORD thread = 0, error = ERROR_SUCCESS;
    UINT taskbarCreated = 0;
    void *context;
    RuneWinTrayEvent event;
    RuneWinTrayRelease release;

    void drop() { if (--refs == 0) delete this; }
    ~RuneWinTray() {
        if (worker) CloseHandle(worker);
        if (ready) CloseHandle(ready);
        release(context);
    }
    std::shared_ptr<RuneWinTraySpec> snapshot() {
        std::lock_guard<std::mutex> guard(lock);
        return model;
    }
    BOOL notify(HWND hwnd, DWORD command) {
        auto current = snapshot();
        auto data = iconData(hwnd);
        data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
        data.hIcon = current->icon->handle;
        data.uCallbackMessage = trayEvent;
        size_t count = std::min(current->tooltip.size(), sizeof(data.szTip) / sizeof(wchar_t) - 1);
        if (count && IS_HIGH_SURROGATE(current->tooltip[count - 1])) --count;
        current->tooltip.copy(data.szTip, count);
        return Shell_NotifyIconW(command, &data);
    }

    void pick(HWND hwnd) {
        auto current = snapshot();  // IDs belong to the menu that was actually opened.
        HMENU menu = CreatePopupMenu();
        if (!menu) return;
        for (size_t i = 0; i < current->menu.size(); ++i) {
            const auto &item = current->menu[i];
            if (item.action)
                AppendMenuW(menu, MF_STRING | (item.enabled ? MF_ENABLED : MF_GRAYED), i + 1, item.label.c_str());
            else AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
        }
        POINT cursor = {};
        GetCursorPos(&cursor);
        DWORD layout = 0;
        GetProcessDefaultLayout(&layout);
        SetForegroundWindow(hwnd);
        UINT flags = TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON;
        if (layout & LAYOUT_RTL) flags |= TPM_LAYOUTRTL | TPM_RIGHTALIGN;
        UINT picked = TrackPopupMenu(menu, flags, cursor.x, cursor.y, 0, hwnd, nullptr);
        DestroyMenu(menu);
        PostMessageW(hwnd, WM_NULL, 0, 0);
        if (picked && picked <= current->menu.size() && !closing) {
            const Item &item = current->menu[picked - 1];
            if (item.action && item.enabled) event(context, reinterpret_cast<const uint16_t *>(item.id.c_str()));
        }
    }
};

namespace {
LRESULT CALLBACK trayProc(HWND hwnd, UINT message, WPARAM w, LPARAM l) {
    if (message == WM_NCCREATE) {
        auto *create = reinterpret_cast<CREATESTRUCTW *>(l);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    }
    auto *tray = reinterpret_cast<RuneWinTray *>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (!tray) return DefWindowProcW(hwnd, message, w, l);
    if (message == trayEvent && w == iconID && !tray->closing) {
        if (l == WM_LBUTTONUP) tray->event(tray->context, nullptr);
        if (l == WM_RBUTTONUP) tray->pick(hwnd);
        return 0;
    }
    if (message == trayUpdate || (tray->taskbarCreated && message == tray->taskbarCreated)) {
        if (!tray->closing) tray->notify(hwnd, message == trayUpdate ? NIM_MODIFY : NIM_ADD);
        return 0;
    }
    if (message == trayClose) {
        EndMenu();  // Can arrive in the popup's nested message loop.
        DestroyWindow(hwnd);
        return 0;
    }
    if (message == WM_DESTROY) {
        auto data = iconData(hwnd);
        Shell_NotifyIconW(NIM_DELETE, &data);
        PostQuitMessage(0);
        return 0;
    }
    if (message == WM_NCDESTROY) {
        {
            std::lock_guard<std::mutex> guard(tray->lock);
            tray->window = nullptr;
        }
        {
            std::lock_guard<std::mutex> guard(liveLock);
            liveWindows.erase(std::remove(liveWindows.begin(), liveWindows.end(), hwnd), liveWindows.end());
        }
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
    }
    return DefWindowProcW(hwnd, message, w, l);
}

DWORD WINAPI trayThread(void *arg) {
    auto *tray = static_cast<RuneWinTray *>(arg);
    HINSTANCE instance = GetModuleHandleW(nullptr);
    WNDCLASSW cls = {};
    cls.lpfnWndProc = trayProc;
    cls.hInstance = instance;
    cls.lpszClassName = trayClass;
    HWND hwnd = nullptr;
    if (!RegisterClassW(&cls) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) tray->error = GetLastError();
    else {
        tray->taskbarCreated = RegisterWindowMessageW(L"TaskbarCreated");
        // A hidden top-level window receives Explorer's TaskbarCreated broadcasts.
        hwnd = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, trayClass, nullptr, WS_POPUP,
                               0, 0, 0, 0, nullptr, nullptr, instance, tray);
        if (!hwnd) tray->error = GetLastError();
        else if (!tray->notify(hwnd, NIM_ADD)) {
            tray->error = GetLastError();
            if (!tray->error) tray->error = ERROR_NOT_READY;
            DestroyWindow(hwnd);
            hwnd = nullptr;
        }
    }
    if (hwnd) {
        tray->window = hwnd;
        std::lock_guard<std::mutex> guard(liveLock);
        liveWindows.push_back(hwnd);
    }
    SetEvent(tray->ready);
    if (hwnd) {
        MSG msg;
        while (GetMessageW(&msg, nullptr, 0, 0) > 0) { TranslateMessage(&msg); DispatchMessageW(&msg); }
        if (IsWindow(hwnd)) DestroyWindow(hwnd);
    }
    tray->drop();
    return 0;
}
}

RuneWinTraySpec *rune_win_tray_spec(const uint16_t *tip, const uint8_t *rgba, uint32_t w, uint32_t h) {
    HICON icon = makeIcon(rgba, w, h);
    if (!icon) return nullptr;
    auto *result = rune_win_tray_spec_keeping_icon(tip);
    result->icon = std::make_shared<TrayImage>(icon);
    return result;
}

RuneWinTraySpec *rune_win_tray_spec_keeping_icon(const uint16_t *tip) {
    auto *result = new RuneWinTraySpec;
    result->tooltip = wide(tip);
    return result;
}

void rune_win_tray_item(RuneWinTraySpec *spec, const uint16_t *id, const uint16_t *label, int enabled) {
    spec->menu.push_back({id != nullptr, enabled != 0, id ? wide(id) : L"", label ? wide(label) : L""});
}

RuneWinTray *rune_win_tray_open(RuneWinTraySpec *spec, void *context, RuneWinTrayEvent event,
                                RuneWinTrayRelease release, uint32_t *error) {
    if (!spec || !spec->icon) {
        *error = ERROR_INVALID_PARAMETER;
        delete spec;
        release(context);
        return nullptr;
    }
    auto *tray = new RuneWinTray;
    tray->model.reset(spec);
    tray->context = context;
    tray->release = release;
    tray->event = event;
    tray->ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (tray->ready) tray->worker = CreateThread(nullptr, 0, trayThread, tray, 0, &tray->thread);
    if (!tray->worker) {
        *error = GetLastError();
        delete tray;
        return nullptr;
    }
    WaitForSingleObject(tray->ready, INFINITE);
    *error = tray->error;
    if (*error) { WaitForSingleObject(tray->worker, INFINITE); tray->drop(); return nullptr; }
    return tray;
}

void rune_win_tray_update(RuneWinTray *tray, RuneWinTraySpec *spec) {
    std::lock_guard<std::mutex> guard(tray->lock);
    if (!spec->icon) spec->icon = tray->model->icon;
    tray->model.reset(spec);
    if (tray->window) PostMessageW(tray->window, trayUpdate, 0, 0);
}

void rune_win_tray_close(RuneWinTray *tray) {
    tray->closing = true;
    {
        std::lock_guard<std::mutex> guard(tray->lock);
        if (tray->window) PostMessageW(tray->window, trayClose, 0, 0);
    }
    if (GetCurrentThreadId() != tray->thread) WaitForSingleObject(tray->worker, INFINITE);
    tray->drop();
}

void rune_win_trays_remove_all() {
    std::lock_guard<std::mutex> guard(liveLock);
    for (HWND hwnd : liveWindows) {
        auto data = iconData(hwnd);
        Shell_NotifyIconW(NIM_DELETE, &data);
    }
}
#endif
