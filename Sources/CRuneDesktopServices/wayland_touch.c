#if defined(__linux__) && !defined(__ANDROID__)
#include "wayland_touch.h"
#include "RuneDesktopServices.h"
#include <SDL.h>
#include <SDL_syswm.h>
#include <glib.h>
#include <wayland-client.h>
#include <string.h>

/* SDL2 drops wl_touch.cancel and may share touch state across seats. Use
   each native seat's contact stream on SDL's default queue to preserve order
   with the rest of its window events. */
enum TouchPhase { TouchDown, TouchMotion, TouchUp, TouchCancel };
struct Contact {
    uint32_t window;
    wl_fixed_t x, y;
};
struct TouchSeat {
    uint32_t name;
    struct wl_seat *seat;
    struct wl_touch *touch;
    GHashTable *contacts; /* protocol ID -> struct Contact */
};

static struct wl_registry *registry;
static gboolean ready;
static GList *seats;
static GHashTable *windows; /* connected SDL window IDs */
static RuneWaylandTouchSink deliver;

void rune_desktop_linux_set_touch_sink(RuneWaylandTouchSink sink) { deliver = sink; }

int rune_desktop_linux_has_native_touch(uint32_t window_id) {
    return ready && deliver && g_hash_table_contains(windows, GUINT_TO_POINTER(window_id));
}

static void emit(struct TouchSeat *seat, int32_t id, enum TouchPhase phase, const struct Contact *c) {
    if (deliver && g_hash_table_contains(windows, GUINT_TO_POINTER(c->window)))
        deliver(c->window, seat->name, id, phase, wl_fixed_to_double(c->x), wl_fixed_to_double(c->y));
}

static void down(void *data, struct wl_touch *touch, uint32_t serial, uint32_t time,
                 struct wl_surface *surface, int32_t id, wl_fixed_t x, wl_fixed_t y) {
    (void)touch; (void)serial; (void)time;
    struct TouchSeat *seat = data;
    /* SDL may recreate its wl_surface when creating or replacing a renderer. */
    GHashTableIter it;
    gpointer window_id;
    g_hash_table_iter_init(&it, windows);
    while (g_hash_table_iter_next(&it, &window_id, NULL)) {
        SDL_Window *window = SDL_GetWindowFromID(GPOINTER_TO_UINT(window_id));
        SDL_SysWMinfo info;
        SDL_VERSION(&info.version);
        if (window && SDL_GetWindowWMInfo(window, &info) && info.subsystem == SDL_SYSWM_WAYLAND &&
            info.info.wl.surface == surface) {
            struct Contact *c = g_new(struct Contact, 1);
            *c = (struct Contact){ .window = GPOINTER_TO_UINT(window_id), .x = x, .y = y };
            g_hash_table_replace(seat->contacts, GINT_TO_POINTER(id), c);
            emit(seat, id, TouchDown, c);
            break;
        }
    }
}
static void up(void *data, struct wl_touch *touch, uint32_t serial, uint32_t time, int32_t id) {
    (void)touch; (void)serial; (void)time;
    struct TouchSeat *seat = data;
    struct Contact *c = g_hash_table_lookup(seat->contacts, GINT_TO_POINTER(id));
    if (!c) return;
    emit(seat, id, TouchUp, c);
    g_hash_table_remove(seat->contacts, GINT_TO_POINTER(id));
}
static void motion(void *data, struct wl_touch *touch, uint32_t time, int32_t id, wl_fixed_t x, wl_fixed_t y) {
    (void)touch; (void)time;
    struct TouchSeat *seat = data;
    struct Contact *c = g_hash_table_lookup(seat->contacts, GINT_TO_POINTER(id));
    if (!c) return;
    c->x = x; c->y = y;
    emit(seat, id, TouchMotion, c);
}
static void frame(void *data, struct wl_touch *touch) { (void)data; (void)touch; }
static gboolean same_window(gpointer key, gpointer value, gpointer window) {
    (void)key;
    return ((struct Contact *)value)->window == GPOINTER_TO_UINT(window);
}
static void cancel(void *data, struct wl_touch *touch) {
    (void)touch;
    struct TouchSeat *seat = data;
    GHashTableIter it;
    gpointer id, contact;
    g_hash_table_iter_init(&it, seat->contacts);
    while (g_hash_table_iter_next(&it, &id, &contact)) {
        emit(seat, GPOINTER_TO_INT(id), TouchCancel, contact);
        g_hash_table_iter_remove(&it);
    }
}
static const struct wl_touch_listener touch_events = {
    .down = down, .up = up, .motion = motion, .frame = frame, .cancel = cancel
};
static void release_touch(struct TouchSeat *seat) {
    if (!seat->touch) return;
    cancel(seat, seat->touch);
    if (wl_touch_get_version(seat->touch) >= WL_TOUCH_RELEASE_SINCE_VERSION) wl_touch_release(seat->touch);
    else wl_touch_destroy(seat->touch);
    seat->touch = NULL;
}
static void capabilities(void *data, struct wl_seat *proxy, uint32_t flags) {
    struct TouchSeat *seat = data;
    if ((flags & WL_SEAT_CAPABILITY_TOUCH) && !seat->touch) {
        seat->touch = wl_seat_get_touch(proxy);
        if (seat->touch) wl_touch_add_listener(seat->touch, &touch_events, seat);
    } else if (!(flags & WL_SEAT_CAPABILITY_TOUCH)) release_touch(seat);
}
static void seat_name(void *data, struct wl_seat *seat, const char *name) { (void)data; (void)seat; (void)name; }
static const struct wl_seat_listener seat_events = {.capabilities = capabilities, .name = seat_name};
static void add_global(void *data, struct wl_registry *r, uint32_t name, const char *type, uint32_t version) {
    (void)data;
    if (strcmp(type, wl_seat_interface.name)) return;
    struct TouchSeat *seat = g_new0(struct TouchSeat, 1);
    seat->seat = wl_registry_bind(r, name, &wl_seat_interface, MIN(version, 5u));
    if (!seat->seat) { g_free(seat); return; }
    seat->name = name;
    seat->contacts = g_hash_table_new_full(NULL, NULL, NULL, g_free);
    seats = g_list_prepend(seats, seat);
    wl_seat_add_listener(seat->seat, &seat_events, seat);
}
static void free_seat(gpointer data) {
    struct TouchSeat *seat = data;
    release_touch(seat);
    if (wl_seat_get_version(seat->seat) >= WL_SEAT_RELEASE_SINCE_VERSION) wl_seat_release(seat->seat);
    else wl_seat_destroy(seat->seat);
    g_hash_table_unref(seat->contacts);
    g_free(seat);
}
static void remove_global(void *data, struct wl_registry *r, uint32_t name) {
    (void)data; (void)r;
    for (GList *l = seats; l; l = l->next) {
        struct TouchSeat *seat = l->data;
        if (seat->name == name) {
            seats = g_list_delete_link(seats, l);
            free_seat(seat);
            return;
        }
    }
}
static const struct wl_registry_listener registry_events = {.global = add_global, .global_remove = remove_global};

