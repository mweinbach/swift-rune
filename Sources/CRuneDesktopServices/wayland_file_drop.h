#ifndef RUNE_WAYLAND_FILE_DROP_H
#define RUNE_WAYLAND_FILE_DROP_H
#include <glib.h>
#include <wayland-client.h>
#include <stdint.h>
void rune_wayland_drop_register(uint32_t window);
void rune_wayland_drop_unregister(uint32_t window);
uint32_t rune_wayland_window_id(struct wl_surface *);
uint32_t rune_wayland_drop_accept(struct wl_surface *surface, struct wl_data_offer *offer,
                                  uint32_t serial, int uri_list, int allowed);
void rune_wayland_drop_leave(uint32_t window);
/* Takes ownership of the offer. */
void rune_wayland_drop_receive(uint32_t window, struct wl_data_offer *offer, float x, float y);
#endif
