#include "CRuneGL.h"
#include "gl_api.h"
#include "layers.h"
#include "gl_surface.h"
#include "production.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { primitive_slots = 9, primitive_floats = 36 };
#define PRIMITIVE_BYTES (primitive_floats * sizeof(float))

typedef struct {
    GLuint texture;
    int width, height;
    GLenum internal_format;
} Atlas;

struct RuneGL {
    RuneGLAPI gl;
    RuneGLLayers *layers;
    RuneGLSurfaces *surfaces;
    RuneGLProduction *production;
    RuneGLFrameSprings springs;
    RuneGLEffectHook effect_hook;
    void *effect_user;
    GLuint program, vao, instance_buffer;
    size_t spring_instance_count;
    int reuse_spring_instances;
    GLint viewport_uniform;
    GLint max_texture_size;
    int es, drawing;
    Atlas glyphs, images;
};

static int fail(char *error, size_t size, const char *message) {
    if (error && size) snprintf(error, size, "%s", message);
    return 0;
}

static int check_gl(const RuneGLAPI *gl, const char *stage, char *error, size_t size) {
    GLenum code = gl->GetError();
    if (code == GL_NO_ERROR) return 1;
    if (error && size) snprintf(error, size, "%s: GL error 0x%04x", stage, code);
    return 0;
}

