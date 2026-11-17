#if defined(__linux__) && !defined(__ANDROID__)
#include "RuneDesktopHotkeys.h"
#include <SDL.h>
#include <string.h>

int rune_hotkeys_uses_wayland(void) {
    const char *driver = SDL_GetCurrentVideoDriver();
    return driver && strcmp(driver, "wayland") == 0;
}
#endif
