#if defined(__linux__) && !defined(__ANDROID__)
#include "RuneDesktopText.h"
#include <pango/pangocairo.h>
#include <pango/pangofc-fontmap.h>
#include <fontconfig/fontconfig.h>
#include <hb-ot.h>
#include <math.h>
#include <string.h>

typedef struct {
    int leading, previous_trailing;
    // The sign records the first grapheme's visual direction, including zero-width
    // RTL glyphs. The magnitude bounds all ranges whose endpoints share this run.
    int signed_run_end;
    uint16_t level, previous_level;  // encoded as bidi embedding level + 1
} RuneGraphemeEdge;

struct RuneDesktopLine {
    RuneGraphemeEdge *grapheme_edges;
    PangoLayout *layout;
    RuneDesktopLineMetrics metrics;
    int32_t length;
    gboolean has_color;
};

// The default PangoCairo font map is thread-local. Invalidate each map lazily when
// an app registers a new face, including maps first used before registration.
static gint font_generation;
G_LOCK_DEFINE_STATIC(app_fonts);

int32_t rune_desktop_register_font_file(const char *path) {
    if (!path || !*path) return 0;
    G_LOCK(app_fonts);
    FcBool ok = FcConfigAppFontAddFile(FcConfigGetCurrent(), (const FcChar8 *)path);
    if (ok) g_atomic_int_inc(&font_generation);
    G_UNLOCK(app_fonts);
    return ok != FcFalse;
}

// Keep Pango's two edges at each Unicode cursor boundary. They can differ at
// changes of embedding level and for combining marks drawn by a fallback font.
static void index_grapheme_edges(RuneDesktopLine *line) {
    g_clear_pointer(&line->grapheme_edges, g_free);
    if (line->length < 128) return;
    line->grapheme_edges = g_try_new0(RuneGraphemeEdge, (gsize)line->length + 1);
    if (!line->grapheme_edges) return;

    const PangoLogAttr *attrs = pango_layout_get_log_attrs_readonly(line->layout, NULL);
    const char *text = pango_layout_get_text(line->layout);
    PangoLayoutIter *iter = pango_layout_get_iter(line->layout);
    const char *last_run = text;
    int run_char = 0;
    do {
        PangoLayoutRun *run = pango_layout_iter_get_run_readonly(iter);
        if (!run) continue;
        PangoRectangle rect;
        pango_layout_iter_get_run_extents(iter, NULL, &rect);
        const int level = run->item->analysis.level;
        const gboolean rtl = level % 2;
        int pen = rect.x + (rtl ? rect.width : 0);
        const char *run_start = text + run->item->offset;
        run_char += run_start >= last_run ? g_utf8_pointer_to_offset(last_run, run_start)
                                          : -g_utf8_pointer_to_offset(run_start, last_run);
        last_run = run_start;
        const int run_end = run->item->offset + run->item->length;
        int grapheme_start = -1;
        PangoGlyphItemIter cluster;
        for (gboolean more = pango_glyph_item_iter_init_start(&cluster, run, text);
             more; more = pango_glyph_item_iter_next_cluster(&cluster)) {
            const int count = ABS(cluster.end_glyph - cluster.start_glyph);
            if (count == 0) {
                grapheme_start = -1;
                continue;
            }
            int first = rtl ? cluster.end_glyph + 1 : cluster.start_glyph;
            int width = 0;
            for (int i = 0; i < count; ++i) width += run->glyphs->glyphs[first + i].geometry.width;
            const int left = rtl ? pen - width : pen;
            pen += rtl ? -width : width;
            const PangoLogAttr *boundaries = attrs + run_char + cluster.start_char;
            const char *start = text + cluster.start_index;
            const int bytes = cluster.end_index - cluster.start_index;
            const gboolean one_scalar = cluster.end_char == cluster.start_char + 1;
#if PANGO_VERSION_CHECK(1, 50, 0)
            // A standalone cluster has the same glyphs, offsets and native
            // ligature carets as the full run. All its glyphs map to byte zero.
            int local_offsets[8] = {0};
            int *offsets = (count <= 8 || one_scalar) ? local_offsets : g_new0(int, count);
            PangoGlyphString slice = {
                .num_glyphs = count, .glyphs = run->glyphs->glyphs + first, .log_clusters = offsets
            };
#else
            // Older Pango has no grapheme-aware cluster query.
            if (!one_scalar || !boundaries[0].is_cursor_position || !boundaries[1].is_cursor_position) {
                grapheme_start = -1;
                continue;
            }
#endif
            int scalar = 0;
            for (const char *ch = start; ch < start + bytes; ch = g_utf8_next_char(ch), ++scalar) {
                const int offset = (int)(ch - text);
                if (boundaries[scalar].is_cursor_position) {
                    int leading = rtl ? width : 0;
#if PANGO_VERSION_CHECK(1, 50, 0)
                    if (!one_scalar)
                        pango_glyph_string_index_to_x_full(&slice, start, bytes, &run->item->analysis,
                            (PangoLogAttr *)boundaries, (int)(ch - start), FALSE, &leading);
#endif
                    RuneGraphemeEdge *edge = line->grapheme_edges + offset;
                    edge->leading = left + leading;
                    edge->level = level + 1;
                    grapheme_start = offset;
                }
                if (boundaries[scalar + 1].is_cursor_position) {
                    // The trailing edge of an isolated fallback mark can coincide
                    // with its leading edge, even if the glyph has nonzero width.
                    int trailing = rtl ? 0 : width;
                    if (!boundaries[scalar].is_cursor_position) trailing = rtl ? width : 0;
#if PANGO_VERSION_CHECK(1, 50, 0)
                    if (!one_scalar)
                        pango_glyph_string_index_to_x_full(&slice, start, bytes, &run->item->analysis,
                            (PangoLogAttr *)boundaries, (int)(ch - start), TRUE, &trailing);
#endif
                    int end = (int)(g_utf8_next_char(ch) - text);
                    RuneGraphemeEdge *edge = line->grapheme_edges + end;
                    edge->previous_trailing = left + trailing;
                    edge->previous_level = level + 1;
                    if (grapheme_start >= 0) {
                        RuneGraphemeEdge *begin = line->grapheme_edges + grapheme_start;
                        begin->signed_run_end = begin->leading > edge->previous_trailing ? -run_end : run_end;
                    }
                    grapheme_start = -1;
                }
            }
#if PANGO_VERSION_CHECK(1, 50, 0)
            if (offsets != local_offsets) g_free(offsets);
#endif
        }
    } while (pango_layout_iter_next_run(iter));
    pango_layout_iter_free(iter);
}

