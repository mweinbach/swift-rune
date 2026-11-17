#ifndef RUNE_WAYLAND_DRAG_H
#define RUNE_WAYLAND_DRAG_H
#include <stdint.h>
#include <glib.h>
#include <SDL_atomic.h>
#include <wayland-client.h>

struct RuneWaylandDropStatus {
    int over_local;
    uint64_t local_drops;
    uint32_t consumed_serial;
    int active;
    int within_app;
    SDL_atomic_t left_presses;
    int recover_left_press, last_left_press;
    struct RuneLinuxDrag *source;
};
struct RuneWaylandDragContext {
    struct wl_display *display;
    struct wl_data_device_manager *manager;
    struct wl_data_device *device;
    struct wl_surface *origin;
    uint32_t serial;
    struct RuneWaylandDropStatus *target;
    struct wl_compositor *compositor;
    struct wl_shm *shm;
    int scale;
    int left_pointer;
};

struct RuneWaylandBoard;
/* All native objects belong to the SDL host thread. A zero serial means
   the window has no current implicit pointer or touch grab. */
int rune_wayland_board_drag_context(struct RuneWaylandBoard *, uint32_t window_id,
                                    struct RuneWaylandDragContext *);
int rune_wayland_drag_context(uint32_t window_id, struct RuneWaylandDragContext *);
void rune_wayland_send_bytes(int fd, GBytes *bytes);
void rune_wayland_drag_escape(struct RuneWaylandDropStatus *);
#endif
