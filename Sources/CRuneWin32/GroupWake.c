#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <stdlib.h>
#include "RuneWinGroupWake.h"
#include "WindowLifecycle.h"

struct RuneWinGroupWake {
    HWND window;
    DWORD owner;
    void *context;
    void (*drain)(void *);
    RuneWinSessionNotify notify;
    unsigned handling;
};

enum { group_wake_message = WM_APP + 1 };

static LRESULT CALLBACK group_wake_proc(HWND window, UINT message, WPARAM wp, LPARAM lp,
                                        UINT_PTR subclass, DWORD_PTR data) {
    (void)subclass;
    RuneWinGroupWake *wake = (RuneWinGroupWake *)data;
    if (message == WM_QUERYENDSESSION || message == WM_ENDSESSION) {
        RuneWinSessionEvent event = message == WM_QUERYENDSESSION ? RuneWinSessionQuery :
                                    wp ? RuneWinSessionEnding : RuneWinSessionCancelled;
        BOOL idle = !wake->handling && rune_win_idle_for_session();
        if (!idle && event != RuneWinSessionCancelled) EndMenu();
        if (wake->notify) {
            ++wake->handling;
            wake->notify(wake->context, event, idle);
            --wake->handling;
        }
        PostMessageW(window, WM_NULL, 0, 0);
        return message == WM_QUERYENDSESSION;
    }
    if (message == group_wake_message) {
        // A sent message alone runs its procedure inside GetMessage without returning it.
        // Also let the outer loop observe group opens, quits and finished windows.
        if (wp) PostMessageW(window, WM_NULL, 0, 0);
        ++wake->handling;
        wake->drain(wake->context);
        --wake->handling;
        return 0;
    }
    return DefSubclassProc(window, message, wp, lp);
}

RuneWinGroupWake *rune_win_group_wake_create(void *context, void (*drain)(void *)) {
    if (!drain) return NULL;
    RuneWinGroupWake *wake = calloc(1, sizeof(*wake));
    if (!wake) return NULL;
    wake->context = context;
    wake->drain = drain;
    wake->owner = GetCurrentThreadId();
    wake->window = CreateWindowExW(WS_EX_TOOLWINDOW, L"STATIC", L"RuneSession", WS_POPUP,
                                   0, 0, 0, 0, NULL, NULL, NULL, NULL);
    if (!wake->window || !SetWindowSubclass(wake->window, group_wake_proc, 1, (DWORD_PTR)wake)) {
        if (wake->window) DestroyWindow(wake->window);
        free(wake);
        return NULL;
    }
    return wake;
}

void rune_win_group_observe_session(RuneWinGroupWake *wake, RuneWinSessionNotify notify) {
    wake->notify = notify;
}

void rune_win_group_wake_post(RuneWinGroupWake *wake) {
    if (GetCurrentThreadId() == wake->owner) {
        // A handle can be called from a Rune callback. Finish that call before draining its requests.
        PostMessageW(wake->window, group_wake_message, 0, 0);
    } else {
        // USER32 delivers sent window messages even inside a filtered menu, drag or dialog loop.
        SendNotifyMessageW(wake->window, group_wake_message, 1, 0);
    }
}

void rune_win_group_wake_destroy(RuneWinGroupWake *wake) {
    if (!wake) return;
    RemoveWindowSubclass(wake->window, group_wake_proc, 1);
    DestroyWindow(wake->window);
    free(wake);
}
#endif
