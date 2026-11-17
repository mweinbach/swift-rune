#ifndef RUNE_SHARED_TEXTURE_H
#define RUNE_SHARED_TEXTURE_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct RuneWinSharedFrame RuneWinSharedFrame;
// Remember the current window's adapter. D3D devices are created on demand.
void rune_win_shared_note_window(void);
int rune_win_shared_adapter(int32_t *high, uint32_t *low);
RuneWinSharedFrame *rune_win_shared_capture(const uint16_t *name, uint32_t width, uint32_t height,
                                            const uint16_t *fence, uint64_t value, int gpu_copy,
                                            char *error, size_t capacity);
void rune_win_shared_destroy(RuneWinSharedFrame *frame);
int rune_win_shared_read(RuneWinSharedFrame *frame, uint8_t *destination, size_t count, char *error, size_t capacity);
int rune_win_shared_gl_available(void);
// Copies to an allocated RGBA8 texture on the current WGL context without reading pixels to the CPU.
int rune_win_shared_copy_gl(void *frame, uint32_t texture);
// Uploads D3D mapped BGRA rows straight to GL on drivers without hardware interop.
int rune_win_shared_upload_gl(void *frame, uint32_t texture);

#ifdef __cplusplus
}
#endif
#endif
