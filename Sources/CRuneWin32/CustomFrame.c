#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <windowsx.h>
#include <commctrl.h>
#include <shellapi.h>
#include <math.h>
#include <stdlib.h>
#include "CRuneWin32.h"
#include "CustomFrame.h"
#include "WindowRedraw.h"

static const WCHAR property[] = L"Rune.Swift.CustomFrame";
static const UINT_PTR subclass_id = 0x52554e46;
enum { caption_menu_message = WM_APP + 0x7b6 };

typedef struct {
    float height;
    BOOL mirrored;
    int button;
    BOOL pressed, over;
} CustomFrame;

static INIT_ONCE version_once = INIT_ONCE_STATIC_INIT;
static BOOL needs_top_pixel;

static BOOL CALLBACK read_version(PINIT_ONCE once, void *argument, void **context) {
    (void)once; (void)argument; (void)context;
    typedef LONG (WINAPI *ReadVersion)(OSVERSIONINFOW *);
    ReadVersion read = (ReadVersion)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion");
    OSVERSIONINFOW version = {.dwOSVersionInfoSize = sizeof(version)};
    needs_top_pixel = read && read(&version) == 0 && version.dwMajorVersion == 10 && version.dwBuildNumber < 22000;
    return TRUE;
}

static int restored_top(void) {
    InitOnceExecuteOnce(&version_once, read_version, NULL, NULL);
    return needs_top_pixel ? 1 : 0;
}

static DWORD style(HWND hwnd) { return (DWORD)GetWindowLongPtrW(hwnd, GWL_STYLE); }
static BOOL framed(HWND hwnd) { return (style(hwnd) & WS_CAPTION) == WS_CAPTION; }
BOOL rune_custom_frame_installed(HWND hwnd) { return hwnd && GetPropW(hwnd, property) && framed(hwnd); }

static int standard_top(HWND hwnd, UINT dpi) {
    RECT bare = {0};
    AdjustWindowRectExForDpi(&bare, style(hwnd) & ~(WS_MINIMIZE | WS_MAXIMIZE), FALSE,
                             (DWORD)GetWindowLongPtrW(hwnd, GWL_EXSTYLE), dpi);
    return -bare.top;
}

void rune_custom_frame_adjust(HWND hwnd, RECT *rect, UINT dpi) {
    if (rune_custom_frame_installed(hwnd)) rect->top += standard_top(hwnd, dpi) - restored_top();
}

static int thickness(UINT dpi) {
    return GetSystemMetricsForDpi(SM_CYFRAME, dpi) + GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
}

static void fit_maximized(const RECT *outer, RECT *client, UINT dpi) {
    client->top += thickness(dpi);
    MONITORINFO monitor = {.cbSize = sizeof(monitor)};
    if (!GetMonitorInfoW(MonitorFromRect(outer, MONITOR_DEFAULTTONEAREST), &monitor)) return;
    for (UINT edge = ABE_LEFT; edge <= ABE_BOTTOM; ++edge) {
        APPBARDATA bar = {.cbSize = sizeof(bar), .uEdge = edge, .rc = monitor.rcMonitor};
        if (!IsWindow((HWND)SHAppBarMessage(ABM_GETAUTOHIDEBAREX, &bar))) continue;
        switch (edge) {
        case ABE_LEFT: ++client->left; break;
        case ABE_RIGHT: --client->right; break;
        case ABE_TOP: ++client->top; break;
        case ABE_BOTTOM: --client->bottom; break;
        }
    }
}

static int button_from_hit(WPARAM hit) {
    switch (hit) {
    case HTMINBUTTON: return 1;
    case HTMAXBUTTON: return 2;
    case HTCLOSE: return 3;
    default: return 0;
    }
}

static int caption_hit(const CustomFrame *frame, HWND hwnd, LONG x, LONG y) {
    DWORD flags = style(hwnd);
    UINT dpi = GetDpiForWindow(hwnd);
    RECT client;
    if (!GetClientRect(hwnd, &client) || x < 0 || x >= client.right || y < 0 ||
        y >= fmaxf(1, roundf(frame->height * dpi / 96))) return HTCLIENT;
    int width = max(1, MulDiv(46, dpi, 96));
    int slot = (frame->mirrored ? x : client.right - 1 - x) / width;
    if (slot == 0) return HTCLOSE;
    if (slot == 1 && (flags & WS_MAXIMIZEBOX)) return HTMAXBUTTON;
    if (slot == 2 && (flags & WS_MINIMIZEBOX)) return HTMINBUTTON;
    return HTCLIENT;
}

static void state(HWND hwnd, CustomFrame *frame, int button, BOOL pressed, BOOL over) {
    if (frame->button == button && frame->pressed == pressed && frame->over == over) return;
    frame->button = button;
    frame->pressed = pressed;
    frame->over = over;
    rune_request_window_paint(hwnd, FALSE);
}

