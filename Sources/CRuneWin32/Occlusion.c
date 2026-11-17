#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dwmapi.h>
#include <wchar.h>
#include "CRuneWin32.h"
#include "WindowLifecycle.h"

typedef struct {
    HWND target;
    HRGN remaining;
    BOOL covered;
    BOOL has_screen;
} OcclusionWalk;

static BOOL combine_rect(HRGN region, const RECT *rect, int operation) {
    HRGN part = CreateRectRgnIndirect(rect);
    if (!part) return FALSE;
    int shape = CombineRgn(region, region, part, operation);
    DeleteObject(part);
    return shape != ERROR;
}

static BOOL CALLBACK add_monitor(HMONITOR monitor, HDC dc, LPRECT rect, LPARAM data) {
    (void)monitor;
    (void)dc;
    OcclusionWalk *walk = (OcclusionWalk *)data;
    if (!combine_rect(walk->remaining, rect, RGN_OR)) return FALSE;
    walk->has_screen = TRUE;
    return TRUE;
}

static BOOL frame_bounds(HWND window, RECT *bounds) {
    return SUCCEEDED(DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS, bounds, sizeof(*bounds)));
}

static DWORD cloak_reason(HWND window) {
    DWORD reason = 0;
    return SUCCEEDED(DwmGetWindowAttribute(window, DWMWA_CLOAKED, &reason, sizeof(reason))) ? reason : 0;
}

static BOOL opaque_bounds(HWND window, RECT *bounds) {
    if (!IsWindowVisible(window) || IsIconic(window)) return FALSE;
    LONG extended = GetWindowLongW(window, GWL_EXSTYLE);
    if (extended & WS_EX_TRANSPARENT) return FALSE;
    if ((extended & WS_EX_TOOLWINDOW) || (GetWindowLongW(window, GWL_STYLE) & WS_POPUP)) {
        WCHAR name[32];
        if (!GetClassNameW(window, name, ARRAYSIZE(name)) || wcscmp(name, L"Shell_TrayWnd") != 0) return FALSE;
    }
    if (extended & WS_EX_LAYERED) {
        COLORREF key;
        BYTE alpha;
        DWORD flags;
        if (!GetLayeredWindowAttributes(window, &key, &alpha, &flags) ||
            (flags & LWA_COLORKEY) || ((flags & LWA_ALPHA) && alpha < 255)) return FALSE;
    }
    HRGN region = CreateRectRgn(0, 0, 0, 0);
    if (!region) return FALSE;
    int shape = GetWindowRgn(window, region);
    DeleteObject(region);
    if (shape == COMPLEXREGION || cloak_reason(window) || !frame_bounds(window, bounds) || IsRectEmpty(bounds)) return FALSE;
    WINDOWPLACEMENT placement = {.length = sizeof(placement)};
    if (GetWindowPlacement(window, &placement) && placement.showCmd == SW_MAXIMIZE) {
        MONITORINFO monitor = {.cbSize = sizeof(monitor)};
        if (GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor))
            IntersectRect(bounds, bounds, &monitor.rcWork);
    }
    return TRUE;
}

static BOOL CALLBACK subtract_window(HWND window, LPARAM data) {
    OcclusionWalk *walk = (OcclusionWalk *)data;
    RECT bounds;
    if (window == walk->target) {
        walk->covered = frame_bounds(window, &bounds) && !RectInRegion(walk->remaining, &bounds);
        return FALSE;
    }
    return !opaque_bounds(window, &bounds) || combine_rect(walk->remaining, &bounds, RGN_DIFF);
}

static BOOL desktop_name(HDESK desktop, WCHAR (*name)[256]) {
    DWORD needed = 0;
    return desktop && GetUserObjectInformationW(desktop, UOI_NAME, *name, sizeof(*name), &needed);
}

int32_t rune_win_is_covered(RuneWinWindow *window) {
    HWND hwnd = window ? rune_win_hwnd(window) : NULL;
    if (!hwnd) return 0;
    WCHAR thread_name[256], input_name[256];
    if (!desktop_name(GetThreadDesktop(GetCurrentThreadId()), &thread_name)) return 0;
    HDESK input = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
    BOOL same = desktop_name(input, &input_name) && wcscmp(thread_name, input_name) == 0;
    if (input) CloseDesktop(input);
    // A capture desktop remains drawable. A locked interactive desktop is covered.
    if (!same) return wcscmp(thread_name, L"Default") == 0;
    return rune_win_covered_on_input_desktop(hwnd);
}

BOOL rune_win_covered_on_input_desktop(HWND hwnd) {
    if (!IsWindowVisible(hwnd)) return 0;
    if (IsIconic(hwnd) || (cloak_reason(hwnd) & DWM_CLOAKED_SHELL)) return 1;

    OcclusionWalk walk = {.target = hwnd, .remaining = CreateRectRgn(0, 0, 0, 0)};
    if (!walk.remaining) return 0;
    if (EnumDisplayMonitors(NULL, NULL, add_monitor, (LPARAM)&walk) && walk.has_screen)
        EnumWindows(subtract_window, (LPARAM)&walk);
    DeleteObject(walk.remaining);
    return walk.covered;
}

static INIT_ONCE memory_once = INIT_ONCE_STATIC_INIT;
static HANDLE low_memory;

static BOOL CALLBACK init_low_memory(PINIT_ONCE once, PVOID parameter, PVOID *context) {
    (void)once;
    (void)parameter;
    (void)context;
    low_memory = CreateMemoryResourceNotification(LowMemoryResourceNotification);
    return TRUE;
}

int32_t rune_win_low_memory(void) {
    InitOnceExecuteOnce(&memory_once, init_low_memory, NULL, NULL);
    BOOL low = FALSE;
    return low_memory && QueryMemoryResourceNotification(low_memory, &low) && low;
}
#endif
