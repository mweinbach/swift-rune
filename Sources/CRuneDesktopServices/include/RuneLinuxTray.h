#ifndef RUNE_LINUX_TRAY_H
#define RUNE_LINUX_TRAY_H
#if defined(__linux__) && !defined(__ANDROID__)
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct RuneLinuxTray RuneLinuxTray;
typedef struct RuneLinuxTraySpec RuneLinuxTraySpec;
typedef void (*RuneLinuxTrayEvent)(void *context, const char *menu_id, const char *activation_token);
typedef void (*RuneLinuxTrayRelease)(void *context);

/* Strings and pixels are copied. A null menu id adds a separator. */
RuneLinuxTraySpec *rune_linux_tray_spec(const char *id, const char *title, const char *tooltip,
                                       const char *icon_name, const uint8_t *rgba, uint32_t width, uint32_t height);
void rune_linux_tray_item(RuneLinuxTraySpec *spec, const char *id, const char *label, int enabled);
/* Takes ownership of spec and context, including on failure. */
RuneLinuxTray *rune_linux_tray_open(RuneLinuxTraySpec *spec, void *context, RuneLinuxTrayEvent event,
                                    RuneLinuxTrayRelease release, char *error, size_t error_capacity);
/* Replaces the exported model on its owning context and consumes spec. */
void rune_linux_tray_update(RuneLinuxTray *tray, RuneLinuxTraySpec *spec, int keep_pixels);
void rune_linux_tray_set_tooltip(RuneLinuxTray *tray, const char *tooltip);
/* Closing from a callback lets the current method reply before the bus connection closes. */
void rune_linux_tray_close(RuneLinuxTray *tray);
#ifdef __cplusplus
}
#endif
#endif
#endif
