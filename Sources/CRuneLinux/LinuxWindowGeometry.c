#if defined(__linux__) && !defined(__ANDROID__)
#include "CRuneLinux.h"
#include "LinuxWindowGeometry.h"
#include <SDL2/SDL_syswm.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#ifdef SDL_VIDEO_DRIVER_X11
#include <X11/Xlib-xcb.h>
#include <X11/Xatom.h>
#include <X11/extensions/shape.h>
#include <xcb/xcb.h>
#endif
#ifdef SDL_VIDEO_DRIVER_WAYLAND
#include <wayland-client.h>
#endif

static SDL_Window *native_window(RuneLinuxWindow *host, SDL_SysWMinfo *info) {
    SDL_Window *window = host ? SDL_GetWindowFromID(rune_linux_id(host)) : NULL;
    SDL_VERSION(&info->version);
    return window && SDL_GetWindowWMInfo(window, info) ? window : NULL;
}

#ifdef SDL_VIDEO_DRIVER_X11
static int x11_placement(SDL_Window *window, const SDL_SysWMinfo *info, RuneLinuxPlacement *out,
                         uint32_t *outer_width, uint32_t *outer_height) {
    Display *display = info->info.x11.display;
    Window client = info->info.x11.window, child;
    XWindowAttributes attrs;
    if (!XGetWindowAttributes(display, client, &attrs) ||
        !XTranslateCoordinates(display, client, attrs.root, 0, 0, &out->content_x, &out->content_y, &child))
        return 0;

    int top = 0, left = 0, bottom = 0, right = 0;
    SDL_GetWindowBordersSize(window, &top, &left, &bottom, &right);
    int width = attrs.width + left + right;
    int height = attrs.height + top + bottom;
    out->x = out->content_x - left;
    out->y = out->content_y - top;
    if (!top && !left) {
        // Some reparenting window managers do not publish _NET_FRAME_EXTENTS.
        Window frame = client, root, parent, *children;
        unsigned count;
        while (XQueryTree(display, frame, &root, &parent, &children, &count)) {
            if (children) XFree(children);
            if (!parent || parent == root) break;
            frame = parent;
        }
        if (frame == client) {
            out->x -= attrs.border_width;
            out->y -= attrs.border_width;
            width = attrs.width + 2 * attrs.border_width;
            height = attrs.height + 2 * attrs.border_width;
        } else {
            XWindowAttributes outer;
            if (XGetWindowAttributes(display, frame, &outer)) {
                out->x = outer.x;
                out->y = outer.y;
                width = outer.width + 2 * outer.border_width;
                height = outer.height + 2 * outer.border_width;
            }
        }
    }
    if (outer_width) *outer_width = (uint32_t)width;
    if (outer_height) *outer_height = (uint32_t)height;
    out->width = (uint32_t)attrs.width;
    out->height = (uint32_t)attrs.height;
    Uint32 flags = SDL_GetWindowFlags(window);
    out->maximized = (flags & SDL_WINDOW_MAXIMIZED) != 0;
    out->minimized = (flags & SDL_WINDOW_MINIMIZED) != 0;
    out->fullscreen = (flags & SDL_WINDOW_FULLSCREEN) != 0;
    int logical = 0, pixels = 0;
    SDL_GetWindowSize(window, &logical, NULL);
    SDL_GL_GetDrawableSize(window, &pixels, NULL);
    out->scale = logical > 0 && pixels > 0 ? (double)pixels / logical : 1.0;

    int index = SDL_GetWindowDisplayIndex(window);
    SDL_Rect bounds;
    if (index >= 0 && SDL_GetDisplayBounds(index, &bounds) == 0 && bounds.w > 0 && bounds.h > 0) {
        out->display_x = bounds.x;
        out->display_y = bounds.y;
        out->display_width = (uint32_t)bounds.w;
        out->display_height = (uint32_t)bounds.h;
    }
    return 1;
}

typedef struct {
    Window frame;
    XRectangle *original;
    int count, ordering;
    bool default_shape;
} FrameInput;

