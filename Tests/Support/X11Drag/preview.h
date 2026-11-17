#ifndef RUNE_X11_TEST_PREVIEW_H
#define RUNE_X11_TEST_PREVIEW_H
#include "CRuneGL.h"
#include <SDL_opengl.h>

/* Four known quadrants in the actual window back buffer. One is translucent
 * and has RGB channels above alpha to distinguish straight/premultiplied. */
static int capture_preview(uint8_t *pixels, size_t capacity) {
    const uint8_t colors[4][4] = {
        {225, 18, 166, 255}, {43, 199, 52, 255},
        {32, 96, 240, 255}, {179, 64, 153, 128}
    };
    glEnable(GL_SCISSOR_TEST);
    for (int i = 0; i < 4; ++i) {
        const uint8_t *color = colors[i];
        glScissor(10 + i % 2 * 20, 150 - (12 + i / 2 * 12) - 12, 20, 12);
        glClearColor(color[0] / 255.f, color[1] / 255.f, color[2] / 255.f, color[3] / 255.f);
        glClear(GL_COLOR_BUFFER_BIT);
    }
    glDisable(GL_SCISSOR_TEST);
    glPixelStorei(GL_PACK_ALIGNMENT, 8);
    glPixelStorei(GL_PACK_ROW_LENGTH, 51);
    glPixelStorei(GL_PACK_SKIP_PIXELS, 2);
    glPixelStorei(GL_PACK_SKIP_ROWS, 1);
    if (!rune_gl_window_snapshot(SDL_GL_GetProcAddress, 10, 12, 40, 24, 150, pixels, capacity)) return 0;
    GLint state;
    glGetIntegerv(GL_PACK_ROW_LENGTH, &state);
    if (state != 51) return 0;
    glGetIntegerv(GL_PACK_SKIP_ROWS, &state);
    if (state != 1) return 0;
    for (int y = 0; y < 24; ++y) {
        for (int x = 0; x < 40; ++x) {
            if (memcmp(pixels + (y * 40 + x) * 4, colors[(y >= 12) * 2 + (x >= 20)], 4)) return 0;
        }
    }
    return 1;
}
#endif