int rune_gl_load_api(RuneGLAPI *gl, RuneGLResolve resolve, char *error, size_t size) {
    if (!gl || !resolve) return fail(error, size, "Missing GL resolver");
    /* WGL/GLX/EGL importers return callable addresses, sometimes via a
     * platform library for the GL 1.x symbols. Do not cast through an integer. */
#define RUNE_GL_FN(result, name, params) do { \
    void *address = resolve("gl" #name); \
    if (!address) return fail(error, size, "GL entry point unavailable: gl" #name); \
    _Static_assert(sizeof(gl->name) == sizeof(address), "Unsupported GL function pointer ABI"); \
    memcpy(&gl->name, &address, sizeof(address)); \
} while (0);
#include "gl_functions.inc"
#undef RUNE_GL_FN
    return 1;
}

static GLuint compile_shader(const RuneGLAPI *gl, GLenum stage, const char *prefix,
                             const char *source, char *error, size_t size) {
    GLuint shader = gl->CreateShader(stage);
    if (!shader) {
        fail(error, size, "GL could not allocate a shader");
        return 0;
    }
    const GLchar *parts[] = { prefix, source };
    gl->ShaderSource(shader, 2, parts, NULL);
    gl->CompileShader(shader);
    GLint success = 0;
    gl->GetShaderiv(shader, GL_COMPILE_STATUS, &success);
    if (!success) {
        char log[2048] = {0};
        gl->GetShaderInfoLog(shader, sizeof(log) - 1, NULL, log);
        if (error && size) snprintf(error, size, "%s shader compilation failed: %s",
                                    stage == GL_VERTEX_SHADER ? "Vertex" : "Fragment", log);
        gl->DeleteShader(shader);
        return 0;
    }
    return shader;
}

GLuint rune_gl_program(const RuneGLAPI *gl, int es, const char *vertex,
                       const char *fragment, char *error, size_t size) {
    const char *prefix = es ? "#version 300 es\nprecision highp float;\nprecision highp int;\nprecision highp sampler2D;\n"
                            : "#version 330 core\n";
    GLuint vs = compile_shader(gl, GL_VERTEX_SHADER, prefix, vertex, error, size);
    if (!vs) return 0;
    GLuint fs = compile_shader(gl, GL_FRAGMENT_SHADER, prefix, fragment, error, size);
    if (!fs) {
        gl->DeleteShader(vs);
        return 0;
    }
    GLuint program = gl->CreateProgram();
    if (program) {
        gl->AttachShader(program, vs);
        gl->AttachShader(program, fs);
        gl->LinkProgram(program);
        GLint linked = 0;
        gl->GetProgramiv(program, GL_LINK_STATUS, &linked);
        if (!linked) {
            char log[2048] = {0};
            gl->GetProgramInfoLog(program, sizeof(log) - 1, NULL, log);
            if (error && size) snprintf(error, size, "GL program linking failed: %s", log);
            gl->DeleteProgram(program);
            program = 0;
        }
    } else {
        fail(error, size, "GL could not allocate a program");
    }
    gl->DeleteShader(vs);
    gl->DeleteShader(fs);
    return program;
}

const RuneGLAPI *rune_gl_current_api(const RuneGL *r) { return r ? &r->gl : NULL; }

const char *rune_gl_renderer(const RuneGL *r) { return (const char *)r->gl.GetString(GL_RENDERER); }
const char *rune_gl_vendor(const RuneGL *r) { return (const char *)r->gl.GetString(GL_VENDOR); }
const char *rune_gl_version(const RuneGL *r) { return (const char *)r->gl.GetString(GL_VERSION); }

static void set_atlas_params(const RuneGLAPI *gl, Atlas *atlas) {
    gl->GenTextures(1, &atlas->texture);
    gl->BindTexture(GL_TEXTURE_2D, atlas->texture);
    gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}

RuneGL *rune_gl_create_device(RuneGLResolve resolve, const char *fullscreen, const char *layer,
                              char *error, size_t size) {
    if (!resolve || !fullscreen || !layer) {
        fail(error, size, "Missing GL resolver or shader source");
        return NULL;
    }
    RuneGL *r = calloc(1, sizeof(*r));
    if (!r) {
        fail(error, size, "Unable to allocate GL renderer");
        return NULL;
    }
    RuneGLAPI *gl = &r->gl;
    if (!rune_gl_load_api(gl, resolve, error, size)) {
        free(r);
        return NULL;
    }
    const char *version = rune_gl_version(r);
    if (!version) {
        fail(error, size, "No current GL context");
        goto failure;
    }
    r->es = strncmp(version, "OpenGL ES", 9) == 0;
    GLint major = 0, minor = 0;
    gl->GetIntegerv(GL_MAJOR_VERSION, &major);
    gl->GetIntegerv(GL_MINOR_VERSION, &minor);
    if (major < 3 || (major == 3 && !r->es && minor < 3)) {
        if (error && size) snprintf(error, size, "Rune requires OpenGL 3.3 or GLES 3.0; current version: %s", version);
        goto failure;
    }
    gl->GetIntegerv(GL_MAX_TEXTURE_SIZE, &r->max_texture_size);
    gl->GenBuffers(1, &r->instance_buffer);
    set_atlas_params(gl, &r->glyphs);
    set_atlas_params(gl, &r->images);
    r->layers = rune_layers_create(gl, r->es, fullscreen, layer, error, size);
    if (!r->layers || !check_gl(gl, "Creating Rune renderer", error, size)) goto failure;
    return r;

failure:
    rune_gl_destroy(r);
    return NULL;
}

int rune_gl_configure_reference(RuneGL *r, const char *vertex, const char *fragment,
                                char *error, size_t size) {
    if (!r || !vertex || !fragment) return fail(error, size, "Missing Rune reference shader");
    if (r->drawing) return fail(error, size, "Cannot replace Rune reference shaders during a frame");
    const RuneGLAPI *gl = &r->gl;
    GLuint program = rune_gl_program(gl, r->es, vertex, fragment, error, size);
    if (!program) return 0;
    GLint viewport = gl->GetUniformLocation(program, "uViewport");
    GLint glyph = gl->GetUniformLocation(program, "uGlyphAtlas");
    GLint image = gl->GetUniformLocation(program, "uImageAtlas");
    if (viewport < 0 || glyph < 0 || image < 0) {
        gl->DeleteProgram(program);
        return fail(error, size, "Rune primitive shader is missing viewport or atlas uniforms");
    }
    gl->UseProgram(program);
    gl->Uniform1i(glyph, 0);
    gl->Uniform1i(image, 1);
    GLuint vao = 0;
    gl->GenVertexArrays(1, &vao);
    gl->BindVertexArray(vao);
    for (GLuint slot = 0; slot < primitive_slots; slot++) {
        gl->EnableVertexAttribArray(slot);
        gl->VertexAttribDivisor(slot, 1);
    }
    if (!check_gl(gl, "Creating Rune reference pipeline", error, size)) {
        gl->DeleteVertexArrays(1, &vao);
        gl->DeleteProgram(program);
        return 0;
    }
    if (r->vao) gl->DeleteVertexArrays(1, &r->vao);
    if (r->program) gl->DeleteProgram(r->program);
    r->vao = vao;
    r->program = program;
    r->viewport_uniform = viewport;
    return 1;
}

RuneGL *rune_gl_create(RuneGLResolve resolve, const char *vertex, const char *fragment,
                       const char *fullscreen, const char *layer, char *error, size_t size) {
    if (!vertex || !fragment) {
        fail(error, size, "Missing GL resolver or shader source");
        return NULL;
    }
    RuneGL *r = rune_gl_create_device(resolve, fullscreen, layer, error, size);
    if (r && !rune_gl_configure_reference(r, vertex, fragment, error, size)) {
        rune_gl_destroy(r);
        return NULL;
    }
    return r;
}

void rune_gl_set_effect_hook(RuneGL *r, RuneGLEffectHook hook, void *user) {
    if (!r) return;
    r->effect_hook = hook;
    r->effect_user = user;
}

uint32_t rune_gl_draw_framebuffer(const RuneGL *r) {
    GLint framebuffer = 0;
    r->gl.GetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &framebuffer);
    return (uint32_t)framebuffer;
}

