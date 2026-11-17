#if defined(__linux__) && !defined(__ANDROID__)
#define _GNU_SOURCE
#include "services_internal.h"
#include "wayland_primary.h"
#include "wayland_drag.h"
#include <fcntl.h>
#include <unistd.h>

/* wayland-scanner private-code generated from wayland-protocols and wlr-protocols.
   Namespace the interface symbols independently of SDL and toolkit bindings. */
#define zwp_primary_selection_device_manager_v1_interface rune_primary_manager_interface
#define zwp_primary_selection_device_v1_interface rune_primary_device_interface
#define zwp_primary_selection_offer_v1_interface rune_primary_offer_interface
#define zwp_primary_selection_source_v1_interface rune_primary_source_interface
#define ext_data_control_manager_v1_interface rune_ext_manager_interface
#define ext_data_control_device_v1_interface rune_ext_device_interface
#define ext_data_control_offer_v1_interface rune_ext_offer_interface
#define ext_data_control_source_v1_interface rune_ext_source_interface
#define zwlr_data_control_manager_v1_interface rune_wlr_manager_interface
#define zwlr_data_control_device_v1_interface rune_wlr_device_interface
#define zwlr_data_control_offer_v1_interface rune_wlr_offer_interface
#define zwlr_data_control_source_v1_interface rune_wlr_source_interface
#include "WaylandPrimarySelectionProtocol.inc"
#include "WaylandExtDataControl.inc"
#include "WaylandWlrDataControl.inc"

struct Binding {
    const struct wl_interface *manager, *device, *source;
    uint32_t version;
};
static const struct Binding bindings[] = {
    [RUNE_PRIMARY_FOCUSED] = {&rune_primary_manager_interface, &rune_primary_device_interface, &rune_primary_source_interface, 1},
    [RUNE_PRIMARY_EXT] = {&rune_ext_manager_interface, &rune_ext_device_interface, &rune_ext_source_interface, 1},
    [RUNE_PRIMARY_WLR] = {&rune_wlr_manager_interface, &rune_wlr_device_interface, &rune_wlr_source_interface, 2}
};

/* These requests have the same wire opcodes in all three XML protocols.
   Only the device selection request and the device event lists differ. */
enum { MANAGER_CREATE_SOURCE, MANAGER_GET_DEVICE, MANAGER_DESTROY };
enum { DEVICE_SET_FOCUSED_SELECTION, DEVICE_DESTROY, DEVICE_SET_CONTROL_PRIMARY };
enum { SOURCE_OFFER, SOURCE_DESTROY };
enum { OFFER_RECEIVE, OFFER_DESTROY };
enum { EVENT_OFFER, EVENT_SELECTION, CONTROL_FINISHED, CONTROL_PRIMARY_SELECTION };
enum { SOURCE_SEND, SOURCE_CANCELLED };

struct PrimaryOffer {
    struct wl_proxy *proxy;
    char *format;
    int preference;
};
struct RuneWaylandPrimary {
    const struct Binding *binding;
    struct wl_proxy *manager, *device, *source;
    gboolean focused, supports_primary;
    GBytes *text;
    struct PrimaryOffer *selection;
    GList *offers;
};

static void destroy(struct wl_proxy *proxy, uint32_t opcode) {
    if (proxy) wl_proxy_marshal_flags(proxy, opcode, NULL, wl_proxy_get_version(proxy), WL_MARSHAL_FLAG_DESTROY);
}

void rune_wayland_primary_global(struct RunePrimaryGlobals *globals, uint32_t name, const char *type, uint32_t version) {
    for (unsigned i = 0; i < G_N_ELEMENTS(bindings); ++i) {
        if (version >= bindings[i].version && !strcmp(type, bindings[i].manager->name)) globals->names[i] = name;
    }
}

static int text_format(const char *mime) {
    if (!g_ascii_strcasecmp(mime, RUNE_PLAIN)) return 3;
    if (!strcmp(mime, "UTF8_STRING")) return 2;
    return !g_ascii_strcasecmp(mime, "text/plain");
}

static int offer_event(const void *impl, void *target, uint32_t opcode, const struct wl_message *message, union wl_argument *args) {
    (void)impl; (void)opcode; (void)message;
    struct PrimaryOffer *offer = wl_proxy_get_user_data(target);
    const char *mime = args[0].s;
    int rank = text_format(mime);
    if (rank > offer->preference) {
        g_free(offer->format);
        offer->format = g_strdup(mime);
        offer->preference = rank;
    }
    return 0;
}

static void drop_offer(struct RuneWaylandPrimary *board, struct PrimaryOffer *offer) {
    if (!offer) return;
    board->offers = g_list_remove(board->offers, offer);
    destroy(offer->proxy, OFFER_DESTROY);
    g_free(offer->format);
    g_free(offer);
}

static void drop_source(struct RuneWaylandPrimary *board) {
    destroy(board->source, SOURCE_DESTROY);
    board->source = NULL;
    g_clear_pointer(&board->text, g_bytes_unref);
}

