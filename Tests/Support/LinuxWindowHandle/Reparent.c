#include "CRuneLinux.h"
#include <SDL2/SDL.h>
#include <SDL2/SDL_syswm.h>
#include <X11/Xatom.h>
#include <X11/extensions/shape.h>
#include <stdio.h>
#include <string.h>

static XRectangle original_input[] = {{2, 3, 51, 15}, {25, 39, 25, 44}};

// A second X client owns the frames and reparents Rune windows the way a WM does.
static Window create_frame(Display *manager, Window root) {
    Window frame = XCreateSimpleWindow(manager, root, 0, 0, 230, 150, 0, 0, 0);
    XShapeCombineRectangles(manager, frame, ShapeInput, 0, 0, original_input, 2, ShapeSet, Unsorted);
    XMapWindow(manager, frame);
    return frame;
}

static void reparent(Display *manager, Window window, Window parent) {
    XReparentWindow(manager, window, parent, 8, 16);
    XMapWindow(manager, window);
    XSync(manager, False);
}

static int matches_input(Display *manager, Window frame, int enabled) {
    int count = -1, ordering;
    XRectangle *shape = XShapeGetRectangles(manager, frame, ShapeInput, &count, &ordering);
    int matches = enabled ? count == 2 && shape && memcmp(shape, original_input, sizeof original_input) == 0
                          : count == 0;
    if (shape) XFree(shape);
    return matches;
}

static Window managed_client(Display *manager, RuneLinuxWindow *host) {
    SDL_SysWMinfo info = {0};
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(SDL_GetWindowFromID(rune_linux_id(host)), &info) || info.subsystem != SDL_SYSWM_X11)
        return None;
    Atom state = XInternAtom(manager, "WM_STATE", False);
    unsigned long normal[] = {1, None};
    XChangeProperty(manager, info.info.x11.window, state, state, 32, PropModeReplace, (unsigned char *)normal, 2);
    return info.info.x11.window;
}

int main(void) {
    if (!rune_linux_group_begin()) return 1;
    RuneLinuxWindowOptions options = {
        .width = 201, .height = 118, .minWidth = 1, .minHeight = 1, .resizable = true, .visible = true
    };
    RuneLinuxWindow *first = rune_linux_open("Rune frame ownership", options);
    RuneLinuxWindow *second = rune_linux_open("Rune sibling", options);
    Display *manager = XOpenDisplay(NULL);
    if (!first || !second || !manager) return 1;
    Window root = DefaultRootWindow(manager);
    Window client = managed_client(manager, first);
    Window sibling = managed_client(manager, second);
    if (!client || !sibling) return 1;
    Window old_frame = create_frame(manager, root);
    Window new_frame = create_frame(manager, root);
    Window container = create_frame(manager, root);

    reparent(manager, client, old_frame);
    int disabled = rune_linux_click_through(first, 1) && matches_input(manager, old_frame, 0);
    reparent(manager, client, new_frame);
    reparent(manager, old_frame, container);
    int moved = rune_linux_click_through(first, 1) &&
                matches_input(manager, old_frame, 1) && matches_input(manager, new_frame, 0);

    reparent(manager, sibling, new_frame);
    int shared = rune_linux_click_through(first, 1) && matches_input(manager, new_frame, 1);
    reparent(manager, sibling, root);
    int exclusive = rune_linux_click_through(first, 1) && matches_input(manager, new_frame, 0);

    reparent(manager, client, root);
    XDestroyWindow(manager, new_frame);
    XSync(manager, False);
    int destroyed = rune_linux_click_through(first, 0);
    reparent(manager, old_frame, root);
    reparent(manager, client, old_frame);
    int active = rune_linux_click_through(first, 1) && matches_input(manager, old_frame, 0);
    rune_linux_close(first);
    int closed = matches_input(manager, old_frame, 1);
    rune_linux_close(second);
    rune_linux_group_end();
    XCloseDisplay(manager);

    printf("X11 frame input disabled=%d moved=%d shared=%d exclusive=%d destroyed=%d active=%d closed=%d\n",
           disabled, moved, shared, exclusive, destroyed, active, closed);
    return !(disabled && moved && shared && exclusive && destroyed && active && closed);
}
