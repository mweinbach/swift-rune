#ifndef C_RUNE_LINUX_A11Y_H
#define C_RUNE_LINUX_A11Y_H

#include <stdint.h>

typedef struct RuneA11yWindow RuneA11yWindow;
typedef void (*RuneA11yWake)(void *);
typedef void (*RuneA11yAction)(void *, const char *target, int kind, const char *text, double number, int start, int end);

enum {
    RUNE_AX_PRESS = 1, RUNE_AX_FOCUS = 2, RUNE_AX_INCREMENT = 4, RUNE_AX_DECREMENT = 8,
    RUNE_AX_SET_TEXT = 16, RUNE_AX_SET_NUMBER = 32, RUNE_AX_SELECT_TEXT = 64, RUNE_AX_REPLACE_TEXT = 128
};
enum {
    RUNE_AX_DISABLED = 1 << 0, RUNE_AX_FOCUSABLE = 1 << 1, RUNE_AX_FOCUSED = 1 << 2,
    RUNE_AX_CHECKABLE = 1 << 3, RUNE_AX_CHECKED = 1 << 4, RUNE_AX_MIXED = 1 << 5,
    RUNE_AX_SELECTABLE = 1 << 6, RUNE_AX_SELECTED = 1 << 7, RUNE_AX_EXPANDABLE = 1 << 8,
    RUNE_AX_EXPANDED = 1 << 9, RUNE_AX_READ_ONLY = 1 << 10, RUNE_AX_BUSY = 1 << 11,
    RUNE_AX_INVALID = 1 << 12, RUNE_AX_MODAL = 1 << 13, RUNE_AX_OFFSCREEN = 1 << 14
};

typedef struct {
    int x, y, width, height;
    /* Unicode scalar offsets, -1 for fields whose selection is unavailable. */
    int anchor, caret;
    uint32_t state, actions;
    double value, minimum, maximum, step;
} RuneA11yProperties;

/* Scalar indices refer to the original UTF-8 string. Coordinates are logical pixels in
   the Rune window. Fully clipped graphemes retain their logical ranges and visual line. */
typedef struct {
    int32_t start, end, line;
    double x, y, width, height;
} RuneA11yTextCell;

/* Calls run on the SDL host thread. Only wake is called on a background poll thread. */
RuneA11yWindow *rune_ax_open(const char *title, int visible, RuneA11yWake wake, void *context);
void rune_ax_visible(RuneA11yWindow *, int visible);
/* Add/remove another toolkit's native AtkObject from the shared application root. */
void rune_ax_toolkit_window(void *accessible, int visible);
void rune_ax_pump(RuneA11yWindow *, RuneA11yAction consume, void *context);
void rune_ax_begin(RuneA11yWindow *, const char *title, int x, int y, int width, int height, int focused);
void rune_ax_node(RuneA11yWindow *, const char *key, const char *parent_key, int index,
                  const char *target, const char *role, const char *name, const char *help,
                  const char *value_text, const char *shortcut, RuneA11yProperties properties);
void rune_ax_text_geometry(RuneA11yWindow *, const char *key, const RuneA11yTextCell *cells, int count);
void rune_ax_end(RuneA11yWindow *);
void rune_ax_announce(RuneA11yWindow *, const char *text, int assertive);
void rune_ax_close(RuneA11yWindow *);
#endif
