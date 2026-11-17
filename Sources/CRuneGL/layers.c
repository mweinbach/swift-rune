#include "layers.h"
#include "production_blur.h"
#include "layer_cache.h"

#include <float.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { REF_MAX_LAYER_DEPTH = 8 };  /* RefScene.maxLayerDepth */
enum { SPARE_TARGETS = 64, SPARE_BYTES = 32*1024*1024, RESTING_BYTES = 8*1024*1024 };
enum { BLUR, COMPOSITE, BACKDROP, PRESENT, ADD, COPY, PRESENT_FRAME, CLEAR_FRAME };

typedef struct {
    GLuint texture, fbo;
    GLenum format;
    int x, y, width, height;
} Target;

typedef struct {
    float clip[4], widths[4], offsets[4], corners[4], hole[4], pose[4];
    RuneGLCachedLayer cache_key;
    int enabled, additive, cached;
} FrameStyle;

typedef struct { float x0, y0, x1, y1; } Edges;
typedef struct {
    const void *begin;
    size_t subtree_end;
    float rect[4];
    int hidden, retain;
} LayerPlan;

typedef struct {
    Target target;
    float primitive[36];
    FrameStyle style;
    // Match the production planner's union of visible child geometry.
    Edges edges, limit, frame;
    float support;
    int free_to_rotate;
    size_t plan_index;
} Level;

struct RuneGLLayers {
    const RuneGLAPI *gl;
    GLuint program, vao;
    GLint mode, radius, horizontal, bounds, rect, clip, radii, fade, pose, srgb_blend, display_srgb;
    GLint frame_style, frame_clip, clip_widths, clip_offsets, clip_corners, hole;
    GLint target_rect, source_rect, clear_color;
    int backdrop_count;
    int es, width, height, depth, gamma, checked_layer_format, scratch_used;
    GLint max_texture_size;
    GLenum format;
    Level *levels;
    size_t capacity;
    LayerPlan *plans;
    size_t plan_count, plan_capacity, plan_cursor;
    Target parked[SPARE_TARGETS];
    size_t parked_count, used_depth, previous_depth;
    uint64_t parked_bytes;
    uint64_t scope_allocations;
    int production_frame, kept_production_blur;
    Target blur[2], spare, snapshot;
    RuneGLBlur *production_blur;
    RuneLayerCache *cache;
};

static int fail(char *error, size_t capacity, const char *message) {
    if (error && capacity) snprintf(error, capacity, "%s", message);
    return 0;
}

static void release_target(RuneGLLayers *layers, Target *target) {
    if (!target->texture && !target->fbo) return;
    layers->gl->DeleteFramebuffers(1, &target->fbo);
    layers->gl->DeleteTextures(1, &target->texture);
    *target = (Target){0};
}

static uint64_t target_bytes(Target t) {
    return (uint64_t)t.width * (uint64_t)t.height * (t.format == GL_RGBA16F ? 8 : 4);
}

static Target take_parked(RuneGLLayers *layers, size_t i) {
    Target t = layers->parked[i];
    layers->parked_bytes -= target_bytes(t);
    layers->parked_count--;
    memmove(layers->parked+i, layers->parked+i+1, (layers->parked_count-i)*sizeof(Target));
    return t;
}

static void trim_parked(RuneGLLayers *layers, uint64_t budget) {
    while (layers->parked_bytes > budget) {
        Target oldest = take_parked(layers, 0);
        release_target(layers, &oldest);
    }
}

static void park_target(RuneGLLayers *layers, Target *t) {
    if (!t->fbo) return;
    uint64_t bytes = target_bytes(*t);
    if (bytes > SPARE_BYTES) {
        release_target(layers, t);
        return;
    }
    if (layers->parked_count == SPARE_TARGETS) {
        Target oldest = take_parked(layers, 0);
        release_target(layers, &oldest);
    }
    trim_parked(layers, SPARE_BYTES - bytes);
    layers->parked[layers->parked_count++] = *t;
    layers->parked_bytes += bytes;
    *t = (Target){0};
}

static void release_targets(RuneGLLayers *layers) {
    for (size_t i = 0; i < layers->capacity; i++) release_target(layers, &layers->levels[i].target);
    release_target(layers, &layers->blur[0]);
    release_target(layers, &layers->blur[1]);
    release_target(layers, &layers->spare);
    release_target(layers, &layers->snapshot);
    trim_parked(layers, 0);
}

RuneGLLayers *rune_layers_create(const RuneGLAPI *gl, int es, const char *vertex,
                                 const char *fragment, char *error, size_t capacity) {
    RuneGLLayers *layers = calloc(1, sizeof(*layers));
    if (!layers) {
        fail(error, capacity, "Could not allocate Rune GL compositor");
        return NULL;
    }
    layers->gl = gl;
    layers->es = es;
    layers->format = GL_RGBA16F;
    gl->GetIntegerv(GL_MAX_TEXTURE_SIZE, &layers->max_texture_size);
    layers->capacity = REF_MAX_LAYER_DEPTH + 1;
    layers->levels = calloc(layers->capacity, sizeof(Level));
    if (!layers->levels) {
        fail(error, capacity, "Could not allocate Rune GL layer stack");
        free(layers);
        return NULL;
    }
    layers->program = rune_gl_program(gl, es, vertex, fragment, error, capacity);
    if (!layers->program) {
        free(layers->levels);
        free(layers);
        return NULL;
    }
    layers->cache = rune_cache_create(gl);
    if (!layers->cache) {
        fail(error, capacity, "Could not allocate Rune GL layer cache");
        gl->DeleteProgram(layers->program);
        free(layers->levels);
        free(layers);
        return NULL;
    }
    gl->GenVertexArrays(1, &layers->vao);
    gl->UseProgram(layers->program);
    gl->Uniform1i(gl->GetUniformLocation(layers->program, "uSource"), 0);
    gl->Uniform1i(gl->GetUniformLocation(layers->program, "uBlurred"), 1);
    layers->mode = gl->GetUniformLocation(layers->program, "uMode");
    layers->radius = gl->GetUniformLocation(layers->program, "uRadius");
    layers->horizontal = gl->GetUniformLocation(layers->program, "uHorizontal");
    layers->bounds = gl->GetUniformLocation(layers->program, "uBounds");
    layers->rect = gl->GetUniformLocation(layers->program, "uRect");
    layers->clip = gl->GetUniformLocation(layers->program, "uClip");
    layers->radii = gl->GetUniformLocation(layers->program, "uRadii");
    layers->fade = gl->GetUniformLocation(layers->program, "uFade");
    layers->pose = gl->GetUniformLocation(layers->program, "uPose");
    layers->srgb_blend = gl->GetUniformLocation(layers->program, "uSRGBBlend");
    layers->display_srgb = gl->GetUniformLocation(layers->program, "uDisplaySRGB");
    layers->frame_style = gl->GetUniformLocation(layers->program, "uFrameStyle");
    layers->frame_clip = gl->GetUniformLocation(layers->program, "uFrameClip");
    layers->clip_widths = gl->GetUniformLocation(layers->program, "uClipWidths");
    layers->clip_offsets = gl->GetUniformLocation(layers->program, "uClipOffsets");
    layers->clip_corners = gl->GetUniformLocation(layers->program, "uClipCorners");
    layers->hole = gl->GetUniformLocation(layers->program, "uHole");
    layers->target_rect = gl->GetUniformLocation(layers->program, "uTargetRect");
    layers->source_rect = gl->GetUniformLocation(layers->program, "uSourceRect");
    layers->clear_color = gl->GetUniformLocation(layers->program, "uClearColor");
    return layers;
}