static void release(HWND hwnd, CustomFrame *frame, BOOL over) {
    int button = frame->button;
    state(hwnd, frame, 0, FALSE, FALSE);
    if (GetCapture() == hwnd) ReleaseCapture();
    if (!over) return;
    WPARAM command = button == 3 ? SC_CLOSE :
                     button == 2 ? (IsZoomed(hwnd) ? SC_RESTORE : SC_MAXIMIZE) : SC_MINIMIZE;
    PostMessageW(hwnd, WM_SYSCOMMAND, command, 0);
}

static void show_menu(HWND hwnd, BOOL mirrored, POINT p) {
    HMENU menu = GetSystemMenu(hwnd, FALSE);
    if (!menu) return;
    DWORD flags = style(hwnd);
    BOOL zoomed = IsZoomed(hwnd);
    EnableMenuItem(menu, SC_RESTORE, MF_BYCOMMAND | (zoomed ? MF_ENABLED : MF_GRAYED));
    EnableMenuItem(menu, SC_MOVE, MF_BYCOMMAND | (!zoomed ? MF_ENABLED : MF_GRAYED));
    EnableMenuItem(menu, SC_SIZE, MF_BYCOMMAND | (!zoomed && (flags & WS_THICKFRAME) ? MF_ENABLED : MF_GRAYED));
    EnableMenuItem(menu, SC_MINIMIZE, MF_BYCOMMAND | ((flags & WS_MINIMIZEBOX) ? MF_ENABLED : MF_GRAYED));
    EnableMenuItem(menu, SC_MAXIMIZE, MF_BYCOMMAND | (!zoomed && (flags & WS_MAXIMIZEBOX) ? MF_ENABLED : MF_GRAYED));
    SetMenuDefaultItem(menu, SC_CLOSE, FALSE);
    UINT pick = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | (mirrored ? TPM_LAYOUTRTL | TPM_RIGHTALIGN : 0),
                               p.x, p.y, 0, hwnd, NULL);
    if (pick) PostMessageW(hwnd, WM_SYSCOMMAND, pick, 0);
}

static LRESULT CALLBACK frame_proc(HWND hwnd, UINT message, WPARAM w, LPARAM l, UINT_PTR id, DWORD_PTR data) {
    CustomFrame *frame = (CustomFrame *)data;
    if (message == WM_NCDESTROY) {
        RemoveWindowSubclass(hwnd, frame_proc, id);
        RemovePropW(hwnd, property);
        free(frame);
        return DefSubclassProc(hwnd, message, w, l);
    }
    if (!framed(hwnd)) return DefSubclassProc(hwnd, message, w, l);
    switch (message) {
    case WM_NCCALCSIZE: {
        if (!w) break;
        RECT *client = &((NCCALCSIZE_PARAMS *)l)->rgrc[0];
        RECT outer = *client;
        DefSubclassProc(hwnd, message, w, l);
        UINT dpi = GetDpiForWindow(hwnd);
        // Keep any attached HMENU's actual (possibly wrapped) height.
        LONG menu = GetMenu(hwnd) ? max(0, client->top - outer.top - standard_top(hwnd, dpi)) : 0;
        client->top = outer.top + menu + (IsZoomed(hwnd) ? 0 : restored_top());
        if (IsZoomed(hwnd)) fit_maximized(&outer, client, dpi);
        return 0;
    }
    case WM_NCHITTEST: {
        LRESULT hit = DefSubclassProc(hwnd, message, w, l);
        if (hit != HTCLIENT) return hit;
        POINT pt = {GET_X_LPARAM(l), GET_Y_LPARAM(l)};
        if (!ScreenToClient(hwnd, &pt)) return hit;
        int edge = thickness(GetDpiForWindow(hwnd));
        if (!IsZoomed(hwnd) && (style(hwnd) & WS_THICKFRAME) && pt.y >= 0 && pt.y < edge) {
            RECT client;
            GetClientRect(hwnd, &client);
            return pt.x < edge ? HTTOPLEFT : pt.x >= client.right - edge ? HTTOPRIGHT : HTTOP;
        }
        return caption_hit(frame, hwnd, pt.x, pt.y);
    }
    case WM_ERASEBKGND: return 1;
    case WM_NCMOUSEMOVE: {
        int button = button_from_hit(w);
        if (!frame->pressed) state(hwnd, frame, button, FALSE, button != 0);
        if (button) {
            TRACKMOUSEEVENT track = {sizeof(track), TME_NONCLIENT | TME_LEAVE, hwnd, 0};
            TrackMouseEvent(&track);
            return 0;
        }
        break;
    }
    case WM_NCMOUSELEAVE:
        if (!frame->pressed) state(hwnd, frame, 0, FALSE, FALSE);
        break;
    case WM_MOUSEMOVE:
        if (frame->pressed) {
            if (!(w & MK_LBUTTON)) release(hwnd, frame, FALSE);
            else state(hwnd, frame, frame->button, TRUE,
                       frame->button == button_from_hit(caption_hit(frame, hwnd, GET_X_LPARAM(l), GET_Y_LPARAM(l))));
            return 0;
        }
        if (frame->button) state(hwnd, frame, 0, FALSE, FALSE);
        break;
    case WM_NCLBUTTONDOWN: case WM_NCLBUTTONDBLCLK:
        if (button_from_hit(w)) {
            state(hwnd, frame, button_from_hit(w), TRUE, TRUE);
            SetCapture(hwnd);
            return 0;
        }
        break;
    case WM_LBUTTONUP: case WM_NCLBUTTONUP:
        if (frame->pressed) {
            int hit = message == WM_LBUTTONUP ? caption_hit(frame, hwnd, GET_X_LPARAM(l), GET_Y_LPARAM(l)) : (int)w;
            release(hwnd, frame, frame->button == button_from_hit(hit));
            return 0;
        }
        if (message == WM_NCLBUTTONUP && button_from_hit(w)) return 0;
        break;
    case WM_CAPTURECHANGED: case WM_CANCELMODE:
        if (frame->pressed) {
            state(hwnd, frame, 0, FALSE, FALSE);
            if (message == WM_CANCELMODE && GetCapture() == hwnd) ReleaseCapture();
        }
        break;
    case WM_NCRBUTTONDOWN: case WM_NCRBUTTONUP: case WM_NCRBUTTONDBLCLK:
        if (button_from_hit(w)) return 0;
        break;
    case WM_NCACTIVATE: return DefSubclassProc(hwnd, message, w, -1);
    case WM_GETDPISCALEDSIZE:
        if (!IsZoomed(hwnd) && l) {
            RECT client, edge = {0};
            UINT old_dpi = GetDpiForWindow(hwnd);
            if (!old_dpi || !GetClientRect(hwnd, &client)) break;
            AdjustWindowRectExForDpi(&edge, style(hwnd), GetMenu(hwnd) != NULL,
                                     (DWORD)GetWindowLongPtrW(hwnd, GWL_EXSTYLE), (UINT)w);
            rune_custom_frame_adjust(hwnd, &edge, (UINT)w);
            SIZE *size = (SIZE *)l;
            size->cx = MulDiv(client.right, (int)w, old_dpi) + edge.right - edge.left;
            size->cy = MulDiv(client.bottom, (int)w, old_dpi) + edge.bottom - edge.top;
            return TRUE;
        }
        break;
    case WM_SYSCOMMAND:
        if ((w & 0xfff0) == SC_KEYMENU && l == L' ' && frame->mirrored) {
            RECT client;
            GetClientRect(hwnd, &client);
            POINT p = {client.right, 0};
            if (ClientToScreen(hwnd, &p)) show_menu(hwnd, TRUE, p);
            return 0;
        }
        break;
    case caption_menu_message:
        show_menu(hwnd, frame->mirrored, (POINT){(LONG)(INT_PTR)w, (LONG)l});
        return 0;
    }
    return DefSubclassProc(hwnd, message, w, l);
}

