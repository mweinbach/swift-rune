#if defined(__linux__) && !defined(__ANDROID__)
#define _GNU_SOURCE
#include "wayland_clipboard.h"
#include "wayland_primary.h"
#include "wayland_drag.h"
#include "wayland_file_drop.h"
#include <SDL_syswm.h>
#include <SDL.h>
#include <SDL_clipboard.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include <glib.h>
#include <linux/input-event-codes.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/mman.h>
#include <unistd.h>

#define TOKEN_PREFIX "application/x-rune-selection-"
struct RuneWaylandBoard;
struct Source {
    struct RuneWaylandBoard *board;
    struct wl_data_source *proxy;
    GHashTable *formats; /* MIME -> GBytes, shared with asynchronous sends */
    char *token;
};
struct Offer {
    struct wl_data_offer *proxy;
    GPtrArray *formats;
    uint32_t action;
};
struct RuneWaylandBoard {
    struct wl_display *display; /* borrowed from SDL */
    struct wl_event_queue *queue;
    struct wl_registry *registry;
    struct wl_compositor *compositor;
    struct wl_shm *shm;
    struct wl_seat *seat;
    struct wl_keyboard *keyboard;
    int keymap_fd;
    uint32_t keymap_size, layout_group;
    struct xkb_state *key_state;
    struct wl_pointer *pointer;
    struct wl_touch *touch;
    struct wl_data_device_manager *manager;
    struct wl_data_device *device;
    struct RuneWaylandPrimary *primary;
    struct RunePrimaryGlobals primary_globals;
    struct Offer *selection, *drag;
    uint32_t drop_window;
    float drop_x, drop_y;
    GList *offers;
    struct Source *source;
    struct RuneWaylandDropStatus target;
    struct wl_surface *pointer_focus, *pointer_origin, *touch_origin;
    uint32_t pointer_serial, pointer_button, touch_serial;
    wl_fixed_t pointer_x, pointer_y;
    int32_t touch_id;
    uint32_t serial;
    int64_t revision;
};

