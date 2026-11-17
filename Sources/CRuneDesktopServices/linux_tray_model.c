#if defined(__linux__) && !defined(__ANDROID__)
#include "linux_tray_model.h"

static void free_item(gpointer data) {
    RuneTrayEntry *item = data;
    g_free(item->id);
    g_free(item->label);
    g_free(item);
}

RuneLinuxTraySpec *rune_linux_tray_spec(const char *id, const char *title, const char *tooltip,
                                        const char *icon_name, const uint8_t *rgba, uint32_t width, uint32_t height) {
    if (!id || !title || !tooltip || !icon_name || width > G_MAXINT || height > G_MAXINT ||
        ((width || height) && (!rgba || !width || !height || width > G_MAXSIZE / height / 4))) return NULL;
    RuneLinuxTraySpec *spec = g_new0(RuneLinuxTraySpec, 1);
    spec->id = g_strdup(id);
    spec->title = g_strdup(title);
    spec->tooltip = g_strdup(tooltip);
    spec->icon_name = g_strdup(icon_name);
    spec->items = g_ptr_array_new_with_free_func(free_item);
    GVariantBuilder pixmaps;
    g_variant_builder_init(&pixmaps, G_VARIANT_TYPE("a(iiay)"));
    if (rgba && width && height) {
        gsize length = (gsize)width * height * 4;
        guint8 *pixels = g_malloc(length);
        for (gsize k = 0; k < length; k += 4) {
            pixels[k] = rgba[k+3];
            pixels[k+1] = rgba[k];
            pixels[k+2] = rgba[k+1];
            pixels[k+3] = rgba[k+2];
        }
        GVariant *bytes = g_variant_new_from_data(G_VARIANT_TYPE("ay"), pixels, length, TRUE, g_free, pixels);
        g_variant_builder_add(&pixmaps, "(ii@ay)", (gint)width, (gint)height, bytes);
    }
    spec->pixmaps = g_variant_ref_sink(g_variant_builder_end(&pixmaps));
    return spec;
}

void rune_linux_tray_item(RuneLinuxTraySpec *spec, const char *id, const char *label, int enabled) {
    RuneTrayEntry *item = g_new0(RuneTrayEntry, 1);
    item->id = g_strdup(id);
    item->label = g_strdup(label);
    item->enabled = enabled != 0;
    g_ptr_array_add(spec->items, item);
}

void rune_tray_spec_free(RuneLinuxTraySpec *spec) {
    g_free(spec->id);
    g_free(spec->title);
    g_free(spec->tooltip);
    g_free(spec->icon_name);
    g_variant_unref(spec->pixmaps);
    g_ptr_array_unref(spec->items);
    g_free(spec);
}

gboolean rune_tray_menu_equal(const RuneLinuxTraySpec *a, const RuneLinuxTraySpec *b) {
    if (a->items->len != b->items->len) return FALSE;
    for (guint i = 0; i < a->items->len; i++) {
        RuneTrayEntry *old = g_ptr_array_index(a->items, i), *next = g_ptr_array_index(b->items, i);
        if (g_strcmp0(old->id, next->id) || g_strcmp0(old->label, next->label) || old->enabled != next->enabled) return FALSE;
    }
    return TRUE;
}

GVariant *rune_tray_menu_properties(const RuneLinuxTraySpec *spec, gint id) {
    GVariantBuilder props;
    g_variant_builder_init(&props, G_VARIANT_TYPE_VARDICT);
    if (id == 0) {
        g_variant_builder_add(&props, "{sv}", "children-display", g_variant_new_string("submenu"));
    } else if (id > 0 && (guint)id <= spec->items->len) {
        RuneTrayEntry *item = g_ptr_array_index(spec->items, id-1);
        if (item->id) {
            g_variant_builder_add(&props, "{sv}", "label", g_variant_new_string(item->label));
            if (!item->enabled) g_variant_builder_add(&props, "{sv}", "enabled", g_variant_new_boolean(FALSE));
        } else {
            g_variant_builder_add(&props, "{sv}", "type", g_variant_new_string("separator"));
        }
    }
    return g_variant_builder_end(&props);
}

GVariant *rune_tray_menu_layout(const RuneLinuxTraySpec *spec, gint id) {
    GVariantBuilder children;
    g_variant_builder_init(&children, G_VARIANT_TYPE("av"));
    if (id == 0) {
        for (guint i = 0; i < spec->items->len; i++)
            g_variant_builder_add(&children, "v", rune_tray_menu_layout(spec, (gint)i+1));
    }
    return g_variant_new("(i@a{sv}@av)", id, rune_tray_menu_properties(spec, id), g_variant_builder_end(&children));
}
#endif
