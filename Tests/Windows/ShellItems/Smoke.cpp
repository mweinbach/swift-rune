// Build on Windows with Tray.cpp and JumpList.cpp; uses one process-private icon and a fresh AppUserModelID.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <wrl/client.h>
#include <cstdio>
#include <string>
#include <memory>
#include "RuneWinShellItems.h"

using Microsoft::WRL::ComPtr;

namespace {
const uint16_t *u(const wchar_t *s) { return reinterpret_cast<const uint16_t *>(s); }

struct Events {
    HANDLE activated = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    HANDLE released = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    ~Events() { CloseHandle(activated); CloseHandle(released); }
};

BOOL CALLBACK findTray(HWND window, LPARAM value) {
    DWORD process;
    GetWindowThreadProcessId(window, &process);
    wchar_t name[128] = {};
    if (process == GetCurrentProcessId() && GetClassNameW(window, name, 128) && wcscmp(name, L"RuneSwift.Tray") == 0) {
        *reinterpret_cast<HWND *>(value) = window;
        return FALSE;
    }
    return TRUE;
}

bool iconPresent(HWND hwnd) {
    NOTIFYICONDATAW icon = {};
    icon.cbSize = sizeof(icon);
    icon.hWnd = hwnd;
    icon.uID = 1;
    return Shell_NotifyIconW(NIM_MODIFY, &icon) != FALSE;
}

bool tray() {
    Events events;
    const uint8_t pixels[] = { 255, 0, 0, 96, 0, 255, 0, 255, 0, 0, 255, 128, 42, 42, 42, 0 };
    auto *spec = rune_win_tray_spec(u(L"Rune shell test"), pixels, 2, 2);
    if (!spec) return false;
    rune_win_tray_item(spec, u(L"alpha"), u(L"Enabled"), 1);
    rune_win_tray_item(spec, nullptr, nullptr, 0);
    rune_win_tray_item(spec, u(L"beta"), u(L"Disabled"), 0);
    uint32_t error = 0;
    auto *handle = rune_win_tray_open(spec, &events, [](void *c, const uint16_t *id) {
        if (!id) SetEvent(static_cast<Events *>(c)->activated);
    }, [](void *c) { SetEvent(static_cast<Events *>(c)->released); }, &error);
    if (!handle) { std::printf("NIM_ADD failed %lu\n", static_cast<unsigned long>(error)); return false; }
    HWND hwnd = nullptr;
    EnumWindows(findTray, reinterpret_cast<LPARAM>(&hwnd));
    bool added = hwnd && iconPresent(hwnd);
    if (added) PostMessageW(hwnd, WM_APP + 1, 1, WM_LBUTTONUP);
    bool activated = added && WaitForSingleObject(events.activated, 3000) == WAIT_OBJECT_0;
    auto *updated = rune_win_tray_spec_keeping_icon(u(L"Updated Rune shell test"));
    if (updated) { rune_win_tray_item(updated, u(L"updated"), u(L"New action"), 1); rune_win_tray_update(handle, updated); }
    // Posting another activation after the update also drains the worker's FIFO.
    if (hwnd) PostMessageW(hwnd, WM_APP + 1, 1, WM_LBUTTONUP);
    bool modified = updated && activated && WaitForSingleObject(events.activated, 3000) == WAIT_OBJECT_0 && iconPresent(hwnd);
    rune_win_trays_remove_all();
    bool fastRemoved = hwnd && !iconPresent(hwnd);
    if (hwnd) SendMessageW(hwnd, RegisterWindowMessageW(L"TaskbarCreated"), 0, 0);
    bool restored = hwnd && iconPresent(hwnd);
    rune_win_tray_close(handle);
    bool removed = WaitForSingleObject(events.released, 3000) == WAIT_OBJECT_0 && !IsWindow(hwnd) && !iconPresent(hwnd);
    std::printf("tray added=%d activate=%d updated=%d fastRemoved=%d explorerRestored=%d closed=%d\n",
                added, activated, modified, fastRemoved, restored, removed);
    return added && activated && modified && fastRemoved && restored && removed;
}

HRESULT jump() {
    GUID guid;
    HRESULT hr = CoCreateGuid(&guid);
    wchar_t text[40] = {};
    if (FAILED(hr) || !StringFromGUID2(guid, text, 40)) return E_FAIL;
    const std::wstring id = std::wstring(L"Rune.ShellTest.") + text;
    hr = SetCurrentProcessExplicitAppUserModelID(id.c_str());
    if (FAILED(hr)) return hr;
    ComPtr<ICustomDestinationList> list;
    hr = CoCreateInstance(CLSID_DestinationList, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&list));
    if (FAILED(hr)) return hr;
    RuneWinJumpDraft *raw = nullptr;
    hr = rune_win_jump_begin(&raw, u(L"--profile=C:\\Rune Test\\"));
    if (SUCCEEDED(hr)) {
        std::unique_ptr<RuneWinJumpDraft, decltype(&rune_win_jump_dispose)> draft(raw, rune_win_jump_dispose);
        hr = rune_win_jump_item(raw, u(L"Temporary test task"), u(L"rune://a path/\"item\""), u(L"Task description"));
        if (SUCCEEDED(hr)) hr = rune_win_jump_category(raw, u(L"Recent test items"));
        if (SUCCEEDED(hr)) hr = rune_win_jump_item(raw, u(L"Test project"), u(L"rune://project"), u(L""));
        if (SUCCEEDED(hr)) hr = rune_win_jump_commit(raw);
    }
    const HRESULT cleanup = list->DeleteList(id.c_str());
    std::printf("jump uniqueID=%ls commit=0x%08lx deleted=0x%08lx\n", id.c_str(), hr, cleanup);
    return FAILED(hr) ? hr : cleanup;
}
}

int main() {
    const bool shellTray = tray();
    const HRESULT com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(com)) return 2;
    const HRESULT jumpList = jump();
    CoUninitialize();
    return shellTray && SUCCEEDED(jumpList) ? 0 : 1;
}
