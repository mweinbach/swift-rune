#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dwmapi.h>
#include <wchar.h>
#include "CRuneWin32.h"
#include "WindowLifecycle.h"

typedef struct {
    HWND target;
    RECT target_bounds;
    HRGN remaining;
    HRGN scratch;
    BOOL covered;
    BOOL has_screen;
    BOOL has_visible_part;
} OcclusionWalk;

static BOOL CALLBACK add_monitor(HMONITOR monitor, HDC dc, LPRECT rect, LPARAM data) {
    (void)monitor;
    (void)dc;
    OcclusionWalk *walk = (OcclusionWalk *)data;
    RECT clipped;
    if (IntersectRect(&clipped, rect, &walk->target_bounds)) {
        if (!SetRectRgn(walk->scratch, clipped.left, clipped.top, clipped.right, clipped.bottom)) return FALSE;
        if (CombineRgn(walk->remaining, walk->remaining, walk->scratch, RGN_OR) == ERROR) return FALSE;
        walk->has_visible_part = TRUE;
    }
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

static BOOL opaque_bounds(HWND window, const RECT *target_bounds, HRGN scratch, RECT *bounds) {
    if (!IsWindowVisible(window) || IsIconic(window)) return FALSE;
    RECT raw, overlap;
    if (!GetWindowRect(window, &raw) || !IntersectRect(&overlap, &raw, target_bounds)) return FALSE;
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
    int shape = GetWindowRgn(window, scratch);
    if (shape == COMPLEXREGION || cloak_reason(window) || !frame_bounds(window, bounds) || IsRectEmpty(bounds)) return FALSE;
    WINDOWPLACEMENT placement = {.length = sizeof(placement)};
    if (GetWindowPlacement(window, &placement) && placement.showCmd == SW_MAXIMIZE) {
        MONITORINFO monitor = {.cbSize = sizeof(monitor)};
        if (GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor))
            IntersectRect(bounds, bounds, &monitor.rcWork);
    }
    return IntersectRect(&overlap, bounds, target_bounds);
}

static BOOL CALLBACK subtract_window(HWND window, LPARAM data) {
    OcclusionWalk *walk = (OcclusionWalk *)data;
    if (window == walk->target) {
        walk->covered = !RectInRegion(walk->remaining, &walk->target_bounds);
        return FALSE;
    }
    RECT bounds;
    if (!opaque_bounds(window, &walk->target_bounds, walk->scratch, &bounds)) return TRUE;
    if (!SetRectRgn(walk->scratch, bounds.left, bounds.top, bounds.right, bounds.bottom)) return FALSE;
    int shape = CombineRgn(walk->remaining, walk->remaining, walk->scratch, RGN_DIFF);
    if (shape == ERROR) return FALSE;
    if (shape == NULLREGION) {
        walk->covered = TRUE;
        return FALSE;
    }
    return TRUE;
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
    RECT target_bounds;
    if (!frame_bounds(hwnd, &target_bounds)) return 0;

    OcclusionWalk walk = {
        .target = hwnd,
        .target_bounds = target_bounds,
        .remaining = CreateRectRgn(0, 0, 0, 0),
        .scratch = CreateRectRgn(0, 0, 0, 0),
    };
    if (!walk.remaining || !walk.scratch) {
        if (walk.remaining) DeleteObject(walk.remaining);
        if (walk.scratch) DeleteObject(walk.scratch);
        return 0;
    }
    if (EnumDisplayMonitors(NULL, NULL, add_monitor, (LPARAM)&walk) && walk.has_screen) {
        if (!walk.has_visible_part) walk.covered = TRUE;
        else EnumWindows(subtract_window, (LPARAM)&walk);
    }
    DeleteObject(walk.remaining);
    DeleteObject(walk.scratch);
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
