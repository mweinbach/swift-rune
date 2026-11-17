#include "production_blur.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

/* Matches RenderPasses.LayerBlurKernel and BackdropBlurSchedule. All intermediate
 * textures store premultiplied values in the host's active blending space. */
enum { PREFILTER, GAUSSIAN, RESAMPLE, DOWN, UP, RESOLVE };
enum { MIP_COUNT = 7, MAX_TAPS = 128, BUCKET = 64 };

typedef struct {
    GLuint texture, fbo;
    GLenum format;
    int width, height;
} BlurTarget;

struct RuneGLBlur {
    const RuneGLAPI *gl;
    GLuint program, vao;
    GLint mode, additive, domain, dest, map, region, axis, count, taps, blend;
    BlurTarget scratch[2], down[MIP_COUNT], up[MIP_COUNT-1], output;
};

static int fail(char *error, size_t capacity, const char *message) {
    if (error && capacity) snprintf(error, capacity, "%s", message);
    return 0;
}

RuneGLBlur *rune_gl_blur_create(const RuneGLAPI *gl, int es, const char *fullscreen,
                                const char *fragment, char *error, size_t capacity) {
    RuneGLBlur *b = calloc(1, sizeof(*b));
    if (!b) {
        fail(error, capacity, "Could not allocate the Rune GL blur pipeline");
        return NULL;
    }
    b->gl = gl;
    b->program = rune_gl_program(gl, es, fullscreen, fragment, error, capacity);
    if (!b->program) { free(b); return NULL; }
    gl->GenVertexArrays(1, &b->vao);
    gl->UseProgram(b->program);
    gl->Uniform1i(gl->GetUniformLocation(b->program, "uSource"), 0);
    gl->Uniform1i(gl->GetUniformLocation(b->program, "uFine"), 1);
    b->mode = gl->GetUniformLocation(b->program, "uMode");
    b->additive = gl->GetUniformLocation(b->program, "uAdditive");
    b->domain = gl->GetUniformLocation(b->program, "uDomain");
    b->dest = gl->GetUniformLocation(b->program, "uDest");
    b->map = gl->GetUniformLocation(b->program, "uMap");
    b->region = gl->GetUniformLocation(b->program, "uRegion");
    b->axis = gl->GetUniformLocation(b->program, "uAxis");
    b->count = gl->GetUniformLocation(b->program, "uCount");
    b->taps = gl->GetUniformLocation(b->program, "uTaps[0]");
    b->blend = gl->GetUniformLocation(b->program, "uBlend");
    return b;
}

static void release_target(const RuneGLAPI *gl, BlurTarget *t) {
    gl->DeleteFramebuffers(1, &t->fbo);
    gl->DeleteTextures(1, &t->texture);
    *t = (BlurTarget){0};
}

void rune_gl_blur_destroy(RuneGLBlur *b) {
    if (!b) return;
    for (int i = 0; i < 2; ++i) release_target(b->gl, &b->scratch[i]);
    for (int i = 0; i < MIP_COUNT; ++i) release_target(b->gl, &b->down[i]);
    for (int i = 0; i < MIP_COUNT-1; ++i) release_target(b->gl, &b->up[i]);
    release_target(b->gl, &b->output);
    b->gl->DeleteVertexArrays(1, &b->vao);
    b->gl->DeleteProgram(b->program);
    free(b);
}

static int resize_target(RuneGLBlur *b, BlurTarget *t, int width, int height, GLenum format,
                         char *error, size_t capacity) {
    if (t->width == width && t->height == height && t->format == format) return 1;
    const RuneGLAPI *gl = b->gl;
    release_target(gl, t);
    gl->GenTextures(1, &t->texture);
    gl->BindTexture(GL_TEXTURE_2D, t->texture);
    gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    gl->TexImage2D(GL_TEXTURE_2D, 0, (GLint)format, width, height, 0, GL_RGBA,
                   format == GL_RGBA16F ? GL_HALF_FLOAT : GL_UNSIGNED_BYTE, NULL);
    gl->GenFramebuffers(1, &t->fbo);
    gl->BindFramebuffer(GL_FRAMEBUFFER, t->fbo);
    gl->FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, t->texture, 0);
    if (gl->CheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        release_target(gl, t);
        if (error && capacity) snprintf(error, capacity, "Rune GL blur framebuffer %dx%d incomplete", width, height);
        return 0;
    }
    t->width = width;
    t->height = height;
    t->format = format;
    return 1;
}