static void measure_face(PangoFont *font, RuneDesktopLineMetrics *metrics) {
    hb_font_t *hb_font = pango_font_get_hb_font(font);
    hb_position_t position;
    if (hb_ot_metrics_get_position(hb_font, HB_OT_METRICS_TAG_HORIZONTAL_ASCENDER, &position))
        metrics->font_ascent = fmaxf(metrics->font_ascent, position / (float)PANGO_SCALE);
    if (hb_ot_metrics_get_position(hb_font, HB_OT_METRICS_TAG_HORIZONTAL_DESCENDER, &position))
        metrics->font_descent = fmaxf(metrics->font_descent, -position / (float)PANGO_SCALE);
    if (hb_ot_metrics_get_position(hb_font, HB_OT_METRICS_TAG_CAP_HEIGHT, &position))
        metrics->cap_height = fmaxf(metrics->cap_height, position / (float)PANGO_SCALE);
}

static void measure_line(RuneDesktopLine *result) {
    index_grapheme_edges(result);
    PangoRectangle ink, logical;
    pango_layout_get_pixel_extents(result->layout, &ink, NULL);
    pango_layout_get_extents(result->layout, NULL, &logical);
    // With fractional font metrics Cairo's antialiased coverage can reach two device
    // pixels beyond Pango's reported ink, including on the top edge of accented capitals.
    if (ink.width > 0 && ink.height > 0) {
        ink.x -= 2;
        ink.y -= 2;
        ink.width += 4;
        ink.height += 4;
    }
    float ascent = pango_layout_get_baseline(result->layout) / (float)PANGO_SCALE;
    result->metrics = (RuneDesktopLineMetrics) {
        logical.width / (float)PANGO_SCALE, ascent, logical.height / (float)PANGO_SCALE - ascent,
        ink.x, ink.y, ink.width, ink.height, 0, 0, 0
    };
    result->has_color = FALSE;
    PangoLayoutLine *line = pango_layout_get_line_readonly(result->layout, 0);
    for (GSList *entry = line ? line->runs : NULL; entry; entry = entry->next) {
        PangoLayoutRun *run = entry->data;
        if (run->item->analysis.font) measure_face(run->item->analysis.font, &result->metrics);
#if PANGO_VERSION_CHECK(1, 50, 0)
        for (int i = 0; !result->has_color && i < run->glyphs->num_glyphs; ++i)
            result->has_color = run->glyphs->glyphs[i].attr.is_color;
#endif
    }
    if (!line || !line->runs) {
        PangoFont *font = pango_context_load_font(pango_layout_get_context(result->layout),
            pango_layout_get_font_description(result->layout));
        if (font) {
            measure_face(font, &result->metrics);
            g_object_unref(font);
        }
    }
    if (result->metrics.font_ascent <= 0) {
        result->metrics.font_ascent = result->metrics.ascent;
        result->metrics.font_descent = result->metrics.descent;
    }
}