void rune_layers_destroy(RuneGLLayers *layers) {
    if (!layers) return;
    release_targets(layers);
    free(layers->levels);
    free(layers->plans);
    rune_gl_blur_destroy(layers->production_blur);
    rune_cache_destroy(layers->cache);
    layers->gl->DeleteVertexArrays(1, &layers->vao);
    layers->gl->DeleteProgram(layers->program);
    free(layers);
}

int rune_layers_configure_blur(RuneGLLayers *layers, const char *vertex, const char *fragment,
                               char *error, size_t capacity) {
    RuneGLBlur *blur = rune_gl_blur_create(layers->gl, layers->es, vertex, fragment, error, capacity);
    if (!blur) return 0;
    rune_gl_blur_destroy(layers->production_blur);
    layers->production_blur = blur;
    return 1;
}

int rune_layers_additive(const RuneGLLayers *layers) {
    return layers->levels[layers->depth].style.additive;
}

void rune_layers_cache_budget(RuneGLLayers *layers, uint64_t bytes) { rune_cache_budget(layers->cache, bytes); }
void rune_layers_window_rest(RuneGLLayers *layers, int all) {
    rune_cache_rest(layers->cache);
    trim_parked(layers, 0);
    if (all) {
        for (size_t i = 0; i < layers->capacity; ++i) release_target(layers, &layers->levels[i].target);
        layers->used_depth = layers->previous_depth = 0;
    }
    if (all || !layers->scratch_used) {
        release_target(layers, &layers->blur[0]);
        release_target(layers, &layers->blur[1]);
        release_target(layers, &layers->spare);
        release_target(layers, &layers->snapshot);
        rune_gl_blur_rest(layers->production_blur);
    }
}

void rune_layers_cache_clear(RuneGLLayers *layers) { rune_cache_clear(layers->cache); }
RuneGLLayerStorage rune_layers_storage(const RuneGLLayers *layers) {
    uint64_t filters = rune_gl_blur_bytes(layers->production_blur) +
                       target_bytes(layers->blur[0]) + target_bytes(layers->blur[1]);
    uint64_t bytes = filters + rune_cache_stats(layers->cache).bytes + layers->parked_bytes +
                     target_bytes(layers->spare) + target_bytes(layers->snapshot);
    for (size_t i = 1; i < layers->capacity; ++i) bytes += target_bytes(layers->levels[i].target);
    return (RuneGLLayerStorage){layers->plan_capacity, bytes, filters};
}

RuneGLLayerCacheStats rune_layers_cache_stats(RuneGLLayers *layers) {
    RuneGLLayerCacheStats stats = rune_cache_stats(layers->cache);
    stats.active_count = stats.count;
    stats.active_bytes = stats.bytes;
    stats.target_allocations += layers->scope_allocations;
    // A depth slot owns at most one target, even if several sibling scopes
    // reused it. Retained textures have already left these slots on adoption.
    if (layers->production_frame) {
        for (size_t i = 1; i <= layers->used_depth; i++) {
            Target t = layers->levels[i].target;
            if (t.texture) {
                stats.active_count++;
                stats.active_bytes += target_bytes(t);
            }
        }
    }
    return stats;
}
int rune_layers_cache_contains(RuneGLLayers *layers, RuneGLCachedLayer id) {
    return rune_cache_contains(layers->cache, id);
}

size_t rune_layers_cache_entries(RuneGLLayers *layers, RuneGLCachedLayer *out, size_t capacity) {
    return rune_cache_entries(layers->cache, out, capacity);
}
void rune_layers_cache_begin(RuneGLLayers *layers) {
    rune_cache_begin(layers->cache);
    for (size_t i = 0; i < layers->plan_count;) {
        const LayerPlan *plan = &layers->plans[i];
        const float *p = plan->begin;
        // Only protect textures the painter will sample. Hidden subtrees and
        // the children of a hit must remain eligible for LRU eviction.
        if (plan->hidden || (p[19] >= 0.5f && rune_cache_pin(layers->cache, rune_cache_key(p)))) {
            i = plan->subtree_end;
        } else {
            i++;
        }
    }
}

void rune_layers_target_geometry(const RuneGLLayers *layers, int *x, int *y, int *width, int *height) {
    const Target *t = &layers->levels[layers->depth].target;
    *x = t->x;
    *y = t->y;
    *width = t->width;
    *height = t->height;
}

static GLenum allocate_target(RuneGLLayers *layers, Target *target, int w, int h, GLenum format) {
    const RuneGLAPI *gl = layers->gl;
    target->format = format;
    target->width = w;
    target->height = h;
    gl->GenTextures(1, &target->texture);
    gl->BindTexture(GL_TEXTURE_2D, target->texture);
    gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    gl->TexImage2D(GL_TEXTURE_2D, 0, (GLint)format, w, h,
                   0, GL_RGBA, format == GL_RGBA16F ? GL_HALF_FLOAT : GL_UNSIGNED_BYTE, NULL);
    gl->GenFramebuffers(1, &target->fbo);
    gl->BindFramebuffer(GL_FRAMEBUFFER, target->fbo);
    gl->FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, target->texture, 0);
    return gl->CheckFramebufferStatus(GL_FRAMEBUFFER);
}

