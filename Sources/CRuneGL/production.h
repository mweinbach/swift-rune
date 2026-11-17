#ifndef RUNE_GL_PRODUCTION_H
#define RUNE_GL_PRODUCTION_H

#include "gl_api.h"

typedef struct RuneGLProduction RuneGLProduction;
enum RuneGLPaintVariant {
    RUNE_GL_FRAME, RUNE_GL_OUTLINE, RUNE_GL_OUTLINE_LCD, RUNE_GL_MASK_FILL, RUNE_GL_COMMON
};
typedef struct {
    GLuint tracks, ids;
    GLfloat seconds, fraction;
} RuneGLFrameSprings;
RuneGLProduction *rune_production_create(const RuneGLAPI *gl, int es, int variant, const char *vs,
                                         const char *fs, char *error, size_t capacity);
void rune_production_destroy(RuneGLProduction *production);
void rune_production_batch(RuneGLProduction *production, GLuint buffer, int width,
                           int height, int origin_x, int origin_y, size_t first, size_t count,
                           int srgb_blend, int in_layer, int atlas_fill, const RuneGLFrameSprings *springs);
int rune_production_marker(const void *instance, float converted[36]);

#endif
