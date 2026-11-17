#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <stdlib.h>
#include "RuneMenus.h"
#include "WindowRedraw.h"

struct RuneWinMenu {
    HWND hwnd;
    HMENU bar;
    void *owner;
    RuneWinMenuSelect select;
    uint64_t revision;
    int tracking;
};
struct RuneWinMenuDraft { HMENU bar, section; };

static LRESULT CALLBACK menu_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp, UINT_PTR id, DWORD_PTR userdata) {
    RuneWinMenu *m = (RuneWinMenu *)userdata;
    switch (msg) {
    case WM_ENTERMENULOOP:
        ++m->tracking;
        break;
    case WM_EXITMENULOOP:
        if (m->tracking) --m->tracking;
        // A menu revision received while the native menu was open may now be installed.
        rune_request_window_paint(hwnd, FALSE);
        break;
    case WM_MENUCOMMAND: {
        for (int i = 0; i < GetMenuItemCount(m->bar); ++i) {
            HMENU section = GetSubMenu(m->bar, i);
            if (!section || section != (HMENU)lp) continue;
            MENUITEMINFOW item = {.cbSize = sizeof(item), .fMask = MIIM_ID | MIIM_STATE | MIIM_FTYPE};
            if (GetMenuItemInfoW(section, (UINT)wp, TRUE, &item) && item.wID &&
                !(item.fType & MFT_SEPARATOR) && !(item.fState & (MFS_DISABLED | MFS_GRAYED))) {
                m->select(m->owner, item.wID, m->revision);
            }
            return 0;
        }
        break;
    }
    case WM_NCDESTROY:
        RemoveWindowSubclass(hwnd, menu_proc, id);
        m->hwnd = NULL;
        m->bar = NULL; // DestroyWindow releases its attached menu.
        break;
    }
    return DefSubclassProc(hwnd, msg, wp, lp);
}

RuneWinMenu *rune_win_menu_open(void *hwnd, void *owner, RuneWinMenuSelect select) {
    if (!hwnd || !select) return NULL;
    RuneWinMenu *m = calloc(1, sizeof(*m));
    if (!m) return NULL;
    m->hwnd = (HWND)hwnd;
    m->owner = owner;
    m->select = select;
    if (!SetWindowSubclass(m->hwnd, menu_proc, (UINT_PTR)m, (DWORD_PTR)m)) {
        free(m);
        return NULL;
    }
    return m;
}

int rune_win_menu_tracking(RuneWinMenu *m) { return m && m->tracking; }

RuneWinMenuDraft *rune_win_menu_begin(void) {
    RuneWinMenuDraft *draft = calloc(1, sizeof(*draft));
    if (draft && !(draft->bar = CreateMenu())) { free(draft); return NULL; }
    return draft;
}

int rune_win_menu_section(RuneWinMenuDraft *draft, const uint16_t *title) {
    HMENU section = CreatePopupMenu();
    MENUINFO info = {.cbSize = sizeof(info), .fMask = MIM_STYLE, .dwStyle = MNS_NOTIFYBYPOS};
    if (!section) return 0;
    if (!SetMenuInfo(section, &info) ||
        !AppendMenuW(draft->bar, MF_POPUP, (UINT_PTR)section, (const wchar_t *)title)) {
        DestroyMenu(section);
        return 0;
    }
    draft->section = section;
    return 1;
}

int rune_win_menu_item(RuneWinMenuDraft *draft, uint32_t command, const uint16_t *label, int enabled, int checked) {
    if (!command) return AppendMenuW(draft->section, MF_SEPARATOR, 0, NULL);
    UINT flags = MF_STRING | (enabled ? MF_ENABLED : MF_GRAYED) | (checked ? MF_CHECKED : MF_UNCHECKED);
    return AppendMenuW(draft->section, flags, command, (const wchar_t *)label);
}

int rune_win_menu_install(RuneWinMenu *m, RuneWinMenuDraft *draft, uint64_t revision) {
    if (!m || !m->hwnd || m->tracking) return 0;
    RECT before, after, outer;
    BOOL sized = GetClientRect(m->hwnd, &before) && GetWindowRect(m->hwnd, &outer) &&
                 !IsZoomed(m->hwnd) && !IsIconic(m->hwnd);
    HMENU previous = m->bar;
    HMENU next = draft ? draft->bar : NULL;
    if (!SetMenu(m->hwnd, next)) return 0;
    m->bar = next;
    m->revision = revision;
    if (draft) draft->bar = NULL;
    if (previous) DestroyMenu(previous);
    DrawMenuBar(m->hwnd);
    // Keep the requested client area when adding/removing rows of menu chrome.
    if (sized && GetClientRect(m->hwnd, &after) && before.bottom != after.bottom) {
        SetWindowPos(m->hwnd, NULL, 0, 0, outer.right - outer.left,
                     outer.bottom - outer.top + before.bottom - after.bottom,
                     SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    }
    return 1;
}

void rune_win_menu_dispose(RuneWinMenuDraft *draft) {
    if (draft) {
        if (draft->bar) DestroyMenu(draft->bar);
        free(draft);
    }
}

void rune_win_menu_close(RuneWinMenu *m) {
    if (!m) return;
    if (m->hwnd) {
        RemoveWindowSubclass(m->hwnd, menu_proc, (UINT_PTR)m);
        if (m->bar && SetMenu(m->hwnd, NULL)) DestroyMenu(m->bar);
    }
    free(m);
}
#endif
