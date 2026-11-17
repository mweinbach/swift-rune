#include "CRuneOffscreenGL.h"

#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

#if (defined(__APPLE__) && TARGET_OS_OSX) || defined(_WIN32) || (defined(__linux__) && !defined(__ANDROID__))

#include <RuneGLPass.h>
#include <stdio.h>
#include <stdlib.h>

#ifdef __APPLE__
#define GL_SILENCE_DEPRECATION
#include <OpenGL/OpenGL.h>
#include <dlfcn.h>
#elif defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <CRuneWin32.h>
#include <limits.h>
#else
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <dlfcn.h>
#endif

struct RuneOffscreenGLContext {
#ifdef __APPLE__
    CGLContextObj context, previous;
#elif defined(_WIN32)
    RuneWinWindow *window;
    HDC dc, previous_dc;
    HGLRC context, previous;
#else
    EGLDisplay display, previous_display;
    EGLContext context, previous;
    EGLSurface surface, previous_read, previous_draw;
    EGLenum previous_api;
#endif
    RuneGLPassDevice *passes;
    RuneGLPassTarget target;
};

#ifdef __APPLE__
static int open_context(RuneOffscreenGLContext *gl, char *error, size_t size) {
    CGLPixelFormatAttribute attributes[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core, kCGLPFAAccelerated, 0
    };
    CGLPixelFormatObj format = NULL;
    GLint count = 0;
    gl->previous = CGLGetCurrentContext();
    if (gl->previous) CGLRetainContext(gl->previous);
    CGLError result = CGLChoosePixelFormat(attributes, &format, &count);
    if (result == kCGLNoError && format) {
        result = CGLCreateContext(format, NULL, &gl->context);
        CGLReleasePixelFormat(format);
        if (result == kCGLNoError) result = CGLSetCurrentContext(gl->context);
    }
    if (!gl->context || result != kCGLNoError) {
        if (error && size) snprintf(error, size, "CGL context creation failed (%s)", CGLErrorString(result));
        return 0;
    }
    return 1;
}

int rune_offscreen_gl_current(RuneOffscreenGLContext *gl) {
    return gl && gl->context && (CGLGetCurrentContext() == gl->context ||
        CGLSetCurrentContext(gl->context) == kCGLNoError);
}

static void close_context(RuneOffscreenGLContext *gl) {
    CGLSetCurrentContext(gl->previous);
    if (gl->previous) CGLReleaseContext(gl->previous);
    if (gl->context) CGLReleaseContext(gl->context);
}

void *rune_offscreen_gl_proc(const char *name) {
    return name ? dlsym(RTLD_DEFAULT, name) : NULL;
}

#elif defined(_WIN32)
static int open_context(RuneOffscreenGLContext *gl, char *error, size_t size) {
    static const uint16_t title[] = {'R','u','n','e',0};
    gl->previous_dc = wglGetCurrentDC();
    gl->previous = wglGetCurrentContext();
    gl->window = rune_win_create(title, 1, 1, 0, 0, 0, error, size > INT_MAX ? INT_MAX : (int32_t)size);
    if (!gl->window) return 0;
    gl->dc = wglGetCurrentDC();
    gl->context = wglGetCurrentContext();
    return gl->context != NULL;
}

int rune_offscreen_gl_current(RuneOffscreenGLContext *gl) {
    return gl && gl->context && ((wglGetCurrentContext() == gl->context && wglGetCurrentDC() == gl->dc) ||
        wglMakeCurrent(gl->dc, gl->context));
}

static void close_context(RuneOffscreenGLContext *gl) {
    rune_win_destroy(gl->window);
    wglMakeCurrent(gl->previous_dc, gl->previous);
}

void *rune_offscreen_gl_proc(const char *name) {
    return name ? rune_win_gl_proc(name) : NULL;
}

#else
static int egl_failure(char *error, size_t size, const char *stage) {
    EGLint code = eglGetError();
    if (error && size) snprintf(error, size, "%s (EGL error 0x%x)", stage, code);
    return 0;
}

