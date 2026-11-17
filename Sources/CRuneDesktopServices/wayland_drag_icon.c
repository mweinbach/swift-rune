#if defined(__linux__) && !defined(__ANDROID__)
#define _GNU_SOURCE
#include "wayland_drag_icon.h"
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

static int storage(int bytes) {
    int fd = memfd_create("Rune drag preview", MFD_CLOEXEC);
    if (fd < 0) return -1;
    int error;
    do {
        error = posix_fallocate(fd, 0, bytes);
    } while (error == EINTR);
    if (error) {
        close(fd);
        return -1;
    }
    return fd;
}

/* Wayland ARGB8888 is a native-endian word with premultiplied channels. */
static void copy_pixels(uint32_t *dst, const GdkPixbuf *source) {
    const uint8_t *src = gdk_pixbuf_read_pixels(source);
    int width = gdk_pixbuf_get_width(source), height = gdk_pixbuf_get_height(source);
    int stride = gdk_pixbuf_get_rowstride(source);
    for (int y = 0; y < height; ++y) {
        const uint8_t *p = src + (size_t)y * stride;
        for (int x = 0; x < width; ++x, p += 4) {
            uint32_t a = p[3];
            uint32_t r = (p[0] * a + 127) / 255;
            uint32_t g = (p[1] * a + 127) / 255;
            uint32_t b = (p[2] * a + 127) / 255;
            *dst++ = (a << 24) | (r << 16) | (g << 8) | b;
        }
    }
}

struct RuneWaylandDragIcon rune_wayland_icon_create(const struct RuneWaylandDragContext *seat,
                                                    const RuneLinuxDragPreview *preview) {
    struct RuneWaylandDragIcon icon = {0};
    if (!preview || !seat->compositor || !seat->shm) return icon;
    const uint64_t max_pixels = 16 * 1024 * 1024;
    int scale = wl_compositor_get_version(seat->compositor) >= 3 ? seat->scale : 1;
    uint64_t area = (uint64_t)preview->display_width * preview->display_height;
    if (!area || area > max_pixels) return icon;
    if (scale < 1 || (uint64_t)scale * scale > max_pixels / area) scale = 1;
    int width = preview->display_width * scale, height = preview->display_height * scale;
    int bytes = width * height * 4;

    GdkPixbuf *pixels = gdk_pixbuf_new_from_data(preview->rgba, GDK_COLORSPACE_RGB, TRUE, 8,
                                                 preview->width, preview->height, preview->width * 4, NULL, NULL);
    if (!pixels) return icon;
    if (width != preview->width || height != preview->height) {
        GdkPixbuf *scaled = gdk_pixbuf_scale_simple(pixels, width, height, GDK_INTERP_BILINEAR);
        g_object_unref(pixels);
        if (!scaled) return icon;
        pixels = scaled;
    }
    int fd = storage(bytes);
    if (fd >= 0) {
        uint32_t *mapped = mmap(NULL, (size_t)bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (mapped != MAP_FAILED) {
            copy_pixels(mapped, pixels);
            munmap(mapped, (size_t)bytes);
            struct wl_shm_pool *pool = wl_shm_create_pool(seat->shm, fd, bytes);
            if (pool) {
                icon.buffer = wl_shm_pool_create_buffer(pool, 0, width, height, width * 4, WL_SHM_FORMAT_ARGB8888);
                wl_shm_pool_destroy(pool);
            }
        }
        close(fd);
    }
    g_object_unref(pixels);
    if (!icon.buffer) return icon;
    icon.surface = wl_compositor_create_surface(seat->compositor);
    if (!icon.surface) {
        rune_wayland_icon_destroy(&icon);
        return icon;
    }
    icon.scale = scale;
    icon.hotspot_x = preview->hotspot_x;
    icon.hotspot_y = preview->hotspot_y;
    icon.width = preview->display_width;
    icon.height = preview->display_height;
    return icon;
}

/* Assign the drag-icon role with start_drag before setting the initial hotspot. */
void rune_wayland_icon_commit(struct RuneWaylandDragIcon *icon) {
    if (!icon->surface) return;
    if (icon->scale > 1) wl_surface_set_buffer_scale(icon->surface, icon->scale);
    int x = -icon->hotspot_x, y = -icon->hotspot_y;
#ifdef WL_SURFACE_OFFSET_SINCE_VERSION
    if (wl_surface_get_version(icon->surface) >= WL_SURFACE_OFFSET_SINCE_VERSION) {
        wl_surface_offset(icon->surface, x, y);
        x = 0;
        y = 0;
    }
#endif
    wl_surface_attach(icon->surface, icon->buffer, x, y);
    wl_surface_damage(icon->surface, 0, 0, icon->width, icon->height);
    wl_surface_commit(icon->surface);
}

void rune_wayland_icon_destroy(struct RuneWaylandDragIcon *icon) {
    if (icon->surface) wl_surface_destroy(icon->surface);
    if (icon->buffer) wl_buffer_destroy(icon->buffer);
    *icon = (struct RuneWaylandDragIcon){0};
}
#endif