int32_t rune_win_caption(RuneWinWindow *window, float height, int32_t mirrored, RuneWinCaption *out) {
    HWND hwnd = window ? (HWND)rune_win_hwnd(window) : NULL;
    if (!hwnd || !out) return 0;
    CustomFrame *frame = (CustomFrame *)GetPropW(hwnd, property);
    if (!frame) {
        frame = calloc(1, sizeof(*frame));
        if (!frame) return 0;
        if (!SetPropW(hwnd, property, frame) || !SetWindowSubclass(hwnd, frame_proc, subclass_id, (DWORD_PTR)frame)) {
            RemovePropW(hwnd, property);
            free(frame);
            return 0;
        }
        RECT before, after, outer;
        frame->height = height;
        frame->mirrored = mirrored != 0;
        if (framed(hwnd) && GetClientRect(hwnd, &before)) {
            UINT flags = SWP_NOMOVE | SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOOWNERZORDER;
            SetWindowPos(hwnd, NULL, 0, 0, 0, 0, flags | SWP_FRAMECHANGED | SWP_NOSIZE);
            if (!IsZoomed(hwnd) && GetClientRect(hwnd, &after) && before.bottom != after.bottom && GetWindowRect(hwnd, &outer))
                SetWindowPos(hwnd, NULL, 0, 0, outer.right - outer.left,
                             outer.bottom - outer.top + before.bottom - after.bottom, flags);
        }
    }
    frame->height = height;
    frame->mirrored = mirrored != 0;
    DWORD flags = style(hwnd);
    *out = (RuneWinCaption){frame->button, frame->pressed, frame->over, IsZoomed(hwnd) != 0,
                            (flags & WS_MINIMIZEBOX) != 0, (flags & WS_MAXIMIZEBOX) != 0, !framed(hwnd)};
    return 1;
}

int32_t rune_win_caption_menu(RuneWinWindow *window, int32_t keyboard, int32_t x, int32_t y) {
    HWND hwnd = window ? (HWND)rune_win_hwnd(window) : NULL;
    if (!hwnd || !(style(hwnd) & WS_SYSMENU)) return 0;
    if (keyboard) return PostMessageW(hwnd, WM_SYSCOMMAND, SC_KEYMENU, L' ');
    else if (rune_custom_frame_installed(hwnd)) {
        POINT p = {x, y};
        if (ClientToScreen(hwnd, &p)) return PostMessageW(hwnd, caption_menu_message, (WPARAM)(INT_PTR)p.x, (LPARAM)p.y);
    }
    return 0;
}
#endif
