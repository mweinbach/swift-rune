#ifndef RUNE_WIN_VIDEO_LAYER_H
#define RUNE_WIN_VIDEO_LAYER_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct RuneWinVideoWindow RuneWinVideoWindow;
typedef struct RuneWinVideoLayer RuneWinVideoLayer;
// All tree changes run on the window thread. Present calls on one layer must be
// serialized with removal. The decoder's D3D11 device has multithread protection.
RuneWinVideoWindow *rune_win_video_window(void *hwnd);
void rune_win_video_window_free(RuneWinVideoWindow *window);
uintptr_t rune_win_video_device_id(void *texture);
RuneWinVideoLayer *rune_win_video_prepare(RuneWinVideoWindow *window, void *texture, uint32_t slice,
                                      uint32_t source_width, uint32_t source_height,
                                      int32_t x, int32_t y, uint32_t width, uint32_t height,
                                      int32_t clip_left, int32_t clip_top, int32_t clip_right, int32_t clip_bottom,
                                      int full_range, int bt709);
// Attach only after the decoder primed the swap chain. The window thread waits for
// DWM to take this tree before suppressing the ordinary UI frames.
int rune_win_video_attach(RuneWinVideoWindow *window, RuneWinVideoLayer *layer);
int rune_win_video_present(RuneWinVideoLayer *layer, void *texture, uint32_t slice);
void rune_win_video_hide(RuneWinVideoWindow *window, RuneWinVideoLayer *layer);
#ifdef __cplusplus
}
#endif
#endif
