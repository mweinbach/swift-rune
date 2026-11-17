#ifndef RUNE_X11_DRAG_ICON_H
#define RUNE_X11_DRAG_ICON_H
#include "linux_drag_internal.h"
#include <gtk/gtk.h>

/* GTK retains the Cairo surface. The conversion copies and premultiplies the
 * borrowed RGBA pixels, and preserves native pixel density at fractional DPI. */
static void rune_x11_drag_icon(GdkDragContext *context, const RuneLinuxDragPreview *p) {
    GdkPixbuf *pixbuf = gdk_pixbuf_new_from_data(p->rgba, GDK_COLORSPACE_RGB, TRUE, 8,
                                                  p->width, p->height, p->width * 4, NULL, NULL);
    if (!pixbuf) return;
    cairo_surface_t *surface = gdk_cairo_surface_create_from_pixbuf(pixbuf, 1, NULL);
    g_object_unref(pixbuf);
    if (surface && cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS) {
        double scale_x = (double)p->width / p->display_width;
        double scale_y = (double)p->height / p->display_height;
        cairo_surface_set_device_scale(surface, scale_x, scale_y);
        cairo_surface_set_device_offset(surface, -p->hotspot_x * scale_x, -p->hotspot_y * scale_y);
        gtk_drag_set_icon_surface(context, surface);
    }
    if (surface) cairo_surface_destroy(surface);
}
#endif