void rune_wayland_watch_touch_window(uint32_t id) {
    if (!deliver || !id) return;
    SDL_Window *window = SDL_GetWindowFromID(id);
    SDL_SysWMinfo info;
    SDL_VERSION(&info.version);
    if (!window || !SDL_GetWindowWMInfo(window, &info) || info.subsystem != SDL_SYSWM_WAYLAND) return;
    if (!windows) windows = g_hash_table_new(NULL, NULL);
    g_hash_table_add(windows, GUINT_TO_POINTER(id));
    if (registry) return;
    struct wl_display *display = info.info.wl.display;
    registry = wl_display_get_registry(display);
    if (!registry) return;
    wl_registry_add_listener(registry, &registry_events, NULL);
    /* Discover seats, then their capabilities, before showing the first window. */
    if (wl_display_roundtrip(display) < 0 || wl_display_roundtrip(display) < 0) {
        rune_wayland_close_touch_windows();
        return;
    }
    wl_display_flush(display);
    ready = TRUE;
}
void rune_desktop_linux_forget_touch_window(uint32_t id) {
    if (!windows) return;
    gpointer window = GUINT_TO_POINTER(id);
    g_hash_table_remove(windows, window);
    for (GList *l = seats; l; l = l->next)
        g_hash_table_foreach_remove(((struct TouchSeat *)l->data)->contacts, same_window, window);
}
void rune_wayland_close_touch_windows(void) {
    if (!windows) return;
    ready = FALSE;
    g_hash_table_remove_all(windows);
    g_list_free_full(seats, free_seat);
    seats = NULL;
    if (registry) wl_registry_destroy(registry);
    registry = NULL;
    g_clear_pointer(&windows, g_hash_table_unref);
}
#endif
