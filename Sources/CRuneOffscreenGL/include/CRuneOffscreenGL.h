#ifndef C_RUNE_OFFSCREEN_GL_H
#define C_RUNE_OFFSCREEN_GL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RuneOffscreenGLContext RuneOffscreenGLContext;

/* A windowless GLES 3 context on Linux and a desktop core-profile GL context on
 * macOS/Windows. Use on its owning OS thread. Opening makes it current; closing
 * restores the previous context. Close nested contexts in reverse order. */
RuneOffscreenGLContext *rune_offscreen_gl_open(char *error, size_t error_size);
void rune_offscreen_gl_close(RuneOffscreenGLContext *context);
int rune_offscreen_gl_current(RuneOffscreenGLContext *context);
void *rune_offscreen_gl_proc(const char *name);

/* Bind or resize the RGBA8 color attachment. A failed resize preserves the
 * previous attachment. Read returns width * height * 4 bytes, bottom row first. */
int rune_offscreen_gl_bind(RuneOffscreenGLContext *context, int width, int height);
int rune_offscreen_gl_read(RuneOffscreenGLContext *context, uint8_t *pixels, size_t count);

#ifdef __cplusplus
}
#endif
#endif
