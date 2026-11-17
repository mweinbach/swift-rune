#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdlib.h>
#include "RuneWinOverlay.h"

struct RuneMouseWatch {
    void *owner;
    RuneMouseSample callback;
    struct RuneMouseWatch *next;
};
static SRWLOCK lifecycle_lock = SRWLOCK_INIT;
static SRWLOCK observers_lock = SRWLOCK_INIT;
static RuneMouseWatch *observers;
static HANDLE pump;
static DWORD pump_id;
struct HookStart { HANDLE ready; BOOL hooked; };

static LRESULT CALLBACK observe_mouse(int code, WPARAM message, LPARAM data) {
    if (code == HC_ACTION && message == WM_MOUSEMOVE) {
        POINT point = ((const MSLLHOOKSTRUCT *)data)->pt;
        AcquireSRWLockShared(&observers_lock);
        for (RuneMouseWatch *watch = observers; watch; watch = watch->next)
            watch->callback(watch->owner, point.x, point.y);
        ReleaseSRWLockShared(&observers_lock);
    }
    return CallNextHookEx(NULL, code, message, data);
}

static DWORD WINAPI watch_thread(void *arg) {
    struct HookStart *start = (struct HookStart *)arg;
    MSG message;
    PeekMessageW(&message, NULL, 0, 0, PM_NOREMOVE);
    HHOOK hook = SetWindowsHookExW(WH_MOUSE_LL, observe_mouse, GetModuleHandleW(NULL), 0);
    start->hooked = hook != NULL;
    SetEvent(start->ready);
    if (!hook) return 0;
    while (GetMessageW(&message, NULL, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    UnhookWindowsHookEx(hook);
    return 0;
}

RuneMouseWatch *rune_win_mouse_watch(void *owner, RuneMouseSample callback) {
    if (!callback) return NULL;
    RuneMouseWatch *watch = calloc(1, sizeof(*watch));
    if (!watch) return NULL;
    watch->owner = owner;
    watch->callback = callback;
    AcquireSRWLockExclusive(&lifecycle_lock);
    if (!pump) {
        struct HookStart start = {.ready = CreateEventW(NULL, FALSE, FALSE, NULL)};
        if (start.ready) {
            pump = CreateThread(NULL, 0, watch_thread, &start, 0, &pump_id);
            if (pump) {
                WaitForSingleObject(start.ready, INFINITE);
                if (!start.hooked) { WaitForSingleObject(pump, INFINITE); CloseHandle(pump); pump = NULL; }
            }
            CloseHandle(start.ready);
        }
    }
    if (pump) {
        AcquireSRWLockExclusive(&observers_lock);
        watch->next = observers;
        observers = watch;
        ReleaseSRWLockExclusive(&observers_lock);
    } else { free(watch); watch = NULL; }
    ReleaseSRWLockExclusive(&lifecycle_lock);
    return watch;
}

void rune_win_mouse_unwatch(RuneMouseWatch *watch) {
    if (!watch) return;
    AcquireSRWLockExclusive(&lifecycle_lock);
    AcquireSRWLockExclusive(&observers_lock);
    RuneMouseWatch **link = &observers;
    while (*link && *link != watch) link = &(*link)->next;
    if (*link) *link = watch->next;
    BOOL empty = observers == NULL;
    ReleaseSRWLockExclusive(&observers_lock);
    if (empty && pump) {
        PostThreadMessageW(pump_id, WM_QUIT, 0, 0);
        WaitForSingleObject(pump, INFINITE);
        CloseHandle(pump);
        pump = NULL;
    }
    ReleaseSRWLockExclusive(&lifecycle_lock);
    free(watch);
}
#endif
