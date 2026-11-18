#ifdef __wasi__
#include "RuneDesktopText.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

// A standalone WASI command has only Preview 1 imports and uses Rune's bitmap font.
#ifdef RUNE_BROWSER_TEXT
#define IMPORT(name) __attribute__((import_module("rune_text"), import_name(name)))
IMPORT("spell_request") extern int32_t browser_spell_request(int32_t, const uint8_t *, int32_t);
IMPORT("spell_read") extern void browser_spell_read(uint8_t *, int32_t);
int32_t rune_browser_spell_request(int32_t op, const uint8_t *input, int32_t length) {
    return browser_spell_request(op, input, length);
}
void rune_browser_spell_read(uint8_t *output, int32_t length) {
    browser_spell_read(output, length);
}
IMPORT("platform") extern int32_t browser_text_platform(void);
IMPORT("word_range") extern void browser_word_range(const uint8_t *, int32_t, int32_t, int32_t *);
IMPORT("dictionary_lines") extern void browser_dictionary_lines(const uint8_t *, int32_t, uint8_t *);
IMPORT("dictionary_words") extern void browser_dictionary_words(const uint8_t *, int32_t, uint8_t *);
IMPORT("create") extern uint32_t browser_create(const char *, int32_t, const char *, int32_t,
    float, int32_t, int32_t, int32_t, int32_t, RuneDesktopLineMetrics *, uint32_t);
IMPORT("release") extern void browser_release(uint32_t);
IMPORT("extract_ink") extern uint32_t browser_extract_ink(uint32_t, int32_t, int32_t,
    RuneDesktopLineMetrics *, uint32_t);
IMPORT("caret") extern float browser_caret(uint32_t, int32_t);
IMPORT("cell") extern int32_t browser_cell(uint32_t, int32_t, int32_t, float *, float *, uint32_t);
IMPORT("cells") extern void browser_cells(uint32_t, RuneBrowserCell *, int32_t, int32_t);
IMPORT("mask") extern int32_t browser_mask(uint32_t, int32_t, int32_t, int32_t, int32_t, uint8_t *, uint32_t);
IMPORT("has_color") extern int32_t browser_has_color(uint32_t);
IMPORT("color") extern int32_t browser_color(uint32_t, int32_t, int32_t, int32_t, int32_t, uint8_t *);
IMPORT("font") extern int32_t browser_register_font(const uint8_t *, uint32_t);
IMPORT("font_url") extern void browser_font_url(const char *, int32_t, int32_t);
IMPORT("configure") extern void browser_configure(uint32_t, const char *, int32_t, const char *,
    int32_t, const char *, int32_t, RuneDesktopLineMetrics *, uint32_t);
#elif defined(__clang__)
// Standalone implementations below satisfy the same ABI without a text host.
#pragma clang diagnostic ignored "-Wunused-parameter"
#endif

#ifdef RUNE_BROWSER_TEXT
void rune_browser_font_url(const char *url, int32_t late) {
    if (url) browser_font_url(url, (int32_t)strlen(url), late);
}

void rune_browser_word_range(const uint8_t *text, int32_t length, int32_t position, int32_t bounds[2]) {
    browser_word_range(text, length, position, bounds);
}

void rune_browser_dictionary_lines(const uint8_t *text, int32_t length, uint8_t *breaks) {
    browser_dictionary_lines(text, length, breaks);
}

void rune_browser_dictionary_words(const uint8_t *text, int32_t length, uint8_t *breaks) {
    browser_dictionary_words(text, length, breaks);
}
#endif

struct RuneDesktopLine {
    RuneDesktopLineMetrics metrics;
    uint32_t handle;
};

int32_t rune_browser_text_platform(void) {
#ifdef RUNE_BROWSER_TEXT
    return browser_text_platform();
#else
    return 0;
#endif
}

RuneDesktopLine *rune_desktop_line_create(const char *text, int32_t length, const char *family,
    float size, int32_t weight, int32_t italic, int32_t mono, int32_t direction) {
#ifdef RUNE_BROWSER_TEXT
    if (!text || length < 0 || !isfinite(size) || size <= 0 || size > 4096) return NULL;
    RuneDesktopLine *line = calloc(1, sizeof *line);
    if (!line) return NULL;
    line->handle = browser_create(text, length, family, family ? (int32_t)strlen(family) : 0,
        size, weight, italic, mono, direction, &line->metrics, sizeof(line->metrics));
    if (line->handle) return line;
    free(line);
#endif
    return NULL;
}

