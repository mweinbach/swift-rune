#ifndef RUNE_WIN_GL_COMPLETION_H
#define RUNE_WIN_GL_COMPLETION_H
#ifdef __cplusplus
extern "C" {
#endif
typedef struct RuneWinGLCompletion RuneWinGLCompletion;
typedef void (*RuneWinGLCompleted)(void *context, int completed);
// Create on the thread with Rune's presenting WGL context current.
RuneWinGLCompletion *rune_win_gl_completion_create(void);
// Service the current context after a synchronous offscreen readback. Window hosts also poll on an idle timer.
void rune_win_gl_completion_poll_current(void);
// On success the owner takes the flushed GLsync and the callback context.
int rune_win_gl_completion_submit(RuneWinGLCompletion *worker, void *fence, void *context, RuneWinGLCompleted finish);
// Drain callbacks before returning. On context loss, discard pending fences without reporting successful completion.
void rune_win_gl_completion_destroy(RuneWinGLCompletion *worker, int context_lost);
#ifdef __cplusplus
}
#endif
#endif
