#pragma once
#ifdef _WIN32
#include <windows.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct RuneWGLCover RuneWGLCover;

// Stage the last GDI frame above the hidden WGL child's own DC. The caller may
// show the child after this succeeds. The pixels are borrowed only for this call.
RuneWGLCover *rune_wgl_cover(HWND child, const void *bgra, int width, int height, int stride_bytes);
// Call after completing the child's first visible swap. On failure, hide the
// child before releasing the cover so the parent can continue presenting its DIB.
int rune_wgl_uncover(RuneWGLCover *cover);
void rune_wgl_cover_free(RuneWGLCover *cover);

#ifdef __cplusplus
}
#endif
#endif