static int ready_fd(int fd, short events, gint64 deadline) {
    struct pollfd f = {fd, events, 0};
    for (;;) {
        gint64 remaining = (deadline - g_get_monotonic_time() + 999) / 1000;
        if (remaining <= 0) return 0;
        int n = poll(&f, 1, (int)remaining);
        if (n >= 0) return n && !(f.revents & POLLNVAL);
        if (errno != EINTR) return 0;
    }
}
struct Transfer { int fd; GBytes *bytes; };
static gpointer send_bytes(gpointer data) {
    struct Transfer *job = data;
    sigset_t blocked;
    sigemptyset(&blocked); sigaddset(&blocked, SIGPIPE);
    pthread_sigmask(SIG_BLOCK, &blocked, NULL);
    gsize size;
    const uint8_t *bytes = g_bytes_get_data(job->bytes, &size);
    size_t offset = 0;
    int flags = fcntl(job->fd, F_GETFL);
    if (flags != -1 && fcntl(job->fd, F_SETFL, flags | O_NONBLOCK) == 0) {
        gint64 deadline = g_get_monotonic_time() + 5000000;
        while (offset < size && ready_fd(job->fd, POLLOUT, deadline)) {
            ssize_t sent = write(job->fd, bytes + offset, size - offset);
            if (sent > 0) offset += (size_t)sent;
            else if (!sent || (errno != EINTR && errno != EAGAIN)) break;
        }
    }
    close(job->fd);
    g_bytes_unref(job->bytes);
    g_free(job);
    return NULL;
}
static void source_target(void *data, struct wl_data_source *proxy, const char *type) {
    (void)data; (void)proxy; (void)type;
}
void rune_wayland_send_bytes(int fd, GBytes *bytes) {
    if (!bytes) { close(fd); return; }
    struct Transfer *job = g_new(struct Transfer, 1);
    job->fd = fd; job->bytes = g_bytes_ref(bytes);
    GThread *thread = g_thread_try_new("rune-transfer", send_bytes, job, NULL);
    if (thread) g_thread_unref(thread);
    else { close(fd); g_bytes_unref(job->bytes); g_free(job); }
}
static void source_send(void *data, struct wl_data_source *proxy, const char *type, int32_t fd) {
    (void)proxy;
    struct Source *source = data;
    rune_wayland_send_bytes(fd, g_hash_table_lookup(source->formats, type));
}
static void free_source(struct Source *src) {
    if (!src) return;
    wl_data_source_destroy(src->proxy);
    g_hash_table_unref(src->formats);
    g_free(src->token);
    g_free(src);
}
static void source_cancelled(void *data, struct wl_data_source *proxy) {
    (void)proxy;
    struct Source *src = data;
    if (src->board->source == src) { src->board->source = NULL; ++src->board->revision; }
    free_source(src);
}
static const struct wl_data_source_listener source_events = {
    .target = source_target, .send = source_send, .cancelled = source_cancelled
};
static void offer_type(void *data, struct wl_data_offer *proxy, const char *type) {
    (void)proxy;
    struct Offer *offer = data;
    /* Writers add a text alias, a secret hint and an ownership token in
       addition to the public MIME entries. */
    if (offer && offer->formats->len < RUNE_CLIPBOARD_TYPES + 3 && strlen(type) <= 1024)
        g_ptr_array_add(offer->formats, g_strdup(type));
}
static void offer_action(void *data, struct wl_data_offer *proxy, uint32_t action) {
    (void)proxy;
    if (data) ((struct Offer *)data)->action = action;
}
static void offer_actions(void *data, struct wl_data_offer *proxy, uint32_t actions) {
    (void)data; (void)proxy; (void)actions;
}
static const struct wl_data_offer_listener offer_events = {
    .offer = offer_type, .source_actions = offer_actions, .action = offer_action
};
static void free_offer(struct RuneWaylandBoard *b, struct Offer *offer) {
    if (!offer) return;
    b->offers = g_list_remove(b->offers, offer);
    if (offer->proxy) wl_data_offer_destroy(offer->proxy);
    g_ptr_array_unref(offer->formats);
    g_free(offer);
}
static void got_offer(void *data, struct wl_data_device *device, struct wl_data_offer *proxy) {
    (void)device;
    struct RuneWaylandBoard *b = data;
    struct Offer *offer = g_new0(struct Offer, 1);
    offer->proxy = proxy; offer->formats = g_ptr_array_new_with_free_func(g_free);
    b->offers = g_list_prepend(b->offers, offer);
    wl_data_offer_add_listener(proxy, &offer_events, offer);
}
static void drag_enter(void *data, struct wl_data_device *device, uint32_t serial, struct wl_surface *surface,
                       wl_fixed_t x, wl_fixed_t y, struct wl_data_offer *proxy) {
    (void)device;
    struct RuneWaylandBoard *b = data;
    if (b->drag) free_offer(b, b->drag);
    b->drag = proxy ? wl_data_offer_get_user_data(proxy) : NULL;
    b->target.over_local = 1;
    rune_wayland_drop_leave(b->drop_window);
    int uri_list = b->drag && g_ptr_array_find_with_equal_func(b->drag->formats, "text/uri-list", g_str_equal, NULL);
    b->drop_window = rune_wayland_drop_accept(surface, proxy, serial, uri_list,
        !b->target.active || b->target.within_app);
    b->drop_x = wl_fixed_to_double(x); b->drop_y = wl_fixed_to_double(y);
}
static void drag_leave(void *data, struct wl_data_device *device) {
    (void)device;
    struct RuneWaylandBoard *b = data;
    free_offer(b, b->drag);
    b->drag = NULL;
    b->target.over_local = 0;
    rune_wayland_drop_leave(b->drop_window);
    b->drop_window = 0;
}
static void drag_motion(void *d, struct wl_data_device *p, uint32_t t, wl_fixed_t x, wl_fixed_t y) {
    (void)p; (void)t;
    struct RuneWaylandBoard *b = d;
    b->drop_x = wl_fixed_to_double(x); b->drop_y = wl_fixed_to_double(y);
}
static void drag_drop(void *d, struct wl_data_device *p) {
    (void)p;
    struct RuneWaylandBoard *b = d;
    ++b->target.local_drops;
    if (b->drop_window && b->drag && b->drag->action == WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY) {
        struct wl_data_offer *proxy = b->drag->proxy;
        b->drag->proxy = NULL;
        wl_data_offer_set_user_data(proxy, NULL);
        rune_wayland_drop_receive(b->drop_window, proxy, b->drop_x, b->drop_y);
        wl_display_flush(b->display);
    }
}
static int is_own(const struct RuneWaylandBoard *b) {
    return b->selection && b->source &&
        g_ptr_array_find_with_equal_func(b->selection->formats, b->source->token, g_str_equal, NULL);
}
static void new_selection(void *data, struct wl_data_device *device, struct wl_data_offer *proxy) {
    (void)device;
    struct RuneWaylandBoard *b = data;
    free_offer(b, b->selection);
    b->selection = proxy ? wl_data_offer_get_user_data(proxy) : NULL;
    /* Losing keyboard focus withdraws our offer but doesn't cancel our source. */
    if (!b->source || (b->selection && !is_own(b))) ++b->revision;
}
static const struct wl_data_device_listener device_events = {
    .data_offer = got_offer, .enter = drag_enter, .leave = drag_leave,
    .motion = drag_motion, .drop = drag_drop, .selection = new_selection
};

