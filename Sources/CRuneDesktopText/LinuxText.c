#if defined(__linux__) && !defined(__ANDROID__)
#include "RuneDesktopText.h"
#include <pango/pangocairo.h>
#include <pango/pangofc-fontmap.h>
#include <fontconfig/fontconfig.h>
#include <hb-ot.h>
#include <cairo-ft.h>
#include <ft2build.h>
#include FT_MULTIPLE_MASTERS_H
#include FT_GASP_H
#include FT_OUTLINE_H
#include FT_TRUETYPE_TABLES_H
#include <math.h>
#include <string.h>

typedef struct {
    int leading, previous_trailing;
    // The sign records the first grapheme's visual direction, including zero-width
    // RTL glyphs. The magnitude bounds all ranges whose endpoints share this run.
    int signed_run_end;
    uint16_t level, previous_level;  // encoded as bidi embedding level + 1
} RuneGraphemeEdge;

typedef struct {
    int owner, visual, x, baseline, first, count;
    PangoFont *font;
    PangoGlyphString *glyphs;
} InkCluster;

struct RuneDesktopLine {
    GMutex index_lock;
    GArray *cluster_index;
    GPtrArray *indexed_runs;
    GArray *owned_clusters;
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
    g_clear_pointer(&result->cluster_index, g_array_unref);
    g_clear_pointer(&result->indexed_runs, g_ptr_array_unref);
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

#if PANGO_VERSION_CHECK(1, 46, 0)
typedef struct {
    int weight, style, stretch;
} RuneStaticCut;

typedef struct {
    PangoFontMap *map;
    guint serial;
    GHashTable *stacks;
} RuneFaceCache;

static void free_face_cache(gpointer value) {
    RuneFaceCache *cache = value;
    g_hash_table_unref(cache->stacks);
    g_object_unref(cache->map);
    g_free(cache);
}

static GPrivate thread_face_cache = G_PRIVATE_INIT(free_face_cache);

// Pango's default map belongs to the thread. A map serial also changes when
// new app fonts arrive, so a previous fallback cannot hide a newly added cut.
static GArray *static_cuts(PangoFontMap *map, const char *stack) {
    const guint serial = pango_font_map_get_serial(map);
    RuneFaceCache *cache = g_private_get(&thread_face_cache);
    if (!cache || cache->map != map || cache->serial != serial) {
        cache = g_new(RuneFaceCache, 1);
        cache->map = g_object_ref(map);
        cache->serial = serial;
        cache->stacks = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, (GDestroyNotify)g_array_unref);
        g_private_replace(&thread_face_cache, cache);
    }
    GArray *cuts = g_hash_table_lookup(cache->stacks, stack);
    if (cuts) return cuts;
    cuts = g_array_new(FALSE, FALSE, sizeof(RuneStaticCut));
    gchar **families = g_strsplit(stack, ",", -1);
    for (gchar **part = families; *part; ++part) {
        const char *name = g_strstrip(*part);
        if (!*name) continue;
        // Fontconfig handles generic families and variable design axes natively.
        if (g_ascii_strcasecmp(name, "sans-serif") == 0 || g_ascii_strcasecmp(name, "serif") == 0 ||
            g_ascii_strcasecmp(name, "monospace") == 0 || g_ascii_strcasecmp(name, "system-ui") == 0) break;
        PangoFontFamily *family = pango_font_map_get_family(map, name);
        if (!family) continue;
        if (pango_font_family_is_variable(family)) break;
        PangoFontFace **faces = NULL;
        int count = 0;
        pango_font_family_list_faces(family, &faces, &count);
        for (int i = 0; i < count; ++i) {
            if (pango_font_face_is_synthesized(faces[i])) continue;
            PangoFontDescription *desc = pango_font_face_describe(faces[i]);
            RuneStaticCut cut = { pango_font_description_get_weight(desc), pango_font_description_get_style(desc),
                                  pango_font_description_get_stretch(desc) };
            g_array_append_val(cuts, cut);
            pango_font_description_free(desc);
        }
        g_free(faces);
        break;
    }
    g_strfreev(families);
    // Arbitrary user-authored fallback stacks should not grow this thread's cache without bound.
    if (g_hash_table_size(cache->stacks) >= 256) g_hash_table_remove_all(cache->stacks);
    g_hash_table_insert(cache->stacks, g_strdup(stack), cuts);
    return cuts;
}

static int weight_rank(int weight, int target) {
    if (target >= 400 && target <= 500) {
        if (weight >= target && weight <= 500) return weight - target;
        if (weight < target) return 1000 + target - weight;
        return 2000 + weight - 500;
    }
    const gboolean preferred = target < 400 ? weight <= target : weight >= target;
    return (preferred ? 0 : 1000) + ABS(weight - target);
}
#endif

