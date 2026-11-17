#ifndef RUNE_DESKTOP_TEXT_H
#define RUNE_DESKTOP_TEXT_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

// A single styled line. Lengths and cursor indices are UTF-8 byte offsets.
// All coordinates are device pixels, x increases right and y increases down.
// The logical origin of the line is its top left, including for RTL text.
typedef struct RuneDesktopLine RuneDesktopLine;
#if defined(__wasi__)
// Browser raster platform: 0 other/standalone, 1 desktop Mac, 2 iOS/iPadOS, 3 Windows.
int32_t rune_browser_text_platform(void);
#endif
#if defined(__ANDROID__)
void rune_android_text_attach(void *native_activity);
int32_t rune_android_bundled_fonts_ready(void);
#endif
// Adds a font to this process's text backend. The caller may release the byte
// buffer immediately. File registrations require the file to remain available.
int32_t rune_desktop_register_font_file(const char *utf8_path);
int32_t rune_desktop_register_font_bytes(const uint8_t *bytes, uint32_t length);
typedef struct {
    // Native raster layout and its ink bounds, measured from the line's top left.
    float advance, ascent, descent;
    int32_t ink_x, ink_y, ink_width, ink_height;
    // Unhinted face extents at the requested device-pixel size. Descent is positive.
    // cap_height is zero when unavailable.
    float font_ascent, font_descent, cap_height;
} RuneDesktopLineMetrics;
// direction: 0 = auto, 1 = LTR, 2 = RTL. An empty family selects the system UI font.
RuneDesktopLine *rune_desktop_line_create(const char *utf8, int32_t length,
    const char *family, float size_px, int32_t weight, int32_t italic,
    int32_t mono, int32_t direction);
// Apply a language tag and comma-separated tag=value numeric OpenType settings after creation.
void rune_desktop_line_configure(RuneDesktopLine *line, const char *language,
    const char *features, const char *variations);
void rune_desktop_line_destroy(RuneDesktopLine *line);
RuneDesktopLineMetrics rune_desktop_line_metrics(const RuneDesktopLine *line);
float rune_desktop_line_caret(const RuneDesktopLine *line, int32_t byte_offset);
// Visual left edge and positive advance of [byte_offset, byte_end), a grapheme.
// Returns +1 for LTR, -1 for RTL or 0 for an empty range.
int32_t rune_desktop_line_cell(const RuneDesktopLine *line, int32_t byte_offset, int32_t byte_end,
    float *left, float *advance);
// Paint the requested rectangle into a packed width * height R8 coverage buffer.
int32_t rune_desktop_line_mask(const RuneDesktopLine *line, int32_t x, int32_t y,
    int32_t width, int32_t height, uint8_t *pixels);
// The R8 mask contains foreground-tinted ink. Embedded palette colors are
// returned separately as straight sRGB RGBA, transparent outside colored glyphs.
int32_t rune_desktop_line_has_color(const RuneDesktopLine *line);
int32_t rune_desktop_line_color(const RuneDesktopLine *line, int32_t x, int32_t y,
    int32_t width, int32_t height, uint8_t *rgba);
#ifdef __cplusplus
}
#endif
#endif