/* A second binding to SDL's seat receives the same input serials without
   taking over the host's keyboard, pointer, drag, or text input listeners. */
static void keymap(void *d, struct wl_keyboard *k, uint32_t f, int32_t fd, uint32_t n) {
    (void)k;
    struct RuneWaylandBoard *b = d;
    if (b->keymap_fd >= 0) close(b->keymap_fd);
    g_clear_pointer(&b->key_state, xkb_state_unref);
    b->keymap_fd = -1;
    if (f == WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 && n > 1) {
        b->keymap_fd = fd;
        b->keymap_size = n;
    } else { close(fd); }
}
static void key_enter(void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *w, struct wl_array *keys) {
    (void)k; (void)w; (void)keys; ((struct RuneWaylandBoard *)d)->serial = s;
}
static void key_leave(void *d, struct wl_keyboard *k, uint32_t s, struct wl_surface *w) {
    (void)d; (void)k; (void)s; (void)w;
}
static void key_press(void *d, struct wl_keyboard *k, uint32_t s, uint32_t t, uint32_t key, uint32_t state) {
    (void)k; (void)t;
    struct RuneWaylandBoard *b = d;
    b->serial = s;
    if (key == KEY_ESC && state == WL_KEYBOARD_KEY_STATE_PRESSED)
        rune_wayland_drag_escape(&b->target);
}
static void modifiers(void *d, struct wl_keyboard *k, uint32_t s, uint32_t a, uint32_t b, uint32_t c, uint32_t g) {
    (void)k; (void)s; (void)a; (void)b; (void)c;
    ((struct RuneWaylandBoard *)d)->layout_group = g;
}
static const struct wl_keyboard_listener key_events = {
    .keymap = keymap, .enter = key_enter, .leave = key_leave, .key = key_press, .modifiers = modifiers
};
static int SDLCALL count_presses(void *data, SDL_Event *event) {
    if (event->type == SDL_MOUSEBUTTONDOWN && event->button.button == SDL_BUTTON_LEFT &&
        event->button.which != SDL_TOUCH_MOUSEID)
        SDL_AtomicAdd(&((struct RuneWaylandBoard *)data)->target.left_presses, 1);
    return 1;
}
static void pointer_enter(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *w, wl_fixed_t x, wl_fixed_t y) {
    (void)p; (void)s;
    struct RuneWaylandBoard *b = d;
    b->pointer_focus = w; b->pointer_x = x; b->pointer_y = y;
}
static void pointer_leave(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *w) {
    (void)p; (void)s; (void)w;
    struct RuneWaylandBoard *b = d;
    b->pointer_focus = NULL; b->pointer_serial = 0;
}
static void pointer_motion(void *d, struct wl_pointer *p, uint32_t t, wl_fixed_t x, wl_fixed_t y) {
    (void)p; (void)t;
    struct RuneWaylandBoard *b = d;
    b->pointer_x = x; b->pointer_y = y;
}
static void pointer_button(void *d, struct wl_pointer *p, uint32_t s, uint32_t t, uint32_t v, uint32_t st) {
    (void)p; (void)t;
    struct RuneWaylandBoard *b = d;
    b->serial = s;
    if (st == WL_POINTER_BUTTON_STATE_PRESSED && v == BTN_LEFT && b->target.recover_left_press) {
        /* Wayland consumes the release ending a drag. SDL2 can keep that
           button down internally and discard the *next* physical press.
           Give SDL its own queue first, then deliver the observed seat press
           only when SDL has skipped it. No action is generated on drag end. */
        b->target.recover_left_press = 0;
        SDL_PumpEvents();
        uint32_t window = rune_wayland_window_id(b->pointer_focus);
        if (window && SDL_AtomicGet(&b->target.left_presses) == b->target.last_left_press) {
            SDL_Event event = {0};
            event.type = SDL_MOUSEBUTTONDOWN; event.button.windowID = window;
            event.button.state = SDL_PRESSED; event.button.button = SDL_BUTTON_LEFT;
            event.button.clicks = 1;
            event.button.x = wl_fixed_to_int(b->pointer_x); event.button.y = wl_fixed_to_int(b->pointer_y);
            SDL_PushEvent(&event);
        }
    }
    if (st == WL_POINTER_BUTTON_STATE_PRESSED &&
        (!b->pointer_serial || (b->pointer_serial == b->target.consumed_serial && v == b->pointer_button))) {
        b->pointer_serial = s; b->pointer_button = v; b->pointer_origin = b->pointer_focus;
    } else if (st == WL_POINTER_BUTTON_STATE_RELEASED && v == b->pointer_button) {
        b->pointer_serial = 0;
    }
}
static void pointer_axis(void *d, struct wl_pointer *p, uint32_t t, uint32_t a, wl_fixed_t v) {
    (void)d; (void)p; (void)t; (void)a; (void)v;
}
static const struct wl_pointer_listener pointer_events = {
    .enter = pointer_enter, .leave = pointer_leave, .motion = pointer_motion, .button = pointer_button, .axis = pointer_axis
};
static void touch_down(void *d, struct wl_touch *p, uint32_t s, uint32_t t, struct wl_surface *w, int32_t id, wl_fixed_t x, wl_fixed_t y) {
    (void)p; (void)t; (void)x; (void)y;
    struct RuneWaylandBoard *b = d;
    b->serial = s;
    if (!b->touch_serial) {
        b->touch_serial = s; b->touch_origin = w; b->touch_id = id;
    }
}
static void touch_up(void *d, struct wl_touch *p, uint32_t s, uint32_t t, int32_t id) {
    (void)p; (void)t;
    struct RuneWaylandBoard *b = d;
    b->serial = s;
    if (id == b->touch_id) b->touch_serial = 0;
}
static void touch_motion(void *d, struct wl_touch *p, uint32_t t, int32_t id, wl_fixed_t x, wl_fixed_t y) {
    (void)d; (void)p; (void)t; (void)id; (void)x; (void)y;
}
static void touch_noop(void *d, struct wl_touch *p) { (void)d; (void)p; }
static void touch_cancel(void *d, struct wl_touch *p) { (void)p; ((struct RuneWaylandBoard *)d)->touch_serial = 0; }
static const struct wl_touch_listener touch_events = {.down=touch_down, .up=touch_up, .motion=touch_motion, .frame=touch_noop, .cancel=touch_cancel};
static void capabilities(void *data, struct wl_seat *seat, uint32_t flags) {
    struct RuneWaylandBoard *b = data;
    if ((flags & WL_SEAT_CAPABILITY_KEYBOARD) && !b->keyboard) {
        b->keyboard = wl_seat_get_keyboard(seat); wl_keyboard_add_listener(b->keyboard, &key_events, b);
    } else if (!(flags & WL_SEAT_CAPABILITY_KEYBOARD) && b->keyboard) { wl_keyboard_release(b->keyboard); b->keyboard = NULL; }
    if ((flags & WL_SEAT_CAPABILITY_POINTER) && !b->pointer) {
        b->pointer = wl_seat_get_pointer(seat); wl_pointer_add_listener(b->pointer, &pointer_events, b);
    } else if (!(flags & WL_SEAT_CAPABILITY_POINTER) && b->pointer) {
        wl_pointer_release(b->pointer); b->pointer = NULL; b->pointer_focus = NULL; b->pointer_serial = 0;
    }
    if ((flags & WL_SEAT_CAPABILITY_TOUCH) && !b->touch) {
        b->touch = wl_seat_get_touch(seat); wl_touch_add_listener(b->touch, &touch_events, b);
    } else if (!(flags & WL_SEAT_CAPABILITY_TOUCH) && b->touch) {
        wl_touch_release(b->touch); b->touch = NULL; b->touch_serial = 0;
    }
}
static void seat_name(void *d, struct wl_seat *s, const char *n) { (void)d; (void)s; (void)n; }
static const struct wl_seat_listener seat_events = {.capabilities = capabilities, .name = seat_name};
static void global(void *data, struct wl_registry *registry, uint32_t name, const char *type, uint32_t version) {
    struct RuneWaylandBoard *b = data;
    rune_wayland_primary_global(&b->primary_globals, name, type, version);
    if (!strcmp(type, "wl_seat") && !b->seat && version >= 3) {
        b->seat = wl_registry_bind(registry, name, &wl_seat_interface, 3);
        wl_seat_add_listener(b->seat, &seat_events, b);
    } else if (!strcmp(type, "wl_data_device_manager") && !b->manager && version >= 2) {
        b->manager = wl_registry_bind(registry, name, &wl_data_device_manager_interface, MIN(version, 3u));
    } else if (!strcmp(type, "wl_compositor") && !b->compositor) {
        uint32_t supported = MIN(5u, (uint32_t)wl_compositor_interface.version);
        b->compositor = wl_registry_bind(registry, name, &wl_compositor_interface, MIN(version, supported));
    } else if (!strcmp(type, "wl_shm") && !b->shm) {
        b->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    }
}
static void removed(void *d, struct wl_registry *r, uint32_t name) { (void)d; (void)r; (void)name; }
static const struct wl_registry_listener registry_events = {.global = global, .global_remove = removed};
struct RuneWaylandBoard *rune_wayland_board_open(uint32_t id) {
    SDL_Window *window = SDL_GetWindowFromID(id);
    SDL_SysWMinfo info;
    SDL_VERSION(&info.version);
    if (!window || !SDL_GetWindowWMInfo(window, &info) || info.subsystem != SDL_SYSWM_WAYLAND) return NULL;
    struct RuneWaylandBoard *b = g_new0(struct RuneWaylandBoard, 1);
    b->keymap_fd = -1;
    b->display = info.info.wl.display;
    b->queue = wl_display_create_queue(b->display);
    if (!b->queue) goto failed;
    struct wl_display *wrapper = wl_proxy_create_wrapper(b->display);
    if (!wrapper) goto failed;
    wl_proxy_set_queue((struct wl_proxy *)wrapper, b->queue);
    b->registry = wl_display_get_registry(wrapper);
    wl_proxy_wrapper_destroy(wrapper);
    wl_registry_add_listener(b->registry, &registry_events, b);
    if (wl_display_roundtrip_queue(b->display, b->queue) < 0 || !b->seat || !b->manager) goto failed;
    b->device = wl_data_device_manager_get_data_device(b->manager, b->seat);
    wl_data_device_add_listener(b->device, &device_events, b);
    b->primary = rune_wayland_primary_open(b->registry, b->seat, &b->primary_globals, b->display, b->queue);
    if (wl_display_roundtrip_queue(b->display, b->queue) < 0) goto failed;
    SDL_AddEventWatch(count_presses, b);
    return b;
failed:
    rune_wayland_board_close(b);
    return NULL;
}
void rune_wayland_board_close(struct RuneWaylandBoard *b) {
    if (!b) return;
    SDL_DelEventWatch(count_presses, b);
    if (b->keymap_fd >= 0) close(b->keymap_fd);
    xkb_state_unref(b->key_state);
    rune_wayland_primary_close(b->primary);
    while (b->offers) free_offer(b, b->offers->data);
    free_source(b->source);
    if (b->device) wl_data_device_release(b->device);
    if (b->manager) wl_data_device_manager_destroy(b->manager);
    if (b->shm) wl_shm_destroy(b->shm);
    if (b->compositor) wl_compositor_destroy(b->compositor);
    if (b->keyboard) wl_keyboard_release(b->keyboard);
    if (b->pointer) wl_pointer_release(b->pointer);
    if (b->touch) wl_touch_release(b->touch);
    if (b->seat) wl_seat_destroy(b->seat);
    if (b->registry) wl_registry_destroy(b->registry);
    if (b->queue) wl_event_queue_destroy(b->queue);
    g_free(b);
}
void rune_wayland_board_pump(struct RuneWaylandBoard *b) {
    if (!b) return;
    wl_display_dispatch_queue_pending(b->display, b->queue);
    /* Poll the shared fd before SDL's next frame. Reading delivers events
       to their respective queues and leaves SDL's callbacks to SDL. */
    if (wl_display_prepare_read_queue(b->display, b->queue) == 0) {
        struct pollfd fd = {wl_display_get_fd(b->display), POLLIN, 0};
        if (poll(&fd, 1, 0) > 0 && (fd.revents & POLLIN)) {
            if (wl_display_read_events(b->display) == 0)
                wl_display_dispatch_queue_pending(b->display, b->queue);
        } else {
            wl_display_cancel_read(b->display);
        }
    }
}
/* SDL2 reports physical RAlt in both US and German layouts. Resolve it
   against the active compositor group when an RAlt chord actually arrives. */
