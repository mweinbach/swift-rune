#include "gl_surface.h"

#include <stdio.h>
#include <stdlib.h>

#define RUNE_GL_RG 0x8227
#define RUNE_GL_RG8 0x822B

// One cached, revisable pair of textures per surface. Placed copies share the cache.
typedef struct SurfaceImage {
    uint64_t key, version;
    int width, height, format;
    GLuint textures[2];
    struct SurfaceImage *next;
} SurfaceImage;

struct RuneGLSurfaces {
    const RuneGLAPI *gl;
    GLuint program, vao;
    GLint uniforms;
    GLint max_texture_size;
    SurfaceImage *images;
};

static int fail(char *error, size_t capacity, const char *message) {
    if (error && capacity) snprintf(error, capacity, "%s", message);
    return 0;
}

static SurfaceImage *image_for(RuneGLSurfaces *s, uint64_t key) {
    for (SurfaceImage *entry = s->images; entry; entry = entry->next) {
        if (entry->key == key) return entry;
    }
    return NULL;
}

RuneGLSurfaces *rune_surfaces_create(const RuneGLAPI *gl, int es, const char *vs,
                                     const char *fs, char *error, size_t capacity) {
    RuneGLSurfaces *s = calloc(1, sizeof(*s));
    if (!s) { fail(error, capacity, "unable to allocate surface renderer"); return NULL; }
    s->gl = gl;
    s->program = rune_gl_program(gl, es, vs, fs, error, capacity);
    if (!s->program) { free(s); return NULL; }
    gl->GenVertexArrays(1, &s->vao);
    gl->GetIntegerv(GL_MAX_TEXTURE_SIZE, &s->max_texture_size);
    s->uniforms = gl->GetUniformLocation(s->program, "uSurface[0]");
    GLint plane0 = gl->GetUniformLocation(s->program, "uPlane0");
    GLint plane1 = gl->GetUniformLocation(s->program, "uPlane1");
    if (!s->vao || s->uniforms < 0 || plane0 < 0 || plane1 < 0) {
        rune_surfaces_destroy(s);
        fail(error, capacity, "native surface shader interface unavailable");
        return NULL;
    }
    gl->UseProgram(s->program);
    gl->Uniform1i(plane0, 0);
    gl->Uniform1i(plane1, 1);
    return s;
}

static void upload(const RuneGLAPI *gl, GLuint texture, GLenum channels, GLint storage,
                   int w, int h, const uint8_t *bytes, int reuse) {
    gl->BindTexture(GL_TEXTURE_2D, texture);
    if (reuse) {
        gl->TexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, channels, GL_UNSIGNED_BYTE, bytes);
    } else {
        gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        gl->TexImage2D(GL_TEXTURE_2D, 0, storage, w, h, 0, channels, GL_UNSIGNED_BYTE, bytes);
    }
}

int rune_surfaces_upload(RuneGLSurfaces *s, uint64_t key, uint64_t version, int width,
                         int height, int format, const uint8_t *plane0, size_t bytes0,
                         const uint8_t *plane1, size_t bytes1, char *error, size_t capacity) {
    if (!s || !plane0 || width <= 0 || height <= 0 || width > 16384 || height > 16384 ||
        width > s->max_texture_size || height > s->max_texture_size || format < 0 || format > 3)
        return fail(error, capacity, "invalid native surface format or dimensions for this device");
    int nv12 = format == 1 || format == 2;
    size_t pixels = (size_t)width * (size_t)height;
    if (bytes0 != pixels * (nv12 ? 1u : 4u) || (nv12 && ((width | height) & 1)) ||
        bytes1 != (nv12 ? pixels / 2 : 0) || (nv12 && !plane1))
        return fail(error, capacity, "invalid native surface plane byte counts");
    SurfaceImage *entry = image_for(s, key);
    if (entry && entry->width == width && entry->height == height && entry->format == format && entry->version == version) return 1;
    const RuneGLAPI *gl = s->gl;
    if (!entry) {
        entry = calloc(1, sizeof(*entry));
        if (!entry) return fail(error, capacity, "unable to allocate native surface textures");
        gl->GenTextures(2, entry->textures);
        entry->key = key;
        entry->next = s->images;
        s->images = entry;
    }
    int reuse = entry->width == width && entry->height == height && entry->format == format;
    gl->BindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    gl->PixelStorei(GL_UNPACK_ALIGNMENT, 1);
    gl->PixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    gl->PixelStorei(GL_UNPACK_SKIP_PIXELS, 0);
    gl->PixelStorei(GL_UNPACK_SKIP_ROWS, 0);
    gl->ActiveTexture(GL_TEXTURE0);
    upload(gl, entry->textures[0], nv12 ? GL_RED : GL_RGBA, nv12 ? GL_R8 : GL_RGBA8, width, height, plane0, reuse);
    if (nv12) upload(gl, entry->textures[1], RUNE_GL_RG, RUNE_GL_RG8, width / 2, height / 2, plane1, reuse);
    if (gl->GetError() != GL_NO_ERROR) {
        entry->width = 0; // force reallocating both planes on retry
        return fail(error, capacity, "native surface texture upload failed");
    }
    entry->width = width;
    entry->height = height;
    entry->format = format;
    entry->version = version;
    return 1;
}

