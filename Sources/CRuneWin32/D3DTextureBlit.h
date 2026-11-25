#pragma once
#include <cstddef>
#include <d3d11.h>
#include <GL/gl.h>

struct RuneWinD3DBlit {
    ID3D11Texture2D *texture;
    UINT width, height;
    GLuint destination;
};

// The caller holds the texture(s) through WGL registration and copy.
bool rune_win_blit_d3d_textures(ID3D11Device *device, const RuneWinD3DBlit *blits, size_t count);
bool rune_win_blit_d3d_texture(ID3D11Device *device, ID3D11Texture2D *texture,
                               UINT width, UINT height, GLuint destination);
