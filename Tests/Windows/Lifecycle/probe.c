/* Build with the CRuneWin32 native target and its Windows SDK libraries.
   The probe uses a private, never-switched desktop. Messages go only to its own HWNDs. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <string.h>
#include <dwmapi.h>
#include <stdio.h>
#include "CRuneWin32.h"
#include "WindowLifecycle.h"

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "line %d: %s (Win32 %lu)\n", __LINE__, #condition, GetLastError()); return 1; \
} } while (0)

typedef struct {
    RuneWinWindow *window;
    HWND session;
    int pre_present, locks, frames, queries, cancellations, endings, idle, busy, nested_query;
    int presses;
    RuneWinEvent press;
} Probe;

static int32_t receive(void *context, const RuneWinEvent *event) {
    Probe *probe = context;
    if (event->kind == RUNE_WIN_SESSION_LOCK) ++probe->locks;
    if (event->kind == RUNE_WIN_DOWN || event->kind == RUNE_WIN_UP) {
        probe->press = *event;
        ++probe->presses;
    }
    if (event->kind == RUNE_WIN_FRAME) {
        ++probe->frames;
        if (probe->nested_query && (InSendMessageEx(NULL) & ISMEX_SEND)) {
            probe->nested_query = 0;
            SendMessageW(probe->session, WM_QUERYENDSESSION, 0, ENDSESSION_CLOSEAPP);
        }
        if (probe->frames == 1) {
            DWORD reasons = 0;
            HWND hwnd = rune_win_hwnd(probe->window);
            if (SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &reasons, sizeof(reasons))))
                probe->pre_present = (reasons & DWM_CLOAKED_APP) != 0;
            SendMessageW(hwnd, WM_WTSSESSION_CHANGE, 7, 0);
        }
    }
    return -1;
}

static void drain(void *context) { (void)context; }

static void session(void *context, RuneWinSessionEvent event, int idle) {
    Probe *probe = context;
    if (event == RuneWinSessionQuery) ++probe->queries;
    if (event == RuneWinSessionCancelled) ++probe->cancellations;
    if (event == RuneWinSessionEnding) ++probe->endings;
    if (idle) ++probe->idle; else ++probe->busy;
}

static BOOL CALLBACK find_session(HWND hwnd, LPARAM data) {
    WCHAR text[64];
    if (GetWindowTextW(hwnd, text, ARRAYSIZE(text)) && wcscmp(text, L"RuneSession") == 0) {
        ((Probe *)data)->session = hwnd;
        return FALSE;
    }
    return TRUE;
}

static DWORD WINAPI request_end(void *context) {
    HWND hwnd = ((Probe *)context)->session;
    SendMessageW(hwnd, WM_QUERYENDSESSION, 0, ENDSESSION_CLOSEAPP);
    SendMessageW(hwnd, WM_ENDSESSION, FALSE, ENDSESSION_CLOSEAPP);
    SendMessageW(hwnd, WM_ENDSESSION, TRUE, ENDSESSION_CLOSEAPP);
    return 0;
}

static DWORD WINAPI request_paint(void *context) {
    HWND hwnd = context;
    SendMessageW(hwnd, WM_PAINT, 0, 0);
    PostMessageW(hwnd, WM_NULL, 0, 0);
    return 0;
}

static DWORD WINAPI run_probe(void *desktop) {
    CHECK(SetThreadDesktop((HDESK)desktop));
    Probe probe = {0};
    RuneWinGroupWake *group = rune_win_group_wake_create(&probe, drain);
    CHECK(group);
    rune_win_group_observe_session(group, session);
    EnumThreadWindows(GetCurrentThreadId(), find_session, (LPARAM)&probe);
    CHECK(probe.session && !IsWindowVisible(probe.session));
    CHECK((GetWindowLongW(probe.session, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) != 0);
    CHECK(SendMessageW(probe.session, WM_QUERYENDSESSION, 0, ENDSESSION_CLOSEAPP) == TRUE && probe.busy == 1);

    HANDLE worker = CreateThread(NULL, 0, request_end, &probe, 0, NULL);
    CHECK(worker);
    // Pump like the Swift window group. The worker's synchronous sends arrive in GetMessageW.
    UINT_PTR guard = SetTimer(NULL, 0, 100, NULL);
    ULONGLONG deadline = GetTickCount64() + 3000;
    while (!probe.endings && GetTickCount64() < deadline) rune_win_pump();
    KillTimer(NULL, guard);
    CHECK(WaitForSingleObject(worker, 1000) == WAIT_OBJECT_0);
    CloseHandle(worker);
    CHECK(probe.queries == 2 && probe.cancellations == 1 && probe.endings == 1 && probe.idle == 3);

    char error[256] = {0};
    probe.window = rune_win_create((const uint16_t *)L"Rune lifecycle", 200, 100, 1, 1, 0, error, sizeof(error));
    if (!probe.window) fprintf(stderr, "%s\n", error);
    CHECK(probe.window);
    HWND hwnd = rune_win_hwnd(probe.window);
    rune_win_defer_startup_hooks(probe.window);
    rune_win_start(probe.window, &probe, receive, 1, 1);
    CHECK(probe.frames && probe.pre_present && probe.locks == 0 && !rune_win_is_covered(probe.window));
    // A synchronous paint may run inside GetMessage, then a quit inside that paint.
    probe.nested_query = 1;
    worker = CreateThread(NULL, 0, request_paint, hwnd, 0, NULL);
    CHECK(worker);
    deadline = GetTickCount64() + 3000;
    guard = SetTimer(NULL, 0, 100, NULL);
    CHECK(guard);
    while (probe.nested_query && GetTickCount64() < deadline) rune_win_pump();
    KillTimer(NULL, guard);
    CHECK(WaitForSingleObject(worker, 1000) == WAIT_OBJECT_0);
    CloseHandle(worker);
    CHECK(probe.queries == 3 && probe.busy == 2 && probe.idle == 3);
    rune_win_group_wake_destroy(group);
    // Hiding before the first swap releases without activation. A later show gets a fresh
    // deadline, so a frame that stalls cannot keep the window invisible.
    DWORD reasons = 0;
    rune_win_show(probe.window, 0);
    CHECK(SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &reasons, sizeof(reasons))) && !(reasons & DWM_CLOAKED_APP));
    rune_win_show(probe.window, 1);
    CHECK(SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &reasons, sizeof(reasons))) && (reasons & DWM_CLOAKED_APP));
    deadline = GetTickCount64() + 5000;
    guard = SetTimer(NULL, 0, 100, NULL);
    CHECK(guard);
    while ((reasons & DWM_CLOAKED_APP) && GetTickCount64() < deadline) {
        rune_win_pump();
        CHECK(SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &reasons, sizeof(reasons))));
    }
    KillTimer(NULL, guard);
    CHECK(!(reasons & DWM_CLOAKED_APP));
    rune_win_show(probe.window, 0);
    rune_win_show(probe.window, 1);
    CHECK(SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &reasons, sizeof(reasons))) && (reasons & DWM_CLOAKED_APP));
    CHECK(rune_win_take_frame_slot(probe.window));
    RECT client;
    CHECK(GetClientRect(hwnd, &client));
    CHECK(rune_win_swap_damage(probe.window, client.right, client.bottom, NULL, -1));
    CHECK(SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &reasons, sizeof(reasons))) && !(reasons & DWM_CLOAKED_APP));
    // The Swift desktop host installs WTS on its deferred hooks turn after the first swap.
    SendMessageW(hwnd, WM_WTSSESSION_CHANGE, 7, 0);
    CHECK(probe.locks == 0);
    rune_win_install_session_lock(probe.window);
    rune_win_install_session_lock(probe.window);
    SendMessageW(hwnd, WM_WTSSESSION_CHANGE, 8, 0);  // unlock
    CHECK(probe.locks == 0);
    SendMessageW(hwnd, WM_WTSSESSION_CHANGE, 7, 0);
    CHECK(probe.locks == 1);
    // The point in a button message survives leave tracking, independent of the system cursor.
    const UINT buttons[][4] = {
        {WM_LBUTTONDOWN, WM_LBUTTONUP, WM_LBUTTONDBLCLK, WM_LBUTTONUP},
        {WM_RBUTTONDOWN, WM_RBUTTONUP, WM_RBUTTONDBLCLK, WM_RBUTTONUP},
        {WM_MBUTTONDOWN, WM_MBUTTONUP, WM_MBUTTONDBLCLK, WM_MBUTTONUP},
        {WM_XBUTTONDOWN, WM_XBUTTONUP, WM_XBUTTONDBLCLK, WM_XBUTTONUP},
        {WM_XBUTTONDOWN, WM_XBUTTONUP, WM_XBUTTONDBLCLK, WM_XBUTTONUP},
    };
    SendMessageW(hwnd, WM_MOUSELEAVE, 0, 0);
    for (unsigned button = 0; button < ARRAYSIZE(buttons); ++button) {
        WPARAM extra = button < 3 ? 0 : MAKEWPARAM(0, button == 3 ? XBUTTON1 : XBUTTON2);
        for (unsigned step = 0; step < ARRAYSIZE(buttons[0]); ++step) {
            int x = -30 - (int)button, y = 17 + (int)step, previous = probe.presses;
            SendMessageW(hwnd, buttons[button][step], extra, MAKELPARAM(x, y));
            CHECK(probe.presses == previous + 1);
            CHECK(probe.press.kind == (step % 2 ? RUNE_WIN_UP : RUNE_WIN_DOWN));
            CHECK(probe.press.value == button && probe.press.x == x && probe.press.y == y);
        }
    }
    puts("PASS signed button-message points for all five buttons on down, up and double click");
    rune_win_show(probe.window, 0);
    CHECK(!IsWindowVisible(hwnd));
    rune_win_show(probe.window, 1);
    CHECK(IsWindowVisible(hwnd) && !rune_win_is_covered(probe.window));
    RECT target;
    CHECK(GetWindowRect(hwnd, &target));
    HWND cover = CreateWindowExW(WS_EX_NOACTIVATE, L"STATIC", L"Occluder", WS_OVERLAPPEDWINDOW,
        target.left - 20, target.top - 20, target.right - target.left + 40, target.bottom - target.top + 40,
        NULL, NULL, GetModuleHandleW(NULL), NULL);
    CHECK(cover);
    SetWindowPos(cover, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    DwmFlush();
    CHECK(rune_win_covered_on_input_desktop(hwnd));
    SetWindowLongPtrW(cover, GWL_EXSTYLE, GetWindowLongPtrW(cover, GWL_EXSTYLE) | WS_EX_TRANSPARENT);
    CHECK(!rune_win_covered_on_input_desktop(hwnd));
    SetWindowLongPtrW(cover, GWL_EXSTYLE, WS_EX_NOACTIVATE);
    SetWindowPos(cover, NULL, target.left + 70, target.top, 0, 0, SWP_NOZORDER | SWP_NOSIZE | SWP_NOACTIVATE);
    DwmFlush();
    CHECK(!rune_win_covered_on_input_desktop(hwnd));
    DestroyWindow(cover);
    CHECK(!rune_win_covered_on_input_desktop(hwnd));
    rune_win_destroy(probe.window);
    CHECK(!IsWindow(hwnd));
    CHECK(!rune_win_is_covered(NULL));
    int low = rune_win_low_memory();
    CHECK(low == 0 || low == 1);
    printf("PASS session query/cancel/end, idle and reentrant delivery, private desktop visibility and z-order, first-swap and timer cloak release, WTS lock registration; cloak before swap=%d low_memory=%d\n", probe.pre_present, low);
    return 0;
}

static unsigned application_destroy, subclass_destroy;

static LRESULT CALLBACK observed_window(HWND window, UINT message, WPARAM wp, LPARAM lp) {
    if (message == WM_DESTROY || message == WM_NCDESTROY) ++application_destroy;
    return DefWindowProcW(window, message, wp, lp);
}

static LRESULT CALLBACK observed_subclass(HWND window, UINT message, WPARAM wp, LPARAM lp,
                                         UINT_PTR id, DWORD_PTR data) {
    (void)id;
    (void)data;
    if (message == WM_DESTROY || message == WM_NCDESTROY) ++subclass_destroy;
    return DefSubclassProc(window, message, wp, lp);
}

static DWORD WINAPI run_fast_exit_probe(void *desktop) {
    CHECK(SetThreadDesktop((HDESK)desktop));
    WNDCLASSW cls = {.lpfnWndProc = observed_window, .hInstance = GetModuleHandleW(NULL),
                     .lpszClassName = L"RuneSwiftExitProbe"};
    CHECK(RegisterClassW(&cls));
    HWND host = CreateWindowExW(0, cls.lpszClassName, NULL, WS_OVERLAPPEDWINDOW,
        0, 0, 10, 10, NULL, NULL, cls.hInstance, NULL);
    HWND popup = CreateWindowExW(WS_EX_TOOLWINDOW, cls.lpszClassName, NULL, WS_POPUP,
        0, 0, 10, 10, host, NULL, cls.hInstance, NULL);
    CHECK(host && popup && SetWindowSubclass(host, observed_subclass, 1, 0) &&
          SetWindowSubclass(popup, observed_subclass, 1, 0));
    LARGE_INTEGER frequency, start, end;
    CHECK(QueryPerformanceFrequency(&frequency) && QueryPerformanceCounter(&start));
    rune_win_destroy_quit_windows();
    QueryPerformanceCounter(&end);
    CHECK(!IsWindow(host) && !IsWindow(popup));
    CHECK(application_destroy == 0 && subclass_destroy == 0);
    printf("PASS fast exit removed the top-level window and owned popup without application or subclass callbacks (%.3f ms)\n",
           1000.0 * (end.QuadPart - start.QuadPart) / frequency.QuadPart);
    return 0;
}

int main(int argc, char **argv) {
    WCHAR name[64];
    swprintf_s(name, ARRAYSIZE(name), L"RuneLifecycleProbe-%lu", GetCurrentProcessId());
    HDESK desktop = CreateDesktopW(name, NULL, NULL, 0, GENERIC_ALL, NULL);
    CHECK(desktop);
    LPTHREAD_START_ROUTINE test = argc > 1 && strcmp(argv[1], "fast-exit") == 0 ? run_fast_exit_probe : run_probe;
    HANDLE runner = CreateThread(NULL, 0, test, desktop, 0, NULL);
    CHECK(runner && WaitForSingleObject(runner, 90000) == WAIT_OBJECT_0);
    DWORD result = 1;
    CHECK(GetExitCodeThread(runner, &result));
    CloseHandle(runner);
    CHECK(CloseDesktop(desktop));
    return result;
}
