/* Source fixture for test.py. Hit-testing uses SDL's real X11 pointer events;
   the production Rune driver owns the drag and supplies its selection data. */
#include "linux_drag_internal.h"
#include <SDL.h>
#include <glib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "preview.h"

static RuneMimeData *read_payload(const char *directory) {
    static const char *types[] = {"text/plain;charset=utf-8", "text/uri-list", "image/png"};
    static const char *names[] = {"text", "uris", "png"};
    RuneMimeData *items = rune_mime_create();
    for (size_t i = 0; items && i < G_N_ELEMENTS(types); ++i) {
        gchar *path = g_build_filename(directory, names[i], NULL);
        gchar *bytes = NULL;
        gsize length = 0;
        gboolean ok = g_file_get_contents(path, &bytes, &length, NULL)
                      && rune_mime_add(items, types[i], (const uint8_t *)bytes, length);
        g_free(bytes);
        g_free(path);
        if (!ok) { rune_mime_free(items); return NULL; }
    }
    return items;
}

int main(int argc, char **argv) {
    int with_preview = argc == 4 && !strcmp(argv[3], "--preview");
    if ((argc != 3 && !with_preview) || SDL_Init(SDL_INIT_VIDEO) != 0) return 1;
    if (with_preview) SDL_GL_SetAttribute(SDL_GL_ALPHA_SIZE, 8);
    SDL_Window *window = SDL_CreateWindow("Rune X11 drag source", 20, 20, 180, 150,
                                          SDL_WINDOW_SHOWN | (with_preview ? SDL_WINDOW_OPENGL : 0));
    SDL_GLContext context = window && with_preview ? SDL_GL_CreateContext(window) : NULL;
    uint8_t pixels[40 * 24 * 4];
    RuneLinuxDragPreview preview = {pixels, sizeof pixels, 40, 24, 80, 48, 13, 7};
    if (with_preview && (!context || !capture_preview(pixels, sizeof pixels))) return 6;
    RuneLinuxDrag *driver = window ? rune_x11_drag_open(SDL_GetWindowID(window)) : NULL;
    RuneMimeData *items = read_payload(argv[2]);
    if (!driver || !items) return 2;
    setvbuf(stdout, NULL, _IOLBF, 0);
    puts("ready");
    int started = 0, result = -1;
    Uint64 deadline = SDL_GetTicks64() + 30000;
    while (result < 0 && SDL_GetTicks64() < deadline) {
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            if (!started && event.type == SDL_MOUSEMOTION && (event.motion.state & SDL_BUTTON_LMASK)) {
                driver->preview = with_preview ? &preview : NULL;
                if (!driver->begin(driver, items, (unsigned)atoi(argv[1]), 0)) {
                    fputs("native drag did not start\n", stderr);
                    return 3;
                }
                started = 1;
                puts("started");
            }
        }
        if (started) result = driver->poll(driver);
        SDL_Delay(3);
    }
    /* GDK receives the physical release while it holds the XDND seat grab.
       Subsequent SDL input must see the released button, too. Escape can
       cancel while the initiating button is still physically down. */
    deadline = SDL_GetTicks64() + 2000;
    Uint32 down;
    do {
        SDL_PumpEvents();
        down = (SDL_GetMouseState(NULL, NULL) | SDL_GetGlobalMouseState(NULL, NULL)) & SDL_BUTTON_LMASK;
        if (down) SDL_Delay(5);
    } while (down && SDL_GetTicks64() < deadline);
    if (down) {
        fputs("SDL button state stayed pressed after the physical release\n", stderr);
        return 5;
    }
    printf("result %d\n", result);
    int pressed = 0, released = 0;
    deadline = SDL_GetTicks64() + 12000;
    while (!released && SDL_GetTicks64() < deadline) {
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            if (event.type != SDL_MOUSEBUTTONDOWN && event.type != SDL_MOUSEBUTTONUP) continue;
            if (event.button.button != SDL_BUTTON_LEFT || event.button.windowID != SDL_GetWindowID(window)) continue;
            if (event.type == SDL_MOUSEBUTTONDOWN) {
                printf("press %d %d\n", event.button.x, event.button.y);
                pressed = 1;
            } else if (pressed) {
                released = 1;
            }
        }
        if (!released) SDL_Delay(3);
    }
    driver->destroy(driver);
    rune_mime_free(items);
    if (context) SDL_GL_DeleteContext(context);
    SDL_DestroyWindow(window);
    SDL_Quit();
    return result < 0 || !released ? 4 : 0;
}