RuneDesktopLine *rune_desktop_line_create(const char *utf8, int32_t length,
    const char *family, float size_px, int32_t weight, int32_t italic,
    int32_t mono, int32_t direction) {
    if (!utf8 || length < 0 || !isfinite(size_px) || size_px <= 0 || size_px * (double)PANGO_SCALE > G_MAXINT) return NULL;
    PangoFontMap *map = pango_cairo_font_map_get_default();
    if (!map) return NULL;
    gint generation = g_atomic_int_get(&font_generation);
    if (PANGO_IS_FC_FONT_MAP(map) &&
        GPOINTER_TO_INT(g_object_get_data(G_OBJECT(map), "rune-font-generation")) != generation) {
        pango_fc_font_map_config_changed(PANGO_FC_FONT_MAP(map));
        g_object_set_data(G_OBJECT(map), "rune-font-generation", GINT_TO_POINTER(generation));
    }
    PangoContext *context = pango_font_map_create_context(map);
    cairo_font_options_t *options = cairo_font_options_create();
    cairo_font_options_set_antialias(options, CAIRO_ANTIALIAS_GRAY);
    cairo_font_options_set_hint_metrics(options, CAIRO_HINT_METRICS_OFF);
    pango_cairo_context_set_font_options(context, options);
    cairo_font_options_destroy(options);
#if PANGO_VERSION_CHECK(1, 44, 0)
    pango_context_set_round_glyph_positions(context, FALSE);
#endif
    if (direction) pango_context_set_base_dir(context, direction == 2 ? PANGO_DIRECTION_RTL : PANGO_DIRECTION_LTR);
    PangoLayout *layout = pango_layout_new(context);
    g_object_unref(context);
    pango_layout_set_auto_dir(layout, direction == 0);
    pango_layout_set_single_paragraph_mode(layout, TRUE);
    PangoFontDescription *font = pango_font_description_new();
    pango_font_description_set_family(font, family && *family ? family : (mono ? "monospace" : "sans-serif"));
    pango_font_description_set_absolute_size(font, size_px * PANGO_SCALE);
    pango_font_description_set_weight(font, (PangoWeight)weight);
    pango_font_description_set_style(font, italic ? PANGO_STYLE_ITALIC : PANGO_STYLE_NORMAL);
    pango_layout_set_font_description(layout, font);
    pango_font_description_free(font);
    // Pango stops at an embedded NUL even with an explicit byte count. Preserve the
    // remainder and its UTF-8 indices, including for caret and fallback queries.
    char *sanitized = NULL;
    if (memchr(utf8, 0, (size_t)length)) {
        sanitized = g_malloc((gsize)length + 1);
        for (int i = 0; i < length; ++i) sanitized[i] = utf8[i] ? utf8[i] : ' ';
        sanitized[length] = 0;
        utf8 = sanitized;
    }
    if (!g_utf8_validate(utf8, length, NULL)) {
        g_free(sanitized);
        g_object_unref(layout);
        return NULL;
    }
    pango_layout_set_text(layout, utf8, length);
    g_free(sanitized);

    RuneDesktopLine *result = g_new0(RuneDesktopLine, 1);
    result->layout = layout;
    result->length = length;
    measure_line(result);
    return result;
}