void rune_gl_bind_draw_framebuffer(RuneGL *r, uint32_t framebuffer) {
    r->gl.BindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
}

int rune_gl_configure_surfaces(RuneGL *r, const char *vertex, const char *fragment,
                               char *error, size_t size) {
    if (!r || !vertex || !fragment) return fail(error, size, "Missing Rune surface shader");
    if (r->drawing) return fail(error, size, "Cannot replace Rune surface shaders during a frame");
    RuneGLSurfaces *surfaces = rune_surfaces_create(&r->gl, r->es, vertex, fragment, error, size);
    if (!surfaces) return 0;
    if (r->surfaces) rune_surfaces_destroy(r->surfaces);
    r->surfaces = surfaces;
    return 1;
}

int rune_gl_surface_upload(RuneGL *r, uint64_t key, uint64_t version, int width, int height,
                           int format, const uint8_t *plane0, size_t bytes0,
                           const uint8_t *plane1, size_t bytes1, char *error, size_t size) {
    if (!r || !r->surfaces) return fail(error, size, "Rune surface shaders are not configured");
    if (r->drawing) return fail(error, size, "Cannot replace Rune surface contents during a frame");
    return rune_surfaces_upload(r->surfaces, key, version, width, height, format, plane0, bytes0,
                                plane1, bytes1, error, size);
}

int rune_gl_configure_frame(RuneGL *r, const char *vertex, const char *fragment,
                            const char *fullscreen, const char *blur, char *error, size_t size) {
    if (!r || !vertex || !fragment || !fullscreen || !blur) return fail(error, size, "Missing Rune frame shader");
    if (r->drawing) return fail(error, size, "Cannot replace Rune frame shaders during a frame");
    RuneGLProduction *production = rune_production_create(&r->gl, r->es, vertex, fragment, error, size);
    if (!production) return 0;
    if (!rune_layers_configure_blur(r->layers, fullscreen, blur, error, size)) {
        rune_production_destroy(production);
        return 0;
    }
    if (r->production) rune_production_destroy(r->production);
    r->production = production;
    return 1;
}

void rune_gl_frame_springs(RuneGL *r, uint32_t tracks, uint32_t ids, float seconds, float fraction) {
    if (r) r->springs = (RuneGLFrameSprings){ tracks, ids, seconds, fraction };
}

void rune_gl_destroy(RuneGL *r) {
    if (!r) return;
    if (r->production) rune_production_destroy(r->production);
    if (r->surfaces) rune_surfaces_destroy(r->surfaces);
    if (r->layers) rune_layers_destroy(r->layers);
    if (r->program) r->gl.DeleteProgram(r->program);
    if (r->vao) r->gl.DeleteVertexArrays(1, &r->vao);
    if (r->instance_buffer) r->gl.DeleteBuffers(1, &r->instance_buffer);
    if (r->glyphs.texture) r->gl.DeleteTextures(1, &r->glyphs.texture);
    if (r->images.texture) r->gl.DeleteTextures(1, &r->images.texture);
    free(r);
}

