#ifndef RUNE_DESKTOP_HOTKEYS_H
#define RUNE_DESKTOP_HOTKEYS_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* A manager owns its native registrations and finishes callbacks before close returns.
   Key names use ParsedShortcut's canonical lowercase US physical-key names.
   Modifier bits: Ctrl=1, Alt=2, Shift=4, Super=8. The optional activation token is
   borrowed for the call. The public ID range is independent of OS limits. */
typedef void (*RuneHotkeySink)(void *context, uint32_t id, const char *activation_token);
enum {
    RUNE_HOTKEY_OK = 0,
    RUNE_HOTKEY_CONFLICT = 1,
    RUNE_HOTKEY_INVALID = 2,
    RUNE_HOTKEY_UNKNOWN_ID = 3,
    RUNE_HOTKEY_UNSUPPORTED = 4,
    RUNE_HOTKEY_DENIED = 5,
    RUNE_HOTKEY_FAILED = 6
};

#define RUNE_HOTKEY_API(prefix) \
    void *rune_##prefix##_hotkeys_open(RuneHotkeySink sink, void *context, int *status); \
    int rune_##prefix##_hotkeys_register(void *manager, uint32_t id, uint8_t mods, const char *name); \
    int rune_##prefix##_hotkeys_unregister(void *manager, uint32_t id); \
    void rune_##prefix##_hotkeys_close(void *manager)

#if defined(_WIN32)
RUNE_HOTKEY_API(win);
#elif defined(__linux__) && !defined(__ANDROID__)
int rune_hotkeys_uses_wayland(void);
RUNE_HOTKEY_API(x11);
RUNE_HOTKEY_API(portal);
#endif
#undef RUNE_HOTKEY_API

#ifdef __cplusplus
}
#endif
#endif
