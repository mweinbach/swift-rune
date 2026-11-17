#ifndef RUNE_WINDOW_REDRAW_H
#define RUNE_WINDOW_REDRAW_H
#include <windows.h>

enum { rune_request_paint = WM_APP + 0x7b7 };
#define RUNE_REDRAW_PROPERTY L"Rune.Swift.RedrawTurns"

// A menu or UIA provider may also be installed on an HWND managed by the embedder.
static inline BOOL rune_request_window_paint(HWND hwnd, BOOL asynchronous) {
    if (!hwnd) return FALSE;
    if (GetPropW(hwnd, RUNE_REDRAW_PROPERTY)) {
        if (!asynchronous) return (BOOL)SendMessageW(hwnd, rune_request_paint, 0, 0);
        // Providers may hold their tree lock on an RPC thread.
        if (PostMessageW(hwnd, rune_request_paint, 0, 0)) return TRUE;
    }
    return InvalidateRect(hwnd, NULL, FALSE);
}
#endif