/* A lost context reclaims its objects. The same teardown still frees all
 * host-side caches; its delete dispatch must never address another context. */
static void RUNE_GL_CALL abandon_names(GLsizei count, const GLuint *names) {
    (void)count;
    (void)names;
}

static void RUNE_GL_CALL abandon_program(GLuint program) {
    (void)program;
}

void rune_gl_abandon(RuneGL *r) {
    if (!r) return;
    r->gl.DeleteProgram = abandon_program;
    r->gl.DeleteFramebuffers = abandon_names;
    r->gl.DeleteBuffers = abandon_names;
    r->gl.DeleteVertexArrays = abandon_names;
    r->gl.DeleteTextures = abandon_names;
    rune_gl_destroy(r);
}

void rune_gl_layer_cache_budget(RuneGL *r, uint64_t bytes) {
    rune_layers_cache_budget(r->layers, bytes);
}

void rune_gl_layer_cache_clear(RuneGL *r) {
    rune_layers_cache_clear(r->layers);
}

RuneGLLayerCacheStats rune_gl_layer_cache_stats(RuneGL *r) {
    return rune_layers_cache_stats(r->layers);
}

int rune_gl_layer_cache_contains(RuneGL *r, RuneGLCachedLayer id) {
    return rune_layers_cache_contains(r->layers, id);
}

size_t rune_gl_layer_cache_entries(RuneGL *r, RuneGLCachedLayer *out, size_t capacity) {
    return rune_layers_cache_entries(r->layers, out, capacity);
}

static void prepare_unpack(const RuneGLAPI *gl, int row_length) {
    gl->BindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    gl->PixelStorei(GL_UNPACK_ALIGNMENT, 1);
    gl->PixelStorei(GL_UNPACK_ROW_LENGTH, row_length);
    gl->PixelStorei(GL_UNPACK_SKIP_PIXELS, 0);
    gl->PixelStorei(GL_UNPACK_SKIP_ROWS, 0);
}

int rune_gl_patch_atlas(RuneGL *r, int channels, int width, int height,
                        const uint8_t *previous, const uint8_t *next, char *error, size_t size) {
    if (!r || !previous || !next || (channels != 1 && channels != 4)) {
        return fail(error, size, "Invalid Rune atlas patch");
    }
    if (r->drawing) return fail(error, size, "Cannot update a Rune atlas during a frame");
    const Atlas *atlas = channels == 1 ? &r->glyphs : &r->images;
    if (width <= 0 || height <= 0 || atlas->width != width || atlas->height != height) {
        return fail(error, size, "Rune atlas patch dimensions do not match the resident texture");
    }
    // Swift retains the old Array across frames. Equal addresses denote the
    // same immutable storage and require neither a comparison nor a driver call.
    if (previous == next) return 1;
    const size_t stride = (size_t)width * channels;
    if ((size_t)height > SIZE_MAX / stride) return fail(error, size, "Rune atlas byte count exceeds addressable memory");
    int x0 = width, x1 = 0, y0 = height, y1 = 0;
    for (int y = 0; y < height; ++y) {
        size_t row = (size_t)y * stride;
        const uint8_t *a = previous + row, *b = next + row;
        if (memcmp(a, b, stride) == 0) continue;
        if (y < y0) y0 = y;
        y1 = y + 1;
        int x = 0;
        while (x < x0 && memcmp(a + (size_t)x * channels, b + (size_t)x * channels, channels) == 0) ++x;
        x0 = x;
        x = width;
        while (x > x1) {
            size_t last = (size_t)(x - 1) * channels;
            if (memcmp(a + last, b + last, channels) != 0) break;
            --x;
        }
        x1 = x;
    }
    if (y1 == 0) return 1;
    const RuneGLAPI *gl = &r->gl;
    gl->ActiveTexture(channels == 1 ? GL_TEXTURE0 : GL_TEXTURE1);
    gl->BindTexture(GL_TEXTURE_2D, atlas->texture);
    prepare_unpack(gl, width);
    size_t start = (size_t)y0 * stride + (size_t)x0 * channels;
    gl->TexSubImage2D(GL_TEXTURE_2D, 0, x0, y0, x1 - x0, y1 - y0,
                      channels == 1 ? GL_RED : GL_RGBA, GL_UNSIGNED_BYTE, next + start);
    gl->PixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    return check_gl(gl, "Updating Rune atlas region", error, size);
}

