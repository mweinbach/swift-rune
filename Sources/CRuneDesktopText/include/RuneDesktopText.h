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
#if defined(_WIN32)
// Windows' system ICU dictionaries load off the frame thread. Word ends are
// UTF-16 offsets. A negative count leaves the caller's rule-based fallback active.
void rune_windows_segmenter_start(void);
void rune_windows_segmenter_presented(void);
int32_t rune_windows_word_ends(const uint16_t *text, int32_t units, int32_t *ends);
int32_t rune_windows_visual_word_breaks(const uint16_t *text, int32_t units, uint8_t *flags);
RuneDesktopLine *rune_windows_line_create(const char *utf8, int32_t length, const char *family,
    float size_px, int32_t weight, int32_t italic, int32_t mono, int32_t direction, int32_t chromium_mask);
RuneDesktopLine *rune_windows_line_create_configured(const char *utf8, int32_t length, const char *family,
    float size_px, int32_t weight, int32_t italic, int32_t mono, int32_t direction, int32_t chromium_mask,
    const char *language, const char *features, const char *variations);
// Packed RGB coverage, with the same geometry as rune_desktop_line_mask.
int32_t rune_windows_line_lcd(const RuneDesktopLine *line, int32_t x, int32_t y,
    int32_t width, int32_t height, uint8_t *rgb);
#endif
#if defined(__wasi__)
// Browser raster platform: 0 other/standalone, 1 desktop Mac, 2 iOS/iPadOS, 3 Windows.
int32_t rune_browser_text_platform(void);
// As rune_desktop_line_cell, with magnitude 2 for a grapheme painted by a registered face.
int32_t rune_browser_ink_cell(const RuneDesktopLine *line, int32_t start, int32_t end,
    float *left, float *advance);
// Fill selection geometry for authored graphemes of a single native line in one host call.
// The caller supplies byte ranges. Collapsed caret positions can differ from selection edges.
typedef struct {
    int32_t start, end;
    float left, advance, caret, end_caret;
    int32_t direction;
} RuneBrowserCell;
void rune_browser_line_cells(const RuneDesktopLine *line, RuneBrowserCell *cells, int32_t count,
    int32_t report_source);
// Canvas font smoothing can change the R8 coverage with the opaque sRGB foreground.
int32_t rune_browser_line_fixed_pitch(const RuneDesktopLine *line);
// Query white coverage in [left, right). Returns 0 for full raster fallback, 1 for
// an empty crop, or 2 + (first covered row << 8) + exclusive end row.
int32_t rune_browser_line_mask_rows(const RuneDesktopLine *line, int32_t x, int32_t y,
    int32_t width, int32_t height, int32_t left, int32_t right, int32_t phase_x, int32_t phase_y);
int32_t rune_browser_line_geometry_style(const RuneDesktopLine *line);
int32_t rune_browser_line_mask_ink(const RuneDesktopLine *line, int32_t x, int32_t y,
    int32_t width, int32_t height, uint32_t rgb, uint8_t *pixels);
void rune_browser_host_wake(double delay_seconds);
#if defined(RUNE_BROWSER_TEXT)
// Synchronous browser spell request. READ consumes the sized response.
int32_t rune_browser_spell_request(int32_t op, const uint8_t *input, int32_t length);
void rune_browser_spell_read(uint8_t *output, int32_t length);
void rune_browser_font_url(const char *url, int32_t late);
// Browser dictionary segmentation. Text is UTF-8, the query and its result use UTF-16.
void rune_browser_word_range(const uint8_t *text, int32_t length, int32_t position, int32_t bounds[2]);
// Refines the UAX #14 break flags (one per UTF-16 boundary) inside dictionary-script runs.
void rune_browser_dictionary_lines(const uint8_t *text, int32_t length, uint8_t *breaks);
// Refines UAX #29 word flags (one per UTF-8 boundary) for visual caret movement.
void rune_browser_dictionary_words(const uint8_t *text, int32_t length, uint8_t *breaks);
#endif
#endif
#if defined(__ANDROID__)
void rune_android_text_attach(void *native_activity);
int32_t rune_android_bundled_fonts_ready(void);
int32_t rune_android_text_outlines_available(void);
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
#if defined(_WIN32)
typedef struct {
    int32_t start, end;
    float left, advance, caret, end_caret;
    int32_t direction;
} RuneWindowsCell;
void rune_windows_line_cells(const RuneDesktopLine *line, RuneWindowsCell *cells, int32_t count);
// Layout metrics (advance, ascent, descent, font_ascent, font_descent, cap_height) without
// forcing glyph-run raster analysis. ink_* fields are left zero.
RuneDesktopLineMetrics rune_windows_line_layout_metrics(const RuneDesktopLine *line);
// Nonzero when every shaped cluster in the line is a single UTF-16 code unit.
int32_t rune_windows_line_is_unit_clusters(const RuneDesktopLine *line);
#endif
// direction: 0 = auto, 1 = LTR, 2 = RTL. An empty family selects the system UI font.
RuneDesktopLine *rune_desktop_line_create(const char *utf8, int32_t length,
    const char *family, float size_px, int32_t weight, int32_t italic,
    int32_t mono, int32_t direction);
