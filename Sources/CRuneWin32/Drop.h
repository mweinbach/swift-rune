#ifndef RUNE_WINDOWS_DROP_PRIVATE_H
#define RUNE_WINDOWS_DROP_PRIVATE_H
#include "CRuneWin32.h"
#ifdef __cplusplus
extern "C" {
#endif
int rune_win_drop_event(RuneWinWindow *window, RuneWinEventKind kind, void *files, int32_t x, int32_t y);
int rune_win_drag_mutes_local_targets(void);
#ifdef __cplusplus
}
#endif
#endif