static int set_atlas(const RuneGLAPI *gl, Atlas *atlas, GLenum unit,
                     int width, int height, GLenum internal, GLenum format,
                     const uint8_t *data, char *error, size_t size) {
    int resize = width != atlas->width || height != atlas->height || internal != atlas->internal_format;
    if (!data) {
        if (resize) return fail(error, size, "New atlas dimensions or format require pixel data");
        return 1;
    }
    gl->ActiveTexture(unit);
    gl->BindTexture(GL_TEXTURE_2D, atlas->texture);
    if (resize) {
        gl->TexImage2D(GL_TEXTURE_2D, 0, (GLint)internal, width, height, 0, format, GL_UNSIGNED_BYTE, data);
    } else {
        gl->TexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, format, GL_UNSIGNED_BYTE, data);
    }
    if (!check_gl(gl, "Uploading Rune atlas", error, size)) return 0;
    atlas->width = width;
    atlas->height = height;
    atlas->internal_format = internal;
    return 1;
}

static void draw_batch(RuneGL *r, int production, int width, int height, int srgb_blend,
                       int in_layer, size_t start, size_t count) {
    if (!count) return;
    const RuneGLAPI *gl = &r->gl;
    gl->ActiveTexture(GL_TEXTURE0);
    gl->BindTexture(GL_TEXTURE_2D, r->glyphs.texture);
    gl->ActiveTexture(GL_TEXTURE1);
    gl->BindTexture(GL_TEXTURE_2D, r->images.texture);
    gl->Enable(GL_BLEND);
    gl->BlendEquation(GL_FUNC_ADD);
    gl->BlendFunc(GL_ONE, (production && rune_layers_additive(r->layers)) ? GL_ONE : GL_ONE_MINUS_SRC_ALPHA);
    if (production) {
        int x, y;
        rune_layers_target_geometry(r->layers, &x, &y, &width, &height);
        gl->Viewport(0, 0, width, height);
        rune_production_batch(r->production, r->instance_buffer, width, height, x, y, start, count,
                              srgb_blend, in_layer, &r->springs);
        return;
    }
    gl->UseProgram(r->program);
    gl->Uniform2f(r->viewport_uniform, (float)width, (float)height);
    gl->BindVertexArray(r->vao);
    gl->BindBuffer(GL_ARRAY_BUFFER, r->instance_buffer);
    for (GLuint slot = 0; slot < primitive_slots; slot++) {
        uintptr_t offset = start * PRIMITIVE_BYTES + slot * 4 * sizeof(float);
        gl->VertexAttribPointer(slot, 4, GL_FLOAT, GL_FALSE, PRIMITIVE_BYTES, (const void *)offset);
    }
    gl->DrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, (GLsizei)count);
}

/* A hidden or cached group skips all children, including its native surfaces. */
static size_t matching_layer_end(const void *instances, size_t begin, size_t count) {
    int depth = 1;
    for (size_t i = begin + 1; i < count; ++i) {
        const float *instance = (const float *)((const uint8_t *)instances + i * 128);
        if (instance[17] == 8) ++depth;
        if (instance[17] == 9 && --depth == 0) return i;
    }
    return count;
}

void rune_gl_reuse_spring_instances(RuneGL *r, int same_storage) {
    if (r) r->reuse_spring_instances = same_storage;
}

