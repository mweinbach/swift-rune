#if defined(__linux__) && !defined(__ANDROID__)
#include "LinuxNotificationWindow.h"
#include <SDL2/SDL_syswm.h>
#include <stdbool.h>
#include <string.h>
#ifdef SDL_VIDEO_DRIVER_WAYLAND
#include <wayland-client.h>

/* Generated protocol metadata; private symbol names also allow static SDL linking. */
#define xdg_activation_v1_interface rune_xdg_activation_interface
#define xdg_activation_token_v1_interface rune_xdg_activation_token_interface
#include "WaylandActivationProtocol.inc"
enum { ActivationDestroy = 0, ActivationRequest = 2 };

static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    struct wl_proxy **activation = data;
    if (!*activation && version && strcmp(interface, xdg_activation_v1_interface.name) == 0)
        *activation = wl_registry_bind(registry, name, &xdg_activation_v1_interface, 1);
}

static void removed(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}

static bool wayland_activate(SDL_Window *window, const char *token) {
    SDL_SysWMinfo info = {0};
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(window, &info) || info.subsystem != SDL_SYSWM_WAYLAND) return false;

    struct wl_display *display = info.info.wl.display;
    struct wl_event_queue *queue = wl_display_create_queue(display);
    if (!queue) return false;
    /* Discover the global on a private queue so this roundtrip never dispatches
     * SDL input (or another library's callbacks) reentrantly. */
    struct wl_display *wrapper = wl_proxy_create_wrapper(display);
    if (!wrapper) { wl_event_queue_destroy(queue); return false; }
    wl_proxy_set_queue((struct wl_proxy *)wrapper, queue);
    struct wl_registry *registry = wl_display_get_registry(wrapper);
    wl_proxy_wrapper_destroy(wrapper);
    struct wl_proxy *activation = NULL;
    if (registry) {
        static const struct wl_registry_listener listener = { global, removed };
        wl_registry_add_listener(registry, &listener, &activation);
        wl_display_roundtrip_queue(display, queue);
        wl_registry_destroy(registry);
    }

    bool sent = activation != NULL;
    if (activation) {
        wl_proxy_marshal(activation, ActivationRequest, token, info.info.wl.surface);
        wl_proxy_marshal(activation, ActivationDestroy);
        wl_proxy_destroy(activation);
        wl_display_flush(display);
    }
    wl_event_queue_destroy(queue);
    return sent;
}
#endif

#ifdef SDL_VIDEO_DRIVER_X11
/* X11 startup-notification IDs end in _TIME<timestamp>. The WM uses that
 * timestamp to distinguish a notification click from an unsolicited raise. */
static bool x11_activate(SDL_Window *window, const char *token) {
    const char *suffix = strrchr(token, '_');
    if (!suffix || strncmp(suffix, "_TIME", 5) != 0) return false;
    uint64_t timestamp = 0;
    for (const char *p = suffix + 5; *p; ++p) {
        if (*p < '0' || *p > '9') return false;
        timestamp = timestamp * 10 + (unsigned)(*p - '0');
        if (timestamp > UINT32_MAX) return false;
    }
    if (!timestamp) return false;
    SDL_SysWMinfo info = {0};
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(window, &info) || info.subsystem != SDL_SYSWM_X11) return false;
    Display *display = info.info.x11.display;
    XWindowAttributes attributes;
    if (!XGetWindowAttributes(display, info.info.x11.window, &attributes)) return false;
    Atom active = XInternAtom(display, "_NET_ACTIVE_WINDOW", True);
    if (active == None) return false;
    XEvent event = {0};
    event.xclient.type = ClientMessage;
    event.xclient.window = info.info.x11.window;
    event.xclient.message_type = active;
    event.xclient.format = 32;
    event.xclient.data.l[0] = 1; /* Application (EWMH 1.5). */
    event.xclient.data.l[1] = (long)timestamp;
    int sent = XSendEvent(display, attributes.root, False,
                          SubstructureRedirectMask | SubstructureNotifyMask, &event);
    XFlush(display);
    return sent != 0;
}
#endif

void rune_linux_activate_notification_window(SDL_Window *window, const char *token) {
    SDL_RestoreWindow(window);
    SDL_ShowWindow(window);
#ifdef SDL_VIDEO_DRIVER_WAYLAND
    if (token && wayland_activate(window, token)) return;
#endif
#ifdef SDL_VIDEO_DRIVER_X11
    if (token && x11_activate(window, token)) return;
#endif
    (void)token;
    SDL_RaiseWindow(window);
}
#endif
