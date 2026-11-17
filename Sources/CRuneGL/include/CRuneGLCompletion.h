#ifndef C_RUNE_GL_COMPLETION_H
#define C_RUNE_GL_COMPLETION_H

#if defined(__linux__)
#ifdef __cplusplus
extern "C" {
#endif

typedef struct RuneGL RuneGL;
typedef struct RuneGLCompletion RuneGLCompletion;

/* Create and submit on the rendering context. A successful submission transfers
 * user to exactly one FIFO callback on the receiver thread. completed is zero
 * on context loss. EGL fences complete even after the rendering thread sleeps. */
RuneGLCompletion *rune_gl_completion_create(RuneGL *renderer);
int rune_gl_completion_submit(RuneGLCompletion *queue, void *user, void (*finished)(void *, int));
/* GLX and EGL drivers without native fences require a zero-timeout poll on
 * the originating context. No context is needed to query whether work is due. */
int rune_gl_completion_needs_poll(RuneGLCompletion *queue);
int rune_gl_completion_poll(RuneGLCompletion *queue);
/* The owner stops submitting/polling before destroying the queue once.
 * Graceful destruction requires the originating context and drains accepted
 * work. Context loss can be reported by the callback itself. */
void rune_gl_completion_destroy(RuneGLCompletion *queue, int context_lost);

#ifdef __cplusplus
}
#endif
#endif
#endif
