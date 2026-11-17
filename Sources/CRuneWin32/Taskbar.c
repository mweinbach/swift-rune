#ifdef _WIN32
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shobjidl.h>
#include <math.h>
#include <stddef.h>
#include <stdlib.h>
#include "CRuneWin32.h"

static HICON badge_icon(HWND window, uint32_t count) {
    UINT dpi = GetDpiForWindow(window);
    int size = GetSystemMetricsForDpi(SM_CXSMICON, dpi ? dpi : 96);
    if (size <= 0 || size > 256) return NULL;
    BITMAPINFO info = {0};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = size;
    info.bmiHeader.biHeight = -size;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;

    HDC dc = CreateCompatibleDC(NULL);
    if (!dc) return NULL;
    uint8_t *bits = NULL;
    HBITMAP color = CreateDIBSection(dc, &info, DIB_RGB_COLORS, (void **)&bits, NULL, 0);
    HICON icon = NULL;
    if (color && bits) {
        HGDIOBJ prior_bitmap = SelectObject(dc, color);
        wchar_t text[3] = {count > 9 ? L'9' : (wchar_t)(L'0' + count), count > 9 ? L'+' : 0, 0};
        HFONT font = CreateFontW(-(size * (count > 9 ? 62 : 78) / 100), 0, 0, 0, FW_BOLD, 0, 0, 0,
                                 DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                                 ANTIALIASED_QUALITY, DEFAULT_PITCH, L"Segoe UI");
        HGDIOBJ prior_font = font ? SelectObject(dc, font) : NULL;
        memset(bits, 0, (size_t)size * size * 4);
        SetBkMode(dc, TRANSPARENT);
        SetTextColor(dc, RGB(255,255,255));
        RECT bounds = {0, 0, size, size};
        DrawTextW(dc, text, -1, &bounds, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
        GdiFlush();
        if (font) { SelectObject(dc, prior_font); DeleteObject(font); }
        SelectObject(dc, prior_bitmap);

        double r = size * 0.5;
        for (int y = 0; y < size; ++y) for (int x = 0; x < size; ++x) {
            uint8_t *p = &bits[(y * size + x) * 4];
            double dx = x + 0.5 - r, dy = y + 0.5 - r;
            double a = fmax(0.0, fmin(1.0, r - sqrt(dx*dx + dy*dy)));
            double ink = p[1] / 255.0;
            const uint8_t disc[3] = {0x1c,0x2b,0xc4};
            for (int k = 0; k < 3; ++k) p[k] = (uint8_t)lround((disc[k] * (1 - ink) + 255 * ink) * a);
            p[3] = (uint8_t)lround(255 * a);
        }
        HBITMAP mask = CreateBitmap(size, size, 1, 1, NULL);
        if (mask) {
            ICONINFO image = {TRUE, 0, 0, mask, color};
            icon = CreateIconIndirect(&image);
            DeleteObject(mask);
        }
    }
    if (color) DeleteObject(color);
    DeleteDC(dc);
    return icon;
}

int rune_win_taskbar(void *destination, int32_t progress, uint32_t badge, const uint16_t *description) {
    HWND window = destination;
    if (!window || !IsWindow(window)) return 0;
    HRESULT init = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    if (FAILED(init) && init != RPC_E_CHANGED_MODE) return 0;
    ITaskbarList3 *list = NULL;
    HRESULT hr = CoCreateInstance(&CLSID_TaskbarList, NULL, CLSCTX_INPROC_SERVER, &IID_ITaskbarList3, (void **)&list);
    if (SUCCEEDED(hr)) {
        hr = ITaskbarList3_HrInit(list);
        if (SUCCEEDED(hr)) {
            TBPFLAG flag = progress == 1 ? TBPF_INDETERMINATE :
                           progress == 2 ? TBPF_PAUSED : progress == 3 ? TBPF_ERROR : TBPF_NOPROGRESS;
            if (flag == TBPF_PAUSED || flag == TBPF_ERROR) ITaskbarList3_SetProgressValue(list, window, 1, 1);
            hr = ITaskbarList3_SetProgressState(list, window, flag);
            HICON icon = badge ? badge_icon(window, badge) : NULL;
            if (badge && !icon) hr = E_OUTOFMEMORY;
            if (SUCCEEDED(hr))
                hr = ITaskbarList3_SetOverlayIcon(list, window, icon, (LPCWSTR)description);
            if (icon) DestroyIcon(icon);
        }
        ITaskbarList3_Release(list);
    }
    if (SUCCEEDED(init)) CoUninitialize();
    return SUCCEEDED(hr);
}
#endif
