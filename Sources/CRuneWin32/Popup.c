#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include <windows.h>
#include <commctrl.h>
#include <math.h>
#include <stdlib.h>
#include <wchar.h>
#include "RuneWinPopup.h"
#include "RuneWinOverlay.h"
#include "WindowKeyboard.h"

typedef struct Popup {
    HWND hwnd;
    HMENU menu;
    UINT_PTR token, retry_timer;
    double x, y, width, height;
    int rect_anchor, rtl, inside_menu;
    uint32_t positioned, shortcut_pick;
    void *context;
    RuneWinPopupKey key;
    RuneWinPopupDone done;
    struct Popup *next;
} Popup;

enum { popup_message = WM_APP + 0x104, popup_subclass = 1 };
// User32 tracks one menu at a time on a UI thread, including when its nested
// event loop receives work for a second Rune window.
static _Thread_local Popup *tracking;
static _Thread_local Popup *waiting;
static _Thread_local UINT_PTR next_token;

typedef struct DestroyingOwner {
    HWND hwnd;
    struct DestroyingOwner *previous;
} DestroyingOwner;
static _Thread_local DestroyingOwner *destroying;

static LRESULT CALLBACK popup_proc(HWND, UINT, WPARAM, LPARAM, UINT_PTR, DWORD_PTR);

RuneWinPopupMenu *rune_win_popup_create(void) {
    return (RuneWinPopupMenu *)CreatePopupMenu();
}

static BOOL append_label(HMENU parent, UINT flags, UINT_PTR value, const uint16_t *label) {
    if (!parent || !label) return FALSE;
    const WCHAR *text = (const WCHAR *)label;
    if (!wcschr(text, L'&')) return AppendMenuW(parent, flags, value, text);
    size_t length = wcslen(text);
    if (length > (SIZE_MAX / sizeof(WCHAR) - 1) / 2) return FALSE;
    WCHAR *escaped = malloc((2 * length + 1) * sizeof(*escaped));
    if (!escaped) return FALSE;
    WCHAR *out = escaped;
    for (; *text; ++text) {
        if (*text == L'&') *out++ = L'&';
        *out++ = *text;
    }
    *out = 0;
    BOOL ok = AppendMenuW(parent, flags, value, escaped);
    free(escaped);
    return ok;
}

RuneWinPopupMenu *rune_win_popup_submenu(RuneWinPopupMenu *parent, const uint16_t *title, int enabled) {
    HMENU child = CreatePopupMenu();
    if (!child) return NULL;
    if (!append_label((HMENU)parent, MF_POPUP | (enabled ? MF_ENABLED : MF_GRAYED), (UINT_PTR)child, title)) {
        DestroyMenu(child);
        return NULL;
    }
    return (RuneWinPopupMenu *)child;
}

int rune_win_popup_item(RuneWinPopupMenu *parent, uint32_t command, const uint16_t *label, int enabled, int checked) {
    if (!command) return AppendMenuW((HMENU)parent, MF_SEPARATOR, 0, NULL);
    UINT flags = MF_STRING | (enabled ? MF_ENABLED : MF_GRAYED) | (checked ? MF_CHECKED : MF_UNCHECKED);
    return append_label((HMENU)parent, flags, command, label);
}

void rune_win_popup_dispose(RuneWinPopupMenu *root) {
    if (root) DestroyMenu((HMENU)root);
}

static LONG pixels(double dip, UINT dpi) {
    double value = round(dip * dpi / USER_DEFAULT_SCREEN_DPI);
    if (value >= INT32_MAX) return INT32_MAX;
    if (value <= INT32_MIN) return INT32_MIN;
    return (LONG)value;
}

static void remove_waiter(Popup *s) {
    for (Popup **it = &waiting; *it; it = &(*it)->next) {
        if (*it == s) {
            *it = s->next;
            s->next = NULL;
            return;
        }
    }
}

static void release_popup(Popup *s) {
    DestroyMenu(s->menu);
    free(s);
}

static void finish(Popup *s, uint32_t command) {
    RuneWinPopupDone done = s->done;
    if (!done) return;
    void *context = s->context;
    s->key = NULL;
    s->done = NULL;
    s->context = NULL;
    remove_waiter(s);
    if (s->retry_timer) KillTimer(s->hwnd, s->retry_timer);
    RemoveWindowSubclass(s->hwnd, popup_proc, popup_subclass);
    // Cancellation can run inside TrackPopupMenuEx. Its call frame keeps the
    // HMENU alive until User32 returns, while Swift can release its callback now.
    if (s->inside_menu) EndMenu();
    if (tracking != s) release_popup(s);
    done(context, command);
}