static int render(RuneGL *r, int production, int width, int height, const float *clear, int srgb_blend,
                  const void *instances, size_t count,
                  const uint8_t *glyphs, int gw, int gh, const uint8_t *images, int iw, int ih,
                  const RuneGLSurfaceDraw *draws, size_t draw_count, char *error, size_t size) {
    size_t stride = production ? 128 : PRIMITIVE_BYTES;
    if (!r || !clear || (count && !instances) || count > INT_MAX || count > PTRDIFF_MAX / stride) {
        return fail(error, size, "Invalid Rune instance data or clear color");
    }
    if (r->drawing) return fail(error, size, "Cannot submit nested frames on the same Rune GL renderer");
    if (production && !r->production) return fail(error, size, "Rune frame shaders are not configured");
    if (!production && !r->program) return fail(error, size, "Rune reference shaders are not configured");
    if (draw_count && (!draws || !r->surfaces)) return fail(error, size, "Missing Rune surface data or shaders");
    int max = r->max_texture_size;
    if (width <= 0 || height <= 0 || gw <= 0 || gh <= 0 || iw <= 0 || ih <= 0 ||
        width > max || height > max || gw > max || gh > max || iw > max || ih > max) {
        return fail(error, size, "Frame or atlas dimensions exceed GL texture limits");
    }

    const RuneGLAPI *gl = &r->gl;
    GLint destination = 0, read_framebuffer = 0;
    gl->GetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &destination);
    gl->GetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read_framebuffer);
    gl->Viewport(0, 0, width, height);
    gl->Disable(GL_DEPTH_TEST);
    gl->Disable(GL_STENCIL_TEST);
    gl->Disable(GL_SCISSOR_TEST);
    gl->Disable(GL_CULL_FACE);
    gl->Disable(GL_RASTERIZER_DISCARD);
    gl->BindSampler(0, 0);
    gl->BindSampler(1, 0);
    gl->ColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    if (!r->es) gl->Disable(GL_FRAMEBUFFER_SRGB);
    prepare_unpack(gl, 0);
    if (!set_atlas(gl, &r->glyphs, GL_TEXTURE0, gw, gh, GL_R8, GL_RED, glyphs, error, size) ||
        !set_atlas(gl, &r->images, GL_TEXTURE1, iw, ih, (!production && srgb_blend) ? GL_RGBA8 : GL_SRGB8_ALPHA8,
                   GL_RGBA, images, error, size)) return 0;
    gl->BindBuffer(GL_ARRAY_BUFFER, r->instance_buffer);
    int spring_frame = production && r->springs.tracks && r->springs.ids;
    int retained = spring_frame && r->reuse_spring_instances && count == r->spring_instance_count;
    r->reuse_spring_instances = 0;
    r->spring_instance_count = 0;
    if (count && !retained) gl->BufferData(GL_ARRAY_BUFFER, (GLsizeiptr)(count * stride), instances, GL_STREAM_DRAW);
    r->drawing = 1;
    int success = rune_layers_frame(r->layers, width, height, clear, srgb_blend, production, r->glyphs.texture, error, size);
    if (!success) goto done;

    if (production) {
        success = rune_layers_plan(r->layers, instances, count, width, height, error, size);
        if (!success) goto done;
        rune_layers_cache_begin(r->layers);
    }

    /* Preserve painter order while keeping all adjacent UI primitives in one
     * instanced draw. Marker transforms apply to the intervening draws only. */
    size_t first = 0, surface = 0;
    int depth = 0;
    for (size_t i = 0; i <= count; i++) {
        /* The Metal host flushes any remaining surface at end-of-frame, including
         * callers using UINT32_MAX as the final insertion point. */
        if (surface < draw_count && (i == count || draws[surface].before_instance <= i)) {
            draw_batch(r, production, width, height, srgb_blend, depth > 0, first, i - first);
            first = i;
            int origin_x = 0, origin_y = 0, w = width, h = height;
            if (production) rune_layers_target_geometry(r->layers, &origin_x, &origin_y, &w, &h);
            gl->Viewport(0, 0, w, h);
            do {
                if (!rune_surfaces_draw(r->surfaces, w, h, origin_x, origin_y, production && rune_layers_additive(r->layers),
                                        &draws[surface], error, size)) {
                    success = 0;
                    goto done;
                }
                surface++;
            } while (surface < draw_count && (i == count || draws[surface].before_instance <= i));
        }
        if (i == count) break;
        const void *instance = (const uint8_t *)instances + i * stride;
        float translated[36];
        const float *marker = instance;
        int kind;
        if (production) {
            kind = rune_production_marker(instance, translated);
            if (!kind) continue;
            marker = translated;
        } else {
            float k = marker[17]; /* RuneRef params.y */
            if (k != 8 && k != 9 && k != 12 && k != 13) continue;
            kind = (int)k;
        }
        draw_batch(r, production, width, height, srgb_blend, depth > 0, first, i - first);
        if (production && kind == 8 && (rune_layers_should_skip(r->layers, instance) ||
                                        rune_layers_cache_composite(r->layers, marker, instance))) {
            size_t end = matching_layer_end(instances, i, count);
            if (end == count) {
                success = fail(error, size, "Unclosed Rune GL layer");
                goto done;
            }
            while (surface < draw_count && draws[surface].before_instance <= end) ++surface;
            i = end;
            first = end + 1;
            continue;
        }
        if (production && kind == 13 && r->effect_hook) {
            GLuint framebuffer = 0, backdrop = 0;
            int clip[4];
            success = rune_layers_effect_begin(r->layers, instance, &framebuffer, &backdrop, clip, error, size);
            if (!success) goto done;
            if (framebuffer) {
                int origin_x, origin_y, target_width, target_height;
                rune_layers_target_geometry(r->layers, &origin_x, &origin_y, &target_width, &target_height);
                int commit = r->effect_hook(r->effect_user, i, framebuffer, backdrop, target_width,
                                            target_height, origin_x, origin_y);
                rune_layers_effect_end(r->layers, clip, commit);
                if (!commit) {
                    success = fail(error, size, "Rune custom GPU effect failed");
                    goto done;
                }
            }
        } else if (kind != 13) {
            success = production ? rune_layers_frame_marker(r->layers, kind, marker, instance, error, size)
                                 : rune_layers_marker(r->layers, kind, marker, error, size);
            if (!success) goto done;
        }
        if (kind == 8) depth++;
        if (kind == 9) depth--;
        first = i + 1;
    }
    draw_batch(r, production, width, height, srgb_blend, depth > 0, first, count - first);
    success = rune_layers_present(r->layers, (GLuint)destination, error, size);
    if (success) success = check_gl(gl, "Drawing Rune frame", error, size);
    if (success) rune_surfaces_prune(r->surfaces, draws, draw_count);