int rune_surfaces_draw(RuneGLSurfaces *s, int width, int height, int origin_x, int origin_y, int additive,
                       const RuneGLSurfaceDraw *draw, char *error, size_t capacity) {
    if (!s || !draw) return fail(error, capacity, "native surface renderer unconfigured");
    SurfaceImage *entry = image_for(s, draw->key);
    if (!entry || entry->width == 0 || entry->version != draw->version)
        return fail(error, capacity, "native surface draw references an unavailable texture revision");
    const RuneGLAPI *gl = s->gl;
    gl->UseProgram(s->program);
    gl->Uniform4fv(s->uniforms, 13, draw->uniforms[0]);
    gl->Uniform4f(s->uniforms, (float)width, (float)height, (float)origin_x, (float)origin_y);
    gl->BindVertexArray(s->vao);
    gl->Enable(GL_BLEND);
    gl->BlendEquation(GL_FUNC_ADD);
    gl->BlendFunc(GL_ONE, additive ? GL_ONE : GL_ONE_MINUS_SRC_ALPHA);
    gl->ActiveTexture(GL_TEXTURE0);
    gl->BindTexture(GL_TEXTURE_2D, entry->textures[0]);
    gl->ActiveTexture(GL_TEXTURE1);
    gl->BindTexture(GL_TEXTURE_2D, (entry->format == 1 || entry->format == 2) ? entry->textures[1] : entry->textures[0]);
    gl->DrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    return 1;
}

void rune_surfaces_prune(RuneGLSurfaces *s, const RuneGLSurfaceDraw *draws, size_t count) {
    if (!s) return;
    SurfaceImage **link = &s->images;
    while (*link) {
        SurfaceImage *entry = *link;
        size_t i = 0;
        while (i < count && entry->key != draws[i].key) ++i;
        if (i == count) {
            *link = entry->next;
            s->gl->DeleteTextures(2, entry->textures);
            free(entry);
        } else {
            link = &entry->next;
        }
    }
}

void rune_surfaces_destroy(RuneGLSurfaces *s) {
    if (!s) return;
    rune_surfaces_prune(s, NULL, 0);
    s->gl->DeleteVertexArrays(1, &s->vao);
    s->gl->DeleteProgram(s->program);
    free(s);
}

void *rune_gl_surface_fence(RuneGL *r) {
    const RuneGLAPI *gl = rune_gl_current_api(r);
    return gl ? gl->FenceSync(0x9117 /* GL_SYNC_GPU_COMMANDS_COMPLETE */, 0) : NULL;
}

void *rune_gl_submit_fence(RuneGL *r) {
    const RuneGLAPI *gl = rune_gl_current_api(r);
    void *fence = rune_gl_surface_fence(r);
    if (!fence) return NULL;
    gl->Flush();
    return fence;
}

int rune_gl_surface_wait(RuneGL *r, void *fence, int wait) {
    const RuneGLAPI *gl = rune_gl_current_api(r);
    if (!gl || !fence) return -1;
    const GLenum already = 0x911A, signaled = 0x911C, timed_out = 0x911B;
    for (;;) {
        GLenum result = gl->ClientWaitSync(fence, wait ? 1u /* GL_SYNC_FLUSH_COMMANDS_BIT */ : 0u,
                                           wait ? UINT64_C(100000000) : 0u);
        if (result == already || result == signaled) return 1;
        if (result != timed_out) return -1;
        if (!wait) return 0;
    }
}

void rune_gl_surface_fence_free(RuneGL *r, void *fence) {
    const RuneGLAPI *gl = rune_gl_current_api(r);
    if (gl && fence) gl->DeleteSync(fence);
}