static LRESULT CALLBACK menu_filter(int code, WPARAM wp, LPARAM lp) {
    Popup *s = tracking;
    if (code == MSGF_MENU && s && s->key) {
        const MSG *msg = (const MSG *)lp;
        if (msg->message == WM_KEYDOWN || msg->message == WM_SYSKEYDOWN) {
            uint32_t mods = modifiers();
            UINT vk = (UINT)msg->wParam;
            UINT scan = ((UINT_PTR)msg->lParam >> 16) & 0xff;
            uint32_t scalar = shortcut_character(vk, scan, GetKeyboardLayout(0));
            uint32_t command = s->key(s->context, vk, mods, scalar);
            if (command && s->done && EndMenu()) {
                s->shortcut_pick = command;
                return 1;
            }
        }
    }
    return CallNextHookEx(NULL, code, wp, lp);
}

static LONG selected_offset(Popup *s, UINT dpi) {
    if (!s->positioned) return -1;
    int row = GetSystemMetricsForDpi(SM_CYMENU, dpi);
    LONG offset = GetSystemMetricsForDpi(SM_CYEDGE, dpi);
    int count = GetMenuItemCount(s->menu);
    for (int i = 0; i < count; ++i) {
        MENUITEMINFOW info = {.cbSize = sizeof(info), .fMask = MIIM_ID | MIIM_FTYPE | MIIM_SUBMENU};
        if (!GetMenuItemInfoW(s->menu, (UINT)i, TRUE, &info)) return -1;
        if (!info.hSubMenu && info.wID == s->positioned) return offset;
        offset += (info.fType & MFT_SEPARATOR) ? (row + 1) / 2 : row;
    }
    return -1;
}

// Whether the menu's owner gives the foreground back to previous once the menu closes:
// an overlay, whatever its KeyPolicy, that took the foreground only for the menu and still
// has it. One that had the foreground before (an OnDemand overlay the user clicked) keeps it.
static int hands_back(int is_overlay, HWND previous, HWND owner, HWND foreground) {
    return is_overlay && previous != NULL && previous != owner && foreground == owner;
}

static uint32_t track(Popup *s) {
    HWND hwnd = s->hwnd;
    if (!IsWindowVisible(hwnd) || IsIconic(hwnd) || !IsWindowEnabled(hwnd)) return 0;
    // Rune can request a context menu from the secondary-button press, before
    // the matching release relinquishes the window's native pointer capture.
    if (GetCapture() == hwnd) ReleaseCapture();
    if (!s->done) return 0;
    UINT dpi = GetDpiForWindow(hwnd);
    if (!dpi) return 0;
    POINT left = {pixels(s->x, dpi), pixels(s->y, dpi)};
    POINT right = {pixels(s->x + s->width, dpi), pixels(s->y + s->height, dpi)};
    if (!ClientToScreen(hwnd, &left) || !ClientToScreen(hwnd, &right)) return 0;
    TPMPARAMS params = {.cbSize = sizeof(params)};
    params.rcExclude = (RECT){min(left.x, right.x), min(left.y, right.y),
                              max(left.x, right.x), max(left.y, right.y)};
    int rtl = s->rtl < 0 ? !!(GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_LAYOUTRTL) : !!s->rtl;
    LONG x = s->rect_anchor ? (rtl ? params.rcExclude.right : params.rcExclude.left) : left.x;
    LONG y = left.y;
    LONG selected = selected_offset(s, dpi);
    if (selected >= 0) y = (LONG)max((int64_t)y - selected, INT32_MIN);
    else if (s->rect_anchor) y = right.y;
    // A menu closes on a click elsewhere, and gets the keyboard, only while its owner is
    // the foreground window. An overlay takes the foreground for its menu, and hands it back
    // after (`hands_back`, #1240).
    HWND previous = GetForegroundWindow();
    if (previous != hwnd) SetForegroundWindow(hwnd);
    UINT flags = TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON | TPM_VERTICAL | TPM_WORKAREA |
                 (rtl ? TPM_RIGHTALIGN | TPM_LAYOUTRTL : TPM_LEFTALIGN);
    HHOOK hook = s->key ? SetWindowsHookExW(WH_MSGFILTER, menu_filter, NULL, GetCurrentThreadId()) : NULL;
    s->inside_menu = 1;
    uint32_t command = (uint32_t)TrackPopupMenuEx(s->menu, flags, x, y, hwnd,
                                                  s->rect_anchor && selected < 0 ? &params : NULL);
    s->inside_menu = 0;
    if (hook) UnhookWindowsHookEx(hook);
    if (IsWindow(hwnd)) {
        // The menu's loop lets go of the foreground state once the owner gets a message.
        PostMessageW(hwnd, WM_NULL, 0, 0);
        if (hands_back(rune_win_is_overlay_hwnd(hwnd), previous, hwnd, GetForegroundWindow())) {
            SetForegroundWindow(previous);
        }
    }
    return s->shortcut_pick ? s->shortcut_pick : command;
}

