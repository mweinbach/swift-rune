#ifndef RUNE_WIN_PRESENT_INTEROP_H
#define RUNE_WIN_PRESENT_INTEROP_H

#ifdef _WIN32
#include <d3d11.h>

struct RunePresentInterop;

// All calls belong to the window's current WGL context and its presentation thread.
RunePresentInterop *rune_present_interop_create(ID3D11Device *device);
bool rune_present_interop_resize(RunePresentInterop *interop, int width, int height);
void rune_present_interop_bind(RunePresentInterop *interop);
// Pixels are display-encoded RGBA8. Dirty rectangles are top-down, with exclusive ends.
// Zero rectangles copies the whole frame. The texture is borrowed until resize or teardown.
ID3D11Texture2D *rune_present_interop_copy(RunePresentInterop *interop, const RECT *dirty, unsigned count);
void rune_present_interop_fallback(RunePresentInterop *interop);
void rune_present_interop_destroy(RunePresentInterop *interop, bool current);
#endif
#endif
