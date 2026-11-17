#ifndef RUNE_WAYLAND_TOUCH_H
#define RUNE_WAYLAND_TOUCH_H
#include <stdint.h>
void rune_wayland_watch_touch_window(uint32_t window_id);
void rune_wayland_close_touch_windows(void);
#endif
