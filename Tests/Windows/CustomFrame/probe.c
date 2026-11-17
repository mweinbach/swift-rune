/* Windows 11 fixture. Only creates windows on a private, never-switched desktop. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include "CRuneWin32.h"

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "line %d: %s (Win32 %lu)\n", __LINE__, #condition, GetLastError()); return 1; \
} } while (0)

static int32_t receive(void *context, const RuneWinEvent *event) {
    if (event->kind == RUNE_WIN_CLOSE) ++*(int *)context;
    return event->kind == RUNE_WIN_FRAME ? -1 : 1;
}

static int hit(HWND hwnd, LONG x, LONG y) {
    POINT pt = {x, y};
    ClientToScreen(hwnd, &pt);
    return (int)SendMessageW(hwnd, WM_NCHITTEST, 0, MAKELPARAM(pt.x, pt.y));
}

static UINT take_command(HWND hwnd, BOOL act) {
    MSG msg;
    if (!PeekMessageW(&msg, hwnd, WM_SYSCOMMAND, WM_SYSCOMMAND, PM_REMOVE)) return 0;
    if (act) DispatchMessageW(&msg);
    return (UINT)(msg.wParam & 0xfff0);
}

static void press(HWND hwnd, int hit_code, LONG x, LONG y) {
    POINT screen = {x, y};
    ClientToScreen(hwnd, &screen);
    SendMessageW(hwnd, WM_NCLBUTTONDOWN, hit_code, MAKELPARAM(screen.x, screen.y));
}

static DWORD WINAPI run_probe(void *desktop) {
    CHECK(SetThreadDesktop((HDESK)desktop));
    SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    char error[256] = {0};
    RuneWinWindow *window = rune_win_create((const uint16_t *)L"Rune caption fixture", 480, 330, 220, 140, 0,
                                            error, sizeof(error));
    if (!window) fprintf(stderr, "%s\n", error);
    CHECK(window);
    RuneWinOptions opts = {.max_width = 900, .max_height = 700, .resizable = 1, .minimizable = 1, .closable = 1};
    rune_win_configure(window, opts);
    HWND hwnd = rune_win_hwnd(window);
    RECT before, client, outer;
    CHECK(GetClientRect(hwnd, &before));
    RuneWinCaption sample = {0};
    CHECK(rune_win_caption(window, 44, FALSE, &sample));
    CHECK(!sample.hidden && sample.minimizable && sample.maximizable && !sample.maximized);
    CHECK(GetClientRect(hwnd, &client) && EqualRect(&before, &client));
    int closes = 0;
    rune_win_start(window, &closes, receive, 1, 1);
    UINT dpi = GetDpiForWindow(hwnd);
    int bw = MulDiv(46, dpi, 96), y = MulDiv(24, dpi, 96);
    int cx = client.right, mid = cx - bw - bw / 2;
    CHECK(hit(hwnd, 0, 0) == HTTOPLEFT && hit(hwnd, cx - 1, 0) == HTTOPRIGHT && hit(hwnd, cx / 2, 0) == HTTOP);
    CHECK(hit(hwnd, 30, y) == HTCLIENT);
    CHECK(hit(hwnd, cx - 2*bw - 1, y) == HTMINBUTTON);
    CHECK(hit(hwnd, cx - 2*bw, y) == HTMAXBUTTON && hit(hwnd, cx - bw - 1, y) == HTMAXBUTTON);
    CHECK(hit(hwnd, cx - bw, y) == HTCLOSE);
    CHECK(hit(hwnd, mid, MulDiv(44, dpi, 96)) == HTCLIENT);
    SendMessageW(hwnd, WM_NCMOUSEMOVE, HTMAXBUTTON, 0);
    CHECK(rune_win_caption(window, 44, FALSE, &sample) && sample.button == 2 && !sample.pressed);
    press(hwnd, HTMAXBUTTON, mid, y);
    CHECK(GetCapture() == hwnd);
    SendMessageW(hwnd, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(30, y));
    CHECK(rune_win_caption(window, 44, FALSE, &sample) && sample.pressed && !sample.over);
    SendMessageW(hwnd, WM_LBUTTONUP, 0, MAKELPARAM(30, y));
    CHECK(!take_command(hwnd, FALSE) && GetCapture() != hwnd);
    press(hwnd, HTMAXBUTTON, mid, y);
    SendMessageW(hwnd, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(30, y));
    SendMessageW(hwnd, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(mid, y));
    CHECK(rune_win_caption(window, 44, FALSE, &sample) && sample.pressed && sample.over);
    SendMessageW(hwnd, WM_LBUTTONUP, 0, MAKELPARAM(mid, y));
    CHECK(take_command(hwnd, TRUE) == SC_MAXIMIZE && IsZoomed(hwnd));
    CHECK(rune_win_caption(window, 44, FALSE, &sample) && sample.maximized);
    rune_win_toggle_fullscreen(window);
    CHECK(rune_win_caption(window, 44, FALSE, &sample) && sample.hidden);
    rune_win_toggle_fullscreen(window);
    CHECK(rune_win_caption(window, 44, FALSE, &sample) && !sample.hidden && sample.maximized);
    CHECK(GetClientRect(hwnd, &client));
    CHECK(hit(hwnd, client.right - bw - 1, 0) == HTMAXBUTTON);
    POINT top = {0};
    ClientToScreen(hwnd, &top);
    MONITORINFO monitor = {.cbSize = sizeof(monitor)};
    CHECK(GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor));
    CHECK(top.y >= monitor.rcWork.top && top.y <= monitor.rcWork.top + 1);
    press(hwnd, HTMAXBUTTON, client.right - bw - 1, y);
    SendMessageW(hwnd, WM_NCLBUTTONUP, HTMAXBUTTON, 0);
    CHECK(take_command(hwnd, TRUE) == SC_RESTORE && !IsZoomed(hwnd));
    CHECK(GetClientRect(hwnd, &client) && EqualRect(&before, &client));
    CHECK(rune_win_caption(window, 36, TRUE, &sample));
    CHECK(hit(hwnd, 0, y) == HTCLOSE && hit(hwnd, bw, y) == HTMAXBUTTON && hit(hwnd, 2*bw, y) == HTMINBUTTON);
    CHECK(hit(hwnd, bw, MulDiv(36, dpi, 96)) == HTCLIENT);
    press(hwnd, HTMINBUTTON, 2*bw, y);
    SendMessageW(hwnd, WM_CANCELMODE, 0, 0);
    CHECK(rune_win_caption(window, 36, TRUE, &sample) && !sample.button && !sample.pressed);
    press(hwnd, HTMINBUTTON, 2*bw, y);
    SendMessageW(hwnd, WM_LBUTTONUP, 0, MAKELPARAM(2*bw, y));
    CHECK(take_command(hwnd, TRUE) == SC_MINIMIZE && IsIconic(hwnd));
    ShowWindow(hwnd, SW_RESTORE);
    rune_win_place(window, 0, 0, 0, 1, 390, 220);
    CHECK(GetClientRect(hwnd, &client) && client.right == MulDiv(390, dpi, 96) && client.bottom == MulDiv(220, dpi, 96));
    CHECK(GetWindowRect(hwnd, &outer));
    int dw = outer.right - outer.left - client.right, dh = outer.bottom - outer.top - client.bottom;
    MINMAXINFO mm = {0};
    SendMessageW(hwnd, WM_GETMINMAXINFO, 0, (LPARAM)&mm);
    CHECK(mm.ptMinTrackSize.x == MulDiv(220, dpi, 96) + dw && mm.ptMinTrackSize.y == MulDiv(140, dpi, 96) + dh);
    CHECK(mm.ptMaxTrackSize.x == MulDiv(900, dpi, 96) + dw && mm.ptMaxTrackSize.y == MulDiv(700, dpi, 96) + dh);
    SIZE scaled;
    CHECK(SendMessageW(hwnd, WM_GETDPISCALEDSIZE, dpi, (LPARAM)&scaled));
    CHECK(scaled.cx == client.right + dw && scaled.cy == client.bottom + dh);
    CHECK(SendMessageW(hwnd, WM_GETDPISCALEDSIZE, 144, (LPARAM)&scaled));
    RECT edges = {0};
    CHECK(AdjustWindowRectExForDpi(&edges, GetWindowLongW(hwnd, GWL_STYLE), FALSE,
                                   GetWindowLongW(hwnd, GWL_EXSTYLE), 144));
    CHECK(scaled.cx == MulDiv(client.right, 144, dpi) + edges.right - edges.left);
    CHECK(scaled.cy == MulDiv(client.bottom, 144, dpi) + edges.bottom);
    CHECK(rune_win_caption_menu(window, 1, 0, 0) && take_command(hwnd, FALSE) == SC_KEYMENU);
    opts.resizable = 0;
    rune_win_configure(window, opts);
    CHECK(rune_win_caption(window, 36, TRUE, &sample) && !sample.maximizable && sample.minimizable);
    CHECK(hit(hwnd, bw, y) == HTCLIENT && hit(hwnd, 2*bw, y) == HTMINBUTTON && hit(hwnd, bw, 0) == HTCLIENT);
    opts.minimizable = 0;
    rune_win_configure(window, opts);
    CHECK(hit(hwnd, bw, y) == HTCLIENT && hit(hwnd, 2*bw, y) == HTCLIENT && hit(hwnd, 0, y) == HTCLOSE);
    opts.fullscreen = 1;
    rune_win_configure(window, opts);
    CHECK(rune_win_caption(window, 36, TRUE, &sample) && sample.hidden && hit(hwnd, 1, y) == HTCLIENT);
    rune_win_toggle_fullscreen(window);
    CHECK(rune_win_caption(window, 36, TRUE, &sample) && !sample.hidden);
    CHECK(GetClientRect(hwnd, &client) && client.right == MulDiv(390, dpi, 96) && client.bottom == MulDiv(220, dpi, 96));
    press(hwnd, HTCLOSE, 1, y);
    SendMessageW(hwnd, WM_LBUTTONUP, 0, MAKELPARAM(1, y));
    CHECK(take_command(hwnd, TRUE) == SC_CLOSE && closes == 1 && rune_win_running(window) == 0);
    rune_win_destroy(window);
    printf("PASS DPI %u client preservation, top corners, HTMAXBUTTON Snap target, capture cancel/reenter, maximize/restore/minimize/close, work area, DPI size, min/max track, RTL, fullscreen and disabled controls\n", dpi);
    return 0;
}

int main(void) {
    WCHAR name[80];
    swprintf_s(name, ARRAYSIZE(name), L"RuneCustomFrameProbe-%lu", GetCurrentProcessId());
    HDESK desktop = CreateDesktopW(name, NULL, NULL, 0, GENERIC_ALL, NULL);
    CHECK(desktop);
    HANDLE runner = CreateThread(NULL, 0, run_probe, desktop, 0, NULL);
    CHECK(runner && WaitForSingleObject(runner, 30000) == WAIT_OBJECT_0);
    DWORD result = 1;
    CHECK(GetExitCodeThread(runner, &result));
    CloseHandle(runner);
    CHECK(CloseDesktop(desktop));
    return result;
}
