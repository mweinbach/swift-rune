#ifndef RUNE_WAYLAND_DRAG_ICON_H
#define RUNE_WAYLAND_DRAG_ICON_H
#include "linux_drag_internal.h"
#include "wayland_drag.h"

struct RuneWaylandDragIcon {
    struct wl_surface *surface;
    struct wl_buffer *buffer;
    int scale, hotspot_x, hotspot_y, width, height;
};

struct RuneWaylandDragIcon rune_wayland_icon_create(const struct RuneWaylandDragContext *,
                                                    const RuneLinuxDragPreview *);
void rune_wayland_icon_commit(struct RuneWaylandDragIcon *);
void rune_wayland_icon_destroy(struct RuneWaylandDragIcon *);
#endif