static int ensure_size(RuneGLLayers *layers, Target *target, int x, int y, int w, int h, GLenum format,
                       char *error, size_t capacity) {
    if (target->width != w || target->height != h || target->format != format) {
        park_target(layers, target);
        for (size_t i = layers->parked_count; i > 0; i--) {
            if (layers->parked[i-1].width == w && layers->parked[i-1].height == h && layers->parked[i-1].format == format) {
                *target = take_parked(layers, i-1);
                break;
            }
        }
    }
    target->x = x;
    target->y = y;
    if (target->fbo) return 1;
    GLenum previous = layers->gl->GetError();
    if (previous != GL_NO_ERROR) {
        if (error && capacity) snprintf(error, capacity, "GL error 0x%x before framebuffer allocation", previous);
        return 0;
    }
    GLenum status = allocate_target(layers, target, w, h, format);
    if (status == GL_FRAMEBUFFER_COMPLETE) {
        size_t next = (size_t)layers->depth + 1;
        if (layers->production_frame && next < layers->capacity && target == &layers->levels[next].target) {
            layers->scope_allocations++;
        }
        return 1;
    }
    GLenum allocation_error = layers->gl->GetError();
    release_target(layers, target);
    if (error && capacity) snprintf(error, capacity, "GL framebuffer %dx%d incomplete (0x%x; GL error 0x%x)",
                                    w, h, status, allocation_error);
    return 0;
}

static int ensure_target(RuneGLLayers *layers, Target *target, char *error, size_t capacity) {
    return ensure_size(layers, target, 0, 0, layers->width, layers->height, layers->format, error, capacity);
}

static void clear_target(RuneGLLayers *layers, Target target, float r, float g, float b, float a) {
    layers->gl->BindFramebuffer(GL_FRAMEBUFFER, target.fbo);
    layers->gl->ClearColor(r, g, b, a);
    layers->gl->Clear(GL_COLOR_BUFFER_BIT);
}

static void pass(RuneGLLayers *layers, int mode, GLuint dst, GLuint src, GLuint other);

int rune_layers_frame(RuneGLLayers *layers, int width, int height, int srgb_blend, int production,
                      char *error, size_t capacity) {
    if (width <= 0 || height <= 0) return fail(error, capacity, "Empty Rune GL drawable");
    if (layers->width != width || layers->height != height) {
        release_targets(layers);
        layers->width = width;
        layers->height = height;
    }
    layers->depth = 0;
    layers->backdrop_count = 0;
    layers->plan_count = layers->plan_cursor = 0;
    layers->used_depth = 0;
    layers->scratch_used = 0;
    layers->production_frame = production;
    layers->gamma = srgb_blend;
    if (layers->es && !layers->checked_layer_format) {
        // Half-float attachments are optional in ES 3. Probe once for isolated layers and blur.
        Target probe = {0};
        if (allocate_target(layers, &probe, 1, 1, GL_RGBA16F) != GL_FRAMEBUFFER_COMPLETE) {
            layers->format = GL_RGBA8;
            layers->gl->GetError();
        }
        release_target(layers, &probe);
        layers->checked_layer_format = 1;
    }
    if (layers->format != GL_RGBA16F) {
        // Preserve dark premultiplied colors on ES devices with only 8-bit render targets.
        layers->format = production && !srgb_blend ? GL_SRGB8_ALPHA8 : GL_RGBA8;
    }
    // Metal's production window stores every blend into an 8-bit attachment.
    // Linear-space blending uses an sRGB attachment to encode the stored RGB.
    GLenum root_format = production ? (srgb_blend ? GL_RGBA8 : GL_SRGB8_ALPHA8) : layers->format;
    if (!ensure_size(layers, &layers->levels[0].target, 0, 0, width, height, root_format, error, capacity)) return 0;
    layers->gl->Viewport(0, 0, width, height);
    if (!layers->es && root_format == GL_SRGB8_ALPHA8) layers->gl->Enable(GL_FRAMEBUFFER_SRGB);
    return 1;
}

void rune_layers_clear_root(RuneGLLayers *layers, const float *clear, GLuint atlas) {
    float a = fmaxf(0, fminf(clear[3], 1));
    float r = clear[0]*a, g = clear[1]*a, b = clear[2]*a;
    const RuneGLAPI *gl = layers->gl;
    if (!layers->es && layers->levels[0].target.format == GL_SRGB8_ALPHA8 &&
        ((r > 0 && r < 1) || (g > 0 && g < 1) || (b > 0 && b < 1))) {
        // Desktop clear operations can bypass the attachment's sRGB conversion.
        // Draw its linear clear color with the same conversion as every UI fragment.
        gl->UseProgram(layers->program);
        gl->BindVertexArray(layers->vao);
        gl->Uniform4f(layers->clear_color, r, g, b, a);
        pass(layers, CLEAR_FRAME, layers->levels[0].target.fbo, atlas, 0);
    } else {
        clear_target(layers, layers->levels[0].target, r, g, b, a);
    }
}

// Both texture units are rebound on every pass. Leaving a destination texture
// on an inactive shader branch can still create a framebuffer feedback loop.
static void pass(RuneGLLayers *layers, int mode, GLuint dst, GLuint src, GLuint other) {
    const RuneGLAPI *gl = layers->gl;
    gl->BindFramebuffer(GL_FRAMEBUFFER, dst);
    gl->ActiveTexture(GL_TEXTURE0);
    gl->BindTexture(GL_TEXTURE_2D, src);
    gl->ActiveTexture(GL_TEXTURE1);
    gl->BindTexture(GL_TEXTURE_2D, other ? other : src);
    gl->Uniform1i(layers->mode, mode);
    if (mode == COMPOSITE) {
        gl->Enable(GL_BLEND);
        gl->BlendEquation(GL_FUNC_ADD);
        gl->BlendFunc(GL_ONE, rune_layers_additive(layers) ? GL_ONE : GL_ONE_MINUS_SRC_ALPHA);
    } else {
        gl->Disable(GL_BLEND);
    }
    gl->DrawArrays(GL_TRIANGLES, 0, 3);
}

