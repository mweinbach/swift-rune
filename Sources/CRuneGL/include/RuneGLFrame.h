#ifndef RUNE_GL_FRAME_H
#define RUNE_GL_FRAME_H
#include "CRuneGLSurface.h"

#ifdef __cplusplus
extern "C" {
#endif

/* The spring caller retains the exact, immutable RenderInstance storage submitted
 * on the previous successful frame. A zero hint always uploads the next buffer. */
void rune_gl_reuse_spring_instances(RuneGL *renderer, int same_storage);

/* Configure the production RenderInstance pipeline. The RuneRef pipeline remains
 * available on the same context for GPU differential tests and replay. */
int rune_gl_configure_frame(RuneGL *renderer, const char *vertex, const char *fragment,
                            const char *fullscreen, const char *blur, char *error, size_t capacity);

/* Select borrowed spring coefficient and instance-to-node textures for the spring vertex
 * shader. Supply both names, or zero to disable. State survives shader configuration. */
void rune_gl_frame_springs(RuneGL *renderer, uint32_t tracks, uint32_t ids,
                           float seconds, float fraction);

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