// A reparenting WM may own a second input surface around the client. Only
// touch a dedicated frame. A tabbed frame or virtual desktop can contain
// other managed clients, whose input must keep working.
static bool has_property(Display *display, Window window, Atom atom) {
    if (atom == None) return false;
    Atom type;
    int format;
    unsigned long nitems, remaining;
    unsigned char *value = NULL;
    int status = XGetWindowProperty(display, window, atom, 0, 0, False, AnyPropertyType,
                                    &type, &format, &nitems, &remaining, &value);
    if (value) XFree(value);
    return status != Success || type != None;
}

static bool contains_managed_client(Display *display, Window window, Atom wm_state, unsigned depth) {
    if (has_property(display, window, wm_state) || depth == 0) return true;
    Window root, parent, *children;
    unsigned count;
    if (!XQueryTree(display, window, &root, &parent, &children, &count)) return true;
    bool managed = false;
    for (unsigned i = 0; i < count && !managed; ++i)
        managed = contains_managed_client(display, children[i], wm_state, depth - 1);
    if (children) XFree(children);
    return managed;
}

static bool is_virtual_root(Display *display, Window root, Window candidate) {
    if (has_property(display, candidate, XInternAtom(display, "__SWM_VROOT", True))) return true;
    Atom roots = XInternAtom(display, "_NET_VIRTUAL_ROOTS", True);
    if (roots == None) return false;
    Atom type;
    int format;
    unsigned long count, remaining;
    unsigned char *list = NULL;
    int status = XGetWindowProperty(display, root, roots, 0, 4096, False, XA_WINDOW,
                                    &type, &format, &count, &remaining, &list);
    bool found = status != Success || remaining != 0;
    if (type == XA_WINDOW && format == 32 && list) {
        for (unsigned long i = 0; i < count && !found; ++i)
            found = ((const Window *)list)[i] == candidate;
    }
    if (list) XFree(list);
    return found;
}

static Window dedicated_frame(Display *display, Window client) {
    Window root, frame, *children;
    unsigned count;
    if (!XQueryTree(display, client, &root, &frame, &children, &count)) return None;
    if (children) XFree(children);
    if (frame == None || frame == root) return None;
    Window parent;
    if (!XQueryTree(display, frame, &root, &parent, &children, &count)) return None;
    Atom wm_state = XInternAtom(display, "WM_STATE", True);
    bool dedicated = parent == root && has_property(display, client, wm_state) &&
        !has_property(display, frame, wm_state) && !is_virtual_root(display, root, frame);
    for (unsigned i = 0; i < count && dedicated; ++i)
        if (children[i] != client && contains_managed_client(display, children[i], wm_state, 8))
            dedicated = false;
    if (children) XFree(children);
    return dedicated ? frame : None;
}

static void restore_frame_input(Display *display, Window client, Atom owner, FrameInput *state) {
    // The original frame may have moved to another parent, been destroyed,
    // or had its XID reused. XCB delivers BadWindow to this request alone.
    xcb_connection_t *connection = XGetXCBConnection(display);
    XFlush(display);
    xcb_get_property_cookie_t query = xcb_get_property(connection, 0, state->frame, owner, XCB_ATOM_WINDOW, 0, 1);
    xcb_generic_error_t *error = NULL;
    xcb_get_property_reply_t *reply = xcb_get_property_reply(connection, query, &error);
    if (reply && reply->format == 32 && xcb_get_property_value_length(reply) == 4 &&
        *(const uint32_t *)xcb_get_property_value(reply) == client) {
        int count, ordering;
        XRectangle *current = XShapeGetRectangles(display, state->frame, ShapeInput, &count, &ordering);
        if (current) XFree(current);
        // A WM may have supplied a new shape itself during the reparent.
        if (count == 0) {
            if (state->default_shape)
                XShapeCombineMask(display, state->frame, ShapeInput, 0, 0, None, ShapeSet);
            else
                XShapeCombineRectangles(display, state->frame, ShapeInput, 0, 0, state->original,
                                        state->count, ShapeSet, state->ordering);
        }
        XDeleteProperty(display, state->frame, owner);
    }
    free(reply);
    free(error);
    if (state->original) XFree(state->original);
    *state = (FrameInput){0};
}