int rune_wayland_board_altgr(struct RuneWaylandBoard *b) {
    if (!b) return 0;
    rune_wayland_board_pump(b);
    if (!b->keyboard) return 0;
    if (b->keymap_fd >= 0) {
        void *bytes = mmap(NULL, b->keymap_size, PROT_READ, MAP_PRIVATE, b->keymap_fd, 0);
        close(b->keymap_fd);
        b->keymap_fd = -1;
        if (bytes != MAP_FAILED) {
            struct xkb_context *ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
            struct xkb_keymap *map = ctx ? xkb_keymap_new_from_buffer(ctx, bytes, b->keymap_size - 1,
                XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS) : NULL;
            if (map) b->key_state = xkb_state_new(map);
            xkb_keymap_unref(map);
            xkb_context_unref(ctx);
            munmap(bytes, b->keymap_size);
        }
    }
    if (!b->key_state) return 0;
    struct xkb_keymap *map = xkb_state_get_keymap(b->key_state);
    xkb_keycode_t key = xkb_keymap_key_by_name(map, "RALT");
    if (key == XKB_KEYCODE_INVALID) return 0;
    xkb_state_update_mask(b->key_state, 0, 0, 0, 0, 0, b->layout_group);
    xkb_keysym_t sym = xkb_state_key_get_one_sym(b->key_state, key);
    return sym == XKB_KEY_ISO_Level3_Shift || sym == XKB_KEY_Mode_switch || sym == XKB_KEY_ISO_Level5_Shift;
}

