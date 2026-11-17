#pragma once
#include <stdint.h>

typedef struct RuneLinuxOverlay RuneLinuxOverlay;
typedef enum {
    RuneOverlayDraw, RuneOverlayMotion, RuneOverlayLeave, RuneOverlayButton, RuneOverlayWheel,
    RuneOverlayKey, RuneOverlayFocus, RuneOverlayLost, RuneOverlayMonitor, RuneOverlayDue, RuneOverlayGLGone,
    RuneOverlayClosed, RuneOverlayGeometry, RuneOverlayPollGPU
} RuneOverlayEventKind;
typedef struct {
    RuneOverlayEventKind kind;
    int active, code, scale, width, height;
    unsigned modifiers, unicode;
    double x, y, dx, dy;
} RuneOverlayEvent;
typedef int (*RuneOverlayDispatch)(void *, const RuneOverlayEvent *);
typedef struct { int x, y, width, height; } RuneOverlayRect;
typedef enum { RuneOverlayX11, RuneOverlayLayer, RuneOverlayXWayland } RuneOverlayBackend;

RuneLinuxOverlay *rune_overlay_new(const char *name, int allow_xwayland, void *context, RuneOverlayDispatch dispatch);
const char *rune_overlay_error(void);
RuneOverlayBackend rune_overlay_backend(RuneLinuxOverlay *);
uint32_t rune_overlay_xid(RuneLinuxOverlay *);
int rune_overlay_has_keys(RuneLinuxOverlay *);
int rune_overlay_make_current(RuneLinuxOverlay *);
int rune_overlay_uses_gles(RuneLinuxOverlay *);
int rune_overlay_scale(RuneLinuxOverlay *);
int rune_overlay_wayland_session(void);
void rune_overlay_park(RuneLinuxOverlay *);
int rune_overlay_origin(RuneLinuxOverlay *, int32_t *x, int32_t *y, int32_t *primary_x, int32_t *primary_y);
void *rune_overlay_gl_proc(const char *);
void rune_overlay_free(RuneLinuxOverlay *);
void rune_overlay_monitor(RuneLinuxOverlay *, int index, int under_pointer, const char *name, RuneOverlayRect *out);
void rune_overlay_place(RuneLinuxOverlay *, RuneOverlayRect rect, int full, int follow);
void rune_overlay_observe_regions(RuneLinuxOverlay *, int enabled);
void rune_overlay_level(RuneLinuxOverlay *, int level);
void rune_overlay_input(RuneLinuxOverlay *, int all, const RuneOverlayRect *, int count);
void rune_overlay_focus(RuneLinuxOverlay *);
void rune_overlay_show(RuneLinuxOverlay *, int show, double seconds);
void rune_overlay_redraw(RuneLinuxOverlay *);
void rune_overlay_schedule(RuneLinuxOverlay *, double delay);
void rune_overlay_schedule_gpu_poll(RuneLinuxOverlay *);
void rune_overlay_cursor(RuneLinuxOverlay *, const char *name);
void rune_overlay_image_cursor(RuneLinuxOverlay *, const uint8_t *rgba, int w, int h, int width, int height, int x, int y);
void rune_overlay_pump(void);