static void set_frame_input(Display *display, Window client, Window frame, FrameInput *state) {
    if (frame == state->frame) return;
    Atom owner = XInternAtom(display, "_RUNE_WINDOW_INPUT_SHAPE_OWNER", False);
    if (state->frame != None) restore_frame_input(display, client, owner, state);
    XWindowAttributes attrs;
    if (frame == None || has_property(display, frame, owner) || !XGetWindowAttributes(display, frame, &attrs))
        return;
    state->original = XShapeGetRectangles(display, frame, ShapeInput, &state->count, &state->ordering);
    int border = attrs.border_width;
    const XRectangle *rect = state->original;
    state->default_shape = state->count == 1 && rect && rect->x == -border && rect->y == -border &&
        rect->width == attrs.width + 2 * border && rect->height == attrs.height + 2 * border;
    state->frame = frame;
    XChangeProperty(display, frame, owner, XA_WINDOW, 32, PropModeReplace, (unsigned char *)&client, 1);
    XShapeCombineRectangles(display, frame, ShapeInput, 0, 0, NULL, 0, ShapeSet, Unsorted);
}

static const char *frame_input_key = "RuneX11InputShape";

static int x11_click_through(SDL_Window *window, const SDL_SysWMinfo *info, int on) {
    Display *display = info->info.x11.display;
    Window client = info->info.x11.window;
    int major, minor;
    if (!XShapeQueryVersion(display, &major, &minor) || major < 1 || (major == 1 && minor < 1)) {
        SDL_SetError("Pointer pass-through requires X Shape 1.1");
        return 0;
    }
    FrameInput *state = SDL_GetWindowData(window, frame_input_key);
    bool already_on = state != NULL;
    if (on && !state) {
        state = calloc(1, sizeof *state);
        if (!state) { SDL_OutOfMemory(); return 0; }
        SDL_SetWindowData(window, frame_input_key, state);
        if (SDL_GetWindowData(window, frame_input_key) != state) { free(state); return 0; }
    }
    // Keep the frame identity and saved input shape stable while the WM is
    // free to reparent or remove decorations between calls.
    XGrabServer(display);
    if (state) set_frame_input(display, client, on ? dedicated_frame(display, client) : None, state);
    if (on) {
        if (!already_on) XShapeCombineRectangles(display, client, ShapeInput, 0, 0, NULL, 0, ShapeSet, Unsorted);
    } else {
        XShapeCombineMask(display, client, ShapeInput, 0, 0, None, ShapeSet);
        if (state) {
            SDL_SetWindowData(window, frame_input_key, NULL);
            free(state);
        }
    }
    XUngrabServer(display);
    XFlush(display);
    return 1;
}
#endif

#ifdef SDL_VIDEO_DRIVER_WAYLAND
// The empty region is immutable and can be shared across every surface on SDL's display.
static struct wl_region *empty_region;

static void registry_global(void *data, struct wl_registry *registry, uint32_t name,
                            const char *interface, uint32_t version) {
    struct wl_compositor **compositor = data;
    if (!*compositor && version && strcmp(interface, wl_compositor_interface.name) == 0)
        *compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 1);
}

static void registry_removed(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}

static struct wl_region *make_empty_region(struct wl_display *display) {
    struct wl_event_queue *queue = wl_display_create_queue(display);
    if (!queue) return NULL;
    // The roundtrip only dispatches discovery events. SDL's input stays in its own queue.
    struct wl_display *wrapper = wl_proxy_create_wrapper(display);
    struct wl_compositor *compositor = NULL;
    struct wl_region *region = NULL;
    if (wrapper) {
        wl_proxy_set_queue((struct wl_proxy *)wrapper, queue);
        struct wl_registry *registry = wl_display_get_registry(wrapper);
        wl_proxy_wrapper_destroy(wrapper);
        if (registry) {
            static const struct wl_registry_listener listener = {registry_global, registry_removed};
            wl_registry_add_listener(registry, &listener, &compositor);
            if (wl_display_roundtrip_queue(display, queue) >= 0 && compositor) {
                region = wl_compositor_create_region(compositor);
                if (region) wl_proxy_set_queue((struct wl_proxy *)region, NULL);
            }
            if (compositor) wl_compositor_destroy(compositor);
            wl_registry_destroy(registry);
        }
    }
    wl_event_queue_destroy(queue);
    return region;
}

