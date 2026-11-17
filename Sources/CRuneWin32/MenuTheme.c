#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "RuneWinPopup.h"

typedef LONG (WINAPI *GetVersionInfo)(OSVERSIONINFOW *);
typedef int (WINAPI *SetPreferredAppMode)(int);
typedef void (WINAPI *FlushMenuThemes)(void);

static INIT_ONCE menu_theme_once = INIT_ONCE_STATIC_INIT;
static SetPreferredAppMode set_app_mode;
static FlushMenuThemes flush_menus;
static LONG applied_mode;

static BOOL CALLBACK load_menu_theme(PINIT_ONCE once, PVOID argument, PVOID *context) {
    (void)once; (void)argument; (void)context;
    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    GetVersionInfo version = ntdll ? (GetVersionInfo)GetProcAddress(ntdll, "RtlGetVersion") : NULL;
    OSVERSIONINFOW info = {.dwOSVersionInfoSize = sizeof(info)};
    // Earlier builds export functions with different signatures at these ordinals.
    if (!version || version(&info) != 0 || info.dwBuildNumber < 18362) return TRUE;
    HMODULE theme = LoadLibraryExW(L"uxtheme.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (theme) {
        set_app_mode = (SetPreferredAppMode)GetProcAddress(theme, MAKEINTRESOURCEA(135));
        flush_menus = (FlushMenuThemes)GetProcAddress(theme, MAKEINTRESOURCEA(136));
    }
    return TRUE;
}

void rune_win_menu_scheme(RuneWinMenuScheme scheme) {
    if (InterlockedCompareExchange(&applied_mode, 0, 0) == (LONG)scheme) return;
    InitOnceExecuteOnce(&menu_theme_once, load_menu_theme, NULL, NULL);
    if (InterlockedExchange(&applied_mode, (LONG)scheme) == (LONG)scheme || !set_app_mode || !flush_menus) return;
    set_app_mode((int)scheme);
    flush_menus();
}
#endif