static void show(Popup *s) {
    if (tracking) {
        if (tracking != s) {
            Popup **it = &waiting;
            while (*it && *it != s) it = &(*it)->next;
            *it = s;
        }
        return;
    }

    // External menus can suppress WM_EXITMENULOOP with TPM_NONOTIFY. Recheck
    // on a timer only while that external loop owns the thread's menu input.
    GUITHREADINFO info = {.cbSize = sizeof(info)};
    DWORD menu_flags = GUI_INMENUMODE | GUI_POPUPMENUMODE | GUI_SYSTEMMENUMODE;
    if (GetGUIThreadInfo(GetCurrentThreadId(), &info) && (info.flags & menu_flags)) {
        s->retry_timer = SetTimer(s->hwnd, (UINT_PTR)s, 80, NULL);
        if (!s->retry_timer) finish(s, 0);
        return;
    }

    tracking = s;
    DPI_AWARENESS_CONTEXT previous = SetThreadDpiAwarenessContext(GetWindowDpiAwarenessContext(s->hwnd));
    uint32_t command = track(s);
    if (previous) SetThreadDpiAwarenessContext(previous);
    tracking = NULL;
    if (s->done) finish(s, command);
    else release_popup(s);

    while (waiting) {
        Popup *next = waiting;
        waiting = next->next;
        next->next = NULL;
        if (!PostMessageW(next->hwnd, popup_message, next->token, 0)) finish(next, 0);
    }
}

static LRESULT CALLBACK popup_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp, UINT_PTR id, DWORD_PTR data) {
    (void)id;
    Popup *s = (Popup *)data;
    if (msg == WM_TIMER && s->retry_timer && wp == s->retry_timer) {
        KillTimer(hwnd, s->retry_timer);
        s->retry_timer = 0;
        show(s);
        return 0;
    }
    if (msg == popup_message) {
        if (wp == s->token) show(s);
        return 0;
    }
    if (msg == WM_NCDESTROY) {
        // The completion may immediately submit another popup while IsWindow
        // still succeeds. A window being destroyed can never service that post.
        DestroyingOwner owner = {hwnd, destroying};
        destroying = &owner;
        finish(s, 0);
        LRESULT result = DefSubclassProc(hwnd, msg, wp, lp);
        destroying = owner.previous;
        return result;
    }
    if (msg == WM_CLOSE || (msg == WM_SHOWWINDOW && !wp)) finish(s, 0);
    return DefSubclassProc(hwnd, msg, wp, lp);
}

int rune_win_popup_show(void *window, RuneWinPopupMenu *root, double x, double y, double width, double height,
                        int rect_anchor, int rtl, uint32_t positioned, void *context,
                        RuneWinPopupKey key, RuneWinPopupDone done) {
    HWND hwnd = (HWND)window;
    DWORD_PTR existing;
    for (DestroyingOwner *owner = destroying; owner; owner = owner->previous) {
        if (owner->hwnd == hwnd) return 0;
    }
    if (!hwnd || !root || !done || !isfinite(x) || !isfinite(y) || !isfinite(width) || !isfinite(height) ||
        GetMenuItemCount((HMENU)root) <= 0 || GetWindowThreadProcessId(hwnd, NULL) != GetCurrentThreadId() ||
        GetWindowSubclass(hwnd, popup_proc, popup_subclass, &existing)) return 0;
    Popup *s = calloc(1, sizeof(*s));
    if (!s) return 0;
    *s = (Popup){.hwnd = hwnd, .menu = (HMENU)root, .token = ++next_token, .x = x, .y = y,
                 .width = width, .height = height, .rect_anchor = rect_anchor, .rtl = rtl,
                 .positioned = positioned, .context = context, .key = key, .done = done};
    if (SetWindowSubclass(hwnd, popup_proc, popup_subclass, (DWORD_PTR)s)) {
        if (PostMessageW(hwnd, popup_message, s->token, 0)) return 1;
        RemoveWindowSubclass(hwnd, popup_proc, popup_subclass);
    }
    free(s);
    return 0;
}

void rune_win_popup_cancel(void *window) {
    DWORD_PTR data;
    HWND hwnd = (HWND)window;
    if (hwnd && GetWindowThreadProcessId(hwnd, NULL) == GetCurrentThreadId() &&
        GetWindowSubclass(hwnd, popup_proc, popup_subclass, &data))
        finish((Popup *)data, 0);
}
#endif