int rune_wayland_board_drag_context(struct RuneWaylandBoard *b, uint32_t id,
                                    struct RuneWaylandDragContext *out) {
    if (!b || !out || wl_data_device_manager_get_version(b->manager) < 3) return 0;
    SDL_Window *window = SDL_GetWindowFromID(id);
    SDL_SysWMinfo info;
    SDL_VERSION(&info.version);
    if (!window || !SDL_GetWindowWMInfo(window, &info) || info.subsystem != SDL_SYSWM_WAYLAND ||
        info.info.wl.display != b->display || !info.info.wl.surface) return 0;
    rune_wayland_board_pump(b);
    struct wl_surface *origin = info.info.wl.surface;
    uint32_t serial = 0;
    if (b->pointer_serial && b->pointer_origin == origin) serial = b->pointer_serial;
    else if (b->touch_serial && b->touch_origin == origin) serial = b->touch_serial;
    int width = 0, pixels = 0;
    SDL_GetWindowSize(window, &width, NULL);
#if SDL_VERSION_ATLEAST(2, 26, 0)
    SDL_GetWindowSizeInPixels(window, &pixels, NULL);
#else
    if (SDL_GetWindowFlags(window) & SDL_WINDOW_OPENGL) SDL_GL_GetDrawableSize(window, &pixels, NULL);
#endif
    *out = (struct RuneWaylandDragContext){
        .display = b->display, .manager = b->manager, .device = b->device,
        .origin = origin, .serial = serial, .target = &b->target,
        .compositor = b->compositor, .shm = b->shm,
        .scale = width > 0 && pixels > 0 ? MAX(1, (int)(((int64_t)pixels + width / 2) / width)) : 1,
        .left_pointer = serial && serial == b->pointer_serial && b->pointer_button == BTN_LEFT,
    };
    return 1;
}
int64_t rune_wayland_board_revision(struct RuneWaylandBoard *b) {
    rune_wayland_board_pump(b);
    return b->revision;
}
static void advertise(struct Source *s, const char *type, const uint8_t *bytes, size_t length) {
    if (g_hash_table_contains(s->formats, type)) return;
    g_hash_table_insert(s->formats, g_strdup(type), g_bytes_new(bytes, length));
    wl_data_source_offer(s->proxy, type);
}
int64_t rune_wayland_board_write(struct RuneWaylandBoard *b, const RuneMimeData *data, int concealed) {
    rune_wayland_board_pump(b);
    if (!b->serial || !data->count) return -1;
    struct Source *s = g_new0(struct Source, 1);
    s->board = b;
    s->proxy = wl_data_device_manager_create_data_source(b->manager);
    s->formats = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, (GDestroyNotify)g_bytes_unref);
    char *uuid = g_uuid_string_random();
    s->token = g_strconcat(TOKEN_PREFIX, uuid, NULL);
    g_free(uuid);
    wl_data_source_add_listener(s->proxy, &source_events, s);
    for (size_t i = 0; i < data->count; ++i) {
        const struct RuneMimeEntry *e = &data->entries[i];
        advertise(s, e->type, e->bytes, e->length);
        if (!strcmp(e->type, RUNE_PLAIN)) advertise(s, "text/plain", e->bytes, e->length);
    }
    advertise(s, s->token, NULL, 0);
    if (concealed) advertise(s, "x-kde-passwordManagerHint", (const uint8_t *)"secret", 6);
    struct Source *old = b->source;
    b->source = s;
    wl_data_device_set_selection(b->device, s->proxy, b->serial);
    free_source(old);
    if (wl_display_roundtrip_queue(b->display, b->queue) < 0 || !is_own(b)) {
        if (b->source == s) { b->source = NULL; free_source(s); }
        return -1;
    }
    return ++b->revision;
}
static GByteArray *read_pipe(int fd, size_t limit, gint64 deadline) {
    GByteArray *data = g_byte_array_new();
    int complete = 0;
    uint8_t buffer[16384];
    while (ready_fd(fd, POLLIN, deadline)) {
        ssize_t n = read(fd, buffer, sizeof(buffer));
        if (!n) { complete = 1; break; }
        if (n < 0) { if (errno == EINTR) continue; break; }
        if ((size_t)n > limit - data->len) break;
        g_byte_array_append(data, buffer, (guint)n);
    }
    close(fd);
    if (!complete) { g_byte_array_unref(data); return NULL; }
    return data;
}
static GByteArray *read_type(struct RuneWaylandBoard *b, const char *type, size_t limit, gint64 deadline) {
    int fds[2];
    if (pipe2(fds, O_CLOEXEC)) return NULL;
    wl_data_offer_receive(b->selection->proxy, type, fds[1]);
    close(fds[1]);
    wl_display_flush(b->display);
    return read_pipe(fds[0], limit, deadline);
}

