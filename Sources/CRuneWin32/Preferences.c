#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dwmapi.h>
#include "CRuneWin32.h"

static uint32_t rgb(COLORREF color) {
    return ((uint32_t)GetRValue(color) << 16) | ((uint32_t)GetGValue(color) << 8) | GetBValue(color);
}

static int setting(const wchar_t *path, const wchar_t *key, int fallback) {
    DWORD value, size = sizeof(value);
    LSTATUS status = RegGetValueW(HKEY_CURRENT_USER, path, key, RRF_RT_REG_DWORD, NULL, &value, &size);
    return status == ERROR_SUCCESS ? value != 0 : fallback;
}

RuneWinPreferences rune_win_preferences(void) {
    RuneWinPreferences p = {0};
    int light = setting(L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize", L"AppsUseLightTheme", -1);
    p.dark = light < 0 ? -1 : !light;
    p.overlay_scrollbars = setting(L"Control Panel\\Accessibility", L"DynamicScrollbars", 1);
    p.double_click_ms = GetDoubleClickTime();
    BOOL animate = TRUE;
    if (SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &animate, 0)) p.reduced_motion = !animate;
    HIGHCONTRASTW contrast = {.cbSize = sizeof(contrast)};
    if (SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(contrast), &contrast, 0))
        p.high_contrast = (contrast.dwFlags & HCF_HIGHCONTRASTON) != 0;
    DWORD color = 0;
    BOOL opaque = FALSE;
    p.accent = SUCCEEDED(DwmGetColorizationColor(&color, &opaque)) ? color & 0xffffff : rgb(GetSysColor(COLOR_HIGHLIGHT));
    if (p.high_contrast) {
        p.window = rgb(GetSysColor(COLOR_WINDOW));
        p.text = rgb(GetSysColor(COLOR_WINDOWTEXT));
        p.highlight = rgb(GetSysColor(COLOR_HIGHLIGHT));
        p.highlight_text = rgb(GetSysColor(COLOR_HIGHLIGHTTEXT));
        p.disabled = rgb(GetSysColor(COLOR_GRAYTEXT));
        p.button = rgb(GetSysColor(COLOR_BTNFACE));
        p.button_text = rgb(GetSysColor(COLOR_BTNTEXT));
        p.link = rgb(GetSysColor(COLOR_HOTLIGHT));
    }
    return p;
}

uint32_t rune_win_replace_file(const uint16_t *source, const uint16_t *destination) {
    if (!source || !destination) return ERROR_INVALID_PARAMETER;
    return MoveFileExW((LPCWSTR)source, (LPCWSTR)destination, MOVEFILE_REPLACE_EXISTING) ? 0u : (uint32_t)GetLastError();
}

void rune_win_yield_or_sleep_ms(uint32_t ms) {
    if (ms == 0) {
        SwitchToThread();
    } else {
        Sleep(ms);
    }
}
#endif