static int blur_target(RuneGLLayers *layers, GLuint source, const float *rect, float radius,
                       GLuint *result, char *error, size_t capacity) {
    const RuneGLAPI *gl = layers->gl;
    *result = source;
    if (radius < 0.5f) return 1;
    layers->scratch_used = 1;
    int r = (int)fminf(24, floorf(radius + 0.5f));
    // Keep coordinates in floating point until they have been clipped to the drawable.
    float x0 = fmaxf(0, floorf(rect[0]) - r);
    float y0 = fmaxf(0, floorf(rect[1]) - r);
    float x1 = fminf(layers->width - 1, ceilf(rect[0] + rect[2]) + r);
    float y1 = fminf(layers->height - 1, ceilf(rect[1] + rect[3]) + r);
    if (x0 > x1 || y0 > y1) return 1;
    for (int i = 0; i < 2; i++) {
        if (!ensure_target(layers, &layers->blur[i], error, capacity)) return 0;
    }
    gl->Uniform4f(layers->bounds, x0, layers->height - 1 - y1, x1, layers->height - 1 - y0);
    gl->Uniform1i(layers->radius, r);
    // Two horizontal/vertical box-filter iterations match the scalar reference.
    for (int i = 0; i < 4; i++) {
        Target dst = layers->blur[i % 2];
        // Passes 0 and 3 preserve the sharp image outside the filter bounds.
        // The intermediate passes only read and write pixels inside the bounds.
        if (i == 1) {
            gl->Scissor((int)x0, layers->height - 1 - (int)y1, (int)(x1 - x0 + 1), (int)(y1 - y0 + 1));
            gl->Enable(GL_SCISSOR_TEST);
        } else if (i == 3) {
            gl->Disable(GL_SCISSOR_TEST);
        }
        gl->Uniform1i(layers->horizontal, i % 2 == 0);
        pass(layers, BLUR, dst.fbo, source, 0);
        source = dst.texture;
    }
    *result = source;
    return 1;
}

static void bind_effect(RuneGLLayers *layers, const float *p, const FrameStyle *style) {
    const RuneGLAPI *gl = layers->gl;
    Target dst = layers->levels[layers->depth].target;
    gl->UseProgram(layers->program);
    gl->BindVertexArray(layers->vao);
    gl->Viewport(0, 0, dst.width, dst.height);
    gl->Disable(GL_SCISSOR_TEST);
    gl->Uniform4fv(layers->rect, 1, p);
    gl->Uniform4fv(layers->radii, 1, p + 4);
    gl->Uniform4fv(layers->clip, 1, p + 24);
    gl->Uniform4fv(layers->fade, 1, p + 28);
    gl->Uniform1i(layers->frame_style, style->enabled + style->additive);
    gl->Uniform4f(layers->target_rect, dst.x, dst.y, dst.width, dst.height);
    gl->Uniform4f(layers->source_rect, dst.x, dst.y, dst.width, dst.height);
    if (style->enabled) {
        gl->Uniform4fv(layers->frame_clip, 1, style->clip);
        gl->Uniform4fv(layers->clip_widths, 1, style->widths);
        gl->Uniform4fv(layers->clip_offsets, 1, style->offsets);
        gl->Uniform4fv(layers->clip_corners, 1, style->corners);
        gl->Uniform4fv(layers->hole, 1, style->hole);
        gl->Uniform4fv(layers->pose, 1, style->pose);
    } else {
        gl->Uniform4f(layers->pose, p[32], p[33], p[34], p[16]);
    }
}

// Decode the production ABI once per marker using C11 on every host.
static float half_float(uint32_t bits) {
    int exponent = (int)((bits >> 10) & 31);
    int mantissa = (int)(bits & 1023);
    float value = exponent == 0 ? ldexpf((float)mantissa, -24)
                                : ldexpf((float)(1024 + mantissa), exponent - 25);
    return bits & 32768 ? -value : value;
}

static FrameStyle unpack_style(int kind, const void *instance128) {
    FrameStyle style = {0};
    if (!instance128) return style;
    float lanes[28];
    uint32_t packed[4];
    memcpy(lanes, instance128, sizeof(lanes));
    memcpy(packed, (const unsigned char *)instance128 + sizeof(lanes), sizeof(packed));
    style.enabled = 1;
    style.additive = kind == 8 && lanes[16] >= 0.5f;
    style.cached = kind == 8 && lanes[19] >= 0.5f;
    if (style.cached) style.cache_key = rune_cache_key(lanes);
    memcpy(style.clip, lanes + 24, sizeof(style.clip));
    // Cached markers use radii for the cache key.
    if (kind == 8 && lanes[19] < 0.5f) memcpy(style.hole, lanes + 4, sizeof(style.hole));
    style.pose[0] = lanes[14];
    style.pose[1] = lanes[15];
    style.pose[2] = lanes[13];
    style.pose[3] = lanes[11];
    for (int i = 0; i < 4; i++) {
        style.widths[i] = half_float(packed[i / 2] >> ((i % 2) * 16));
        style.offsets[i] = (float)((packed[2] >> (8 * i)) & 255) / 255.0f;
    }
    if ((packed[3] & 0x60000000u) == 0x60000000u) {
        float step = packed[3] & 0x10000000u ? 2.0f : 0.5f;
        if (packed[3] & 0x80000000u) step = -step;
        for (int i = 0; i < 4; i++) style.corners[i] = step * (float)((packed[3] >> (7 * i)) & 127);
    } else {
        for (int i = 0; i < 4; i++) memcpy(style.corners + i, packed + 3, sizeof(float));
    }
    return style;
}

static Edges intersect(Edges a, Edges b) {
    return (Edges){fmaxf(a.x0,b.x0), fmaxf(a.y0,b.y0), fminf(a.x1,b.x1), fminf(a.y1,b.y1)};
}

static Edges expand(Edges b, float grow) {
    return (Edges){b.x0-grow, b.y0-grow, b.x1+grow, b.y1+grow};
}

static void include_edges(Edges *bounds, Edges other) {
    if (other.x1 <= other.x0 || other.y1 <= other.y0) return;
    if (bounds->x1 <= bounds->x0 || bounds->y1 <= bounds->y0) {
        *bounds = other;
        return;
    }
    *bounds = (Edges){fminf(bounds->x0,other.x0), fminf(bounds->y0,other.y0),
                      fmaxf(bounds->x1,other.x1), fmaxf(bounds->y1,other.y1)};
}

