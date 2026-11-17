#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include "WindowLifecycle.h"
#include <dwmapi.h>
#include <stdlib.h>
#include <stdint.h>
#include "RuneWinGroupWake.h"

typedef BOOL (WINAPI *RegisterSession)(HWND, DWORD);
typedef BOOL (WINAPI *UnregisterSession)(HWND);
static INIT_ONCE session_once = INIT_ONCE_STATIC_INIT;
static RegisterSession register_session;
static UnregisterSession unregister_session;

static BOOL CALLBACK load_session_api(PINIT_ONCE once, PVOID param, PVOID *context) {
    (void)once;
    (void)param;
    (void)context;
    HMODULE module = LoadLibraryExW(L"wtsapi32.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (module) {
        register_session = (RegisterSession)GetProcAddress(module, "WTSRegisterSessionNotification");
        unregister_session = (UnregisterSession)GetProcAddress(module, "WTSUnRegisterSessionNotification");
    }
    return TRUE;
}

static void activate_window(HWND window) {
    static LONG first = TRUE;
    if (InterlockedExchange(&first, FALSE)) {
        STARTUPINFOW info = {.cb = sizeof(info)};
        GetStartupInfoW(&info);
        if ((info.dwFlags & STARTF_USESHOWWINDOW) &&
            (info.wShowWindow == SW_SHOWNOACTIVATE || info.wShowWindow == SW_SHOWNA ||
             info.wShowWindow == SW_SHOWMINNOACTIVE || info.wShowWindow == SW_MINIMIZE)) return;
    }
    if (AllowSetForegroundWindow(GetCurrentProcessId())) SetForegroundWindow(window);
}

void rune_lifecycle_hold(HWND window, RuneWinLifecycle *state, BOOL activate) {
    if (state->presented || state->cloaked) return;
    BOOL cloak = TRUE;
    if (SUCCEEDED(DwmSetWindowAttribute(window, DWMWA_CLOAK, &cloak, sizeof(cloak)))) {
        state->cloaked = TRUE;
        state->deadline = GetTickCount64() + 1000;
        state->activate_on_lift = activate;
        if (!SetTimer(window, rune_cloak_timer, 1000, NULL)) rune_lifecycle_lift(window, state, FALSE);
    }
}

void rune_lifecycle_lift(HWND window, RuneWinLifecycle *state, BOOL may_activate) {
    if (!state->cloaked) return;
    BOOL activate = may_activate && state->activate_on_lift;
    state->cloaked = state->activate_on_lift = FALSE;
    KillTimer(window, rune_cloak_timer);
    BOOL cloak = FALSE;
    DwmSetWindowAttribute(window, DWMWA_CLOAK, &cloak, sizeof(cloak));
    if (activate && IsWindowVisible(window) && !IsIconic(window)) activate_window(window);
}

void rune_lifecycle_presented(HWND window, RuneWinLifecycle *state) {
    if (state->presented) return;
    state->presented = TRUE;
    rune_lifecycle_lift(window, state, TRUE);
}

void rune_lifecycle_install_session_lock(HWND window, RuneWinLifecycle *state) {
    if (state->registered) return;
    InitOnceExecuteOnce(&session_once, load_session_api, NULL, NULL);
    state->registered = register_session && unregister_session && register_session(window, 0);
}

void rune_lifecycle_destroy(HWND window, RuneWinLifecycle *state) {
    if (state->registered) unregister_session(window);
    state->registered = FALSE;
}

typedef struct {
    HWND *windows;
    size_t count, capacity;
} QuitWindows;

static BOOL CALLBACK collect_for_exit(HWND window, LPARAM data) {
    QuitWindows *list = (QuitWindows *)data;
    if (list->count == list->capacity) {
        if (list->capacity > SIZE_MAX / sizeof(HWND) / 2) return FALSE;
        size_t capacity = list->capacity ? list->capacity * 2 : 8;
        HWND *windows = realloc(list->windows, capacity * sizeof(HWND));
        if (!windows) return FALSE;
        list->windows = windows;
        list->capacity = capacity;
    }
    list->windows[list->count++] = window;
    return TRUE;
}

void rune_win_destroy_quit_windows(void) {
    QuitWindows list = {0};
    EnumThreadWindows(GetCurrentThreadId(), collect_for_exit, (LPARAM)&list);
    // Disable callbacks on owned popups too before their owner's destruction destroys them.
    for (size_t i = 0; i < list.count; ++i)
        SetWindowLongPtrW(list.windows[i], GWLP_WNDPROC, (LONG_PTR)DefWindowProcW);
    for (size_t i = 0; i < list.count; ++i)
        DestroyWindow(list.windows[i]);
    free(list.windows);
}
#endif
