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
 * available on the same context for GPU differential tests and replay.
 * Returns 0 on failure, 1 on success or 2 when the device refused the optional
 * blur shader. In the latter case error describes the refusal; the production
 * pipeline is usable and layers draw unfiltered without a working blur shader. */
int rune_gl_configure_frame(RuneGL *renderer, const char *vertex, const char *fragment,
                            const char *fullscreen, const char *blur, char *error, size_t capacity);

/* Prepare an optional glyph pipeline. A refused RGB variant leaves the grayscale
 * outline pipeline intact. Records are 1024 RGBA32UI texels per row; first_row
 * is the earliest modified row in the complete padded store snapshot. */
int rune_gl_outline_eligible(const RuneGL *renderer);
int rune_gl_configure_outline(RuneGL *renderer, const char *vertex, const char *fragment, int lcd,
                              char *error, size_t capacity);
int rune_gl_upload_outline_rows(RuneGL *renderer, int rows, int first_row, const uint32_t *texels,
                                char *error, size_t capacity);
/* Fill rectangles in a resident R8 page, optionally replacing its CPU base first.
 * The fill pass restores the host framebuffer. */
int rune_gl_fill_outline_masks(RuneGL *renderer, size_t page, int width, int height, const uint8_t *base,
                               const void *instances, size_t count, char *error, size_t capacity);
void rune_gl_select_outline(RuneGL *renderer, int active, int lcd);

/* Opt in after configuring the stock Rune frame shaders. Shader replacement resets this flag.
 * RUNE_WHOLE_FRAMES=1 forces whole draws for comparison. The last result is -1 for whole,
 * zero for present-only, or the number of GPU scissor rectangles redrawn. */
void rune_gl_enable_frame_damage(RuneGL *renderer, int enable);
/* Borrowed consecutive LTRB coordinates, valid until the next draw. */
const int32_t *rune_gl_last_damage_rects(const RuneGL *renderer);
int rune_gl_last_frame_damage(const RuneGL *renderer);

/* Select borrowed spring coefficient and instance-to-node textures for the spring vertex
 * shader. Supply both names, or zero to disable. State survives shader configuration. */
void rune_gl_frame_springs(RuneGL *renderer, uint32_t tracks, uint32_t ids,
                           float seconds, float fraction);

/* Select R8 glyph (channels=1) or RGBA image (channels=4) slots. Page zero uses the
 * regular render arguments. Missing glyphs use the base glyph texture, missing images
 * sample transparent. Each call requires a current, idle device. */
int rune_gl_atlas_page_count(RuneGL *renderer, int channels, size_t count, char *error, size_t capacity);
/* Update known dirty texels from a full row-major snapshot. Edges are half-open. */
int rune_gl_patch_atlas_region(RuneGL *renderer, int channels, size_t page, int width, int height,
                               int x0, int y0, int x1, int y1, const uint8_t *pixels,
                               char *error, size_t capacity);
int rune_gl_upload_atlas_page(RuneGL *renderer, int channels, size_t page, int width, int height, int srgb,
                              const uint8_t *previous, const uint8_t *pixels,
                              char *error, size_t capacity);

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