static Edges clip_edges(const float *clip) {
    return (Edges){clip[0], clip[1], clip[2], clip[3]};
}

static Edges rotated(Edges b, float angle, const float *pivot) {
    if (angle == 0 || b.x1 <= b.x0 || b.y1 <= b.y0) return b;
    float c = cosf(angle), s = sinf(angle);
    Edges result = {FLT_MAX, FLT_MAX, -FLT_MAX, -FLT_MAX};
    for (int i = 0; i < 4; ++i) {
        float dx = (i & 1 ? b.x1 : b.x0) - pivot[0], dy = (i & 2 ? b.y1 : b.y0) - pivot[1];
        float x = pivot[0] + c*dx - s*dy, y = pivot[1] + s*dx + c*dy;
        result.x0 = fminf(result.x0, x);
        result.y0 = fminf(result.y0, y);
        result.x1 = fmaxf(result.x1, x);
        result.y1 = fmaxf(result.y1, y);
    }
    return result;
}

// COMPOSITE has no influence outside the clip. Include the antialiased edge.
static void clip_composite(RuneGLLayers *layers, const float *p, const FrameStyle *style,
                           const float *source) {
    Target dst = layers->levels[layers->depth].target;
    const float *c = style->enabled ? style->clip : p + 24;
    float right = style->enabled ? c[2] : c[0] + c[2];
    float bottom = style->enabled ? c[3] : c[1] + c[3];
    Edges clip = {c[0], c[1], right, bottom};
    if (source) {
        // A retained tile may be much smaller than its enclosing viewport.
        // Only covered samples can change the destination under source-over or additive blending.
        Edges quad = {source[0], source[1], source[0] + source[2], source[1] + source[3]};
        clip = intersect(clip, expand(rotated(quad, style->pose[2], style->pose), 1));
    }
    int x0 = (int)fminf(dst.width, fmaxf(0, floorf(clip.x0 - dst.x - 0.5f)));
    int y0 = (int)fminf(dst.height, fmaxf(0, floorf(clip.y0 - dst.y - 0.5f)));
    int x1 = (int)fmaxf(x0, fminf(dst.width, ceilf(clip.x1 - dst.x + 0.5f)));
    int y1 = (int)fmaxf(y0, fminf(dst.height, ceilf(clip.y1 - dst.y + 0.5f)));
    layers->gl->Scissor(x0, dst.height - y1, x1 - x0, y1 - y0);
    layers->gl->Enable(GL_SCISSOR_TEST);
}

static float blur_support(const Level *level) {
    return level->primitive[19] < 0.05f ? 0 : ceilf(3 * fminf(64, level->primitive[19]));
}

static void begin_frame_bounds(RuneGLLayers *layers, Level *next) {
    const Level *parent = &layers->levels[layers->depth];
    const float *p = next->primitive;
    next->edges = (Edges){p[0], p[1], p[0]+p[2], p[1]+p[3]};
    next->support = parent->support + blur_support(next);
    next->limit = layers->depth && !parent->free_to_rotate ?
        expand(intersect(clip_edges(parent->style.clip), parent->limit), blur_support(parent)) :
        (Edges){-FLT_MAX,-FLT_MAX,FLT_MAX,FLT_MAX};
    next->free_to_rotate = parent->free_to_rotate || next->style.pose[2] != 0;
    if (next->free_to_rotate) {
        Edges outer = parent->free_to_rotate ? parent->frame :
            expand((Edges){0,0,layers->width,layers->height}, parent->support);
        Edges shown = intersect(outer, clip_edges(next->style.clip));
        next->frame = rotated(shown, -next->style.pose[2], next->style.pose);
    }
}

static void include_instance(RuneGLLayers *layers, const void *instance128) {
    if (!layers->depth) return;
    Level *level = &layers->levels[layers->depth];
    if (level->style.cached) return;
    const float *p = (const float *)instance128;
    int kind = (int)roundf(p[17]);
    Edges bounds = {p[0], p[1], p[0]+p[2], p[1]+p[3]};
    float grow = 1;
    if (kind == 2) {
        float pivot[] = {p[0]+p[2]*0.5f,p[1]+p[3]*0.5f};
        bounds = rotated(bounds, p[16], pivot);
        grow = 0;
    } else if (kind == 1) {
        grow += p[18] * 3;
    } else if (kind == 12) {
        grow += p[18];
    } else if (kind == 0 || kind == 4 || kind == 10 || kind == 11) {
        grow += p[18] * 2;
    }
    include_edges(&level->edges, intersect(expand(bounds, grow), clip_edges(p+24)));
}

static void finish_frame_bounds(RuneGLLayers *layers, const Level *child, LayerPlan *plan) {
    plan->subtree_end = layers->plan_count;
    Edges clip = child->free_to_rotate ? child->frame : intersect(clip_edges(child->style.clip), child->limit);
    Edges visible = expand(intersect(child->edges, clip), blur_support(child));
    if (!child->free_to_rotate) {
        visible = intersect(visible, expand((Edges){0, 0, layers->width, layers->height}, child->support));
    }
    plan->hidden |= visible.x1 <= visible.x0 || visible.y1 <= visible.y0;
    // The cached rectangle includes offscreen content that can later scroll
    // into view. An oversized cache renders only its visible portion.
    double w = ceil(child->edges.x1) - floor(child->edges.x0);
    double h = ceil(child->edges.y1) - floor(child->edges.y0);
    int bytes_per_pixel = layers->format == GL_RGBA16F ? 8 : 4;
    plan->retain = child->style.cached && w > 0 && h > 0 && w <= 4096 && h <= 4096 &&
        w*h*bytes_per_pixel <= (double)rune_cache_budget_bytes(layers->cache);
    Edges b = plan->retain ? child->edges : visible;
    b = (Edges){floorf(b.x0), floorf(b.y0), ceilf(b.x1), ceilf(b.y1)};
    Level *parent = &layers->levels[layers->depth];
    if (layers->depth && !parent->style.cached) include_edges(&parent->edges, rotated(b, child->style.pose[2], child->style.pose));
    plan->rect[0] = b.x0;
    plan->rect[1] = b.y0;
    plan->rect[2] = fmaxf(0, b.x1 - b.x0);
    plan->rect[3] = fmaxf(0, b.y1 - b.y0);
}

