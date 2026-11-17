#if defined(__linux__) && !defined(__ANDROID__)
#include "linux_drag_internal.h"
#include "wayland_drag.h"
#include "wayland_file_drop.h"
#include "wayland_drag_icon.h"
#include "services_internal.h"
#include <errno.h>
#include <unistd.h>

struct WaylandDrag {
    RuneLinuxDrag base;
    uint32_t window_id;
    struct wl_data_source *source;
    struct RuneWaylandDragIcon icon;
    const RuneMimeData *formats;
    struct RuneWaylandDropStatus *target;
    uint64_t initial_local_drops;
    int within_app, result, left_pointer, dropped;
    uint32_t action;
};

static void drag_target(void *context, struct wl_data_source *source, const char *mime) {
    (void)context; (void)source; (void)mime;
}
static void drag_send(void *context, struct wl_data_source *source, const char *type, int32_t fd) {
    (void)source;
    struct WaylandDrag *d = context;
    if (!d->within_app && (d->target->over_local || d->target->local_drops != d->initial_local_drops)) {
        close(fd);
        return;
    }
    const struct RuneMimeEntry *entry = rune_mime_find(d->formats, type);
    if (!entry && !strcmp(type, "text/plain")) entry = rune_mime_find(d->formats, RUNE_PLAIN);
    if (!entry) {
        close(fd);
        return;
    }
    /* The receiver owns the pipe. Its write can outlive the drag and must
       never stall the SDL event thread. */
    GBytes *bytes = g_bytes_new(entry->bytes, entry->length);
    rune_wayland_send_bytes(fd, bytes);
    g_bytes_unref(bytes);
}
static void drag_cancelled(void *context, struct wl_data_source *source) {
    (void)source;
    struct WaylandDrag *d = context;
    if (d->left_pointer) d->target->recover_left_press = 1;
    d->result = 0;
}
static void drag_dropped(void *context, struct wl_data_source *source) {
    (void)source;
    struct WaylandDrag *d = context;
    d->dropped = 1;
    if (d->left_pointer) d->target->recover_left_press = 1;
    /* Release over a destination precedes validation and receipt of its data. */
}
static void drag_finished(void *context, struct wl_data_source *source) {
    (void)source;
    struct WaylandDrag *d = context;
    if (!d->within_app && d->target->local_drops != d->initial_local_drops) d->result = 0;
    else if (d->action == WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY) d->result = 1;
    else if (d->action == WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE) d->result = 2;
    else d->result = 0;
}
static void drag_action(void *context, struct wl_data_source *source, uint32_t action) {
    (void)source; ((struct WaylandDrag *)context)->action = action;
}
static const struct wl_data_source_listener drag_events = {
    .target = drag_target, .send = drag_send, .cancelled = drag_cancelled,
    .dnd_drop_performed = drag_dropped, .dnd_finished = drag_finished, .action = drag_action
};

static int begin(RuneLinuxDrag *base, const RuneMimeData *data, unsigned operations, int within_app) {
    struct WaylandDrag *d = (struct WaylandDrag *)base;
    struct RuneWaylandDragContext seat;
    uint32_t allowed = 0;
    if (operations & 1u) allowed |= WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY;
    if (operations & 2u) allowed |= WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE;
    if (!allowed || !data || !data->count || d->source ||
        !rune_wayland_drag_context(d->window_id, &seat) || !seat.serial ||
        seat.target->active || seat.target->consumed_serial == seat.serial) return 0;
    d->source = wl_data_device_manager_create_data_source(seat.manager);
    if (!d->source) return 0;
    d->formats = data;
    d->within_app = within_app;
    d->target = seat.target;
    d->left_pointer = seat.left_pointer;
    if (d->left_pointer) d->target->last_left_press = SDL_AtomicGet(&d->target->left_presses);
    d->target->active = 1;
    d->target->source = base;
    d->target->within_app = within_app;
    d->target->consumed_serial = seat.serial;
    d->initial_local_drops = seat.target->local_drops;
    d->action = 0;
    d->dropped = 0;
    d->result = -1;
    wl_data_source_add_listener(d->source, &drag_events, d);
    for (size_t i = 0; i < data->count; i++) wl_data_source_offer(d->source, data->entries[i].type);
    if (rune_mime_find(data, RUNE_PLAIN) && !rune_mime_find(data, "text/plain")) {
        wl_data_source_offer(d->source, "text/plain");
    }
    wl_data_source_set_actions(d->source, allowed);
    d->icon = rune_wayland_icon_create(&seat, base->preview);
    wl_data_device_start_drag(seat.device, d->source, seat.origin, d->icon.surface, seat.serial);
    rune_wayland_icon_commit(&d->icon);
    if (wl_display_flush(seat.display) < 0 && errno != EAGAIN) d->result = 0;
    return 1;
}
static void end_source(struct WaylandDrag *d) {
    if (!d->source) return;
    wl_data_source_destroy(d->source);
    rune_wayland_icon_destroy(&d->icon);
    d->target->active = 0;
    d->target->source = NULL;
    d->source = NULL; d->formats = NULL;
}
void rune_wayland_drag_escape(struct RuneWaylandDropStatus *seat) {
    struct WaylandDrag *d = (struct WaylandDrag *)seat->source;
    if (!d || d->dropped || d->result >= 0) return;
    d->result = 0;
    if (d->left_pointer) seat->recover_left_press = 1;
    end_source(d);
}
static int result(RuneLinuxDrag *base) {
    struct WaylandDrag *d = (struct WaylandDrag *)base;
    if (!d->source) return 0;
    struct RuneWaylandDragContext seat;
    if (!rune_wayland_drag_context(d->window_id, &seat) || wl_display_get_error(seat.display)) d->result = 0;
    if (d->result < 0) return -1;
    end_source(d);
    return d->result;
}
static void destroy(RuneLinuxDrag *base) {
    struct WaylandDrag *d = (struct WaylandDrag *)base;
    rune_wayland_drop_unregister(d->window_id);
    end_source(d);
    g_free(d);
}
RuneLinuxDrag *rune_wayland_drag_open(uint32_t window_id) {
    struct RuneWaylandDragContext seat;
    if (!rune_wayland_drag_context(window_id, &seat)) return NULL;
    struct WaylandDrag *d = g_new0(struct WaylandDrag, 1);
    d->window_id = window_id;
    rune_wayland_drop_register(window_id);
    d->base.begin = begin; d->base.poll = result; d->base.destroy = destroy;
    return &d->base;
}
#endif