static void draw(RuneGLBlur *b, int mode, const BlurTarget *dst, GLuint src, GLuint fine) {
    const RuneGLAPI *gl = b->gl;
    gl->BindFramebuffer(GL_FRAMEBUFFER, dst->fbo);
    gl->Viewport(0, 0, dst->width, dst->height);
    gl->Uniform4f(b->dest, 0, 0, (float)dst->width, (float)dst->height);
    gl->ActiveTexture(GL_TEXTURE0);
    gl->BindTexture(GL_TEXTURE_2D, src);
    gl->ActiveTexture(GL_TEXTURE1);
    gl->BindTexture(GL_TEXTURE_2D, fine ? fine : src);
    gl->Uniform1i(b->mode, mode);
    gl->DrawArrays(GL_TRIANGLES, 0, 3);
}

static void set_kernel(RuneGLBlur *b, float sigma, float scale, int vertical) {
    float variance = (scale*scale - 1.0f)*0.25f;
    float effective = sqrtf(fmaxf(1e-6f, sigma*sigma - variance))/scale;
    float weights[MAX_TAPS*2] = {1};
    float pairs[MAX_TAPS][4] = {{0, 1, 0, 0}};
    int radius = (int)fminf(MAX_TAPS*2-2, ceilf(3.0f*effective));
    float sum = 1;
    for (int k = 1; k <= radius; ++k) {
        weights[k] = expf(-0.5f*(float)(k*k)/(effective*effective));
        sum += 2*weights[k];
    }
    pairs[0][1] = 1/sum;
    int count = 1;
    for (int k = 1; k <= radius; k += 2) {
        float combined = weights[k] + weights[k+1];
        if (combined/sum <= 1e-6f) continue;
        pairs[count][0] = (float)k + weights[k+1]/combined;
        pairs[count][1] = combined/sum;
        ++count;
    }
    b->gl->Uniform2f(b->axis, vertical ? 0 : 1, vertical ? 1 : 0);
    b->gl->Uniform1i(b->count, count);
    b->gl->Uniform4fv(b->taps, count, &pairs[0][0]);
}

static int bucket(int n) { return ((n + BUCKET-1) / BUCKET) * BUCKET; }

/* Only reconstruct the region that the compositor will sample. Clearing before
 * applying the scissor prevents prior contents from leaking into a rotated group. */
static void resolve(RuneGLBlur *b, int mode, GLuint source,
                    float left, float top, float right, float bottom) {
    const RuneGLAPI *gl = b->gl;
    const BlurTarget *dst = &b->output;
    int x0 = (int)fminf(dst->width, fmaxf(0, floorf(left)));
    int y0 = (int)fminf(dst->height, fmaxf(0, floorf(top)));
    int x1 = (int)fmaxf(x0, fminf(dst->width, ceilf(right)));
    int y1 = (int)fmaxf(y0, fminf(dst->height, ceilf(bottom)));
    gl->BindFramebuffer(GL_FRAMEBUFFER, dst->fbo);
    gl->ClearColor(0, 0, 0, 0);
    gl->Clear(GL_COLOR_BUFFER_BIT);
    gl->Enable(GL_SCISSOR_TEST);
    gl->Scissor(x0, dst->height - y1, x1-x0, y1-y0);
    draw(b, mode, dst, source, 0);
    gl->Disable(GL_SCISSOR_TEST);
}

static int layer_blur(RuneGLBlur *b, GLenum format, int width, int height, GLuint source,
                      const float *rect, float sigma, int additive, char *error, size_t capacity) {
    const RuneGLAPI *gl = b->gl;
    sigma = fminf(sigma, 64);
    // Bound the area of a caller-supplied isolated layer to its influence on
    // this framebuffer before converting the coordinates to allocation sizes.
    float halo = ceilf(3*sigma);
    float x = fmaxf(-halo, floorf(rect[0])), y = fmaxf(-halo, floorf(rect[1]));
    float right = fminf(width+halo, ceilf(rect[0]+rect[2]));
    float bottom = fminf(height+halo, ceilf(rect[1]+rect[3]));
    if (right <= x || bottom <= y) {
        gl->BindFramebuffer(GL_FRAMEBUFFER, b->output.fbo);
        gl->ClearColor(0, 0, 0, 0);
        gl->Clear(GL_COLOR_BUFFER_BIT);
        return 1;
    }
    int w = bucket((int)(right-x)), h = bucket((int)(bottom-y));
    float reduction = fminf(8.0f, fmaxf(sigma/3.0f, 1.0f));
    int rw = (int)ceilf(w/reduction), rh = (int)ceilf(h/reduction);
    float sx = (float)w/rw, sy = (float)h/rh;
    if (!resize_target(b, &b->scratch[0], rw, rh, format, error, capacity) ||
        !resize_target(b, &b->scratch[1], rw, rh, format, error, capacity)) return 0;
    gl->Uniform1i(b->additive, additive);
    gl->Uniform4f(b->domain, x, y, (float)w, (float)h);
    if (rw != w || rh != h) {
        gl->Uniform4f(b->map, sx, sy, 0, 0);
        draw(b, PREFILTER, &b->scratch[0], source, 0);
        source = b->scratch[0].texture;
        gl->Uniform4f(b->domain, 0, 0, (float)rw, (float)rh);
    }
    set_kernel(b, sigma, sx, 0);
    draw(b, GAUSSIAN, &b->scratch[1], source, 0);
    set_kernel(b, sigma, sy, 1);
    gl->Uniform4f(b->domain, 0, 0, (float)rw, (float)rh);
    draw(b, GAUSSIAN, &b->scratch[0], b->scratch[1].texture, 0);
    gl->Uniform4f(b->map, 1/sx, 1/sy, -x/sx, -y/sy);
    resolve(b, RESAMPLE, b->scratch[0].texture, x, y, right, bottom);
    return 1;
}

