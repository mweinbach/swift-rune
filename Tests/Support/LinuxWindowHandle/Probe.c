#include "CRuneLinux.h"
#include <GL/gl.h>
#include <SDL2/SDL.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/XTest.h>
#include <stdio.h>
#include <stdlib.h>

static RuneLinuxWindow *underlay, *overlay;
static Display *display;
static int pointer_x, pointer_y;

static void present(RuneLinuxWindow *window) {
    if (!window || !rune_linux_make_current(window)) return;
    glClearColor(window == overlay, window == underlay, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    rune_linux_present(window);
}

static uint32_t dispatch(bool down) {
    RuneLinuxEvent event = {0};
    if (rune_linux_next_event(15, &event) <= 0) return 0;
    if (event.kind == RuneLinuxExposed || event.kind == RuneLinuxResized) {
        if (overlay && event.windowID == rune_linux_id(overlay)) present(overlay);
        if (event.windowID == rune_linux_id(underlay)) present(underlay);
    }
    rune_linux_free(event.text);
    return event.kind == RuneLinuxButton && event.active == down ? event.windowID : 0;
}

static int wait_for_color(unsigned long rgb) {
    uint64_t deadline = SDL_GetTicks64() + 5000;
    unsigned long pixel = 0;
    do {
        (void)dispatch(true);
        XImage *sample = XGetImage(display, DefaultRootWindow(display), pointer_x, pointer_y, 1, 1, AllPlanes, ZPixmap);
        if (sample) {
            pixel = XGetPixel(sample, 0, 0);
            XDestroyImage(sample);
            // Weston highlights the active surface. Its dominant channel still distinguishes both windows.
            unsigned red = (pixel >> 16) & 255, green = (pixel >> 8) & 255, blue = pixel & 255;
            if (blue < 110 && (rgb == 0xff0000 ? red > 180 && green < 110 : green > 180 && red < 110)) return 1;
        }
    } while (SDL_GetTicks64() < deadline);
    fprintf(stderr, "Composited pixel at (%d,%d) was #%06lx, expected #%06lx\n", pointer_x, pointer_y, pixel, rgb);
    return 0;
}

static int click(RuneLinuxWindow *expected) {
    XTestFakeMotionEvent(display, DefaultScreen(display), pointer_x + 3, pointer_y + 3, CurrentTime);
    XTestFakeMotionEvent(display, DefaultScreen(display), pointer_x, pointer_y, CurrentTime);
    XFlush(display);
    uint64_t settle = SDL_GetTicks64() + 150;
    while (SDL_GetTicks64() < settle) (void)dispatch(true);
    XTestFakeButtonEvent(display, 1, True, CurrentTime);
    XFlush(display);
    uint32_t target = 0;
    uint64_t deadline = SDL_GetTicks64() + 3000;
    while (!target && SDL_GetTicks64() < deadline) target = dispatch(true);
    XTestFakeButtonEvent(display, 1, False, CurrentTime);
    XFlush(display);
    uint32_t released = 0;
    while (target && !released && SDL_GetTicks64() < deadline) released = dispatch(false);
    printf("Click at (%d,%d) reached %u, expected %u\n", pointer_x, pointer_y, target, rune_linux_id(expected));
    return target == rune_linux_id(expected) && released == target;
}

static int test(Window compositor) {
    RuneLinuxWindowOptions options = {.width = 450, .height = 325, .minWidth = 10, .minHeight = 10,
        .resizable = true, .borderless = getenv("RUNE_TEST_DECORATED") == NULL, .visible = true};
    printf("%s %s windows\n", SDL_GetCurrentVideoDriver(), options.borderless ? "borderless" : "reparented");
    // On Wayland the pointer enters the nested compositor. Its output is 320 by 200.
    pointer_x = 160;
    pointer_y = 100;
    if (compositor) {
        Window child;
        if (!XTranslateCoordinates(display, compositor, DefaultRootWindow(display), 160, 100,
                                   &pointer_x, &pointer_y, &child)) return 0;
    } else if (!options.borderless) {
        XWindowAttributes root;
        uint64_t deadline = SDL_GetTicks64() + 3000;
        do {
            if (XGetWindowAttributes(display, DefaultRootWindow(display), &root) &&
                (root.all_event_masks & SubstructureRedirectMask)) break;
            if (SDL_GetTicks64() >= deadline) {
                fprintf(stderr, "The test window manager did not start\n");
                return 0;
            }
            SDL_Delay(20);
        } while (1);
    }
    underlay = rune_linux_open("Rune input underlay", options);
    if (!underlay) return 0;
    if (!compositor) rune_linux_set_position(underlay, 20, 30);
    present(underlay);
    if (!wait_for_color(0x00ff00)) return 0;

    options.width = 330;
    options.height = 220;
    overlay = rune_linux_open("Rune input overlay", options);
    if (!overlay) return 0;
    if (!compositor) rune_linux_set_position(overlay, 60, 45);
    rune_linux_focus(overlay);
    present(overlay);
    if (!wait_for_color(0xff0000)) return 0;

    RuneLinuxPlacement p = {0};
    int available = rune_linux_placement(overlay, &p);
    if (compositor ? available : (!available || p.x != 60 || p.y != 45 ||
        p.width != 330 || p.height != 220 || p.display_width != 800 || p.display_height != 600)) {
        fprintf(stderr, "Unexpected placement (%d): (%d,%d) %ux%u\n", available, p.x, p.y, p.width, p.height);
        return 0;
    }
    if (!click(overlay) || !rune_linux_click_through(overlay, 1)) return 0;
    present(overlay);
    if (!wait_for_color(0xff0000) || !click(underlay) || !rune_linux_click_through(overlay, 0)) return 0;
    // Focusing the underlay may have raised it. Expose the original overlay again.
    rune_linux_hide(underlay);
    present(overlay);
    return wait_for_color(0xff0000) && click(overlay);
}

int main(int argc, char **argv) {
    display = XOpenDisplay(NULL);
    if (!display || !rune_linux_group_begin()) return 1;
    int passed = test(argc == 2 ? strtoul(argv[1], NULL, 0) : None);
    if (!passed) fprintf(stderr, "%s\n", rune_linux_error());
    if (overlay) rune_linux_close(overlay);
    if (underlay) rune_linux_close(underlay);
    rune_linux_group_end();
    XCloseDisplay(display);
    return passed ? 0 : 1;
}