struct PrimaryRead { int fd; RunePrimaryReply reply; void *context; };
static gpointer read_primary(gpointer queue) {
    for (;;) {
        struct PrimaryRead *read = g_async_queue_pop(queue);
        GByteArray *bytes = read_pipe(read->fd, RUNE_CLIPBOARD_LIMIT, g_get_monotonic_time() + 2000000);
        read->reply(read->context, bytes && bytes->len ? bytes->data : NULL, bytes ? bytes->len : 0);
        if (bytes) g_byte_array_unref(bytes);
        g_free(read);
    }
}

void rune_wayland_read_primary_fd(int fd, RunePrimaryReply reply, void *context) {
    /* Only the host thread queues reads. One worker keeps replies ordered even
       when the old owner is slow, without blocking the host or CLIPBOARD. */
    static GAsyncQueue *requests;
    if (!requests) {
        requests = g_async_queue_new();
        GThread *worker = g_thread_try_new("rune-primary", read_primary, requests, NULL);
        if (!worker) {
            g_clear_pointer(&requests, g_async_queue_unref);
            close(fd);
            reply(context, NULL, 0);
            return;
        }
        g_thread_unref(worker);
    }
    struct PrimaryRead *read = g_new(struct PrimaryRead, 1);
    *read = (struct PrimaryRead){fd, reply, context};
    g_async_queue_push(requests, read);
}

