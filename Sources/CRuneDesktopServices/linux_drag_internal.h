#ifndef RUNE_LINUX_DRAG_INTERNAL_H
#define RUNE_LINUX_DRAG_INTERNAL_H
#include "include/RuneDesktopServices.h"

typedef struct RuneLinuxDrag {
    /* A successful begin borrows the payload until poll completes or destroy returns. */
    int (*begin)(struct RuneLinuxDrag *, const RuneMimeData *, unsigned operations, int within_app);
    int (*poll)(struct RuneLinuxDrag *);
    void (*destroy)(struct RuneLinuxDrag *);
    RuneMimeData *payload;
    const RuneLinuxDragPreview *preview;
} RuneLinuxDrag;

RuneLinuxDrag *rune_x11_drag_open(uint32_t window_id);
RuneLinuxDrag *rune_wayland_drag_open(uint32_t window_id);
#endif
