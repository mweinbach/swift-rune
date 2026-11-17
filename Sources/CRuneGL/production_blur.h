#ifndef RUNE_PRODUCTION_BLUR_H
#define RUNE_PRODUCTION_BLUR_H

#include "gl_api.h"

typedef struct RuneGLBlur RuneGLBlur;
RuneGLBlur *rune_gl_blur_create(const RuneGLAPI *gl, int es, const char *fullscreen,
                                const char *fragment, char *error, size_t capacity);
void rune_gl_blur_destroy(RuneGLBlur *blur);

/* rect is the planned layer allocation rect or the backdrop element rect, in
 * top-left device pixels. The result is a viewport-sized premultiplied texture
 * valid until the next blur call. The caller rebinds its own draw state. */
int rune_gl_blur_draw(RuneGLBlur *blur, GLenum format, int width, int height,
                      GLuint source, const float *rect, float sigma, int backdrop,
                      int additive, GLuint *result, char *error, size_t capacity);

#endif
