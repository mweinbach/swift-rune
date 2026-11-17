// Test the real HMENU and callback routing without focusing a window or moving the pointer.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <cwchar>
static UINT choose = 0;
static bool menuMatches = false;
static BOOL WINAPI keepForeground(HWND) { return TRUE; }
static BOOL WINAPI pickForTest(HMENU menu, UINT flags, int, int, int, HWND, const RECT *) {
    wchar_t title[32] = {};
    GetMenuStringW(menu, 0, title, 32, MF_BYPOSITION);
    menuMatches = (flags & TPM_RETURNCMD) && GetMenuItemCount(menu) == 3 &&
                  !wcscmp(title, L"Open") && GetMenuItemID(menu, 0) == 1 &&
                  (GetMenuState(menu, 1, MF_BYPOSITION) & MF_SEPARATOR) &&
                  (GetMenuState(menu, 2, MF_BYPOSITION) & MF_GRAYED);
    return choose;
}
#define SetForegroundWindow keepForeground
#define TrackPopupMenu pickForTest
#include "../../../Sources/CRuneWin32/Tray.cpp"
#undef SetForegroundWindow
#undef TrackPopupMenu

bool testTrayMenu() {
    const auto u = [](const wchar_t *s) { return reinterpret_cast<const uint16_t *>(s); };
    RuneWinTray tray;
    tray.context = new std::wstring;
    tray.release = [](void *p) { delete static_cast<std::wstring *>(p); };
    tray.event = [](void *p, const uint16_t *item) { *static_cast<std::wstring *>(p) = wide(item); };
    tray.model.reset(rune_win_tray_spec(u(L"Menu test"), nullptr, 0, 0));
    if (!tray.model) return false;
    rune_win_tray_item(tray.model.get(), u(L"open-id"), u(L"Open"), 1);
    rune_win_tray_item(tray.model.get(), nullptr, nullptr, 0);
    rune_win_tray_item(tray.model.get(), u(L"disabled-id"), u(L"Disabled"), 0);
    auto &received = *static_cast<std::wstring *>(tray.context);
    for (UINT command : {0u, 2u, 3u, 4u, 1u}) {
        choose = command;
        tray.pick(nullptr);
        if (!menuMatches || received != (command == 1 ? L"open-id" : L"")) return false;
    }
    return true;
}
