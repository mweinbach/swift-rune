#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include "CpuDib.h"
#include <string.h>

void rune_win_dib_dispose(RuneWinDib *dib) {
    if (!dib) return;
    if (dib->previous && dib->previous != HGDI_ERROR) SelectObject(dib->dc, dib->previous);
    if (dib->dc) DeleteDC(dib->dc);
    if (dib->bitmap) DeleteObject(dib->bitmap);
    *dib = (RuneWinDib){0};
}

static BOOL allocate_dib(RuneWinDib *dib, HDC display, int32_t width, int32_t height) {
    if ((uint64_t)width * height > SIZE_MAX / sizeof(uint32_t)) return FALSE;
    BITMAPINFO info = {0};
    info.bmiHeader.biSize = sizeof(info.bmiHeader);
    info.bmiHeader.biWidth = width;
    info.bmiHeader.biHeight = -height;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    RuneWinDib next = {0};
    next.dc = CreateCompatibleDC(display);
    if (!next.dc) return FALSE;
    void *bits = NULL;
    next.bitmap = CreateDIBSection(next.dc, &info, DIB_RGB_COLORS, &bits, NULL, 0);
    if (next.bitmap && bits) next.previous = SelectObject(next.dc, next.bitmap);
    if (!next.previous || next.previous == HGDI_ERROR) {
        rune_win_dib_dispose(&next);
        return FALSE;
    }
    next.pixels = bits;
    next.capacity_width = width;
    next.capacity_height = height;
    rune_win_dib_dispose(dib);
    *dib = next;
    return TRUE;
}

static BOOL fit_dib(RuneWinDib *dib, HWND window, int32_t width, int32_t height) {
    if (width <= dib->capacity_width && height <= dib->capacity_height) return TRUE;
    int32_t capacity_width = max(width, dib->capacity_width);
    int32_t capacity_height = max(height, dib->capacity_height);
    MONITORINFO info = {.cbSize = sizeof(info)};
    if (GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &info)) {
        capacity_width = max(capacity_width, info.rcMonitor.right - info.rcMonitor.left);
        capacity_height = max(capacity_height, info.rcMonitor.bottom - info.rcMonitor.top);
    }
    // Reserve for ordinary resizes. A smaller allocation can still serve the current window.
    HDC display = GetDC(window);
    if (!display) return FALSE;
    BOOL allocated = allocate_dib(dib, display, capacity_width, capacity_height);
    if (!allocated && (capacity_width != width || capacity_height != height)) {
        allocated = allocate_dib(dib, display, width, height);
    }
    ReleaseDC(window, display);
    return allocated;
}

static void copy_rect(RuneWinDib *dib, const uint8_t *pixels, int32_t stride_bytes, RECT rect) {
    size_t bytes = (size_t)(rect.right - rect.left) * sizeof(*dib->pixels);
    for (LONG y = rect.top; y < rect.bottom; ++y) {
        uint32_t *row = dib->pixels + (size_t)y * dib->capacity_width;
        const uint8_t *source = pixels + (size_t)y * stride_bytes + (size_t)rect.left * sizeof(*dib->pixels);
        memcpy(row + rect.left, source, bytes);
    }
}

int32_t rune_win_dib_paint(RuneWinDib *dib, HDC destination, const RECT *exposed) {
    if (!dib || !dib->dc || !destination) return 0;
    RECT frame = {0, 0, dib->width, dib->height}, copy = frame;
    if (exposed && !IntersectRect(&copy, &frame, exposed)) return 1;
    BOOL copied = BitBlt(destination, copy.left, copy.top, copy.right - copy.left,
                         copy.bottom - copy.top, dib->dc, copy.left, copy.top, SRCCOPY);
    // GDI may batch the blit. Finish reading the section before the next direct
    // pixel write, and before the caller lifts the cloak on the first frame.
    BOOL finished = GdiFlush();
    return copied && finished;
}

int32_t rune_win_dib_present(RuneWinDib *dib, HWND window, const uint8_t *pixels,
                             int32_t width, int32_t height, int32_t stride_bytes,
                             const int32_t *rects, int32_t count, int32_t full) {
    if (!dib) return 0;
    if (!window || !pixels || width <= 0 || height <= 0 || stride_bytes / 4 < width ||
        (uint64_t)height * stride_bytes > SIZE_MAX || count < 0 ||
        (uint64_t)count > SIZE_MAX / (4 * sizeof(*rects)) || (count && !rects)) {
        dib->retry_full = TRUE;
        return 0;
    }
    if (!fit_dib(dib, window, width, height)) {
        dib->retry_full = TRUE;
        return 0;
    }
    RECT frame = {0, 0, width, height}, damage = {0};
    if (full || dib->retry_full || width != dib->width || height != dib->height) {
        damage = frame;
        copy_rect(dib, pixels, stride_bytes, frame);
    } else {
        for (int32_t i = 0; i < count; ++i) {
            const int32_t *r = rects + (size_t)i * 4;
            RECT requested = {r[0], r[1], r[2], r[3]}, clipped;
            if (IntersectRect(&clipped, &frame, &requested)) {
                copy_rect(dib, pixels, stride_bytes, clipped);
                UnionRect(&damage, &damage, &clipped);
            }
        }
    }
    dib->width = width;
    dib->height = height;
    if (IsRectEmpty(&damage)) return 1;
    // DWM can compose between successive blits. Publish the union in one blit
    // after every damaged row has been copied into the persistent source.
    HDC destination = GetDC(window);
    int32_t copied = rune_win_dib_paint(dib, destination, &damage);
    if (destination) ReleaseDC(window, destination);
    dib->retry_full = !copied;
    return copied;
}
#endif
