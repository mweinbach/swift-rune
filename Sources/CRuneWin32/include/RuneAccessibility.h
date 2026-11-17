#ifndef RUNE_WINDOWS_ACCESSIBILITY_H
#define RUNE_WINDOWS_ACCESSIBILITY_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RuneUiaHost RuneUiaHost;
enum RuneUiaAction {
    RUNE_UIA_PRESS = 1, RUNE_UIA_FOCUS, RUNE_UIA_SET_TEXT, RUNE_UIA_SET_NUMBER,
    RUNE_UIA_EXPAND, RUNE_UIA_COLLAPSE, RUNE_UIA_SELECT
};
typedef struct RuneUiaTextCell {
    int32_t start, end, line;    /* UTF-16 offsets and zero-based visual line */
    double x, y, width, height; /* client pixels, clipped to the field */
    uint8_t rtl;
    double hit_midpoint;        /* midpoint of the full glyph advance before clipping */
    uint8_t has_hit_midpoint;
} RuneUiaTextCell;
typedef struct RuneUiaNode {
    int32_t id, parent;
    double x, y, width, height;
    double minimum, maximum, number, step;
    uint8_t focused, focusable, disabled, secure, read_only, pressable, settable, has_range;
    int8_t toggle; /* -1 if unavailable, otherwise UIA ToggleState */
    int8_t selected, expanded; /* -1 if unspecified */
    int32_t level, position, size_of_set; /* one-based, zero if unspecified */
    int8_t live;   /* 0 = off, 1 = polite, 2 = assertive */
} RuneUiaNode;

RuneUiaHost *rune_uia_attach(void *hwnd);
void rune_uia_detach(RuneUiaHost *host);
int rune_uia_active(const RuneUiaHost *host);
void rune_uia_begin(RuneUiaHost *host, const char *title);
void rune_uia_add(RuneUiaHost *host, RuneUiaNode node, const char *key, const char *role,
                  const char *name, const char *help, const char *value, const char *shortcut);
void rune_uia_text_model(RuneUiaHost *host, int32_t id, int32_t anchor, int32_t focus,
                         const uint16_t *text, int32_t length, const int32_t *graphemes, int32_t count);
void rune_uia_text_geometry(RuneUiaHost *host, int32_t id, const RuneUiaTextCell *cells, int32_t count);
int rune_uia_pop_text_selection(RuneUiaHost *host, int32_t *id, int32_t *start, int32_t *end, char **expected, int32_t *byteCount);
void rune_uia_commit(RuneUiaHost *host);
int rune_uia_pop(RuneUiaHost *host, int32_t *id, int32_t *action, char **text, double *number);
void rune_uia_free_text(char *text);

#ifdef __cplusplus
}
#endif
#endif
