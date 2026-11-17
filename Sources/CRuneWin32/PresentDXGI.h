#pragma once
#ifdef _WIN32
#include <windows.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct RuneDXGIPresenter RuneDXGIPresenter;
RuneDXGIPresenter *rune_dxgi_open(HWND window, UINT wake);
// The ordinary CPU-first window keeps its GDI content visible until the first
// completed DXGI frame commits through an independent DirectComposition target.
RuneDXGIPresenter *rune_dxgi_open_cpu(HWND window, UINT wake);
void rune_dxgi_close(RuneDXGIPresenter *presenter, int current);
// 1 has a frame target, 0 is waiting for room, -1 returns the host to WGL.
int rune_dxgi_prepare(RuneDXGIPresenter *presenter);
int rune_dxgi_ready(RuneDXGIPresenter *presenter, ULONG_PTR token);
int rune_dxgi_present(RuneDXGIPresenter *presenter, int width, int height, const int32_t *rects, int count);
void rune_dxgi_report(const char *path, const char *detail, HRESULT result);
#ifdef __cplusplus
}
#endif
#endif
