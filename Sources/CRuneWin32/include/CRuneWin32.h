#ifndef C_RUNE_WIN32_H
#define C_RUNE_WIN32_H

#include <stdint.h>
#include "RuneAccessibility.h"
#include "RuneMenus.h"
#include "RuneWinPopup.h"
#include "RuneWinGroupWake.h"
#include "RuneDragSource.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RuneWinWindow RuneWinWindow;
// With RUNE_BOOT_PROFILE=1, timestamps are milliseconds since process creation.
// End records a phase on stderr and returns its end timestamp. Disabled returns -1.
double rune_win_boot_clock(void);
double rune_win_boot_end(const char *phase, double start_ms);
typedef void (*RuneWinDisplayVisitor)(void *, uint64_t id, const char *name, int32_t x, int32_t y,
                                      uint32_t width, uint32_t height, double scale, int32_t primary);
int rune_win_displays(void *context, RuneWinDisplayVisitor visit);

typedef enum {
    RUNE_WIN_FRAME, RUNE_WIN_SIZE, RUNE_WIN_MOVE, RUNE_WIN_DOWN, RUNE_WIN_UP,
    RUNE_WIN_LEAVE, RUNE_WIN_CAPTURE_LOST, RUNE_WIN_WHEEL, RUNE_WIN_KEY_DOWN,
    RUNE_WIN_KEY_UP, RUNE_WIN_CHAR, RUNE_WIN_IME_PREEDIT, RUNE_WIN_IME_COMMIT,
    RUNE_WIN_FOCUS, RUNE_WIN_VISIBILITY, RUNE_WIN_SETTINGS, RUNE_WIN_CLOSE,
    RUNE_WIN_DROP_FILE, RUNE_WIN_DROP_END, RUNE_WIN_DROP_ENTER, RUNE_WIN_DROP_OVER, RUNE_WIN_DROP_LEAVE, RUNE_WIN_WAKE,
    RUNE_WIN_TASKBAR_CREATED
} RuneWinEventKind;

typedef struct {
    RuneWinEventKind kind;
    uint32_t dpi, value, mods, scan, count, layout_char, shortcut_char;
    int32_t x, y, horizontal, repeated;
    float ticks;
    const uint16_t *text;
    uint32_t length;
} RuneWinEvent;

// All callbacks run synchronously on the thread that owns the window. FRAME returns
// milliseconds until its next redraw (-1 for idle, -2 to leave the loop). CLOSE returns
// whether to close. Key and composition callbacks return whether Rune consumed the message.
typedef int32_t (*RuneWinDispatch)(void *, const RuneWinEvent *);

RuneWinWindow *rune_win_create(const uint16_t *title, int32_t width, int32_t height,
                               int32_t min_width, int32_t min_height, int32_t dark,
                               char *error, int32_t error_capacity);
void *rune_win_hwnd(RuneWinWindow *window);
void rune_win_exit(RuneWinWindow *window);
void *rune_win_gl_proc(const char *name);
int32_t rune_win_make_current(RuneWinWindow *window);
int32_t rune_win_running(RuneWinWindow *window);
uint32_t rune_win_thread(void);
void rune_win_wake_thread(uint32_t thread);
typedef struct {
    int32_t max_width, max_height;
    int32_t borderless, resizable, minimizable, closable, maximized, fullscreen;
} RuneWinOptions;
void rune_win_configure(RuneWinWindow *window, RuneWinOptions options);
void rune_win_start(RuneWinWindow *window, void *context, RuneWinDispatch dispatch, int32_t inactive, int32_t visible);
int32_t rune_win_pump(void);
void rune_win_request_close(RuneWinWindow *window);
void rune_win_topmost(RuneWinWindow *window, int32_t on);
void rune_win_center(RuneWinWindow *window);
void rune_win_flash(RuneWinWindow *window, int32_t on);
int rune_win_taskbar(void *hwnd, int32_t progress, uint32_t badge, const uint16_t *description);
int32_t rune_win_run(RuneWinWindow *window, void *context, RuneWinDispatch dispatch, int32_t inactive);
int32_t rune_win_swap(RuneWinWindow *window);
void rune_win_destroy(RuneWinWindow *window);
void rune_win_wake(RuneWinWindow *window);
typedef struct {
    int32_t dark, reduced_motion, high_contrast, overlay_scrollbars;
    uint32_t double_click_ms, accent, window, text, highlight, highlight_text, disabled, button, button_text, link;
} RuneWinPreferences;
RuneWinPreferences rune_win_preferences(void);
void rune_win_dark_title(RuneWinWindow *window, int32_t dark);
void rune_win_set_title(RuneWinWindow *window, const uint16_t *title);
void rune_win_show(RuneWinWindow *window, int32_t show);
void rune_win_minimize(RuneWinWindow *window);
void rune_win_focus(RuneWinWindow *window);
void rune_win_place(RuneWinWindow *window, int32_t move, int32_t x, int32_t y,
                    int32_t resize, int32_t width, int32_t height);
typedef struct {
    int32_t x, y, content_x, content_y;
    uint32_t width, height;
    double scale;
    int32_t visible, maximized, minimized, fullscreen;
    int32_t has_restore, restore_x, restore_y;
    uint32_t restore_width, restore_height;
    uint64_t display;
    int32_t display_x, display_y;
    uint32_t display_width, display_height;
} RuneWinPlacement;
// Call on the owning window thread. All reported bounds are physical desktop pixels.
int rune_win_placement(RuneWinWindow *window, RuneWinPlacement *placement);
int rune_win_click_through(RuneWinWindow *window, int on);
typedef enum {
    RUNE_CURSOR_ARROW, RUNE_CURSOR_HAND, RUNE_CURSOR_TEXT, RUNE_CURSOR_MOVE,
    RUNE_CURSOR_DENIED, RUNE_CURSOR_COLUMN, RUNE_CURSOR_ROW, RUNE_CURSOR_CROSS,
    RUNE_CURSOR_HIDDEN
} RuneWinCursor;
void rune_win_cursor(RuneWinWindow *window, RuneWinCursor kind);
int rune_win_cursor_image(RuneWinWindow *window, const uint8_t *rgba, int32_t width, int32_t height,
                          int32_t target_width, int32_t target_height, int32_t x_hot, int32_t y_hot, int32_t crisp);
void rune_win_titlebar(RuneWinWindow *window, int32_t double_click);
void rune_win_ime_state(RuneWinWindow *window, int32_t enabled, int32_t reset);
typedef struct RuneWinDropTarget RuneWinDropTarget;
RuneWinDropTarget *rune_win_drop_attach(RuneWinWindow *window);
void rune_win_drop_detach(RuneWinDropTarget *target);
void rune_win_ime_caret(RuneWinWindow *window, int32_t x, int32_t y);

#ifdef __cplusplus
}
#endif

#endif
