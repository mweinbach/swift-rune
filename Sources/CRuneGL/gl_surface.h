#ifndef RUNE_GL_SURFACE_H
#define RUNE_GL_SURFACE_H

#include "gl_api.h"
#include "include/CRuneGLSurface.h"

typedef struct RuneGLSurfaces RuneGLSurfaces;
RuneGLSurfaces *rune_surfaces_create(const RuneGLAPI *gl, int es, const char *vs,
                                     const char *fs, char *error, size_t capacity);
int rune_surfaces_upload(RuneGLSurfaces *s, uint64_t key, uint64_t version, int width,
                         int height, int format, const uint8_t *plane0, size_t bytes0,
                         const uint8_t *plane1, size_t bytes1, char *error, size_t capacity);
int rune_surfaces_draw(RuneGLSurfaces *s, int width, int height, int origin_x, int origin_y, int additive,
                       const RuneGLSurfaceDraw *draw, char *error, size_t capacity);
void rune_surfaces_prune(RuneGLSurfaces *s, const RuneGLSurfaceDraw *draws, size_t count);
void rune_surfaces_destroy(RuneGLSurfaces *s);

#endif
