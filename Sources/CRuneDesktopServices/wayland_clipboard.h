#ifndef RUNE_WAYLAND_CLIPBOARD_H
#define RUNE_WAYLAND_CLIPBOARD_H
#include "services_internal.h"
struct RuneWaylandBoard;
struct RuneWaylandBoard *rune_wayland_board_open(uint32_t window_id);
void rune_wayland_board_close(struct RuneWaylandBoard *);
void rune_wayland_board_pump(struct RuneWaylandBoard *);
int rune_wayland_board_altgr(struct RuneWaylandBoard *);
int rune_wayland_board_wheel_points(struct RuneWaylandBoard *, uint32_t window_id, float x, float y, float *px, float *py);
int64_t rune_wayland_board_write(struct RuneWaylandBoard *, const RuneMimeData *, int concealed);
void rune_wayland_board_read(struct RuneWaylandBoard *, RuneMimeData *);
void rune_wayland_board_write_primary(struct RuneWaylandBoard *, const uint8_t *, size_t);
void rune_wayland_board_read_primary(struct RuneWaylandBoard *, RunePrimaryReply, void *);
int64_t rune_wayland_board_revision(struct RuneWaylandBoard *);
int rune_wayland_board_clear(struct RuneWaylandBoard *, int64_t expected);
#endif