#if defined(__linux__) && !defined(__ANDROID__)
RuneDesktopLine *rune_linux_line_create_configured(const char *utf8, int32_t length,
    const char *family, float size_px, int32_t weight, int32_t italic, int32_t mono, int32_t direction,
    const char *language, const char *features, const char *variations);
#endif
#if defined(__wasi__)
RuneDesktopLine *rune_browser_line_create_configured(const char *utf8, int32_t length,
    const char *family, float size_px, int32_t weight, int32_t italic, int32_t mono, int32_t direction,
    const char *language, const char *features, const char *variations);
#endif
// Apply a language tag and comma-separated tag=value numeric OpenType settings after creation.
void rune_desktop_line_configure(RuneDesktopLine *line, const char *language,
    const char *features, const char *variations);
void rune_desktop_line_destroy(RuneDesktopLine *line);
RuneDesktopLineMetrics rune_desktop_line_metrics(const RuneDesktopLine *line);
// First logical UTF-8 byte of the native shaping cluster containing byte.
// Returns byte for an unavailable cluster or an index outside the line.
int32_t rune_desktop_line_cluster_owner(const RuneDesktopLine *line, int32_t byte);
#if defined(_WIN32) || (defined(__linux__) && !defined(__ANDROID__))
// Glyph origins, advances and UTF-8 cluster owners from the retained native layout.
// Includes glyphs without ink, such as ordinary spaces.
typedef void (*RuneQualityGlyphFn)(void *context, uint32_t glyph, int32_t utf8_owner,
    float x, float y, float advance);
int32_t rune_desktop_line_quality_glyphs(const RuneDesktopLine *line, void *context, RuneQualityGlyphFn emit);
// Independent text_quality raster experiment. Positions are absolute device pixels,
// and the top row of each A8 bitmap is borrowed only for the callback.
typedef void (*RuneQualityMaskFn)(void *context, int32_t x, int32_t y, int32_t width,
    int32_t height, int32_t stride, const uint8_t *pixels);
int32_t rune_desktop_line_quality_masks(const RuneDesktopLine *line, int32_t start, int32_t end,
    float origin_x, float baseline_y, int32_t hint, float embolden, void *context, RuneQualityMaskFn emit);
#endif
// Raster-only view of glyphs whose shaping cluster starts in the given UTF-8 range.
// Coordinates and baseline are those of the source line. A continuation returns a
// valid view with empty ink. Release the view with rune_desktop_line_destroy.
RuneDesktopLine *rune_desktop_line_extract_ink(const RuneDesktopLine *line, int32_t start, int32_t end);
#if defined(_WIN32) || defined(__linux__) || defined(__ANDROID__)
// A cluster view's shaped contours in the original line's device coordinates (y down).
// Commands are move, line, quadratic, cubic, and close (0...4). A valid empty view
// succeeds without emitting a contour. Color or unrepresentable ink uses the raster path.
typedef void (*RuneOutlineEmit)(void *context, int32_t command,
    float x1, float y1, float x2, float y2, float x3, float y3);
int32_t rune_desktop_line_outline(const RuneDesktopLine *ink, RuneOutlineEmit emit, void *context);
// Visits original shaped clusters with conservative device-pixel ink bounds. The byte
// offset names the original line's UTF-8 cluster owner. Zero requests per-range lookup.
typedef void (*RuneOutlineRegion)(void *context, int32_t utf8_owner,
    float left, float top, float right, float bottom);
int32_t rune_desktop_line_outline_regions(const RuneDesktopLine *line, RuneOutlineRegion emit, void *context);
// Stable identity and true pen of a single shaped glyph, for sharing curves
// between independently shaped strings. Returns zero for multi-glyph clusters.
// Bit 0 indicates success. Bit 1 identifies a face with the OS/2 CJK ranges.
int32_t rune_desktop_line_outline_single(const RuneDesktopLine *line, int32_t owner,
    uint64_t *font_id, uint32_t *glyph, float *pen_x, float *pen_y);
// The same single glyph at pen (0, 0) in device pixels, including the shaped
// font's size, axes and transforms. Position with the pen from outline_single.
int32_t rune_desktop_line_outline_unplaced(const RuneDesktopLine *line, int32_t owner,
    RuneOutlineEmit emit, void *context);
#if defined(__linux__) && !defined(__ANDROID__)
enum { RUNE_LINUX_HINT_DESIGN = 0, RUNE_LINUX_HINT_CHROMIUM = 1, RUNE_LINUX_HINT_AUTO = 2 };
// Shape-derived FreeType curves. A nonnegative owner requests intrinsic geometry
// from the original line. A negative owner exports an entire extracted ink view.
int32_t rune_linux_line_outline_fitted(const RuneDesktopLine *line, int32_t owner,
    float ppem, int32_t look, RuneOutlineEmit emit, void *context);
#endif
// Unscaled design metrics for Rune's 7–18 ppem CoreGraphics-style Y transform.
// The named glyphs are resolved via post, never via Unicode or OS/2 heights.
int32_t rune_desktop_line_apple_hint_metrics(const RuneDesktopLine *line, int32_t owner, double metrics[5]);
#endif
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
