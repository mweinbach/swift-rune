#include "CRuneLinux.h"
#include <GL/gl.h>
#include <SDL2/SDL.h>
#include <SDL2/SDL_syswm.h>
#include <X11/Xutil.h>
#include <limits.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>

// Read WM_NORMAL_HINTS from the X server, as a window manager would.
static bool x11_limits(SDL_Window *window, int min_w, int min_h, int max_w, int max_h) {
    SDL_SysWMinfo info = {0};
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(window, &info)) return false;
    if (info.subsystem != SDL_SYSWM_X11) return true;
    XSizeHints hints = {0};
    long supplied;
    if (!XGetWMNormalHints(info.info.x11.display, info.info.x11.window, &hints, &supplied)) return false;
    return (hints.flags & PMinSize) && hints.min_width == min_w && hints.min_height == min_h &&
           (max_w ? ((hints.flags & PMaxSize) && hints.max_width == max_w && hints.max_height == max_h)
                  : (!(hints.flags & PMaxSize) || (hints.max_width == INT_MAX && hints.max_height == INT_MAX)));
}

static bool run(bool floating, bool bounded, bool resizable) {
    RuneLinuxWindowOptions options = {
        .width = 250, .height = 140, .minWidth = 80, .minHeight = 50,
        .maxWidth = bounded ? 400 : 0, .maxHeight = bounded ? 300 : 0,
        .resizable = resizable, .borderless = true, .floatOnOpen = floating,
        .physicalWidth = 200, .physicalHeight = 120
    };
    RuneLinuxWindow *host = rune_linux_open("Rune float-on-open", options);
    if (!host) return false;
    SDL_Window *window = SDL_GetWindowFromID(rune_linux_id(host));
    rune_linux_show(host);
    int w, h, pw, ph;
    rune_linux_size(host, &w, &h, &pw, &ph);
    bool x11 = SDL_strcmp(SDL_GetCurrentVideoDriver(), "x11") == 0;
    bool passed = (!floating || (pw == 200 && ph == 120))
        && !(SDL_GetWindowFlags(window) & SDL_WINDOW_HIDDEN)
        && (floating
            ? (!(SDL_GetWindowFlags(window) & SDL_WINDOW_RESIZABLE) && x11_limits(window, w, h, w, h))
            : (SDL_GetWindowFlags(window) & SDL_WINDOW_RESIZABLE) && x11_limits(window, 80, 50, 400, 300));
    if (floating) {
        SDL_GL_MakeCurrent(NULL, NULL);
        bool swapped = rune_linux_present(host);
        passed = passed && !swapped && *SDL_GetError() && !(SDL_GetWindowFlags(window) & SDL_WINDOW_RESIZABLE);
        passed = rune_linux_make_current(host) && passed;
    }
    glClearColor(0.1f, 0.5f, 1, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    passed = rune_linux_present(host) && passed;
    if (getenv("RUNE_TEST_FLOAT_IPC")) {
        // Continue acknowledging configure events while the tiler inspects and resizes this surface.
        puts("presented"); fflush(stdout);
        struct pollfd input = {.fd = 0, .events = POLLIN};
        while (poll(&input, 1, 16) == 0) {
            SDL_PumpEvents();
            rune_linux_present(host);
        }
    }
    if (resizable) {
        int min_w, min_h, max_w, max_h;
        SDL_GetWindowMinimumSize(window, &min_w, &min_h);
        SDL_GetWindowMaximumSize(window, &max_w, &max_h);
        passed = passed && (SDL_GetWindowFlags(window) & SDL_WINDOW_RESIZABLE)
            && min_w == 80 && min_h == 50 && max_w == options.maxWidth && max_h == options.maxHeight
            && x11_limits(window, min_w, min_h, max_w, max_h);
        // A second presentation must retain any subsequent application sizing change.
        SDL_SetWindowMinimumSize(window, 74, 44);
        rune_linux_present(host);
        SDL_GetWindowMinimumSize(window, &min_w, &min_h);
        passed = passed && min_w == 74 && min_h == 44;
    } else {
        passed = passed && !(SDL_GetWindowFlags(window) & SDL_WINDOW_RESIZABLE) && x11_limits(window, w, h, w, h);
    }
    printf("%s float=%d resize=%d max=%d requested=200x120 drawable=%dx%d logical=%dx%d: %s\n",
           x11 ? "X11" : "Wayland", floating, resizable, options.maxWidth, pw, ph, w, h, passed ? "pass" : "fail");
    rune_linux_close(host);
    return passed;
}

int main(void) {
    if (!rune_linux_group_begin()) return 1;
    const char *ipc = getenv("RUNE_TEST_FLOAT_IPC");
    bool passed = run(!ipc || SDL_strcmp(ipc, "tiled") != 0, true, true);
    if (!ipc) {
        passed = run(true, false, true) && passed;
        passed = run(true, false, false) && passed;
        passed = run(false, true, true) && passed;
    }
    rune_linux_group_end();
    return passed ? 0 : 1;
}