static int wayland_click_through(const SDL_SysWMinfo *info, int on) {
    struct wl_display *display = info->info.wl.display;
    struct wl_surface *surface = info->info.wl.surface;
    if (!surface || !display) {
        SDL_SetError("The Wayland window has no surface");
        return 0;
    }
    if (on && !empty_region && !(empty_region = make_empty_region(display))) {
        SDL_SetError("Could not create a Wayland input region");
        return 0;
    }
    wl_surface_set_input_region(surface, on ? empty_region : NULL);
    wl_surface_commit(surface);
    if (wl_display_flush(display) < 0 && errno != EAGAIN) {
        SDL_SetError("Flushing the Wayland input region failed: %s", strerror(errno));
        return 0;
    }
    return 1;
}
#endif

void rune_linux_release_input_region(void) {
#ifdef SDL_VIDEO_DRIVER_WAYLAND
    if (empty_region) wl_region_destroy(empty_region);
    empty_region = NULL;
#endif
}

void rune_linux_refresh_frame_input(SDL_Window *window, bool closing) {
#ifdef SDL_VIDEO_DRIVER_X11
    if (window && SDL_GetWindowData(window, frame_input_key)) {
        SDL_SysWMinfo info = {0};
        SDL_VERSION(&info.version);
        if (SDL_GetWindowWMInfo(window, &info) && info.subsystem == SDL_SYSWM_X11)
            x11_click_through(window, &info, !closing);
    }
#else
    (void)window; (void)closing;
#endif
}

int rune_linux_frame_geometry(RuneLinuxWindow *host, RuneLinuxPlacement *out,
                              uint32_t *outer_width, uint32_t *outer_height) {
    SDL_SysWMinfo info = {0};
    SDL_Window *window = native_window(host, &info);
    if (!window || !out) return 0;
    *out = (RuneLinuxPlacement){0};
#ifdef SDL_VIDEO_DRIVER_X11
    if (info.subsystem == SDL_SYSWM_X11) return x11_placement(window, &info, out, outer_width, outer_height);
#endif
    return 0;
}

int rune_linux_placement(RuneLinuxWindow *host, RuneLinuxPlacement *out) {
    return rune_linux_frame_geometry(host, out, NULL, NULL);
}

int rune_linux_content_origin(RuneLinuxWindow *host, int32_t *x, int32_t *y, int32_t *primary_x, int32_t *primary_y) {
#ifdef SDL_VIDEO_DRIVER_X11
    SDL_SysWMinfo info = {0};
    SDL_Window *window = native_window(host, &info);
    if (window && info.subsystem == SDL_SYSWM_X11) {
        Display *display = info.info.x11.display;
        XWindowAttributes attrs;
        Window child;
        if (!XGetWindowAttributes(display, info.info.x11.window, &attrs) ||
            !XTranslateCoordinates(display, info.info.x11.window, attrs.root, 0, 0, x, y, &child)) return 0;
        SDL_Rect primary = {0};
        SDL_GetDisplayBounds(0, &primary);
        *primary_x = primary.x;
        *primary_y = primary.y;
        return 1;
    }
#endif
    return 0;
}

void rune_linux_set_position(RuneLinuxWindow *host, int x, int y) {
    SDL_Window *window = SDL_GetWindowFromID(rune_linux_id(host));
    int top = 0, left = 0;
    if (SDL_GetWindowBordersSize(window, &top, &left, NULL, NULL) == 0) {
        // SDL's X11 backend subtracts its own cached border extents before the
        // move. A reparenting WM can expose a frame to XQueryTree but no SDL extents.
        int64_t cx = (int64_t)x + left;
        int64_t cy = (int64_t)y + top;
        x = (int)SDL_clamp(cx, INT_MIN, INT_MAX);
        y = (int)SDL_clamp(cy, INT_MIN, INT_MAX);
    }
    SDL_SetWindowPosition(window, x, y);
}

int rune_linux_click_through(RuneLinuxWindow *host, int on) {
    SDL_SysWMinfo info = {0};
    SDL_Window *window = native_window(host, &info);
    if (!window) return 0;
#ifdef SDL_VIDEO_DRIVER_X11
    if (info.subsystem == SDL_SYSWM_X11) return x11_click_through(window, &info, on);
#endif
#ifdef SDL_VIDEO_DRIVER_WAYLAND
    if (info.subsystem == SDL_SYSWM_WAYLAND) return wayland_click_through(&info, on);
#endif
    SDL_SetError("The SDL video driver does not support pointer pass-through");
    return 0;
}

#endif
