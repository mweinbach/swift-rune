#ifndef RUNE_DESKTOP_SERVICES_H
#define RUNE_DESKTOP_SERVICES_H
#include <stddef.h>
#include <stdint.h>
#include "RuneDesktopHotkeys.h"
#include "RuneDesktopSpell.h"
#include "RuneLinuxTray.h"

#ifdef __cplusplus
extern "C" {
#endif

/* A list of clipboard representations. All input data is copied and all returned
   pointers are valid until the list is freed. A zero-length value is supported. */
typedef struct RuneMimeData RuneMimeData;
RuneMimeData *rune_mime_create(void);
void rune_mime_free(RuneMimeData *list);
int rune_mime_add(RuneMimeData *list, const char *type, const uint8_t *bytes, size_t length);
size_t rune_mime_count(const RuneMimeData *list);
const char *rune_mime_type(const RuneMimeData *list, size_t index);
const uint8_t *rune_mime_bytes(const RuneMimeData *list, size_t index, size_t *length);

/* Commit returns the clipboard revision this write owns, or -1 on failure.
   An expected revision of -1 clears unconditionally. */
int64_t rune_clipboard_write(const RuneMimeData *list, int concealed);
RuneMimeData *rune_clipboard_read(void);
int64_t rune_clipboard_revision(void);
int rune_clipboard_clear(int64_t expected);
int rune_desktop_open_url(const char *url);
#if defined(__linux__) && !defined(__ANDROID__)
int rune_desktop_linux_call(void (*work)(void *), void *context);
void rune_desktop_linux_connect(uint32_t window_id);
int rune_desktop_linux_right_alt_is_altgr(uint32_t window_id);
void rune_desktop_linux_pump(void);
void rune_desktop_linux_disconnect(void);
/* Host-thread operations on X11 PRIMARY or the Wayland seat's primary selection.
   A read replies exactly once, possibly on a worker. The bytes are borrowed
   during the callback only. Missing/empty selections supply NULL. */
typedef void (*RunePrimaryReply)(void *context, const uint8_t *bytes, size_t count);
void rune_linux_primary_write(const uint8_t *bytes, size_t count);
void rune_linux_primary_read(RunePrimaryReply reply, void *context);
typedef struct RuneLinuxDrag RuneLinuxDrag;
typedef struct {
    const uint8_t *rgba; /* Straight-alpha sRGB pixels, top row first. */
    size_t size;
    int32_t width, height;
    int32_t display_width, display_height, hotspot_x, hotspot_y; /* Logical points. */
} RuneLinuxDragPreview;
RuneLinuxDrag *rune_linux_drag_open(uint32_t window_id);
/* begin takes ownership of the MIME list, including on failure. */
int rune_linux_drag_begin(RuneLinuxDrag *drag, RuneMimeData *payload, unsigned operations, int within_app);
/* The optional preview is borrowed for the duration of this call only. */
int rune_linux_drag_begin_with_preview(RuneLinuxDrag *drag, RuneMimeData *payload, unsigned operations,
                                       int within_app, const RuneLinuxDragPreview *preview);
/* Returns -1 while waiting, 0 on cancellation, or the negotiated copy (1), move (2), or link (4). */
int rune_linux_drag_poll(RuneLinuxDrag *drag);
void rune_linux_drag_close(RuneLinuxDrag *drag);
/* Files offered to this Wayland data device, with their target-local coordinates.
   Returns a caller-owned MIME list containing the URI-list representation. */
RuneMimeData *rune_wayland_take_drop(uint32_t window_id, float *x, float *y);
/* Complete each taken offer after the app has accepted or rejected the files. */
void rune_wayland_finish_drop(uint32_t window_id, int accepted);
int rune_wayland_owns_drop(uint32_t window_id);
#endif

/* A picker is configured and used synchronously. Results are native absolute
   paths encoded in UTF-8. show returns 1 on selection, 0 on cancel, -1 on error. */
typedef struct RuneDesktopPicker RuneDesktopPicker;
RuneDesktopPicker *rune_picker_create(void);
void rune_picker_free(RuneDesktopPicker *picker);
int rune_picker_filter(RuneDesktopPicker *picker, const char *name, const char *patterns);
int rune_picker_show(RuneDesktopPicker *picker, int save, int folders, int multiple,
                     const char *title, const char *directory, const char *filename);
size_t rune_picker_count(const RuneDesktopPicker *picker);
const char *rune_picker_path(const RuneDesktopPicker *picker, size_t index);

#ifdef __cplusplus
}
#endif
#endif