void rune_desktop_line_configure(RuneDesktopLine *line, const char *language,
    const char *features, const char *variations) {
    if (!line) return;
    PangoAttrList *attrs = pango_attr_list_new();
    if (language && *language)
        pango_attr_list_insert(attrs, pango_attr_language_new(pango_language_from_string(language)));
    if (features && *features)
        pango_attr_list_insert(attrs, pango_attr_font_features_new(features));
    pango_layout_set_attributes(line->layout, attrs);
    pango_attr_list_unref(attrs);
    PangoFontDescription *font = pango_font_description_copy(pango_layout_get_font_description(line->layout));
    pango_font_description_set_variations(font, variations && *variations ? variations : NULL);
    pango_layout_set_font_description(line->layout, font);
    pango_font_description_free(font);
    measure_line(line);
}

void rune_desktop_line_destroy(RuneDesktopLine *line) {
    if (!line) return;
    g_object_unref(line->layout);
    g_free(line->grapheme_edges);
    g_free(line);
}

RuneDesktopLineMetrics rune_desktop_line_metrics(const RuneDesktopLine *line) {
    return line ? line->metrics : (RuneDesktopLineMetrics){0};
}

float rune_desktop_line_caret(const RuneDesktopLine *line, int32_t byte_offset) {
    if (!line) return 0;
    byte_offset = CLAMP(byte_offset, 0, line->length);
    const char *utf8 = pango_layout_get_text(line->layout);
    while (byte_offset > 0 && byte_offset < line->length &&
           ((unsigned char)utf8[byte_offset] & 0xc0) == 0x80) --byte_offset;
    if (line->grapheme_edges && byte_offset > 0 && byte_offset < line->length) {
        const RuneGraphemeEdge *edge = line->grapheme_edges + byte_offset;
        if (edge->previous_level && edge->level) {
            if (edge->previous_trailing == edge->leading) return edge->leading / (float)PANGO_SCALE;
#if PANGO_VERSION_CHECK(1, 50, 0)
            // Use the boundary edge belonging to the paragraph's strong embedding.
            const int before = edge->previous_level - 1, after = edge->level - 1;
            const PangoLayoutLine *paragraph = pango_layout_get_line_readonly(line->layout, 0);
            const int base = paragraph->resolved_dir == PANGO_DIRECTION_RTL;
            const gboolean strong_before = (before % 2) == base && ((after % 2) != base || before < after);
            return (strong_before ? edge->previous_trailing : edge->leading) / (float)PANGO_SCALE;
#endif
        }
    }
    PangoRectangle strong;
    pango_layout_get_cursor_pos(line->layout, CLAMP(byte_offset, 0, line->length), &strong, NULL);
    return strong.x / (float)PANGO_SCALE;
}

int32_t rune_desktop_line_cell(const RuneDesktopLine *line, int32_t byte_offset, int32_t byte_end,
    float *left, float *advance) {
    if (!left || !advance) return 0;
    *left = *advance = 0;
    if (!line || byte_offset < 0 || byte_end <= byte_offset || byte_end > line->length) return 0;
    if (line->grapheme_edges) {
        const RuneGraphemeEdge *first = line->grapheme_edges + byte_offset;
        const RuneGraphemeEdge *last = line->grapheme_edges + byte_end;
        // Swift can join several Pango graphemes into one Character (Indic conjuncts).
        // Within one run, Pango resolves a selection using just its two outer edges.
        if (last->previous_level && byte_end <= ABS(first->signed_run_end)) {
            const int leading = first->leading, trailing = last->previous_trailing;
            *left = MIN(leading, trailing) / (float)PANGO_SCALE;
            *advance = ABS(trailing - leading) / (float)PANGO_SCALE;
            return first->signed_run_end < 0 ? -1 : 1;
        }
    }
    // Pango resolves the range in visual order, even at a change of direction or within a ligature.
    int *ranges = NULL, count = 0;
    pango_layout_line_get_x_ranges(pango_layout_get_line_readonly(line->layout, 0),
        byte_offset, byte_end, &ranges, &count);
    *left = count ? ranges[0] / (float)PANGO_SCALE : 0;
    *advance = 0;
    for (int i = 0; i < count; ++i) *advance += (ranges[2*i+1] - ranges[2*i]) / (float)PANGO_SCALE;
    g_free(ranges);
    PangoRectangle cell;
    pango_layout_index_to_pos(line->layout, byte_offset, &cell);
    return cell.width < 0 ? -1 : 1;
}

