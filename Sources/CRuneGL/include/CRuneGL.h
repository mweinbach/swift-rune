#ifndef C_RUNE_GL_H
#define C_RUNE_GL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RuneGL RuneGL;
typedef void *(*RuneGLResolve)(const char *name);

/* Captures a top-left crop of the current desktop window before it is swapped.
 * Output is top-down RGBA8. Restores the framebuffer and pixel pack state. */
int rune_gl_window_snapshot(RuneGLResolve resolve, int32_t x, int32_t y, int32_t width,
                            int32_t height, int32_t framebuffer_height, uint8_t *rgba, size_t capacity);

/* All calls require the same current GL 3.3 core or GLES 3 context.
 * Shader sources use the RuneRef primitive ABI, without a #version directive.
 * On failure the supplied error buffer receives a NUL-terminated diagnostic. */
/* Open the shared compositor/device without a primitive pipeline. Callers
 * configure the production and/or reference pipeline before drawing that ABI. */
RuneGL *rune_gl_create_device(RuneGLResolve resolve, const char *fullscreen_source,
                              const char *layer_source, char *error, size_t error_size);
int rune_gl_configure_reference_blur(RuneGL *renderer, const char *fullscreen_source, const char *fragment_source,
                                     char *error, size_t error_capacity);
int rune_gl_configure_reference(RuneGL *renderer, const char *vertex_source,
                                const char *fragment_source, char *error, size_t error_size);

/* Also compile and validate the reference pipeline during creation. */
RuneGL *rune_gl_create(RuneGLResolve resolve, const char *vertex_source,
                       const char *fragment_source, const char *fullscreen_source,
                       const char *layer_source, char *error, size_t error_size);
void rune_gl_destroy(RuneGL *renderer);

/* Frees host allocations without a single GL call when the context is lost or
 * will be destroyed and cannot be made current. The context owns its GL names. */
void rune_gl_abandon(RuneGL *renderer);

/* The synchronous callback draws into an isolated framebuffer, using the
 * snapshot texture as its optional backdrop. Return 1 to composite the result,
 * 0 to fail the frame. Passing NULL unregisters the hook. */
typedef int (*RuneGLEffectHook)(void *user, size_t instance_index, uint32_t framebuffer,
                                uint32_t backdrop, int width, int height, int origin_x, int origin_y);
void rune_gl_set_effect_hook(RuneGL *renderer, RuneGLEffectHook hook, void *user);

/* Scope a host compositor that draws custom passes around the Rune UI pass. */
uint32_t rune_gl_draw_framebuffer(const RuneGL *renderer);
void rune_gl_bind_draw_framebuffer(RuneGL *renderer, uint32_t framebuffer);

const char *rune_gl_renderer(const RuneGL *renderer);
const char *rune_gl_vendor(const RuneGL *renderer);
const char *rune_gl_version(const RuneGL *renderer);

/* Update an existing R8 (channels=1) or RGBA8 (channels=4) atlas. Previous
 * is the last successfully uploaded image and both buffers have exactly
 * width*height*channels bytes. Only changed texels' bounding rectangle is sent.
 * The next render reuses the texture by passing NULL in its place. */
int rune_gl_patch_atlas(RuneGL *renderer, int channels, int width, int height,
                        const uint8_t *previous, const uint8_t *next,
                        char *error, size_t error_size);

/* Each instance contains the 36 consecutive floats of RuneRef.Primitive.
 * Each atlas contains width*height tightly packed pixels (R8 or RGBA8).
 * Pass NULL for an unchanged, already uploaded atlas of the same size/format.
 * The current draw framebuffer is the destination. Returns 1 on success.
 * The renderer owns its GL draw state; the host owns presentation/swap. */
int rune_gl_render(RuneGL *renderer, int width, int height, const float *clear_rgba,
                   int srgb_blend, const void *instances, size_t count,
                   const uint8_t *glyphs, int glyph_width, int glyph_height,
                   const uint8_t *images, int image_width, int image_height,
                   char *error, size_t error_size);

#ifdef __cplusplus
}
#endif

#include "RuneGLPass.h"
#include "CRuneGLSurface.h"
#include "CRuneGLCompletion.h"
#include "RuneGLFrame.h"
#include "RuneGLLayerCache.h"

#endif
