#ifndef RUNE_DECODED_PLANES_H
#define RUNE_DECODED_PLANES_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct RuneWinPlaneUploader RuneWinPlaneUploader;
RuneWinPlaneUploader *rune_win_plane_uploader_create(void);
void rune_win_plane_uploader_destroy(RuneWinPlaneUploader *uploader);

typedef struct RuneWinPlaneCopy {
    RuneWinPlaneUploader *uploader;
    void *texture; /* borrowed ID3D11Texture2D, subresource 0 */
    uint32_t width, height;
    int interop;
    int transferred_on_gpu; /* output: both planes copied through WGL interop */
} RuneWinPlaneCopy;

/* Callback for rune_gl_surface_copy_nv12. Both textures change together. */
int rune_win_plane_copy_gl(void *copy, uint32_t luma, uint32_t chroma);
/* Reads cropped, tightly packed NV12 bytes. Width/height are the visible
   dimensions; decoder stride and padding can exceed either dimension. */
int rune_win_plane_read(void *texture, uint32_t width, uint32_t height,
                        uint8_t *luma, size_t luma_bytes, uint8_t *chroma, size_t chroma_bytes,
                        char *error, size_t capacity);
#ifdef __cplusplus
}
#endif
#endif