static int backdrop_blur(RuneGLBlur *b, GLenum format, int width, int height, GLuint source,
                         const float *rect, float sigma, char *error, size_t capacity) {
    static const float sigmas[MIP_COUNT] = {1.58f, 4.53f, 9.62f, 19.51f, 39.15f, 78.36f, 156.2f};
    float s = fminf(sigmas[MIP_COUNT-1], fmaxf(sigmas[0], sigma));
    int n = 1;
    while (n < MIP_COUNT-1 && s > sigmas[n]) ++n;
    float lo = sigmas[n-1], hi = sigmas[n];
    float share = (s*s-lo*lo)/(hi*hi-lo*lo);
    float reach = 3.0f*fminf(hi,sigma) + 2.0f;
    float left = fmaxf(0, rect[0]-reach), top = fmaxf(0, rect[1]-reach);
    float right = fminf((float)width, rect[0]+rect[2]+reach);
    float bottom = fminf((float)height, rect[1]+rect[3]+reach);
    if (right <= left || bottom <= top) return 0;

    int alignment = 2 << n;
    float x = floorf(left/alignment)*alignment, y = floorf(top/alignment)*alignment;
    int pw = bucket((int)ceilf((right-x)*0.5f)), ph = bucket((int)ceilf((bottom-y)*0.5f));
    float ex = (float)(2*pw), ey = (float)(2*ph);
    const RuneGLAPI *gl = b->gl;
    gl->Uniform4f(b->region, left/width, top/height, right/width, bottom/height);
    gl->Uniform4f(b->map, ex/width, ey/height, x/width, y/height);
    for (int i = 0; i <= n; ++i) {
        if (!resize_target(b, &b->down[i], pw >> i, ph >> i, format, error, capacity)) return 0;
        draw(b, DOWN, &b->down[i], i == 0 ? source : b->down[i-1].texture, 0);
        if (i == 0) {
            gl->Uniform4f(b->region, (left-x)/ex, (top-y)/ey, (right-x)/ex, (bottom-y)/ey);
            gl->Uniform4f(b->map, 1, 1, 0, 0);
        }
    }
    GLuint coarse = b->down[n].texture;
    for (int i = n-1; i >= 0; --i) {
        if (!resize_target(b, &b->up[i], pw >> i, ph >> i, format, error, capacity)) return 0;
        gl->Uniform1f(b->blend, i == n-1 ? share : 1.0f);
        draw(b, UP, &b->up[i], coarse, b->down[i].texture);
        coarse = b->up[i].texture;
    }
    gl->Uniform4f(b->map, (float)width/ex, (float)height/ey, -x/ex, -y/ey);
    resolve(b, RESOLVE, coarse, rect[0]-1, rect[1]-1, rect[0]+rect[2]+1, rect[1]+rect[3]+1);
    return 1;
}

int rune_gl_blur_draw(RuneGLBlur *b, GLenum format, int width, int height, GLuint source,
                      const float *rect, float sigma, int backdrop, int additive, GLuint *result,
                      char *error, size_t capacity) {
    if (!b || !rect || !result || width < 1 || height < 1 || width > 16384 || height > 16384)
        return fail(error, capacity, "Invalid Rune production blur target");
    *result = source;
    if (sigma <= (backdrop ? 0.0f : 0.05f)) return 1;
    if (backdrop && (rect[0]+rect[2] <= 0 || rect[1]+rect[3] <= 0 ||
                     rect[0] >= width || rect[1] >= height)) return 1;
    if (!resize_target(b, &b->output, width, height, format, error, capacity)) return 0;
    b->gl->UseProgram(b->program);
    b->gl->BindVertexArray(b->vao);
    b->gl->Disable(GL_BLEND);
    b->gl->Disable(GL_SCISSOR_TEST);
    int ok = backdrop ? backdrop_blur(b, format, width, height, source, rect, sigma, error, capacity)
                      : layer_blur(b, format, width, height, source, rect, sigma, additive, error, capacity);
    if (ok) *result = b->output.texture;
    return ok;
}
