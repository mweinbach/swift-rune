#pragma once
#include <d3d11.h>
#include <GL/gl.h>

// The caller holds the texture through WGL registration and copy.
bool rune_win_blit_d3d_texture(ID3D11Device *device, ID3D11Texture2D *texture,
                               UINT width, UINT height, GLuint destination);
