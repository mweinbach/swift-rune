#ifndef RUNE_WIN_WGL_WORKER_H
#define RUNE_WIN_WGL_WORKER_H

#ifdef _WIN32
#include <stdint.h>
#include <windows.h>

typedef struct RuneWGLWorker RuneWGLWorker;

// Makes a 3.3 core context current. The caller owns the DC and the resulting RC.
// Set vsync to NULL when this drawable is only used to build the renderer.
const char *rune_wgl_configure(HDC dc, HGLRC *out, int *vsync);
int rune_wgl_vsync(void);

// Called on the owner thread. The worker acquires ctx and calls release exactly
// once, including when it cannot start. prepare runs with the new context current.
RuneWGLWorker *rune_wgl_worker_start(HWND notify, UINT message, int urgent, void *ctx,
                                    int32_t (*prepare)(void *), void (*release)(void *));
uint32_t rune_wgl_worker_token(RuneWGLWorker *worker);
// 0 while preparing, 1 after the worker releases its context, -1 on failure.
int rune_wgl_worker_state(RuneWGLWorker *worker);
void rune_wgl_worker_raise(RuneWGLWorker *worker);
// On success the owner thread has the renderer's original context current on
// its own drawable. It now owns the context and closes it after the renderer.
int rune_wgl_worker_adopt(RuneWGLWorker *worker, HDC drawable, HGLRC *out);
// Cancels further notification and returns without joining the driver thread.
void rune_wgl_worker_close(RuneWGLWorker *worker);
#endif
#endif
