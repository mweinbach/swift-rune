#ifdef __linux__
#include "CRuneLinux.h"
#include "../CSDL2/shim.h"

void rune_linux_origin(RuneLinuxWindow *host, int *x, int *y) {
    SDL_GetWindowPosition(SDL_GetWindowFromID(rune_linux_id(host)), x, y);
}

void rune_linux_toggle_maximized(RuneLinuxWindow *host) {
    SDL_Window *window = SDL_GetWindowFromID(rune_linux_id(host));
    if (SDL_GetWindowFlags(window) & SDL_WINDOW_MAXIMIZED) SDL_RestoreWindow(window);
    else SDL_MaximizeWindow(window);
}
void rune_linux_toggle_fullscreen(RuneLinuxWindow *host) {
    SDL_Window *window = SDL_GetWindowFromID(rune_linux_id(host));
    SDL_SetWindowFullscreen(window, SDL_GetWindowFlags(window) & SDL_WINDOW_FULLSCREEN ? 0 : SDL_WINDOW_FULLSCREEN_DESKTOP);
}

bool rune_linux_has_mouse(RuneLinuxWindow *host) {
    return SDL_GetMouseFocus() == SDL_GetWindowFromID(rune_linux_id(host));
}

void *rune_linux_set_cursor(int kind) {
    if (kind == RuneLinuxCursorHidden) {
        SDL_ShowCursor(SDL_DISABLE);
        return NULL;
    }
    SDL_ShowCursor(SDL_ENABLE);
    SDL_SystemCursor shape;
    switch (kind) {
    case RuneLinuxCursorHand: shape = SDL_SYSTEM_CURSOR_HAND; break;
    case RuneLinuxCursorText: shape = SDL_SYSTEM_CURSOR_IBEAM; break;
    case RuneLinuxCursorNo: shape = SDL_SYSTEM_CURSOR_NO; break;
    case RuneLinuxCursorMove: shape = SDL_SYSTEM_CURSOR_SIZEALL; break;
    case RuneLinuxCursorColumn: shape = SDL_SYSTEM_CURSOR_SIZEWE; break;
    case RuneLinuxCursorRow: shape = SDL_SYSTEM_CURSOR_SIZENS; break;
    case RuneLinuxCursorCross: shape = SDL_SYSTEM_CURSOR_CROSSHAIR; break;
    default:
        SDL_SetCursor(SDL_GetDefaultCursor());
        return NULL;
    }
    SDL_Cursor *cursor = SDL_CreateSystemCursor(shape);
    SDL_SetCursor(cursor ? cursor : SDL_GetDefaultCursor());
    return cursor;
}

void *rune_linux_set_image_cursor(const uint8_t *rgba, int w, int h, int sizeW, int sizeH, int hx, int hy) {
    SDL_ShowCursor(SDL_ENABLE);
    SDL_Surface *source = SDL_CreateRGBSurfaceWithFormatFrom((void *)rgba, w, h, 32, w * 4, SDL_PIXELFORMAT_RGBA32);
    SDL_Surface *scaled = SDL_CreateRGBSurfaceWithFormat(0, sizeW, sizeH, 32, SDL_PIXELFORMAT_RGBA32);
    SDL_Cursor *cursor = NULL;
    if (source && scaled) {
        SDL_SetSurfaceBlendMode(source, SDL_BLENDMODE_NONE);
        if (SDL_BlitScaled(source, NULL, scaled, NULL) == 0)
            cursor = SDL_CreateColorCursor(scaled, hx, hy);
    }
    if (scaled) SDL_FreeSurface(scaled);
    if (source) SDL_FreeSurface(source);
    SDL_SetCursor(cursor ? cursor : SDL_GetDefaultCursor());
    return cursor;
}

void rune_linux_free_cursor(void *cursor) {
    if (cursor) SDL_FreeCursor(cursor);
}
#endif
