#ifndef RUNE_WIN_CPU_DIB_H
#define RUNE_WIN_CPU_DIB_H

#ifdef _WIN32
#include <stdint.h>
#include <windows.h>

// Zero-initialize and use on the window's owner thread, including WM_PAINT.
typedef struct {
    HDC dc;
    HBITMAP bitmap;
    HGDIOBJ previous;
    uint32_t *pixels;
    int32_t capacity_width, capacity_height;
    int32_t width, height;
    BOOL retry_full;
} RuneWinDib;

// pixels is the entire retained, top-down BGRA8 frame. Rectangles are left, top,
// right, bottom with exclusive ends. First frame and size changes always copy all.
// Returns 1 for a successful present or an unchanged frame.
int32_t rune_win_dib_present(RuneWinDib *dib, HWND window, const uint8_t *pixels,
                             int32_t width, int32_t height, int32_t stride_bytes,
                             const int32_t *rects, int32_t count, int32_t full);
// Replays the displayed frame into a paint DC. A null exposed rectangle replays all.
int32_t rune_win_dib_paint(RuneWinDib *dib, HDC destination, const RECT *exposed);
void rune_win_dib_dispose(RuneWinDib *dib);
#endif

#endif