static int device_event(const void *impl, void *device, uint32_t opcode, const struct wl_message *message, union wl_argument *args) {
    (void)impl; (void)message;
    struct RuneWaylandPrimary *board = wl_proxy_get_user_data(device);
    if (opcode == CONTROL_FINISHED) {
        board->supports_primary = FALSE;
        board->selection = NULL;
        while (board->offers) drop_offer(board, board->offers->data);
        drop_source(board);
        destroy(board->device, DEVICE_DESTROY);
        board->device = NULL;
        return 0;
    }
    struct wl_proxy *proxy = (struct wl_proxy *)args[0].o;
    if (opcode == EVENT_OFFER) {
        struct PrimaryOffer *offer = g_new0(struct PrimaryOffer, 1);
        offer->proxy = proxy;
        board->offers = g_list_prepend(board->offers, offer);
        wl_proxy_add_dispatcher(proxy, offer_event, NULL, offer);
    } else if (opcode == CONTROL_PRIMARY_SELECTION || (opcode == EVENT_SELECTION && board->focused)) {
        /* On either data-control protocol a first primary_selection event (even
           with a null offer) acknowledges that the compositor supports PRIMARY. */
        board->supports_primary = TRUE;
        struct PrimaryOffer *offer = proxy ? wl_proxy_get_user_data(proxy) : NULL;
        if (offer != board->selection) drop_offer(board, board->selection);
        board->selection = offer;
    } else if (opcode == EVENT_SELECTION && proxy) {
        /* A data-control device also receives regular clipboard offers. Release
           these immediately without ever requesting their bytes. */
        drop_offer(board, wl_proxy_get_user_data(proxy));
    }
    return 0;
}

static int source_event(const void *impl, void *source, uint32_t opcode, const struct wl_message *message, union wl_argument *args) {
    (void)impl; (void)message;
    struct RuneWaylandPrimary *board = wl_proxy_get_user_data(source);
    if (opcode == SOURCE_SEND) {
        rune_wayland_send_bytes(args[1].h, source == board->source && text_format(args[0].s) ? board->text : NULL);
    } else if (opcode == SOURCE_CANCELLED && source == board->source) {
        drop_source(board);
    }
    return 0;
}

struct RuneWaylandPrimary *rune_wayland_primary_open(struct wl_registry *registry, struct wl_seat *seat,
                                                      const struct RunePrimaryGlobals *globals,
                                                      struct wl_display *display, struct wl_event_queue *queue) {
    /* Prefer the ordinary focused-client protocol. Only open a data-control
       device when the compositor does not expose the focused-client one. */
    for (unsigned i = 0; i < G_N_ELEMENTS(bindings); ++i) {
        if (!globals->names[i]) continue;
        const struct Binding *binding = &bindings[i];
        struct wl_proxy *manager = wl_registry_bind(registry, globals->names[i], binding->manager, binding->version);
        if (!manager) continue;
        struct wl_proxy *device = wl_proxy_marshal_flags(manager, MANAGER_GET_DEVICE, binding->device,
                                                          binding->version, 0, NULL, seat);
        if (!device) { destroy(manager, MANAGER_DESTROY); continue; }
        struct RuneWaylandPrimary *board = g_new0(struct RuneWaylandPrimary, 1);
        board->binding = binding;
        board->manager = manager;
        board->device = device;
        board->focused = i == RUNE_PRIMARY_FOCUSED;
        board->supports_primary = board->focused;
        wl_proxy_add_dispatcher(device, device_event, NULL, board);
        /* PRIMARY is optional even on data-control. If both extensions are
           present, try wlroots when ext never announces PRIMARY on this seat. */
        if (i == RUNE_PRIMARY_EXT && globals->names[RUNE_PRIMARY_WLR]) {
            int result = wl_display_roundtrip_queue(display, queue);
            if (!board->supports_primary || result < 0) {
                rune_wayland_primary_close(board);
                if (result < 0) return NULL;
                continue;
            }
        }
        return board;
    }
    return NULL;
}

void rune_wayland_primary_close(struct RuneWaylandPrimary *board) {
    if (!board) return;
    drop_source(board);
    while (board->offers) drop_offer(board, board->offers->data);
    destroy(board->device, DEVICE_DESTROY);
    destroy(board->manager, MANAGER_DESTROY);
    g_free(board);
}

void rune_wayland_primary_write(struct RuneWaylandPrimary *board, uint32_t serial,
                                const uint8_t *text, size_t count) {
    if (!board || !board->supports_primary || (board->focused && !serial)) return;
    struct wl_proxy *source = wl_proxy_marshal_flags(board->manager, MANAGER_CREATE_SOURCE, board->binding->source,
                                                      wl_proxy_get_version(board->manager), 0, NULL);
    if (!source) return;
    drop_source(board);
    board->source = source;
    board->text = g_bytes_new(text, count);
    wl_proxy_add_dispatcher(source, source_event, NULL, board);
    static const char *const types[] = {RUNE_PLAIN, "text/plain", "UTF8_STRING"};
    for (unsigned i = 0; i < G_N_ELEMENTS(types); ++i)
        wl_proxy_marshal_flags(source, SOURCE_OFFER, NULL, wl_proxy_get_version(source), 0, types[i]);
    uint32_t version = wl_proxy_get_version(board->device);
    if (board->focused)
        wl_proxy_marshal_flags(board->device, DEVICE_SET_FOCUSED_SELECTION, NULL, version, 0, source, serial);
    else
        wl_proxy_marshal_flags(board->device, DEVICE_SET_CONTROL_PRIMARY, NULL, version, 0, source);
}

void rune_wayland_primary_read(struct RuneWaylandPrimary *board, struct wl_display *display,
                               RunePrimaryReply reply, void *context) {
    struct PrimaryOffer *offer = board ? board->selection : NULL;
    int pipe_fds[2];
    if (!offer || !offer->format || pipe2(pipe_fds, O_CLOEXEC)) {
        reply(context, NULL, 0);
        return;
    }
    wl_proxy_marshal_flags(offer->proxy, OFFER_RECEIVE, NULL, wl_proxy_get_version(offer->proxy), 0, offer->format, pipe_fds[1]);
    close(pipe_fds[1]);
    wl_display_flush(display);
    rune_wayland_read_primary_fd(pipe_fds[0], reply, context);
}
#endif