done:
    if (spring_frame && success) r->spring_instance_count = count;
    if (production && !success) {
        rune_layers_cache_clear(r->layers);
        if (!r->es) gl->Disable(GL_FRAMEBUFFER_SRGB);
    }
    r->drawing = 0;
    gl->BindFramebuffer(GL_DRAW_FRAMEBUFFER, (GLuint)destination);
    gl->BindFramebuffer(GL_READ_FRAMEBUFFER, (GLuint)read_framebuffer);
    return success;
}

int rune_gl_render(RuneGL *r, int width, int height, const float *clear, int srgb_blend,
                   const void *instances, size_t count, const uint8_t *glyphs, int gw, int gh,
                   const uint8_t *images, int iw, int ih, char *error, size_t size) {
    return render(r, 0, width, height, clear, srgb_blend, instances, count, glyphs, gw, gh,
                  images, iw, ih, NULL, 0, error, size);
}

int rune_gl_render_surfaces(RuneGL *r, int width, int height, const float *clear, int srgb_blend,
                            const void *instances, size_t count, const uint8_t *glyphs, int gw, int gh,
                            const uint8_t *images, int iw, int ih, const RuneGLSurfaceDraw *draws,
                            size_t draw_count, char *error, size_t size) {
    return render(r, 0, width, height, clear, srgb_blend, instances, count, glyphs, gw, gh,
                  images, iw, ih, draws, draw_count, error, size);
}

int rune_gl_render_frame(RuneGL *r, int width, int height, const float *clear, int srgb_blend,
                         const void *instances, size_t count, const uint8_t *glyphs, int gw, int gh,
                         const uint8_t *images, int iw, int ih, const RuneGLSurfaceDraw *draws,
                         size_t draw_count, char *error, size_t size) {
    return render(r, 1, width, height, clear, srgb_blend, instances, count, glyphs, gw, gh,
                  images, iw, ih, draws, draw_count, error, size);
}
