#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "CRuneWin32.h"

typedef HRESULT (WINAPI *MonitorDpi)(HMONITOR, int, UINT *, UINT *);
typedef struct {
    void *context;
    RuneWinDisplayVisitor visit;
    MonitorDpi monitor_dpi;
} DisplayState;

static BOOL CALLBACK display_info(HMONITOR monitor, HDC dc, LPRECT frame, LPARAM data) {
    (void)dc;
    (void)frame;
    DisplayState *state = (DisplayState *)data;
    MONITORINFOEXW info = {0};
    info.cbSize = sizeof(info);
    if (!GetMonitorInfoW(monitor, (MONITORINFO *)&info)) return TRUE;
    UINT xdpi = GetDpiForSystem(), ydpi = xdpi;
    if (state->monitor_dpi) state->monitor_dpi(monitor, 0, &xdpi, &ydpi);
    char name[CCHDEVICENAME * 4 + 1] = {0};
    WideCharToMultiByte(CP_UTF8, 0, info.szDevice, -1, name, sizeof name, NULL, NULL);
    const RECT r = info.rcMonitor;
    state->visit(state->context, (uint64_t)(uintptr_t)monitor, name, r.left, r.top,
                 (uint32_t)(r.right-r.left), (uint32_t)(r.bottom-r.top),
                 xdpi ? (double)xdpi / 96.0 : 1.0, (info.dwFlags & MONITORINFOF_PRIMARY) != 0);
    return TRUE;
}

int rune_win_displays(void *context, RuneWinDisplayVisitor visit) {
    DPI_AWARENESS_CONTEXT previous = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    HMODULE shcore = LoadLibraryExW(L"shcore.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    DisplayState state = {context, visit, shcore ? (MonitorDpi)GetProcAddress(shcore, "GetDpiForMonitor") : NULL};
    BOOL ok = EnumDisplayMonitors(NULL, NULL, display_info, (LPARAM)&state);
    if (shcore) FreeLibrary(shcore);
    if (previous) SetThreadDpiAwarenessContext(previous);
    return ok;
}
#endif
