#ifndef RUNE_WIN_GROUP_WAKE_H
#define RUNE_WIN_GROUP_WAKE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RuneWinGroupWake RuneWinGroupWake;

// Create and destroy on the UI thread. Post from any thread while the object is alive.
RuneWinGroupWake *rune_win_group_wake_create(void *context, void (*drain)(void *));
void rune_win_group_wake_post(RuneWinGroupWake *wake);
void rune_win_group_wake_destroy(RuneWinGroupWake *wake);

#ifdef __cplusplus
}
#endif
#endif