// CSS/Fontique match width, then style, then weight. Fontconfig's default
// weight comparison instead picks Regular for requests such as Inter 440.
static PangoWeight match_css_weight(PangoFontMap *map, const char *stack, int target, gboolean italic) {
    int best_weight = target;
#if PANGO_VERSION_CHECK(1, 46, 0)
    if (!stack || !*stack) return (PangoWeight)target;
    GArray *cuts = static_cuts(map, stack);
    int best_rank = G_MAXINT;
    for (guint i = 0; i < cuts->len; ++i) {
        RuneStaticCut cut = g_array_index(cuts, RuneStaticCut, i);
        int width_rank = cut.stretch <= PANGO_STRETCH_NORMAL ? PANGO_STRETCH_NORMAL - cut.stretch
                                                             : 5 + cut.stretch - PANGO_STRETCH_NORMAL;
        int style_rank = italic ? (cut.style == PANGO_STYLE_ITALIC ? 0 : cut.style == PANGO_STYLE_OBLIQUE ? 1 : 2)
                                : (cut.style == PANGO_STYLE_NORMAL ? 0 : cut.style == PANGO_STYLE_OBLIQUE ? 1 : 2);
        const int rank = 12000 * width_rank + 4000 * style_rank + weight_rank(cut.weight, target);
        if (rank < best_rank) {
            best_rank = rank;
            best_weight = cut.weight;
        }
    }
#endif
    return (PangoWeight)best_weight;
}

static void set_shaping_options(PangoLayout *layout, PangoFontDescription *font,
    const char *language, const char *features, const char *variations) {
    PangoAttrList *attrs = NULL;
    if ((language && *language) || (features && *features)) {
        attrs = pango_attr_list_new();
        if (language && *language)
            pango_attr_list_insert(attrs, pango_attr_language_new(pango_language_from_string(language)));
        if (features && *features)
            pango_attr_list_insert(attrs, pango_attr_font_features_new(features));
    }
    pango_layout_set_attributes(layout, attrs);
    if (attrs) pango_attr_list_unref(attrs);
    pango_font_description_set_variations(font, variations && *variations ? variations : NULL);
    pango_layout_set_font_description(layout, font);
}

RuneDesktopLine *rune_linux_line_create_configured(const char *utf8, int32_t length,
    const char *family, float size_px, int32_t weight, int32_t italic, int32_t mono, int32_t direction,
    const char *language, const char *features, const char *variations) {
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
    pango_font_description_set_weight(font, match_css_weight(map, family, weight, italic));
    pango_font_description_set_style(font, italic ? PANGO_STYLE_ITALIC : PANGO_STYLE_NORMAL);
    set_shaping_options(layout, font, language, features, variations);
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
    g_mutex_init(&result->index_lock);
    result->layout = layout;
    result->length = length;
    measure_line(result);
    return result;
}

RuneDesktopLine *rune_desktop_line_create(const char *utf8, int32_t length,
    const char *family, float size_px, int32_t weight, int32_t italic, int32_t mono, int32_t direction) {
    return rune_linux_line_create_configured(utf8, length, family, size_px, weight, italic, mono, direction,
                                              NULL, NULL, NULL);
}

void rune_desktop_line_configure(RuneDesktopLine *line, const char *language,
    const char *features, const char *variations) {
    if (!line || !line->layout) return;
    g_mutex_lock(&line->index_lock);
    PangoFontDescription *font = pango_font_description_copy(pango_layout_get_font_description(line->layout));
    set_shaping_options(line->layout, font, language, features, variations);
    pango_font_description_free(font);
    measure_line(line);
    g_mutex_unlock(&line->index_lock);
}

void rune_desktop_line_destroy(RuneDesktopLine *line) {
    if (!line) return;
    if (line->layout) g_mutex_clear(&line->index_lock);
    g_clear_object(&line->layout);
    g_clear_pointer(&line->cluster_index, g_array_unref);
    g_clear_pointer(&line->indexed_runs, g_ptr_array_unref);
    g_clear_pointer(&line->owned_clusters, g_array_unref);
    g_free(line->grapheme_edges);
    g_free(line);
}

RuneDesktopLineMetrics rune_desktop_line_metrics(const RuneDesktopLine *line) {
    return line ? line->metrics : (RuneDesktopLineMetrics){0};
}

