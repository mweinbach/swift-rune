#if defined(__linux__) && !defined(__ANDROID__)
#include "linux_drag_internal.h"
#include <SDL.h>
#include <string.h>

RuneLinuxDrag *rune_linux_drag_open(uint32_t window_id) {
    const char *driver = SDL_GetCurrentVideoDriver();
    if (driver && !strcmp(driver, "wayland")) return rune_wayland_drag_open(window_id);
    if (driver && !strcmp(driver, "x11")) return rune_x11_drag_open(window_id);
    return NULL;
}

int rune_linux_drag_begin(RuneLinuxDrag *drag, RuneMimeData *payload, unsigned operations, int within_app) {
    return rune_linux_drag_begin_with_preview(drag, payload, operations, within_app, NULL);
}

static int valid_preview(const RuneLinuxDragPreview *p) {
    if (!p || !p->rgba || p->width <= 0 || p->height <= 0 ||
        p->display_width <= 0 || p->display_height <= 0) return 0;
    uint64_t source = (uint64_t)p->width * p->height;
    uint64_t output = (uint64_t)p->display_width * p->display_height;
    const uint64_t max_pixels = 16u * 1024u * 1024u;
    return source <= max_pixels && source <= p->size / 4 && output <= max_pixels &&
           p->hotspot_x >= 0 && p->hotspot_x < p->display_width &&
           p->hotspot_y >= 0 && p->hotspot_y < p->display_height;
}

int rune_linux_drag_begin_with_preview(RuneLinuxDrag *drag, RuneMimeData *payload, unsigned operations,
                                       int within_app, const RuneLinuxDragPreview *preview) {
    if (drag && !drag->payload && rune_mime_count(payload)) {
        drag->preview = valid_preview(preview) ? preview : NULL;
        int started = drag->begin(drag, payload, operations, within_app);
        drag->preview = NULL;
        if (started) {
            drag->payload = payload;
            return 1;
        }
    }
    rune_mime_free(payload);
    return 0;
}

int rune_linux_drag_poll(RuneLinuxDrag *drag) {
    if (!drag || !drag->payload) return 0;
    int action = drag->poll(drag);
    if (action >= 0) {
        rune_mime_free(drag->payload);
        drag->payload = NULL;
    }
    return action;
}

void rune_linux_drag_close(RuneLinuxDrag *drag) {
    if (!drag) return;
    RuneMimeData *payload = drag->payload;
    drag->destroy(drag);
    rune_mime_free(payload);
}
#endif
