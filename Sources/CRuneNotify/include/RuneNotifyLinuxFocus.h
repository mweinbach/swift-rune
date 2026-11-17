#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

#if defined(__linux__) && !defined(__ANDROID__)
/* May be called from the notification callback thread. */
int rune_notify_linux_app_focused(void);
void rune_notify_linux_bring_to_front(const char *activation_token);

/* Host integration. Only the event-loop thread manipulates native windows. */
typedef void (*RuneNotifyLinuxWake)(uint32_t window, uint32_t event);
void rune_notify_linux_window_opened(uint32_t window, uint32_t event, RuneNotifyLinuxWake wake);
void rune_notify_linux_window_closed(uint32_t window);
void rune_notify_linux_window_focus(uint32_t window, int focused);
void rune_notify_linux_window_visible(uint32_t window, int visible);
/* A successful take transfers the optional token; release it with free(). */
int rune_notify_linux_take_activation(uint32_t window, char **token);
#endif

#ifdef __cplusplus
}
#endif
