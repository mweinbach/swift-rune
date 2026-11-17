#ifndef C_RUNE_GL_SURFACE_H
#define C_RUNE_GL_SURFACE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RuneGL RuneGL;

typedef struct RuneGLSurfaceDraw {
    uint32_t before_instance;
    uint64_t key;
    uint64_t version;
    // viewport, node, image, radii, clip bounds, fade, fade origin, color,
    // sampling, orientation, per-edge clip fades, offsets, and clip radii.
    float uniforms[13][4];
} RuneGLSurfaceDraw;

int rune_gl_configure_surfaces(RuneGL *r, const char *vertex, const char *fragment,
                               char *error, size_t capacity);
/* The caller retains the planes for this call only. A new version must be
 * supplied whenever the bytes or format of a particular key change. */
int rune_gl_surface_upload(RuneGL *r, uint64_t key, uint64_t version, int width,
                           int height, int format, const uint8_t *plane0, size_t bytes0,
                           const uint8_t *plane1, size_t bytes1, char *error, size_t capacity);
/* The callback fills an allocated RGBA8 texture on the current context.
 * Returns zero on unsupported interop so the caller can upload the original planes. */
typedef int (*RuneGLSurfaceCopy)(void *source, uint32_t texture);
int rune_gl_surface_copy_rgba(RuneGL *r, uint64_t key, uint64_t version, int width, int height,
                              RuneGLSurfaceCopy copy, void *source, char *error, size_t capacity);
/* The callback fills the luma R8 texture and half-size chroma RG8 texture together. */
typedef int (*RuneGLPlaneCopy)(void *source, uint32_t luma, uint32_t chroma);
int rune_gl_surface_copy_nv12(RuneGL *r, uint64_t key, uint64_t version, int width, int height,
                              int format, RuneGLPlaneCopy copy, void *source, char *error, size_t capacity);
/* Fence-based completion. A wait returns 1 for completion, 0 if polling a
 * pending fence, and -1 on an invalid/lost context. */
void *rune_gl_surface_fence(RuneGL *r);
/* Flush all preceding commands to the device before returning the fence. */
void *rune_gl_submit_fence(RuneGL *r);
int rune_gl_surface_wait(RuneGL *r, void *fence, int wait);
void rune_gl_surface_fence_free(RuneGL *r, void *fence);
int rune_gl_render_surfaces(RuneGL *r, int width, int height, const float *clear_rgba,
                            int srgb_blend, const void *instances, size_t count,
                            const uint8_t *glyphs, int glyph_width, int glyph_height,
                            const uint8_t *images, int image_width, int image_height,
                            const RuneGLSurfaceDraw *draws, size_t draw_count,
                            char *error, size_t capacity);

#ifdef __cplusplus
}
#endif
#endif
