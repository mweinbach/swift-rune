#ifndef RUNE_LINUX_TRAY_MODEL_H
#define RUNE_LINUX_TRAY_MODEL_H
#if defined(__linux__) && !defined(__ANDROID__)
#include "RuneLinuxTray.h"
#include <gio/gio.h>

typedef struct {
    char *id, *label;
    gboolean enabled;
} RuneTrayEntry;

struct RuneLinuxTraySpec {
    char *id, *title, *tooltip, *icon_name;
    GVariant *pixmaps;       /* a(iiay), network-order ARGB */
    GPtrArray *items;        /* RuneTrayEntry, item id is array index + 1 */
};
void rune_tray_spec_free(RuneLinuxTraySpec *spec);
gboolean rune_tray_menu_equal(const RuneLinuxTraySpec *a, const RuneLinuxTraySpec *b);
GVariant *rune_tray_menu_properties(const RuneLinuxTraySpec *spec, gint id);
GVariant *rune_tray_menu_layout(const RuneLinuxTraySpec *spec, gint id);
#endif
#endif
