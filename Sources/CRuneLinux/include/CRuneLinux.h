#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef struct RuneLinuxWindow RuneLinuxWindow;
typedef void (*RuneLinuxDisplayVisitor)(void *, uint32_t id, const char *name, int32_t x, int32_t y,
                                        uint32_t width, uint32_t height, double scale, int32_t primary);
int rune_linux_displays(void *context, RuneLinuxDisplayVisitor visit);
typedef struct {
    int width, height, minWidth, minHeight, maxWidth, maxHeight;
    bool resizable, borderless, alwaysOnTop, visible, maximized, fullScreen;
    bool floatOnOpen;
    uint32_t physicalWidth, physicalHeight;
} RuneLinuxWindowOptions;

typedef enum {
    RuneLinuxIgnored, RuneLinuxWake, RuneLinuxClose, RuneLinuxQuit,
    RuneLinuxExposed, RuneLinuxResized, RuneLinuxMoved, RuneLinuxFocus, RuneLinuxVisibility,
    RuneLinuxMotion, RuneLinuxButton, RuneLinuxLeave, RuneLinuxWheel, RuneLinuxKey,
    RuneLinuxText, RuneLinuxPreedit, RuneLinuxDropBegin, RuneLinuxDropFile, RuneLinuxDropEnd
} RuneLinuxEventKind;

typedef struct {
    RuneLinuxEventKind kind;
    uint32_t windowID;
    float x, y, dx, dy;
    int code, scan, start, length;
    unsigned modifiers;
    bool active, repeated;
    char *text;
} RuneLinuxEvent;

enum { RuneLinuxShift = 1, RuneLinuxControl = 2, RuneLinuxAlt = 4, RuneLinuxSuper = 8, RuneLinuxAltGr = 16 };

RuneLinuxWindow *rune_linux_open(const char *title, RuneLinuxWindowOptions options);
void rune_linux_set_altgr_resolver(int (*resolve)(uint32_t window_id));
uint32_t rune_linux_group_begin(void);
void rune_linux_group_end(void);
const char *rune_linux_error(void);
void rune_linux_close(RuneLinuxWindow *host);
void *rune_linux_gl_proc(const char *name);
bool rune_linux_make_current(RuneLinuxWindow *host);
void rune_linux_register_gl_reset(void (*reset)(void));
bool rune_linux_present(RuneLinuxWindow *host);
bool rune_linux_present_paced(const RuneLinuxWindow *host);
int32_t rune_linux_refresh_hz(RuneLinuxWindow *host);
uint32_t rune_linux_id(RuneLinuxWindow *host);
uint32_t rune_linux_wake_type(RuneLinuxWindow *host);
void rune_linux_wake(uint32_t id, uint32_t type);
void rune_linux_size(RuneLinuxWindow *host, int *w, int *h, int *pixelW, int *pixelH);
typedef struct {
    int32_t x, y, content_x, content_y, maximized, minimized, fullscreen, display_x, display_y;
    uint32_t width, height, display_width, display_height;
    double scale;
} RuneLinuxPlacement;
// X11 exposes global physical coordinates. Wayland's xdg-shell does not.
int rune_linux_placement(RuneLinuxWindow *host, RuneLinuxPlacement *out);
int rune_linux_frame_geometry(RuneLinuxWindow *host, RuneLinuxPlacement *out,
                              uint32_t *outer_width, uint32_t *outer_height);
int rune_linux_content_origin(RuneLinuxWindow *host, int32_t *x, int32_t *y, int32_t *primary_x, int32_t *primary_y);
int rune_linux_click_through(RuneLinuxWindow *host, int on);
void rune_linux_set_title(RuneLinuxWindow *host, const char *title);
void rune_linux_set_size(RuneLinuxWindow *host, int w, int h);
void rune_linux_set_position(RuneLinuxWindow *host, int x, int y);
void rune_linux_center(RuneLinuxWindow *host);
void rune_linux_show(RuneLinuxWindow *host);
void rune_linux_hide(RuneLinuxWindow *host);
void rune_linux_focus(RuneLinuxWindow *host);
void rune_linux_activate(RuneLinuxWindow *host, const char *activation_token);
void rune_linux_minimize(RuneLinuxWindow *host);
void rune_linux_topmost(RuneLinuxWindow *host, bool on);
void rune_linux_flash(RuneLinuxWindow *host, bool on);
void rune_linux_set_ime_rect(int x, int y, int w, int h);
void rune_linux_free(void *data);
// Returns 1 for an event, 0 for timeout, or -1 on a wait failure.
// The caller owns event->text and releases it with rune_linux_free.
int rune_linux_next_event(int timeoutMs, RuneLinuxEvent *event);

void rune_linux_origin(RuneLinuxWindow *host, int *x, int *y);
void rune_linux_toggle_maximized(RuneLinuxWindow *host);
void rune_linux_toggle_fullscreen(RuneLinuxWindow *host);
bool rune_linux_has_mouse(RuneLinuxWindow *host);
enum {
    RuneLinuxCursorDefault, RuneLinuxCursorHand, RuneLinuxCursorText, RuneLinuxCursorNo,
    RuneLinuxCursorMove, RuneLinuxCursorColumn, RuneLinuxCursorRow, RuneLinuxCursorCross,
    RuneLinuxCursorHidden
};
void *rune_linux_set_cursor(int kind);
void *rune_linux_set_image_cursor(const uint8_t *rgba, int w, int h, int sizeW, int sizeH, int hx, int hy);
void rune_linux_free_cursor(void *cursor);

typedef struct RuneLinuxAppearance RuneLinuxAppearance;
typedef struct {
    // -1 means unknown. Dark/light are represented by 1/0 respectively.
    int dark, reducedMotion, increasedContrast;
    bool hasAccent;
    double red, green, blue;
} RuneLinuxPreferences;
RuneLinuxAppearance *rune_linux_appearance_open(void);
bool rune_linux_appearance_take(RuneLinuxAppearance *state, RuneLinuxPreferences *result);
void rune_linux_appearance_close(RuneLinuxAppearance *state);

#include "RuneLinuxOverlay.h"
