/* LD_PRELOAD observer for Demand.py. It reads local ATK objects without opening an AT-SPI connection. */
#define _GNU_SOURCE
#include <atk/atk.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>

void atk_object_set_parent(AtkObject *child, AtkObject *parent) {
    void (*set_parent)(AtkObject *, AtkObject *) = dlsym(RTLD_NEXT, "atk_object_set_parent");
    if (!set_parent) g_error("Could not find atk_object_set_parent: %s", dlerror());
    set_parent(child, parent);

    const char *path = g_getenv("RUNE_ATK_PARENT_LOG");
    if (!path || !ATK_IS_COMPONENT(child)) return;
    const char *name = atk_object_get_name(child);
    if (g_strcmp0(name, "A edited") != 0 && g_strcmp0(name, "Scroll item") != 0) return;

    gint x, y, width, height;
    atk_component_get_extents(ATK_COMPONENT(child), &x, &y, &width, &height, ATK_XY_WINDOW);
    FILE *log = fopen(path, "a");
    if (!log) g_error("Could not open %s: %s", path, g_strerror(errno));
    if (fprintf(log, "%s\t%s\t%d,%d,%d,%d\n", parent ? "attach" : "detach", name,
                x, y, width, height) < 0 || fclose(log) != 0)
        g_error("Could not write %s: %s", path, g_strerror(errno));
}