int32_t rune_desktop_line_has_color(const RuneDesktopLine *line) {
    return line && line->has_color;
}

static void paint_glyph_plane(cairo_t *cr, const RuneDesktopLine *line, gboolean color) {
    if (!line->has_color) {
        if (!color) {
            cairo_move_to(cr, 0, 0);
            pango_cairo_show_layout(cr, line->layout);
        }
        return;
    }
#if PANGO_VERSION_CHECK(1, 50, 0)
    PangoLayoutIter *iter = pango_layout_get_iter(line->layout);
    do {
        PangoLayoutRun *run = pango_layout_iter_get_run_readonly(iter);
        if (!run) continue;
        PangoRectangle logical;
        pango_layout_iter_get_run_extents(iter, NULL, &logical);
        const int baseline = pango_layout_iter_get_run_baseline(iter);
        int pen = logical.x;
        const PangoGlyphString *glyphs = run->glyphs;
        // A fallback run can contain both palette glyphs and tintable outlines.
        // Keep each slice's shaped offsets and advance across the other plane's ink.
        for (int first = 0; first < glyphs->num_glyphs;) {
            const gboolean is_color = glyphs->glyphs[first].attr.is_color;
            int end = first, advance = 0;
            do {
                advance += glyphs->glyphs[end].geometry.width;
                ++end;
            } while (end < glyphs->num_glyphs && glyphs->glyphs[end].attr.is_color == is_color);
            if (is_color == color) {
                PangoGlyphString slice = *glyphs;
                slice.num_glyphs = end - first;
                slice.glyphs += first;
                slice.log_clusters += first;
                cairo_move_to(cr, pen / (double)PANGO_SCALE, baseline / (double)PANGO_SCALE);
                pango_cairo_show_glyph_string(cr, run->item->analysis.font, &slice);
            }
            pen += advance;
            first = end;
        }
    } while (pango_layout_iter_next_run(iter));
    pango_layout_iter_free(iter);
#endif
}

static int32_t line_plane(const RuneDesktopLine *line, int32_t x, int32_t y,
    int32_t width, int32_t height, uint8_t *pixels, gboolean color) {
    if (!line || !pixels || width <= 0 || width > 4096 || height <= 0 || height > 4096) return 0;
    cairo_surface_t *surface = cairo_image_surface_create(color ? CAIRO_FORMAT_ARGB32 : CAIRO_FORMAT_A8,
                                                          width, height);
    cairo_t *cr = cairo_create(surface);
    cairo_translate(cr, -(double)x, -(double)y);
    cairo_set_source_rgba(cr, 1, 1, 1, 1);
    paint_glyph_plane(cr, line, color);
    cairo_surface_flush(surface);
    int ok = cairo_status(cr) == CAIRO_STATUS_SUCCESS && cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS;
    if (ok) {
        const uint8_t *data = cairo_image_surface_get_data(surface);
        int stride = cairo_image_surface_get_stride(surface);
        for (int32_t row = 0; row < height; ++row) {
            const uint8_t *src = data + (size_t)row * stride;
            if (!color) {
                memcpy(pixels + (size_t)row * width, src, width);
                continue;
            }
            // Cairo stores native-endian premultiplied ARGB words. Rune's image
            // atlas consumes straight, byte-ordered RGBA in sRGB.
            uint8_t *dst = pixels + (size_t)row * width * 4;
            for (int32_t col = 0; col < width; ++col) {
                const uint32_t pixel = ((const uint32_t *)src)[col];
                const unsigned a = pixel >> 24;
                for (int channel = 0; channel < 3; ++channel) {
                    const unsigned component = (pixel >> (16 - 8 * channel)) & 255;
                    *dst++ = a ? (uint8_t)((component * 255 + a / 2) / a) : 0;
                }
                *dst++ = (uint8_t)a;
            }
        }
    }
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    return ok;
}

int32_t rune_desktop_line_mask(const RuneDesktopLine *line, int32_t x, int32_t y,
    int32_t width, int32_t height, uint8_t *pixels) {
    return line_plane(line, x, y, width, height, pixels, FALSE);
}

int32_t rune_desktop_line_color(const RuneDesktopLine *line, int32_t x, int32_t y,
    int32_t width, int32_t height, uint8_t *pixels) {
    return line_plane(line, x, y, width, height, pixels, TRUE);
}
#endif
