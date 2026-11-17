#ifndef RUNE_WAYLAND_PRIMARY_H
#define RUNE_WAYLAND_PRIMARY_H
#include "RuneDesktopServices.h"
#include <wayland-client.h>

struct RuneWaylandPrimary;
enum { RUNE_PRIMARY_FOCUSED, RUNE_PRIMARY_EXT, RUNE_PRIMARY_WLR, RUNE_PRIMARY_PROTOCOLS };
struct RunePrimaryGlobals { uint32_t names[RUNE_PRIMARY_PROTOCOLS]; };
void rune_wayland_primary_global(struct RunePrimaryGlobals *, uint32_t name, const char *, uint32_t version);
struct RuneWaylandPrimary *rune_wayland_primary_open(struct wl_registry *, struct wl_seat *, const struct RunePrimaryGlobals *,
                                                     struct wl_display *, struct wl_event_queue *);
void rune_wayland_primary_close(struct RuneWaylandPrimary *);
void rune_wayland_primary_write(struct RuneWaylandPrimary *, uint32_t, const uint8_t *, size_t);
void rune_wayland_primary_read(struct RuneWaylandPrimary *, struct wl_display *, RunePrimaryReply, void *);
void rune_wayland_read_primary_fd(int fd, RunePrimaryReply, void *);
#endif