static void swap_target(Target *a, Target *b) {
    Target old = *a;
    *a = *b;
    *b = old;
}

int rune_layers_cache_composite(RuneGLLayers *layers, const float *marker, const void *instance128) {
    if (((const float *)instance128)[19] < 0.5f) return 0;
    FrameStyle style = unpack_style(8, instance128);
    GLuint texture = rune_cache_lookup(layers->cache, style.cache_key);
    if (!texture) return 0;
    if (!(marker[2] > 0 && marker[3] > 0)) return 1;
    // The miss raster uses outward-rounded device pixels. Apply the same
    // placement to a hit, including when its logical origin is fractional.
    float x = floorf(marker[0]), y = floorf(marker[1]);
    float destination[4] = {x, y, ceilf(marker[0] + marker[2]) - x, ceilf(marker[1] + marker[3]) - y};
    Level *parent = &layers->levels[layers->depth];
    if (layers->depth && !parent->style.cached) {
        Edges rect = {marker[0], marker[1], marker[0]+marker[2], marker[1]+marker[3]};
        include_edges(&parent->edges, rotated(rect, style.pose[2], style.pose));
    }
    bind_effect(layers, marker, &style);
    layers->gl->Uniform4fv(layers->source_rect, 1, destination);
    clip_composite(layers, marker, &style, destination);
    pass(layers, COMPOSITE, parent->target.fbo, texture, 0);
    layers->gl->Disable(GL_SCISSOR_TEST);
    return 1;
}

static void retain_layer(RuneGLLayers *layers, Level *child, const float rect[4], GLuint source) {
    // A cache can subsequently be moved into view. Only publish it when the
    // entire rasterized local rectangle exists on the source texture.
    Target *t = &child->target;
    float x = rect[0] - t->x, y = rect[1] - t->y;
    if (x < 0 || y < 0 || rect[2] <= 0 || rect[3] <= 0 ||
        x + rect[2] > t->width || y + rect[3] > t->height) return;
    // The planner normally isolates into exactly this rectangle. Hand the
    // rendered texture to the cache without allocating or copying another.
    int whole = source == t->texture && x == 0 && y == 0 && rect[2] == t->width && rect[3] == t->height;
    int stored = rune_cache_store(layers->cache, child->style.cache_key, layers->format, source,
                                  (int)x, t->height - (int)y - (int)rect[3], (int)rect[2], (int)rect[3], whole);
    if (whole && stored) {
        layers->gl->DeleteFramebuffers(1, &t->fbo);
        *t = (Target){0};
    }
}

static int reserve_level(RuneGLLayers *layers, char *error, size_t capacity) {
    if ((size_t)layers->depth + 1 < layers->capacity) return 1;
    if (layers->capacity > SIZE_MAX / sizeof(Level) / 2) return fail(error, capacity, "Rune GL layer stack overflow");
    size_t size = layers->capacity * 2;
    Level *larger = realloc(layers->levels, size * sizeof(Level));
    if (!larger) return fail(error, capacity, "Could not grow Rune GL layer stack");
    memset(larger + layers->capacity, 0, (size - layers->capacity) * sizeof(Level));
    layers->levels = larger;
    layers->capacity = size;
    return 1;
}

// Placement is needed before the first child draws. The ordered plan also lets
// retained layer hits skip child ranges without changing the stack of targets.
int rune_layers_plan(RuneGLLayers *layers, const void *instances, size_t count, int width, int height,
                     char *error, size_t capacity) {
    if (width != layers->width || height != layers->height || layers->depth) {
        return fail(error, capacity, "Invalid Rune GL layer planning state");
    }
    int needs_filter = 0;
    for (size_t i = 0; i < count; i++) {
        const float *p = (const float *)((const unsigned char *)instances + i*128);
        if (p[17] == 13 && p[16] > 0) needs_filter = 1;
        if (p[17] == 8) {
            if (p[18] >= 0.05f) needs_filter = 1;
            if (!reserve_level(layers, error, capacity)) return 0;
            if (layers->plan_count == layers->plan_capacity) {
                if (layers->plan_capacity > SIZE_MAX / sizeof(LayerPlan) / 2) return fail(error, capacity, "Rune GL plan overflow");
                size_t size = layers->plan_capacity ? layers->plan_capacity * 2 : 8;
                LayerPlan *plans = realloc(layers->plans, size * sizeof(LayerPlan));
                if (!plans) return fail(error, capacity, "Could not allocate Rune GL layer plan");
                layers->plans = plans;
                layers->plan_capacity = size;
            }
            Level *next = &layers->levels[layers->depth + 1];
            memcpy(next->primitive, p, 4*sizeof(float));
            next->primitive[19] = p[18];
            next->style = unpack_style(8, p);
            next->plan_index = layers->plan_count++;
            layers->plans[next->plan_index] = (LayerPlan){
                .begin = p, .hidden = p[11] <= 0 || (layers->depth && layers->plans[layers->levels[layers->depth].plan_index].hidden)
            };
            begin_frame_bounds(layers, next);
            layers->depth++;
        } else if (p[17] == 9) {
            if (!layers->depth) return fail(error, capacity, "Unexpected Rune GL layer end");
            Level *child = &layers->levels[layers->depth--];
            finish_frame_bounds(layers, child, &layers->plans[child->plan_index]);
        } else if (layers->depth) {
            include_instance(layers, p);
        }
    }
    if (layers->depth) return fail(error, capacity, "Unclosed Rune GL layer");
    if (layers->kept_production_blur && !needs_filter) rune_gl_blur_rest(layers->production_blur);
    layers->kept_production_blur = needs_filter;
    return 1;
}

static LayerPlan *seek_plan(RuneGLLayers *layers, const void *instance128) {
    while (layers->plan_cursor < layers->plan_count && layers->plans[layers->plan_cursor].begin != instance128) {
        layers->plan_cursor++;
    }
    return layers->plan_cursor < layers->plan_count ? &layers->plans[layers->plan_cursor] : NULL;
}

int rune_layers_should_skip(RuneGLLayers *layers, const void *instance128) {
    LayerPlan *plan = seek_plan(layers, instance128);
    return plan && plan->hidden;
}

