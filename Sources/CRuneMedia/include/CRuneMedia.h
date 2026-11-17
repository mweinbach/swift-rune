#ifndef C_RUNE_MEDIA_H
#define C_RUNE_MEDIA_H

#include <stddef.h>
#include <stdint.h>
#include "RuneMicrophone.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RuneMedia RuneMedia;

typedef struct RuneMediaInfo {
    uint32_t width, height; /* decoded buffer dimensions; zero for audio-only */
    int has_audio;
    int rotation_clockwise; /* remaining clockwise degrees to display decoded pixels upright */
    double duration; /* seconds, negative if unknown */
    double frame_duration; /* seconds, zero if unknown */
} RuneMediaInfo;

/* URI is UTF-8 and starts with file:, http: or https:. The caller serializes all
 * operations on one handle. The backend can be entered from different threads.
 * audio_only discards video and requires playable audio. Headless plays no audio.
 * All non-frame calls returning int return one on success and zero on failure.
 * Error buffers are NUL-terminated UTF-8 diagnostics. */
RuneMedia *rune_media_open(const char *uri, int audio_only, int headless,
                           RuneMediaInfo *info, char *error, size_t capacity);
void rune_media_close(RuneMedia *media);

/* Copy tightly packed, top-down BGRA8 into pixels. The native decoder may
 * already have applied all or part of the encoded track's display rotation.
 * Seconds >= 0 selects a frame by timestamp; negative retrieves the current
 * playing or paused sample without issuing an additional seek.
 * Return 1 for a frame, 0 if no frame is ready, -1 on failure. */
int rune_media_frame(RuneMedia *media, double seconds, uint8_t *pixels, size_t length,
                     char *error, size_t capacity);

/* A negative seek time preserves the current position. */
int rune_media_transport(RuneMedia *media, int playing, double seek_seconds,
                         double rate, double volume, int muted, char *error, size_t capacity);
int rune_media_status(RuneMedia *media, double *seconds, int *ended, char *error, size_t capacity);

#ifdef __cplusplus
}
#endif
#endif
