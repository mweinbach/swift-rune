#define _POSIX_C_SOURCE 200809L
#include "RuneLinuxGPUSelection.h"
#include "CRuneOffscreenGL.h"
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    char error[256];
    unsetenv("WGPU_ADAPTER_NAME"); unsetenv("WGPU_POWER_PREF");
    RuneOffscreenGLContext *first = rune_offscreen_gl_open(error, sizeof error);
    if (!first) { fprintf(stderr, "%s\n", error); return 1; }
    assert(rune_offscreen_gl_bind(first, 3, 2));
    glClearColor(0, 1, 0, 1); glClear(GL_COLOR_BUFFER_BIT);
    EGLContext original = eglGetCurrentContext();
    EGLDisplay originalDisplay = eglGetCurrentDisplay();
    char *renderer = strdup((const char *)glGetString(GL_RENDERER));
    assert(renderer && *renderer);
    setenv("WGPU_ADAPTER_NAME", renderer, 1);
    EGLDisplay chosen = rune_gpu_offscreen_display();
    assert(chosen != EGL_NO_DISPLAY);
    assert(eglGetCurrentContext() == original && eglGetCurrentDisplay() == originalDisplay);
    RuneOffscreenGLContext *other = rune_offscreen_gl_open(error, sizeof error);
    assert(other && eglGetCurrentDisplay() == chosen && !strcmp(renderer, (const char *)glGetString(GL_RENDERER)));
    assert(rune_offscreen_gl_bind(other, 2, 1));
    uint8_t pixels[24];
    glClearColor(1, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT);
    assert(rune_offscreen_gl_read(other, pixels, 8) && pixels[0] == 255 && pixels[1] == 0);
    rune_offscreen_gl_close(other);
    assert(eglGetCurrentContext() == original && rune_offscreen_gl_read(first, pixels, sizeof pixels) && pixels[0] == 0 && pixels[1] == 255);
    setenv("WGPU_ADAPTER_NAME", "no-such-rune-gpu", 1);
    assert(rune_gpu_offscreen_display() == EGL_NO_DISPLAY);
    assert(eglGetCurrentContext() == original);
    printf("EGL_PLATFORM_DEVICE_EXT named %s; red + restored green surfaces read back; unmatched name fell through\n", renderer);
    free(renderer); rune_offscreen_gl_close(first);
}