int rune_layers_frame_marker(RuneGLLayers *layers, int kind, const float *primitive,
                             const void *instance128, char *error, size_t capacity) {
    if (kind == 13) return 1;  // Effect slots have no scalar draw operation.
    if (kind == 8) {
        if (!instance128 && layers->depth >= REF_MAX_LAYER_DEPTH) return fail(error, capacity, "RuneRef layer stack overflow");
        if (!reserve_level(layers, error, capacity)) return 0;
        Level *next = &layers->levels[layers->depth + 1];
        memcpy(next->primitive, primitive, sizeof(next->primitive));
        next->style = unpack_style(kind, instance128);
        if (instance128) {
            if (!seek_plan(layers, instance128)) return fail(error, capacity, "Missing Rune GL layer plan");
            next->plan_index = layers->plan_cursor++;
            const float *rect = layers->plans[next->plan_index].rect;
            // A zero-coverage scope still consumes its balanced markers.
            if (rect[2] <= 0 || rect[3] <= 0) {
                if (!ensure_size(layers, &next->target, 0, 0, 1, 1, layers->format, error, capacity)) return 0;
            } else {
                if (!isfinite(rect[0]) || !isfinite(rect[1]) || (double)rect[0] < INT_MIN || (double)rect[0] > INT_MAX ||
                    (double)rect[1] < INT_MIN || (double)rect[1] > INT_MAX || rect[2] > layers->max_texture_size ||
                    rect[3] > layers->max_texture_size) {
                    return fail(error, capacity, "Rune GL isolated layer exceeds the supported render extent");
                }
                int width = (int)rect[2], height = (int)rect[3];
                if (!layers->plans[next->plan_index].retain) {
                    // A moving opacity group changes its crop by a pixel at a
                    // time. Reuse the same 64px bucket throughout the motion.
                    width = (int)fmin(layers->max_texture_size, ceil(width / 64.0) * 64);
                    height = (int)fmin(layers->max_texture_size, ceil(height / 64.0) * 64);
                }
                if (!ensure_size(layers, &next->target, (int)rect[0], (int)rect[1], width, height,
                                 layers->format, error, capacity)) return 0;
            }
        } else {
            if (!ensure_target(layers, &next->target, error, capacity)) return 0;
        }
        clear_target(layers, next->target, 0, 0, 0, 0);
        layers->depth++;
        if ((size_t)layers->depth > layers->used_depth) layers->used_depth = (size_t)layers->depth;
        return 1;
    }
    if (kind == 9) {
        if (!layers->depth) return fail(error, capacity, "Unexpected Rune GL layer end");
        Level *child = &layers->levels[layers->depth--];
        Target *parent = &layers->levels[layers->depth].target;
        const float *p = child->primitive;
        GLuint filtered;
        float planned_rect[4];
        if (child->style.enabled) {
            memcpy(planned_rect, layers->plans[child->plan_index].rect, sizeof(planned_rect));
            if (planned_rect[2] <= 0 || planned_rect[3] <= 0) {
                layers->gl->BindFramebuffer(GL_FRAMEBUFFER, parent->fbo);
                return 1;
            }
        }
        bind_effect(layers, p, &child->style);
        if (child->style.enabled && p[19] >= 0.05f && layers->production_blur) {
            float local_rect[] = {planned_rect[0]-child->target.x, planned_rect[1]-child->target.y,
                                  planned_rect[2], planned_rect[3]};
            layers->scratch_used = 1;
            if (!rune_gl_blur_draw(layers->production_blur, layers->format, child->target.width, child->target.height,
                                   child->target.texture, child->target.fbo, local_rect, p[19], 0, child->style.additive,
                                   &filtered, error, capacity)) return 0;
            bind_effect(layers, p, &child->style);
        } else if (child->style.enabled) {
            filtered = child->target.texture;
        } else if (!blur_target(layers, child->target.texture, p, p[19], &filtered, error, capacity)) return 0;
        layers->gl->Uniform4f(layers->source_rect, child->target.x, child->target.y, child->target.width, child->target.height);
        if (child->style.enabled) {
            rune_cache_record_pass(layers->cache);
            if (layers->plans[child->plan_index].retain) retain_layer(layers, child, planned_rect, filtered);
        }
        if (child->style.enabled || p[18] < 0.5f) {
            clip_composite(layers, p, &child->style, child->style.enabled ? planned_rect : NULL);
            pass(layers, COMPOSITE, parent->fbo, filtered, 0);
            layers->gl->Disable(GL_SCISSOR_TEST);
        } else {
            if (!ensure_target(layers, &layers->spare, error, capacity)) return 0;
            pass(layers, ADD, layers->spare.fbo, filtered, parent->texture);
            swap_target(parent, &layers->spare);
        }
        return 1;
    }
    if (kind == 12) {
        FrameStyle style = unpack_style(kind, instance128);
        float opacity = style.enabled ? style.pose[3] : (primitive[11] == 0 && primitive[19] == 0 ? 1 : primitive[11]);
        if (primitive[16] <= 0 || opacity <= 0 || layers->backdrop_count >= 4) return 1;
        if (style.enabled && !layers->production_blur) return 1;
        layers->backdrop_count++;
        Target *current = &layers->levels[layers->depth].target;
        GLuint filtered;
        if (layers->production_blur) {
            float local_rect[] = {primitive[0]-current->x, primitive[1]-current->y, primitive[2], primitive[3]};
            layers->scratch_used = 1;
            if (!rune_gl_blur_draw(layers->production_blur, layers->format, current->width, current->height,
                                   current->texture, 0, local_rect, primitive[16], 1, rune_layers_additive(layers),
                                   &filtered, error, capacity)) return 0;
        } else {
            // The standalone C reference initializer predates the optional pyramid shader.
            bind_effect(layers, primitive, &style);
            if (!blur_target(layers, current->texture, primitive, primitive[16], &filtered, error, capacity)) return 0;
        }
        bind_effect(layers, primitive, &style);
        if (!style.enabled) layers->gl->Uniform4f(layers->pose, 0, 0, 0, opacity);
        if (filtered == current->texture) {
            layers->gl->BindFramebuffer(GL_FRAMEBUFFER, current->fbo);
            return 1;
        }
        if (!ensure_size(layers, &layers->spare, current->x, current->y, current->width, current->height,
                         current->format, error, capacity)) return 0;
        pass(layers, BACKDROP, layers->spare.fbo, current->texture, filtered);
        swap_target(current, &layers->spare);
        return 1;
    }
    return fail(error, capacity, "Unknown Rune GL layer marker");
}

