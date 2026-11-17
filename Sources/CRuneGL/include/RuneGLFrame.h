#ifndef RUNE_GL_FRAME_H
#define RUNE_GL_FRAME_H
#include "CRuneGLSurface.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Configure the production RenderInstance pipeline. The RuneRef pipeline remains
 * available on the same context for GPU differential tests and replay. */
int rune_gl_configure_frame(RuneGL *renderer, const char *vertex, const char *fragment,
                            const char *fullscreen, const char *blur, char *error, size_t capacity);

/* Instances are 128 bytes: seven float4s followed by a uint4 of packed clip data.
 * Surface insertion points index this exact array. The clear color is straight RGBA.
 * The upload/reuse and current-context requirements of rune_gl_render apply. */
int rune_gl_render_frame(RuneGL *renderer, int width, int height, const float *clear_rgba,
                         int srgb_blend, const void *instances, size_t count,
                         const uint8_t *glyphs, int glyph_width, int glyph_height,
                         const uint8_t *images, int image_width, int image_height,
                         const RuneGLSurfaceDraw *draws, size_t draw_count,
                         char *error, size_t capacity);

#ifdef __cplusplus
}
#endif
#endif
