// Link this fixture with CRuneWin32/MenuTheme.c and run on Windows 10 1903 or later.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include "RuneWinPopup.h"

typedef int (WINAPI *SetPreferredAppMode)(int);
typedef LONG (WINAPI *GetVersionInfo)(OSVERSIONINFOW *);

int main(void) {
    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    GetVersionInfo version = ntdll ? (GetVersionInfo)GetProcAddress(ntdll, "RtlGetVersion") : NULL;
    OSVERSIONINFOW info = {.dwOSVersionInfoSize = sizeof(info)};
    if (!version || version(&info) != 0 || info.dwBuildNumber < 18362) return 2;
    HMODULE theme = LoadLibraryExW(L"uxtheme.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    SetPreferredAppMode set = theme ? (SetPreferredAppMode)GetProcAddress(theme, MAKEINTRESOURCEA(135)) : NULL;
    if (!set) return 2;
    // The native setter returns the process's previous mode. Repeating the requested
    // mode here reads back what the production call installed without changing it.
    const RuneWinMenuScheme modes[] = {
        RuneWinMenuFollowSystem, RuneWinMenuDark, RuneWinMenuDark, RuneWinMenuLight, RuneWinMenuFollowSystem,
    };
    for (size_t i = 0; i < ARRAYSIZE(modes); ++i) {
        rune_win_menu_scheme(modes[i]);
        int previous = set((int)modes[i]);
        if (previous != (int)modes[i]) {
            fprintf(stderr, "step %zu expected %d, native menu preference was %d\n", i, (int)modes[i], previous);
            return 1;
        }
    }
    puts("PASS native process menu mode followed system, forced dark, repeated, forced light and followed system again");
    return 0;
}
