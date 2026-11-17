#if defined(__linux__) && !defined(__ANDROID__)
#include "CRuneLinux.h"
#include "../CSDL2/shim.h"

int rune_linux_displays(void *context, RuneLinuxDisplayVisitor visit) {
    if (SDL_InitSubSystem(SDL_INIT_VIDEO) < 0) return -1;
    int count = SDL_GetNumVideoDisplays();
    for (int i = 0; i < count; i++) {
        SDL_Rect bounds;
        SDL_DisplayMode mode;
        if (SDL_GetDisplayBounds(i, &bounds) < 0 || SDL_GetCurrentDisplayMode(i, &mode) < 0 ||
            bounds.w <= 0 || bounds.h <= 0 || mode.w <= 0 || mode.h <= 0) continue;
        double scale = (double)mode.w / bounds.w;
        visit(context, (uint32_t)i, SDL_GetDisplayName(i), (int32_t)(bounds.x * scale),
              (int32_t)(bounds.y * scale), (uint32_t)mode.w, (uint32_t)mode.h, scale, i == 0);
    }
    SDL_QuitSubSystem(SDL_INIT_VIDEO);
    return count;
}
#endif
