#ifndef RUNE_WIN_GROUP_WAKE_H
#define RUNE_WIN_GROUP_WAKE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RuneWinGroupWake RuneWinGroupWake;

// Create and destroy on the UI thread. Post from any thread while the object is alive.
RuneWinGroupWake *rune_win_group_wake_create(void *context, void (*drain)(void *));
typedef enum {
    RuneWinSessionQuery, RuneWinSessionEnding, RuneWinSessionCancelled
} RuneWinSessionEvent;
typedef void (*RuneWinSessionNotify)(void *context, RuneWinSessionEvent event, int idle);
void rune_win_group_observe_session(RuneWinGroupWake *wake, RuneWinSessionNotify notify);
void rune_win_group_wake_post(RuneWinGroupWake *wake);
void rune_win_group_wake_destroy(RuneWinGroupWake *wake);
// Final process exit only. Destroys this GUI thread's top-level windows without calling application procedures.
void rune_win_destroy_quit_windows(void);

#ifdef __cplusplus
}
#endif
#endif
