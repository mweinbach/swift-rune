// Compile with function-level linking so this test can exercise the production
// flash decision without creating a renderer or changing notification settings.
#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <stdio.h>

static QUERY_USER_NOTIFICATION_STATE shell_state;
static HRESULT shell_result;
static HWND foreground;
static FLASHWINFO request;
static int flashes;

static HRESULT WINAPI probe_state(QUERY_USER_NOTIFICATION_STATE *state) {
    *state = shell_state;
    return shell_result;
}
static HWND WINAPI probe_foreground(void) { return foreground; }
static BOOL WINAPI probe_flash(FLASHWINFO *info) {
    ++flashes;
    request = *info;
    return TRUE;
}

#define SHQueryUserNotificationState probe_state
#define GetForegroundWindow probe_foreground
#define FlashWindowEx probe_flash
#include "../../../Sources/CRuneWin32/Win32.c"

#define CHECK(test) do { if (!(test)) { fprintf(stderr, "failed: %s\n", #test); return 1; } } while (0)

int main(void) {
    RuneWinWindow window = {.hwnd = (HWND)(UINT_PTR)1};
    foreground = (HWND)(UINT_PTR)2;
    shell_result = S_OK;
    shell_state = QUNS_ACCEPTS_NOTIFICATIONS;
    rune_win_flash(&window, 1);
    CHECK(flashes == 1 && request.hwnd == window.hwnd && request.cbSize == sizeof(request));
    CHECK(request.dwFlags == FLASHW_TRAY && request.uCount == 2 && request.dwTimeout == 0);

    const QUERY_USER_NOTIFICATION_STATE suppressed[] = {
        QUNS_NOT_PRESENT, QUNS_BUSY, QUNS_RUNNING_D3D_FULL_SCREEN, QUNS_PRESENTATION_MODE,
        QUNS_QUIET_TIME, QUNS_APP
    };
    for (size_t i = 0; i < ARRAYSIZE(suppressed); ++i) {
        shell_state = suppressed[i];
        rune_win_flash(&window, 1);
        CHECK(flashes == 1);
    }
    shell_state = QUNS_ACCEPTS_NOTIFICATIONS;
    shell_result = E_FAIL;
    rune_win_flash(&window, 1);
    CHECK(flashes == 1);
    foreground = window.hwnd;
    shell_result = S_OK;
    rune_win_flash(&window, 1);
    CHECK(flashes == 1);

    shell_state = QUNS_QUIET_TIME;
    shell_result = E_FAIL;
    rune_win_flash(&window, 0);
    CHECK(flashes == 2 && request.hwnd == window.hwnd && request.dwFlags == FLASHW_STOP);
    CHECK(request.uCount == 0 && request.dwTimeout == 0);
    puts("PASS taskbar flash count, tray-only flag, six suppressed shell states, failed query, foreground and stop");
    return 0;
}
