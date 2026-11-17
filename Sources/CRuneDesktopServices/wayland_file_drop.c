#if defined(__linux__) && !defined(__ANDROID__)
#define _GNU_SOURCE
#include "wayland_file_drop.h"
#include "services_internal.h"
#include "wayland_drag.h"
#include <SDL.h>
#include <SDL_syswm.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

#define MAX_URI_LIST (4u * 1024u * 1024u)
struct ReadDrop {
    struct wl_data_offer *offer;
    int fd;
    GByteArray *bytes;
    gint64 deadline;
    float x, y;
};
struct DropWindow {
    uint32_t id;
    int hovering;
    uint32_t marker;
    GQueue reads;
    struct wl_data_offer *taken;
};
static GList *windows;
static uint32_t event_type;
static struct DropWindow *by_id(uint32_t id) {
    for (GList *it = windows; it; it = it->next) {
        struct DropWindow *w = it->data;
        if (w->id == id) return w;
    }
    return NULL;
}
uint32_t rune_wayland_window_id(struct wl_surface *surface) {
    if (!surface) return 0;
    for (GList *it = windows; it; it = it->next) {
        struct DropWindow *w = it->data;
        SDL_Window *window = SDL_GetWindowFromID(w->id);
        SDL_SysWMinfo info;
        SDL_VERSION(&info.version);
        if (window && SDL_GetWindowWMInfo(window, &info) && info.subsystem == SDL_SYSWM_WAYLAND &&
            info.info.wl.surface == surface) return w->id;
    }
    return 0;
}
static void dispose_read(struct ReadDrop *r) {
    close(r->fd);
    if (r->offer) wl_data_offer_destroy(r->offer);
    g_byte_array_unref(r->bytes);
    g_free(r);
}
void rune_wayland_drop_register(uint32_t id) {
    if (by_id(id)) return;
    if (!event_type) event_type = SDL_RegisterEvents(1);
    struct DropWindow *w = g_new0(struct DropWindow, 1);
    w->id = id;
    g_queue_init(&w->reads);
    windows = g_list_prepend(windows, w);
}
void rune_wayland_drop_unregister(uint32_t id) {
    struct DropWindow *w = by_id(id);
    if (!w) return;
    windows = g_list_remove(windows, w);
    struct ReadDrop *r;
    while ((r = g_queue_pop_head(&w->reads))) dispose_read(r);
    if (w->taken) wl_data_offer_destroy(w->taken);
    g_free(w);
    if (!windows) event_type = 0;
}
uint32_t rune_wayland_drop_accept(struct wl_surface *surface, struct wl_data_offer *offer,
                                  uint32_t serial, int uri_list, int allowed) {
    if (!offer || !uri_list || !allowed || wl_data_offer_get_version(offer) < 3) return 0;
    struct DropWindow *w = by_id(rune_wayland_window_id(surface));
    if (w) {
        wl_data_offer_accept(offer, serial, "text/uri-list");
        /* Rune gives applications URLs and leaves the source files intact. */
        wl_data_offer_set_actions(offer, WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY, WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY);
        w->hovering = 1;
        return w->id;
    }
    return 0;
}
void rune_wayland_drop_leave(uint32_t id) {
    struct DropWindow *w = by_id(id);
    if (w) w->hovering = 0;
}
void rune_wayland_drop_receive(uint32_t id, struct wl_data_offer *offer, float x, float y) {
    struct DropWindow *w = by_id(id);
    int fds[2];
    if (!w || g_queue_get_length(&w->reads) >= 8 || pipe2(fds, O_CLOEXEC)) {
        wl_data_offer_destroy(offer);
        return;
    }
    if (fcntl(fds[0], F_SETFL, O_NONBLOCK) < 0) {
        close(fds[0]); close(fds[1]); wl_data_offer_destroy(offer);
        return;
    }
    struct ReadDrop *r = g_new0(struct ReadDrop, 1);
    r->offer = offer; r->x = x; r->y = y; r->fd = fds[0];
    r->bytes = g_byte_array_new();
    r->deadline = g_get_monotonic_time() + 5000000;
    wl_data_offer_receive(offer, "text/uri-list", fds[1]);
    close(fds[1]);
    g_queue_push_tail(&w->reads, r);
    w->hovering = 0;
    /* All SDL events for this offer precede this private queue marker. SDL's
       host discards the marker normally. It cannot mute a later SDL-only drop. */
    SDL_Event marker = {0};
    marker.type = event_type;
    marker.user.windowID = id;
    marker.user.code = (Sint32)++w->marker;
    if (event_type != (uint32_t)-1) SDL_PushEvent(&marker);
}
int rune_wayland_owns_drop(uint32_t id) {
    struct DropWindow *w = by_id(id);
    if (!w) return 0;
    struct RuneWaylandDragContext seat;
    if (!rune_wayland_drag_context(id, &seat)) return 0;
    if (w->hovering) return 1;
    if (!w->marker || event_type == (uint32_t)-1) return 0;
    int count = SDL_PeepEvents(NULL, 0, SDL_PEEKEVENT, event_type, event_type);
    if (count <= 0) return 0;
    SDL_Event *markers = g_new(SDL_Event, count);
    count = SDL_PeepEvents(markers, count, SDL_PEEKEVENT, event_type, event_type);
    int found = 0;
    for (int i = 0; i < count; ++i)
        if (markers[i].user.windowID == id && (uint32_t)markers[i].user.code == w->marker) found = 1;
    g_free(markers);
    return found;
}
RuneMimeData *rune_wayland_take_drop(uint32_t id, float *x, float *y) {
    struct DropWindow *w = by_id(id);
    struct ReadDrop *r = w && !w->taken ? g_queue_peek_head(&w->reads) : NULL;
    if (!r) return NULL;
    RuneMimeData *out = NULL;
    uint8_t bytes[16384];
    while (g_get_monotonic_time() < r->deadline) {
        ssize_t n = read(r->fd, bytes, sizeof bytes);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return NULL;
        if (n == 0) {
            out = rune_mime_create();
            if (out && r->bytes->len && rune_mime_add(out, "text/uri-list", r->bytes->data, r->bytes->len)) {
                if (x) *x = r->x;
                if (y) *y = r->y;
                w->taken = r->offer;
                r->offer = NULL;
            } else { rune_mime_free(out); out = NULL; }
            break;
        }
        if (n < 0 || (size_t)n > MAX_URI_LIST - r->bytes->len) break;
        g_byte_array_append(r->bytes, bytes, (guint)n);
    }
    g_queue_pop_head(&w->reads);
    dispose_read(r);
    return out;
}
void rune_wayland_finish_drop(uint32_t id, int accepted) {
    struct DropWindow *w = by_id(id);
    if (w && w->taken) {
        if (accepted) wl_data_offer_finish(w->taken);
        wl_data_offer_destroy(w->taken);
        w->taken = NULL;
    }
}
#endif