int rune_layers_marker(RuneGLLayers *layers, int kind, const float *primitive, char *error, size_t capacity) {
    return rune_layers_frame_marker(layers, kind, primitive, NULL, error, capacity);
}

static void prepare_effect_copy(RuneGLLayers *layers, Target src, Target dst, const int rect[4]) {
    const RuneGLAPI *gl = layers->gl;
    gl->UseProgram(layers->program);
    gl->BindVertexArray(layers->vao);
    gl->Viewport(0, 0, dst.width, dst.height);
    gl->Uniform4f(layers->target_rect, dst.x, dst.y, dst.width, dst.height);
    gl->Uniform4f(layers->source_rect, src.x, src.y, src.width, src.height);
    gl->Disable(GL_DEPTH_TEST);
    gl->Disable(GL_STENCIL_TEST);
    gl->Disable(GL_CULL_FACE);
    gl->Disable(GL_RASTERIZER_DISCARD);
    gl->BindSampler(0, 0);
    gl->BindSampler(1, 0);
    if (!layers->es) {
        if (layers->production_frame && !layers->gamma) gl->Enable(GL_FRAMEBUFFER_SRGB);
        else gl->Disable(GL_FRAMEBUFFER_SRGB);
    }
    gl->ColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    gl->Scissor(rect[0] - dst.x, dst.height - (rect[1] - dst.y) - rect[3], rect[2], rect[3]);
    gl->Enable(GL_SCISSOR_TEST);
}

int rune_layers_effect_begin(RuneGLLayers *layers, const void *instance128, GLuint *effect_fbo,
                            GLuint *backdrop_tex, int clip[4], char *error, size_t capacity) {
    const float *p = (const float *)instance128;
    const Target current = layers->levels[layers->depth].target;
    float bleed = fmaxf(0, p[18]);
    float x0 = floorf(fmaxf(p[0] - bleed, p[24])), y0 = floorf(fmaxf(p[1] - bleed, p[25]));
    float x1 = ceilf(fminf(p[0] + p[2] + bleed, p[26])), y1 = ceilf(fminf(p[1] + p[3] + bleed, p[27]));
    int local_x = (int)fminf(current.width, fmaxf(0, x0 - current.x));
    int local_y = (int)fminf(current.height, fmaxf(0, y0 - current.y));
    clip[0] = current.x + local_x;
    clip[1] = current.y + local_y;
    clip[2] = (int)fminf(current.width, fmaxf(local_x, x1 - current.x)) - local_x;
    clip[3] = (int)fminf(current.height, fmaxf(local_y, y1 - current.y)) - local_y;
    *effect_fbo = 0;
    *backdrop_tex = 0;
    if (!clip[2] || !clip[3]) return 1;
    layers->scratch_used = 1;
    if (!ensure_size(layers, &layers->spare, current.x, current.y, current.width, current.height,
                     current.format, error, capacity)) return 0;
    Target backdrop = current;
    if (p[16] >= 0.5f && (current.x || current.y || current.width != layers->width || current.height != layers->height)) {
        // Effect hooks sample their backdrop in global drawable coordinates.
        if (!ensure_target(layers, &layers->snapshot, error, capacity)) return 0;
        int full[] = {0, 0, layers->width, layers->height};
        prepare_effect_copy(layers, current, layers->snapshot, full);
        pass(layers, COPY, layers->snapshot.fbo, current.texture, 0);
        backdrop = layers->snapshot;
    }
    prepare_effect_copy(layers, current, layers->spare, clip);
    pass(layers, COPY, layers->spare.fbo, current.texture, 0);
    *effect_fbo = layers->spare.fbo;
    *backdrop_tex = p[16] >= 0.5f ? backdrop.texture : 0;
    return 1;
}

void rune_layers_effect_end(RuneGLLayers *layers, const int clip[4], int commit) {
    Target destination = layers->levels[layers->depth].target;
    // Callback code can replace its viewport, scissor, and framebuffer. Only
    // publish the clipped pixels, and keep a failed draw out of the scene.
    prepare_effect_copy(layers, layers->spare, destination, clip);
    if (commit) pass(layers, COPY, destination.fbo, layers->spare.texture, 0);
    else layers->gl->BindFramebuffer(GL_FRAMEBUFFER, destination.fbo);
    layers->gl->Disable(GL_SCISSOR_TEST);
}

int rune_layers_present(RuneGLLayers *layers, unsigned framebuffer, char *error, size_t capacity) {
    if (layers->depth) return fail(error, capacity, "Unclosed Rune GL layer at presentation");
    const RuneGLAPI *gl = layers->gl;
    gl->UseProgram(layers->program);
    gl->BindVertexArray(layers->vao);
    gl->BindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    gl->Viewport(0, 0, layers->width, layers->height);
    GLint encoding = GL_LINEAR;
    if (layers->es) {
        gl->GetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, framebuffer ? GL_COLOR_ATTACHMENT0 : GL_BACK,
                                               GL_FRAMEBUFFER_ATTACHMENT_COLOR_ENCODING, &encoding);
    } else {
        // The native desktop presentation shader writes display-encoded RGB directly.
        gl->Disable(GL_FRAMEBUFFER_SRGB);
    }
    gl->Uniform1i(layers->srgb_blend, layers->gamma);
    gl->Uniform1i(layers->display_srgb, encoding == GL_SRGB);
    pass(layers, layers->production_frame ? PRESENT_FRAME : PRESENT, framebuffer, layers->levels[0].target.texture, 0);
    for (size_t i = layers->used_depth + 1; i <= layers->previous_depth; ++i) {
        park_target(layers, &layers->levels[i].target);
    }
    layers->previous_depth = layers->used_depth;
    if (!layers->used_depth) trim_parked(layers, RESTING_BYTES);
    // A thousand layers can be transient. Keep an ordinary frame's planning
    // storage warm when the burst ends, including a layerless damage frame.
    size_t keep = layers->plan_count > 64 ? layers->plan_count : 64;
    if (layers->plan_capacity / 2 > keep) {
        LayerPlan *warm = realloc(layers->plans, keep * sizeof(*warm));
        if (warm) {
            layers->plans = warm;
            layers->plan_capacity = keep;
        }
    }
    return 1;
}