void rune_wayland_board_write_primary(struct RuneWaylandBoard *b, const uint8_t *bytes, size_t count) {
    rune_wayland_board_pump(b);
    rune_wayland_primary_write(b->primary, b->serial, bytes, count);
    wl_display_flush(b->display);
}

void rune_wayland_board_read_primary(struct RuneWaylandBoard *b, RunePrimaryReply reply, void *context) {
    rune_wayland_board_pump(b);
    rune_wayland_primary_read(b->primary, b->display, reply, context);
}
void rune_wayland_board_read(struct RuneWaylandBoard *b, RuneMimeData *out) {
    if (wl_display_roundtrip_queue(b->display, b->queue) < 0) return;
    gint64 deadline = g_get_monotonic_time() + 2000000;
    for (guint i = 0; b->selection && i < b->selection->formats->len; ++i) {
        const char *type = g_ptr_array_index(b->selection->formats, i);
        if (g_str_has_prefix(type, TOKEN_PREFIX)) continue;
        const char *mime = !strcmp(type, "text/plain") || !strcmp(type, "UTF8_STRING") ? RUNE_PLAIN : type;
        if (rune_mime_find(out, mime)) continue;
        if (is_own(b)) {
            GBytes *local = g_hash_table_lookup(b->source->formats, type);
            if (local) {
                gsize length;
                const void *bytes = g_bytes_get_data(local, &length);
                rune_mime_add(out, mime, bytes, length);
            }
        } else {
            GByteArray *data = read_type(b, type, RUNE_CLIPBOARD_LIMIT - out->total, deadline);
            if (data) {
                if (data->len || !strcmp(mime, RUNE_CONCEALED))
                    rune_mime_add(out, mime, data->data, data->len);
                g_byte_array_unref(data);
            }
            if (g_get_monotonic_time() >= deadline) break;
        }
    }
    /* Some compositors invalidate every offer except the first device the
       toolkit bound. SDL still owns that text offer on such compositors. */
    if (!rune_mime_find(out, RUNE_PLAIN) && SDL_HasClipboardText()) {
        /* SDL2 gives the owning client less than one frame to serve each
           pipe. A busy process may miss that first request. */
        for (int attempt = 0; attempt < 4; ++attempt) {
            SDL_ClearError();
            char *text = SDL_GetClipboardText();
            int retry = text && !*text && !strcmp(SDL_GetError(), "Pipe timeout");
            if (text && !retry)
                rune_mime_add(out, RUNE_PLAIN, (const uint8_t *)text, strlen(text));
            SDL_free(text);
            if (!retry) break;
        }
    }
}
int rune_wayland_board_clear(struct RuneWaylandBoard *b, int64_t expected) {
    if (wl_display_roundtrip_queue(b->display, b->queue) < 0) return 0;
    if (expected >= 0 && (!b->source || b->revision != expected)) return 0;
    if (b->source) {
        /* Destroy only the source we created. A concurrent external copy
           remains valid even if its cancellation hasn't arrived yet. */
        free_source(b->source); b->source = NULL;
    } else if (b->serial && expected < 0) {
        RuneMimeData *empty = rune_mime_create();
        int ok = rune_mime_add(empty, RUNE_PLAIN, NULL, 0)
            && rune_wayland_board_write(b, empty, 0) >= 0;
        rune_mime_free(empty);
        if (!ok) return 0;
        free_source(b->source); b->source = NULL;
    } else return 0;
    ++b->revision;
    wl_display_flush(b->display);
    return 1;
}
#endif
