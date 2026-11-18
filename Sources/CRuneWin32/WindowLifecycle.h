#ifndef RUNE_WINDOW_LIFECYCLE_H
#define RUNE_WINDOW_LIFECYCLE_H
#include <windows.h>

enum { rune_cloak_timer = 0x5255434c };

typedef struct {
    BOOL presented;
    BOOL cloaked;
    BOOL activate_on_lift;
    ULONGLONG deadline;
    BOOL registered;
} RuneWinLifecycle;

BOOL rune_win_idle_for_session(void);
void rune_win_enter_callback(void);
void rune_win_leave_callback(void);
BOOL rune_win_covered_on_input_desktop(HWND hwnd);
void rune_lifecycle_hold(HWND window, RuneWinLifecycle *state, BOOL activate);
void rune_lifecycle_lift(HWND window, RuneWinLifecycle *state, BOOL may_activate);
void rune_lifecycle_presented(HWND window, RuneWinLifecycle *state);
void rune_lifecycle_install_session_lock(HWND window, RuneWinLifecycle *state);
void rune_lifecycle_destroy(HWND window, RuneWinLifecycle *state);
#endif