float rune_desktop_line_caret(const RuneDesktopLine *line, int32_t byte_offset) {
    if (!line || !line->layout) return 0;
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

static gint cluster_order(gconstpointer a, gconstpointer b) {
    const InkCluster *lhs = a, *rhs = b;
    return lhs->owner != rhs->owner ? lhs->owner - rhs->owner : lhs->visual - rhs->visual;
}

// log_clusters maps visual glyph order back to the first UTF-8 byte of each
// shaping cluster. Index once, since callers can request each grapheme separately.
static GArray *index_clusters(RuneDesktopLine *line) {
    GArray *index = g_array_new(FALSE, FALSE, sizeof(InkCluster));
    line->indexed_runs = g_ptr_array_new_with_free_func((GDestroyNotify)pango_glyph_item_free);
    PangoLayoutIter *iter = pango_layout_get_iter(line->layout);
    do {
        PangoLayoutRun *run = pango_layout_iter_get_run_readonly(iter);
        if (!run) continue;
        PangoRectangle logical;
        pango_layout_iter_get_run_extents(iter, NULL, &logical);
#if PANGO_VERSION_CHECK(1, 50, 0)
        const int baseline = pango_layout_iter_get_run_baseline(iter);
#else
        const int baseline = pango_layout_iter_get_baseline(iter);
#endif
        // Pango can invalidate its layout runs when fonts change. Share immutable
        // snapshots with extracted views so they can outlive a reconfigured line.
        run = pango_glyph_item_copy(run);
        g_ptr_array_add(line->indexed_runs, run);
        PangoGlyphString *glyphs = run->glyphs;
        int pen = logical.x;
        for (int first = 0; first < glyphs->num_glyphs;) {
            const int offset = glyphs->log_clusters[first];
            const int x = pen;
            int end = first;
            do { pen += glyphs->glyphs[end++].geometry.width; }
            while (end < glyphs->num_glyphs && glyphs->log_clusters[end] == offset);
            InkCluster cluster = {run->item->offset + offset, (int)index->len,
                x, baseline, first, end - first, run->item->analysis.font, glyphs};
            g_array_append_val(index, cluster);
            first = end;
        }
    } while (pango_layout_iter_next_run(iter));
    pango_layout_iter_free(iter);
    g_array_sort(index, cluster_order);
    return index;
}

static gint visual_order(gconstpointer a, gconstpointer b) {
    return ((const InkCluster *)a)->visual - ((const InkCluster *)b)->visual;
}

static PangoGlyphString cluster_glyphs(const InkCluster *c) {
    PangoGlyphString slice = *c->glyphs;
    slice.glyphs += c->first;
    slice.log_clusters += c->first;
    slice.num_glyphs = c->count;
    return slice;
}

G_LOCK_DEFINE_STATIC(outline_fonts);
static uint64_t outline_font_serial;

// An ID belongs to this PangoFont instance, including its size, variation and
// synthetic transform. A new font at a recycled address receives a new ID.
typedef struct { uint64_t id; gboolean cjk; } OutlineFont;

static OutlineFont outline_font(PangoFont *font) {
    const GQuark key = g_quark_from_static_string("rune-outline-font-id");
    G_LOCK(outline_fonts);
    OutlineFont *entry = g_object_get_qdata(G_OBJECT(font), key);
    if (!entry) {
        entry = g_new0(OutlineFont, 1);
        entry->id = ++outline_font_serial;
#if PANGO_VERSION_CHECK(1, 44, 0)
        // The pinned painter classifies Han, kana and Hangul by OS/2 ulUnicodeRange2.
        hb_face_t *face = hb_font_get_face(pango_font_get_hb_font(font));
        hb_blob_t *os2 = hb_face_reference_table(face, HB_TAG('O','S','/','2'));
        unsigned length;
        const guint8 *data = (const guint8 *)hb_blob_get_data(os2, &length);
        if (length >= 50) {
            const guint32 bits = (guint32)data[46] << 24 | (guint32)data[47] << 16 |
                (guint32)data[48] << 8 | data[49];
            entry->cjk = (bits & ((1u << 17) | (1u << 24) | (1u << 27))) != 0;
        }
        hb_blob_destroy(os2);
#endif
        g_object_set_qdata_full(G_OBJECT(font), key, entry, g_free);
    }
    const OutlineFont result = *entry;
    G_UNLOCK(outline_fonts);
    return result;
}

// Caller holds index_lock for the lifetime of the returned cluster pointer.
static const InkCluster *single_outline_cluster(RuneDesktopLine *line, int32_t owner) {
    if (!line->cluster_index) line->cluster_index = index_clusters(line);
    GArray *index = line->cluster_index;
    guint lo = 0, hi = index->len;
    while (lo < hi) {
        guint mid = lo + (hi - lo) / 2;
        if (g_array_index(index, InkCluster, mid).owner < owner) lo = mid + 1;
        else hi = mid;
    }
    const InkCluster *c = lo < index->len ? &g_array_index(index, InkCluster, lo) : NULL;
    const gboolean single = c && c->owner == owner && c->count == 1 &&
        (lo + 1 == index->len || g_array_index(index, InkCluster, lo + 1).owner != owner);
    return single ? c : NULL;
}

int32_t rune_desktop_line_outline_single(const RuneDesktopLine *source, int32_t owner,
        uint64_t *font_id, uint32_t *glyph, float *pen_x, float *pen_y) {
    if (!source || !source->layout || !font_id || !glyph || !pen_x || !pen_y) return 0;
    RuneDesktopLine *line = (RuneDesktopLine *)source;
    g_mutex_lock(&line->index_lock);
    const InkCluster *c = single_outline_cluster(line, owner);
    int result = 0;
    if (c) {
        const PangoGlyphInfo *info = &c->glyphs->glyphs[c->first];
        const OutlineFont entry = outline_font(c->font);
        *font_id = entry.id;
        result = entry.cjk ? 3 : 1;
        *glyph = info->glyph;
        *pen_x = (c->x + info->geometry.x_offset) / (float)PANGO_SCALE;
        *pen_y = (c->baseline + info->geometry.y_offset) / (float)PANGO_SCALE;
    }
    g_mutex_unlock(&line->index_lock);
    return result;
}

int32_t rune_desktop_line_outline_regions(const RuneDesktopLine *source, RuneOutlineRegion emit, void *context) {
    if (!source || !source->layout || !emit) return 0;
    RuneDesktopLine *line = (RuneDesktopLine *)source;
    g_mutex_lock(&line->index_lock);
    if (!line->cluster_index) line->cluster_index = index_clusters(line);
    GArray *index = line->cluster_index;
    // Use the same bounds as extract_ink without allocating a separate raster view
    // for every grapheme when a large line first animates.
    for (guint i = 0; i < index->len;) {
        const int owner = g_array_index(index, InkCluster, i).owner;
        int left = G_MAXINT, top = G_MAXINT, right = G_MININT, bottom = G_MININT;
        do {
            const InkCluster *c = &g_array_index(index, InkCluster, i++);
            PangoGlyphString glyphs = cluster_glyphs(c);
            PangoRectangle b;
            pango_glyph_string_extents(&glyphs, c->font, &b, NULL);
            if (b.width > 0 && b.height > 0) {
                b.x += c->x;
                b.y += c->baseline;
                pango_extents_to_pixels(&b, NULL);
                left = MIN(left, b.x); top = MIN(top, b.y);
                right = MAX(right, b.x + b.width); bottom = MAX(bottom, b.y + b.height);
            }
        } while (i < index->len && g_array_index(index, InkCluster, i).owner == owner);
        if (left < right && top < bottom) emit(context, owner, left - 2, top - 2, right + 2, bottom + 2);
    }
    g_mutex_unlock(&line->index_lock);
    return 1;
}

static gboolean emit_cairo_outline(cairo_t *cr, RuneOutlineEmit emit, void *context, gboolean empty_ok) {
    cairo_path_t *path = cairo_copy_path(cr);
    gboolean ok = path->status == CAIRO_STATUS_SUCCESS;
    gboolean has_edges = FALSE;
    for (int i = 0; ok && i < path->num_data;) {
        const cairo_path_data_t *p = &path->data[i];
        switch (p->header.type) {
        case CAIRO_PATH_MOVE_TO:
            emit(context, 0, p[1].point.x, p[1].point.y, 0, 0, 0, 0);
            break;
        case CAIRO_PATH_LINE_TO:
            emit(context, 1, p[1].point.x, p[1].point.y, 0, 0, 0, 0);
            has_edges = TRUE;
            break;
        case CAIRO_PATH_CURVE_TO:
            emit(context, 3, p[1].point.x, p[1].point.y, p[2].point.x, p[2].point.y,
                 p[3].point.x, p[3].point.y);
            has_edges = TRUE;
            break;
        case CAIRO_PATH_CLOSE_PATH:
            emit(context, 4, 0, 0, 0, 0, 0, 0);
            break;
        }
        i += p->header.length;
    }
    cairo_path_destroy(path);
    return ok && (has_edges || empty_ok);
}

int32_t rune_desktop_line_outline(const RuneDesktopLine *ink, RuneOutlineEmit emit, void *context) {
    if (!ink || !ink->owned_clusters || !emit || ink->has_color) return 0;
    if (!ink->owned_clusters->len) return 1;
    cairo_surface_t *surface = cairo_recording_surface_create(CAIRO_CONTENT_ALPHA, NULL);
    cairo_t *cr = cairo_create(surface);
    for (guint i = 0; i < ink->owned_clusters->len; ++i) {
        const InkCluster *c = &g_array_index(ink->owned_clusters, InkCluster, i);
        PangoGlyphString glyphs = cluster_glyphs(c);
        cairo_move_to(cr, c->x / (double)PANGO_SCALE, c->baseline / (double)PANGO_SCALE);
        pango_cairo_glyph_string_path(cr, c->font, &glyphs);
    }
    const gboolean empty = ink->metrics.ink_width == 0 || ink->metrics.ink_height == 0;
    const gboolean ok = emit_cairo_outline(cr, emit, context, empty);
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    return ok;
}

int32_t rune_desktop_line_outline_unplaced(const RuneDesktopLine *source, int32_t owner,
        RuneOutlineEmit emit, void *context) {
    if (!source || !source->layout || !emit) return 0;
    RuneDesktopLine *line = (RuneDesktopLine *)source;
    PangoFont *font = NULL;
    PangoGlyphInfo info;
    g_mutex_lock(&line->index_lock);
    const InkCluster *c = single_outline_cluster(line, owner);
    if (c) {
        info = c->glyphs->glyphs[c->first];
#if PANGO_VERSION_CHECK(1, 50, 0)
        if (!info.attr.is_color)
#endif
            font = g_object_ref(c->font);
    }
    g_mutex_unlock(&line->index_lock);
    if (!font) return 0;

    // Shaping already supplies the native glyph ID and its separately exposed pen.
    // Export once at zero, even if later labels land at other fractional positions.
    info.geometry.x_offset = info.geometry.y_offset = 0;
    int cluster_byte = 0;
    PangoGlyphString glyphs = {0};
    glyphs.num_glyphs = 1;
    glyphs.glyphs = &info;
    glyphs.log_clusters = &cluster_byte;
    cairo_surface_t *surface = cairo_recording_surface_create(CAIRO_CONTENT_ALPHA, NULL);
    cairo_t *cr = cairo_create(surface);
    cairo_move_to(cr, 0, 0);
    pango_cairo_glyph_string_path(cr, font, &glyphs);
    const gboolean ok = emit_cairo_outline(cr, emit, context, FALSE);
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    g_object_unref(font);
    return ok;
}

// Cairo's FT_Face is mutable and shared with other clients and render
// threads. Give Rune a private FreeType library and face for the same actual
// Fontconfig match, sized and varied exactly as Pango shaped it.
typedef struct {
    FT_Library library;
    FT_Face face;
    GMutex lock;
    gboolean upright, tried_metrics, has_metrics;
    double metrics[5];
} FittedFace;

static void free_fitted_face(gpointer ptr) {
    FittedFace *f = ptr;
    if (f->face) FT_Done_Face(f->face);
    if (f->library) FT_Done_FreeType(f->library);
    g_mutex_clear(&f->lock);
    g_free(f);
}

static gboolean open_fitted_face(PangoFont *font, FittedFace *f) {
    if (!PANGO_IS_FC_FONT(font) || !PANGO_IS_CAIRO_FONT(font)) return FALSE;
    cairo_scaled_font_t *scaled = pango_cairo_font_get_scaled_font(PANGO_CAIRO_FONT(font));
    if (!scaled || cairo_scaled_font_get_type(scaled) != CAIRO_FONT_TYPE_FT ||
            cairo_ft_font_face_get_synthesize(cairo_scaled_font_get_font_face(scaled))) return FALSE;
    cairo_matrix_t m;
    cairo_scaled_font_get_font_matrix(scaled, &m);
    // Rune shapes horizontal runs. Preserve Pango's artificial oblique from
    // its actual matrix; FreeType's positive font y points upwards.
    if (!isfinite(m.xx) || !isfinite(m.yy) || !isfinite(m.xy) || m.xx <= 0 || m.yy <= 0 ||
            m.xx > 65535 || m.yy > 65535 || fabs(m.xy / m.yy) > 4 || m.yx != 0) return FALSE;
    f->upright = m.xy == 0;
    FcPattern *pattern = pango_fc_font_get_pattern(PANGO_FC_FONT(font));
    FcChar8 *file = NULL;
    int index = 0;
    if (!pattern || FcPatternGetString(pattern, FC_FILE, 0, &file) != FcResultMatch) return FALSE;
    FcPatternGetInteger(pattern, FC_INDEX, 0, &index);
    if (FT_Init_FreeType(&f->library) ||
            FT_New_Face(f->library, (const char *)file, index, &f->face)) return FALSE;
#if PANGO_VERSION_CHECK(1, 44, 0)
    unsigned count = 0;
    const int *coordinates = hb_font_get_var_coords_normalized(pango_font_get_hb_font(font), &count);
    if (coordinates && count && FT_HAS_MULTIPLE_MASTERS(f->face)) {
        FT_Fixed *blend = g_new(FT_Fixed, count);
        for (unsigned i = 0; i < count; ++i) blend[i] = (FT_Fixed)coordinates[i] * 4;
        const FT_Error error = FT_Set_Var_Blend_Coordinates(f->face, count, blend);
        g_free(blend);
        if (error) return FALSE;
    }
#endif
    if (FT_Set_Char_Size(f->face, lround(m.xx * 64), lround(m.yy * 64), 72, 72)) return FALSE;
    if (!f->upright) {
        FT_Matrix transform = {65536, (FT_Fixed)lround(-65536 * m.xy / m.yy), 0, 65536};
        FT_Set_Transform(f->face, &transform, NULL);
    }
    return TRUE;
}

static FittedFace *fitted_face(PangoFont *font) {
    const GQuark key = g_quark_from_static_string("rune-private-fitted-face");
    G_LOCK(outline_fonts);
    FittedFace *f = g_object_get_qdata(G_OBJECT(font), key);
    if (!f) {
        f = g_new0(FittedFace, 1);
        g_mutex_init(&f->lock);
        if (!open_fitted_face(font, f) && f->face) {
            FT_Done_Face(f->face);
            f->face = NULL;
        }
        g_object_set_qdata_full(G_OBJECT(font), key, f, free_fitted_face);
    }
    G_UNLOCK(outline_fonts);
    return f->face ? f : NULL;
}

typedef struct {
    RuneOutlineEmit emit;
    void *context;
    float x, y;
    gboolean open;
} FittedSink;

static int fitted_move(const FT_Vector *p, void *user) {
    FittedSink *s = user;
    if (s->open) s->emit(s->context, 4, 0, 0, 0, 0, 0, 0);
    s->emit(s->context, 0, s->x + p->x / 64.f, s->y - p->y / 64.f, 0, 0, 0, 0);
    s->open = TRUE;
    return 0;
}
static int fitted_line(const FT_Vector *p, void *user) {
    FittedSink *s = user;
    s->emit(s->context, 1, s->x + p->x / 64.f, s->y - p->y / 64.f, 0, 0, 0, 0);
    return 0;
}
static int fitted_quad(const FT_Vector *c, const FT_Vector *p, void *user) {
    FittedSink *s = user;
    s->emit(s->context, 2, s->x + c->x / 64.f, s->y - c->y / 64.f,
            s->x + p->x / 64.f, s->y - p->y / 64.f, 0, 0);
    return 0;
}
static int fitted_cubic(const FT_Vector *a, const FT_Vector *b, const FT_Vector *p, void *user) {
    FittedSink *s = user;
    s->emit(s->context, 3, s->x + a->x / 64.f, s->y - a->y / 64.f,
            s->x + b->x / 64.f, s->y - b->y / 64.f, s->x + p->x / 64.f, s->y - p->y / 64.f);
    return 0;
}

static int fitted_glyph(PangoFont *font, PangoGlyph glyph, float ppem,
        int look, float x, float y, RuneOutlineEmit emit, void *context) {
    if (glyph == PANGO_GLYPH_EMPTY) return 1;
    if (glyph & PANGO_GLYPH_UNKNOWN_FLAG) return 0;
    FittedFace *f = fitted_face(font);
    if (!f) return 0;
    const gboolean cjk = outline_font(font).cjk;
    g_mutex_lock(&f->lock);
    FT_Face face = f->face;
    int ok = 0;
    if (FT_IS_SCALABLE(face) && !FT_HAS_COLOR(face)) {
        FT_Int32 flags = FT_LOAD_NO_BITMAP;
        if (look == RUNE_LINUX_HINT_AUTO) {
            flags |= FT_LOAD_FORCE_AUTOHINT | FT_LOAD_TARGET_LIGHT;
        } else if (cjk && ppem <= 24) {
            flags |= FT_LOAD_NO_AUTOHINT | FT_LOAD_TARGET_MONO;
        } else {
            FT_ULong program = 0;
            const int gasp = FT_Get_Gasp(face, (FT_UInt)lroundf(ppem));
            const gboolean vertical = look == RUNE_LINUX_HINT_CHROMIUM &&
                !FT_Load_Sfnt_Table(face, FT_MAKE_TAG('f','p','g','m'), 0, NULL, &program) && program &&
                (gasp == FT_GASP_NO_TABLE || (gasp & (FT_GASP_DO_GRIDFIT | FT_GASP_SYMMETRIC_GRIDFIT)));
            flags |= vertical ? FT_LOAD_NO_AUTOHINT | FT_LOAD_TARGET_NORMAL : FT_LOAD_NO_HINTING;
        }
        if (!FT_Load_Glyph(face, glyph, flags) && face->glyph->format == FT_GLYPH_FORMAT_OUTLINE) {
            FittedSink sink = {emit, context, x, y, FALSE};
            const FT_Outline_Funcs funcs = {fitted_move, fitted_line, fitted_quad, fitted_cubic, 0, 0};
            ok = !FT_Outline_Decompose(&face->glyph->outline, &funcs, &sink);
            if (sink.open) emit(context, 4, 0, 0, 0, 0, 0, 0);
        }
    }
    g_mutex_unlock(&f->lock);
    return ok;
}

int32_t rune_linux_line_outline_fitted(const RuneDesktopLine *source, int32_t owner,
        float ppem, int32_t look, RuneOutlineEmit emit, void *context) {
    if (!source || !emit || !isfinite(ppem) || ppem <= 0 || look < 0 || look > RUNE_LINUX_HINT_AUTO) return 0;
    if (owner >= 0) {
        if (!source->layout) return 0;
        RuneDesktopLine *line = (RuneDesktopLine *)source;
        g_mutex_lock(&line->index_lock);
        const InkCluster *c = single_outline_cluster(line, owner);
        PangoFont *font = c ? g_object_ref(c->font) : NULL;
        PangoGlyph glyph = c ? c->glyphs->glyphs[c->first].glyph : PANGO_GLYPH_EMPTY;
        g_mutex_unlock(&line->index_lock);
        if (!font) return 0;
        const int result = fitted_glyph(font, glyph, ppem, look, 0, 0, emit, context);
        g_object_unref(font);
        return result;
    }
    if (!source->owned_clusters || source->has_color) return 0;
    for (guint i = 0; i < source->owned_clusters->len; ++i) {
        const InkCluster *c = &g_array_index(source->owned_clusters, InkCluster, i);
        int pen = c->x;
        for (int g = c->first; g < c->first + c->count; ++g) {
            const PangoGlyphInfo *info = &c->glyphs->glyphs[g];
            const float x = (pen + info->geometry.x_offset) / (float)PANGO_SCALE;
            const float y = (c->baseline + info->geometry.y_offset) / (float)PANGO_SCALE;
            if (!fitted_glyph(c->font, info->glyph, ppem, look, x, y, emit, context)) return 0;
            pen += info->geometry.width;
        }
    }
    return 1;
}

static gboolean post_top(FT_Face face, const char *name, double *top) {
    const FT_UInt gid = FT_Get_Name_Index(face, (FT_String *)name);
    if (!gid || FT_Load_Glyph(face, gid, FT_LOAD_NO_SCALE | FT_LOAD_NO_HINTING | FT_LOAD_NO_BITMAP |
            FT_LOAD_IGNORE_TRANSFORM) || face->glyph->format != FT_GLYPH_FORMAT_OUTLINE ||
            face->glyph->outline.n_points <= 0) return FALSE;
    FT_BBox bounds;
    FT_Outline_Get_CBox(&face->glyph->outline, &bounds);
    *top = bounds.yMax;
    return TRUE;
}

int32_t rune_desktop_line_apple_hint_metrics(const RuneDesktopLine *source, int32_t owner, double metrics[5]) {
    if (!source || !source->layout || !metrics || owner < 0) return 0;
    RuneDesktopLine *line = (RuneDesktopLine *)source;
    g_mutex_lock(&line->index_lock);
    const InkCluster *c = single_outline_cluster(line, owner);
    PangoFont *font = c ? g_object_ref(c->font) : NULL;
    g_mutex_unlock(&line->index_lock);
    if (!font) return 0;
    FittedFace *f = fitted_face(font);
    if (!f) { g_object_unref(font); return 0; }
    g_mutex_lock(&f->lock);
    if (!f->tried_metrics) {
        f->tried_metrics = TRUE;
        FT_Face face = f->face;
        FT_ULong length = 0;
        if (f->upright && face->units_per_EM > 0 && FT_HAS_GLYPH_NAMES(face) &&
                !FT_Load_Sfnt_Table(face, FT_MAKE_TAG('g','l','y','f'), 0, NULL, &length) && length &&
                post_top(face, "o", &f->metrics[1]) && post_top(face, "X", &f->metrics[2])) {
            f->metrics[0] = face->units_per_EM;
            f->metrics[3] = face->bbox.yMax;
            const char *name = FT_Get_Postscript_Name(face);
            f->metrics[4] = name && !strncmp(name, ".SFNS", 5) ? 79 :
                (name && !strcmp(name, "Helvetica") ? 85 : 0);
            f->has_metrics = TRUE;
        }
    }
    const int valid = f->has_metrics;
    if (valid) memcpy(metrics, f->metrics, sizeof(f->metrics));
    g_mutex_unlock(&f->lock);
    g_object_unref(font);
    return valid;
}

RuneDesktopLine *rune_desktop_line_extract_ink(const RuneDesktopLine *source, int32_t start, int32_t end) {
    if (!source || !source->layout || start < 0 || end < start || end > source->length) return NULL;
    RuneDesktopLine *line = (RuneDesktopLine *)source;
    g_mutex_lock(&line->index_lock);
    if (!line->cluster_index) line->cluster_index = index_clusters(line);
    GArray *index = line->cluster_index;
    guint lo = 0, hi = index->len;
    while (lo < hi) {
        guint mid = lo + (hi - lo) / 2;
        if (g_array_index(index, InkCluster, mid).owner < start) lo = mid + 1;
        else hi = mid;
    }
    RuneDesktopLine *ink = g_new0(RuneDesktopLine, 1);
    ink->metrics = line->metrics;
    ink->owned_clusters = g_array_new(FALSE, FALSE, sizeof(InkCluster));
    ink->indexed_runs = g_ptr_array_ref(line->indexed_runs);
    int left = G_MAXINT, top = G_MAXINT, right = G_MININT, bottom = G_MININT;
    for (; lo < index->len; ++lo) {
        InkCluster c = g_array_index(index, InkCluster, lo);
        if (c.owner >= end) break;
        g_array_append_val(ink->owned_clusters, c);
        PangoGlyphString glyphs = cluster_glyphs(&c);
#if PANGO_VERSION_CHECK(1, 50, 0)
        for (int i = 0; i < c.count; ++i) ink->has_color |= glyphs.glyphs[i].attr.is_color;
#endif
        PangoRectangle bounds;
        pango_glyph_string_extents(&glyphs, c.font, &bounds, NULL);
        if (bounds.width <= 0 || bounds.height <= 0) continue;
        bounds.x += c.x;
        bounds.y += c.baseline;
        pango_extents_to_pixels(&bounds, NULL);
        left = MIN(left, bounds.x);
        top = MIN(top, bounds.y);
        right = MAX(right, bounds.x + bounds.width);
        bottom = MAX(bottom, bounds.y + bounds.height);
    }
    // A grapheme may span several visually reordered clusters or fallback fonts.
    if (ink->owned_clusters->len > 1) g_array_sort(ink->owned_clusters, visual_order);
    // Match the antialiasing guard used by measure_line.
    ink->metrics.ink_x = left < right ? left - 2 : 0;
    ink->metrics.ink_y = top < bottom ? top - 2 : 0;
    ink->metrics.ink_width = left < right ? right - left + 4 : 0;
    ink->metrics.ink_height = top < bottom ? bottom - top + 4 : 0;
    g_mutex_unlock(&line->index_lock);
    return ink;
}

static void paint_glyphs(cairo_t *cr, PangoFont *font, PangoGlyphString *glyphs,
                         int pen, int baseline, gboolean color) {
    for (int first = 0; first < glyphs->num_glyphs;) {
        int end = glyphs->num_glyphs, advance = 0;
        gboolean is_color = FALSE;
#if PANGO_VERSION_CHECK(1, 50, 0)
        is_color = glyphs->glyphs[first].attr.is_color;
        end = first;
        do { advance += glyphs->glyphs[end++].geometry.width; }
        while (end < glyphs->num_glyphs && glyphs->glyphs[end].attr.is_color == is_color);
#endif
        if (is_color == color) {
            PangoGlyphString slice = *glyphs;
            slice.num_glyphs = end - first;
            slice.glyphs += first;
            slice.log_clusters += first;
            cairo_move_to(cr, pen / (double)PANGO_SCALE, baseline / (double)PANGO_SCALE);
            pango_cairo_show_glyph_string(cr, font, &slice);
        }
        pen += advance;
        first = end;
    }
}

static void paint_glyph_plane(cairo_t *cr, const RuneDesktopLine *line, gboolean color) {
    if (line->owned_clusters) {
        for (guint i = 0; i < line->owned_clusters->len; ++i) {
            const InkCluster *c = &g_array_index(line->owned_clusters, InkCluster, i);
            PangoGlyphString glyphs = cluster_glyphs(c);
            paint_glyphs(cr, c->font, &glyphs, c->x, c->baseline, color);
        }
        return;
    }
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
        paint_glyphs(cr, run->item->analysis.font, run->glyphs, logical.x,
                     pango_layout_iter_get_run_baseline(iter), color);
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
