#ifndef RUNE_WINDOWS_DRAG_SOURCE_H
#define RUNE_WINDOWS_DRAG_SOURCE_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const uint16_t *text;
    const uint16_t *files;    /* Native absolute paths, each NUL-terminated, plus a final NUL. */
    size_t file_units;
    const uint8_t *png;
    size_t png_size;
    const uint8_t *rgba;      /* Optional top-down, straight RGBA drag image. */
    int32_t width, height, hotspot_x, hotspot_y;
    uint32_t operations;      /* OLE COPY = 1, MOVE = 2, LINK = 4. */
    int32_t within_app;
    size_t rgba_size;
} RuneWinDragPayload;
typedef void (*RuneWinDragDone)(void *context, uint32_t effect);
/* On the HWND's thread. A successful call copies the payload, posts the session and owns
 * exactly one completion. Failure is synchronous and does not call done. */
int rune_win_drag_begin(void *hwnd, const RuneWinDragPayload *payload, RuneWinDragDone done, void *context);
void rune_win_drag_cancel(void *hwnd);
#ifdef __cplusplus
}
#endif
#endif