static int open_context(RuneOffscreenGLContext *gl, char *error, size_t size) {
    gl->previous = eglGetCurrentContext();
    gl->previous_display = eglGetCurrentDisplay();
    gl->previous_draw = eglGetCurrentSurface(EGL_DRAW);
    gl->previous_read = eglGetCurrentSurface(EGL_READ);
    gl->previous_api = eglQueryAPI();
    PFNEGLGETPLATFORMDISPLAYEXTPROC platform_display =
        (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    if (platform_display) {
        gl->display = platform_display(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
    }
    if (gl->display == EGL_NO_DISPLAY || !eglInitialize(gl->display, NULL, NULL)) {
        gl->display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        if (gl->display == EGL_NO_DISPLAY || !eglInitialize(gl->display, NULL, NULL)) {
            return egl_failure(error, size, "Cannot initialize EGL display");
        }
    }
    const EGLint config_attributes[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE
    };
    const EGLint surface_attributes[] = { EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE };
    const EGLint context_attributes[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    EGLConfig config;
    EGLint count = 0;
    if (!eglChooseConfig(gl->display, config_attributes, &config, 1, &count) || !count ||
        !eglBindAPI(EGL_OPENGL_ES_API)) {
        return egl_failure(error, size, "Cannot select EGL ES3 config");
    }
    gl->surface = eglCreatePbufferSurface(gl->display, config, surface_attributes);
    gl->context = eglCreateContext(gl->display, config, EGL_NO_CONTEXT, context_attributes);
    if (gl->surface == EGL_NO_SURFACE || !rune_offscreen_gl_current(gl)) {
        return egl_failure(error, size, "Cannot make ES3 context current");
    }
    return 1;
}

int rune_offscreen_gl_current(RuneOffscreenGLContext *gl) {
    if (!gl || gl->context == EGL_NO_CONTEXT) return 0;
    if (eglGetCurrentContext() == gl->context && eglGetCurrentSurface(EGL_DRAW) == gl->surface &&
        eglGetCurrentSurface(EGL_READ) == gl->surface) return 1;
    return eglBindAPI(EGL_OPENGL_ES_API) && eglMakeCurrent(gl->display, gl->surface, gl->surface, gl->context);
}

static void close_context(RuneOffscreenGLContext *gl) {
    if (gl->display != EGL_NO_DISPLAY) {
        if (gl->context && eglGetCurrentContext() == gl->context) {
            eglMakeCurrent(gl->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        }
        if (gl->context != EGL_NO_CONTEXT) eglDestroyContext(gl->display, gl->context);
        if (gl->surface != EGL_NO_SURFACE) eglDestroySurface(gl->display, gl->surface);
        // EGLDisplay is process-wide; terminating it would also tear down other renderers.
    }
    eglBindAPI(gl->previous_api);
    if (gl->previous != EGL_NO_CONTEXT) {
        eglMakeCurrent(gl->previous_display, gl->previous_draw, gl->previous_read, gl->previous);
    }
}

void *rune_offscreen_gl_proc(const char *name) {
    if (!name) return NULL;
    void *address = (void *)eglGetProcAddress(name);
    return address ? address : dlsym(RTLD_DEFAULT, name);
}
#endif

RuneOffscreenGLContext *rune_offscreen_gl_open(char *error, size_t size) {
    RuneOffscreenGLContext *gl = calloc(1, sizeof(*gl));
    if (!gl) {
        if (error && size) snprintf(error, size, "Out of memory creating GL context");
        return NULL;
    }
    if (!open_context(gl, error, size) || !(gl->passes = rune_gl_pass_open(rune_offscreen_gl_proc, error, size))) {
        close_context(gl);
        free(gl);
        return NULL;
    }
    return gl;
}

void rune_offscreen_gl_close(RuneOffscreenGLContext *gl) {
    if (!gl) return;
    if (rune_offscreen_gl_current(gl)) {
        rune_gl_pass_delete_target(gl->passes, &gl->target);
        rune_gl_pass_close(gl->passes);
    } else {
        rune_gl_pass_abandon(gl->passes);
    }
    close_context(gl);
    free(gl);
}

int rune_offscreen_gl_bind(RuneOffscreenGLContext *gl, int width, int height) {
    if (!rune_offscreen_gl_current(gl) || width <= 0 || height <= 0) return 0;
    if (width != gl->target.width || height != gl->target.height) {
        RuneGLPassTarget replacement;
        if (!rune_gl_pass_target(gl->passes, RuneGLPassRGBA8, width, height, 0, &replacement, NULL, 0)) return 0;
        rune_gl_pass_delete_target(gl->passes, &gl->target);
        gl->target = replacement;
    }
    rune_gl_pass_bind_target(gl->passes, gl->target);
    return 1;
}

int rune_offscreen_gl_read(RuneOffscreenGLContext *gl, uint8_t *pixels, size_t count) {
    return rune_offscreen_gl_current(gl) && gl->target.framebuffer &&
        rune_gl_pass_read(gl->passes, gl->target, pixels, count, NULL, 0);
}
#endif
