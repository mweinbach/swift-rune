#ifndef RUNE_MICROPHONE_H
#define RUNE_MICROPHONE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The worker that opens a device or encoder owns it until close. Samples are
 * interleaved float PCM. Frame counts exclude the channel multiplier. */
typedef struct RuneMic RuneMic;
typedef struct RuneMicAAC RuneMicAAC;

/* 1 allowed, 0 unknown until open, -1 denied, -2 restricted. Never opens a device. */
int rune_mic_permission(void);
/* synthetic selects a generated test input without opening a microphone. */
RuneMic *rune_mic_open(uint32_t sample_rate, uint16_t channels, int synthetic,
                       char *error, size_t capacity);
/* Positive frames read, zero on timeout, -1 on device loss or error. */
int rune_mic_read(RuneMic *mic, float *interleaved, uint32_t frame_capacity,
                  uint32_t timeout_ms, char *error, size_t capacity);
int rune_mic_set_paused(RuneMic *mic, int paused, char *error, size_t capacity);
void rune_mic_close(RuneMic *mic);

RuneMicAAC *rune_mic_aac_open(const char *path_utf8, uint32_t rate, uint16_t channels,
                              char *error, size_t capacity);
int rune_mic_aac_write(RuneMicAAC *encoder, const float *interleaved, uint32_t frames,
                       char *error, size_t capacity);
int rune_mic_aac_finish(RuneMicAAC *encoder, char *error, size_t capacity);
void rune_mic_aac_close(RuneMicAAC *encoder);

/* Replace the final file with the completed staging file on the same volume. */
int rune_mic_publish(const char *staging_utf8, const char *destination_utf8,
                     char *error, size_t capacity);

#ifdef __cplusplus
}
#endif
#endif