void rune_desktop_line_configure(RuneDesktopLine *line, const char *language,
    const char *features, const char *variations) {
#ifdef RUNE_BROWSER_TEXT
    if (line) browser_configure(line->handle, language, language ? (int32_t)strlen(language) : 0,
        features, features ? (int32_t)strlen(features) : 0, variations,
        variations ? (int32_t)strlen(variations) : 0, &line->metrics, sizeof(line->metrics));
#endif
}

void rune_desktop_line_destroy(RuneDesktopLine *line) {
#ifdef RUNE_BROWSER_TEXT
    if (line) browser_release(line->handle);
#endif
    free(line);
}

RuneDesktopLine *rune_desktop_line_extract_ink(const RuneDesktopLine *line, int32_t start, int32_t end) {
#ifdef RUNE_BROWSER_TEXT
    if (!line || start < 0 || end < start) return NULL;
    RuneDesktopLine *ink = calloc(1, sizeof *ink);
    if (!ink) return NULL;
    ink->handle = browser_extract_ink(line->handle, start, end, &ink->metrics, sizeof ink->metrics);
    if (ink->handle) return ink;
    free(ink);
#endif
    return NULL;
}

RuneDesktopLineMetrics rune_desktop_line_metrics(const RuneDesktopLine *line) {
    return line ? line->metrics : (RuneDesktopLineMetrics){0};
}

float rune_desktop_line_caret(const RuneDesktopLine *line, int32_t byte) {
#ifdef RUNE_BROWSER_TEXT
    if (line) return browser_caret(line->handle, byte);
#endif
    return 0;
}

static int32_t read_cell(const RuneDesktopLine *line, int32_t start, int32_t end,
    float *left, float *advance, uint32_t report_source) {
#ifdef RUNE_BROWSER_TEXT
    if (line && left && advance) return browser_cell(line->handle, start, end, left, advance, report_source);
#endif
    return 0;
}

int32_t rune_desktop_line_cell(const RuneDesktopLine *line, int32_t start, int32_t end,
    float *left, float *advance) {
    const int32_t direction = read_cell(line, start, end, left, advance, 0);
    return (direction > 0) - (direction < 0);
}

int32_t rune_browser_ink_cell(const RuneDesktopLine *line, int32_t start, int32_t end,
    float *left, float *advance) {
    return read_cell(line, start, end, left, advance, 1);
}

void rune_browser_line_cells(const RuneDesktopLine *line, RuneBrowserCell *cells, int32_t count,
    int32_t report_source) {
#ifdef RUNE_BROWSER_TEXT
    _Static_assert(sizeof(RuneBrowserCell) == 7 * sizeof(uint32_t), "Unexpected browser cell layout");
    if (line && cells && count > 0) browser_cells(line->handle, cells, count, report_source);
#endif
}

int32_t rune_desktop_line_mask(const RuneDesktopLine *line, int32_t x, int32_t y,
    int32_t width, int32_t height, uint8_t *pixels) {
    return rune_browser_line_mask_ink(line, x, y, width, height, 0xffffff, pixels);
}

int32_t rune_browser_line_mask_ink(const RuneDesktopLine *line, int32_t x, int32_t y,
    int32_t width, int32_t height, uint32_t rgb, uint8_t *pixels) {
#ifdef RUNE_BROWSER_TEXT
    if (line && pixels && width > 0 && height > 0)
        return browser_mask(line->handle, x, y, width, height, pixels, rgb);
#endif
    return 0;
}

int32_t rune_desktop_register_font_bytes(const uint8_t *bytes, uint32_t length) {
#ifdef RUNE_BROWSER_TEXT
    if (bytes && length) return browser_register_font(bytes, length);
#endif
    return 0;
}

int32_t rune_desktop_register_font_file(const char *path) {
    (void)path;
    return 0;
}

int32_t rune_desktop_line_has_color(const RuneDesktopLine *line) {
#ifdef RUNE_BROWSER_TEXT
    if (line) return browser_has_color(line->handle);
#endif
    return 0;
}

int32_t rune_desktop_line_color(const RuneDesktopLine *line, int32_t x, int32_t y,
    int32_t width, int32_t height, uint8_t *rgba) {
#ifdef RUNE_BROWSER_TEXT
    if (line && rgba && width > 0 && height > 0)
        return browser_color(line->handle, x, y, width, height, rgba);
#endif
    return 0;
}
#endif
