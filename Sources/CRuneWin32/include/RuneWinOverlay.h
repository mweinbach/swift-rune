#ifndef RUNE_WIN_OVERLAY_H
#define RUNE_WIN_OVERLAY_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
struct RuneWinWindow;
typedef struct RuneMouseWatch RuneMouseWatch;
typedef void (*RuneMouseSample)(void *owner, int32_t x, int32_t y);
// The callback runs on the hook thread and must only update its mailbox.
RuneMouseWatch *rune_win_mouse_watch(void *owner, RuneMouseSample callback);
void rune_win_mouse_unwatch(RuneMouseWatch *watch);
int rune_win_overlay_pointer(int32_t *x, int32_t *y);
void rune_win_overlay_place(struct RuneWinWindow *window, int32_t x, int32_t y, int32_t width, int32_t height);
int rune_win_overlay_setup(struct RuneWinWindow *window, int can_take_keys);
int rune_win_overlay_set_keys(struct RuneWinWindow *window, int can_take_keys);
int rune_win_overlay_request_keys(struct RuneWinWindow *window);
int rune_win_is_overlay_hwnd(void *hwnd);
int rune_win_overlay_exclude(struct RuneWinWindow *window, int on);
void rune_win_overlay_alpha(struct RuneWinWindow *window, uint8_t alpha);
void rune_win_overlay_raise(struct RuneWinWindow *window);
void rune_win_overlay_due(struct RuneWinWindow *window, uint32_t after_ms);
void rune_win_overlay_observed(struct RuneWinWindow *window);
void rune_win_overlay_release_pointer(struct RuneWinWindow *window);
int rune_win_overlay_work_area(int32_t x, int32_t y, int32_t *top, int32_t *bottom);
typedef struct { void *dc; void *gl; } RuneOverlayGLBinding;
int rune_win_overlay_bind(struct RuneWinWindow *window, RuneOverlayGLBinding *previous);
void rune_win_overlay_restore(RuneOverlayGLBinding previous);
#ifdef __cplusplus
}
#endif
#endif
