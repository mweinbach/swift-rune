#include "CRuneGL.h"
#include "gl_api.h"
#include "layers.h"
#include "gl_surface.h"
#include "production.h"
#include "frame_damage.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { primitive_slots = 9, primitive_floats = 36, instance_ring_slots = 3 };
#define PRIMITIVE_BYTES (primitive_floats * sizeof(float))

typedef struct {
    GLuint texture;
    int width, height;
    GLenum internal_format;
} Atlas;

typedef struct {
    Atlas *extra;
    size_t count;
} AtlasPages;

struct RuneGL {
    RuneGLAPI gl;
    RuneGLLayers *layers;
    RuneGLSurfaces *surfaces;
    RuneGLProduction *production, *outline_program, *lcd_program, *mask_program, *unit_mask_program, *common_program;
    GLuint outline_texture;
    int outline_rows, use_outlines, use_lcd, opaque_root;
    GLuint glyph_fill_target, glyph_fill_attached, glyph_fill_buffer;
    size_t glyph_fill_capacity;
    RuneGLFrameSprings springs;
    RuneGLEffectHook effect_hook;
    void *effect_user;
    GLuint program, vao;
    GLuint instance_buffers[instance_ring_slots];
    size_t instance_capacities[instance_ring_slots];
    unsigned instance_slot;
    size_t spring_instance_count;
    int reuse_spring_instances;
    RuneDamageHistory damage;
    int damage_enabled, last_damage;
    int32_t last_rects[16];
    GLint viewport_uniform;
    GLint max_texture_size;
    int es, drawing, check_errors;
    Atlas glyphs, images;
    GLuint empty_image;
    AtlasPages glyph_pages, image_pages;
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
                             const char *defines, const char *source, char *error, size_t size) {
    GLuint shader = gl->CreateShader(stage);
    if (!shader) {
        fail(error, size, "GL could not allocate a shader");
        return 0;
    }
    const GLchar *parts[] = { prefix, defines, source };
    gl->ShaderSource(shader, 3, parts, NULL);
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
    return rune_gl_program_variant(gl, es, 0, vertex, fragment, error, size);
}

GLuint rune_gl_program_variant(const RuneGLAPI *gl, int es, int variant, const char *vertex,
                               const char *fragment, char *error, size_t size) {
    const char *classic = es ? "#version 300 es\nprecision highp float;\nprecision highp int;\nprecision highp sampler2D;\n"
                             : "#version 330 core\n";
    const char *dual = es ? "#version 300 es\n#extension GL_EXT_blend_func_extended : require\n"
                            "precision highp float;\nprecision highp int;\nprecision highp sampler2D;\n#define RUNE_OUTLINE_LCD 1\n"
                          : "#version 330 core\n#define RUNE_OUTLINE_LCD 1\n";
    int outline_vertex = variant == RUNE_GL_OUTLINE || variant == RUNE_GL_OUTLINE_LCD || variant == RUNE_GL_MASK_FILL;
    GLuint vs = compile_shader(gl, GL_VERTEX_SHADER, classic, outline_vertex ? "#define RUNE_OUTLINE_VERTEX 1\n" : "", vertex, error, size);
    if (!vs) return 0;
    GLuint fs = compile_shader(gl, GL_FRAGMENT_SHADER, variant == RUNE_GL_OUTLINE_LCD ? dual : classic, "", fragment, error, size);
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
    r->last_damage = -1;
    const char *check_env = getenv("RUNE_GL_CHECK_ERRORS");
    r->check_errors = check_env && strcmp(check_env, "1") == 0;
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
    gl->GenBuffers(instance_ring_slots, r->instance_buffers);
    set_atlas_params(gl, &r->glyphs);
    set_atlas_params(gl, &r->images);
    r->layers = rune_layers_create(gl, r->es, fullscreen, layer, error, size);
    if (!r->layers || !check_gl(gl, "Creating Rune renderer", error, size)) goto failure;
    return r;

failure:
    rune_gl_destroy(r);
    return NULL;
}

int rune_gl_configure_present(RuneGL *r, const char *fullscreen, const char *fragment,
                              char *error, size_t capacity) {
    if (!r || r->drawing || !fullscreen || !fragment) return fail(error, capacity, "Invalid Rune presentation pipeline");
    return rune_layers_configure_present(r->layers, fullscreen, fragment, error, capacity);
}

int rune_gl_configure_reference_blur(RuneGL *r, const char *fullscreen, const char *fragment,
                                     char *error, size_t size) {
    if (!r || r->drawing || !fullscreen || !fragment) return fail(error, size, "Invalid Rune backdrop blur configuration");
    return rune_layers_configure_blur(r->layers, fullscreen, fragment, error, size);
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
                                plane1, bytes1, NULL, NULL, NULL, error, size);
}

int rune_gl_surface_copy_rgba(RuneGL *r, uint64_t key, uint64_t version, int width, int height,
                              RuneGLSurfaceCopy copy, void *source, char *error, size_t size) {
    if (!r || !r->surfaces || r->drawing || !copy || !source)
        return fail(error, size, "Cannot import a native texture during a frame or without a configured surface renderer");
    return rune_surfaces_upload(r->surfaces, key, version, width, height, 3, NULL, 0, NULL, 0, copy, NULL, source, error, size);
}

int rune_gl_surface_copy_nv12(RuneGL *r, uint64_t key, uint64_t version, int width, int height,
                              int format, RuneGLPlaneCopy copy, void *source, char *error, size_t size) {
    if (!r || !r->surfaces || r->drawing || !copy || !source || (format != 1 && format != 2))
        return fail(error, size, "Invalid planar surface import");
    return rune_surfaces_upload(r->surfaces, key, version, width, height, format, NULL, 0, NULL, 0,
                                NULL, copy, source, error, size);
}

int rune_gl_configure_frame(RuneGL *r, const char *vertex, const char *fragment,
                            const char *fullscreen, const char *blur, char *error, size_t size) {
    if (!r || !vertex || !fragment || !fullscreen || !blur) return fail(error, size, "Missing Rune frame shader");
    if (r->drawing) return fail(error, size, "Cannot replace Rune frame shaders during a frame");
    RuneGLProduction *production = rune_production_create(&r->gl, r->es, 0, vertex, fragment, error, size);
    if (!production) return 0;
    int blur_ready = rune_layers_configure_blur(r->layers, fullscreen, blur, error, size);
    if (r->production) rune_production_destroy(r->production);
    r->production = production;
    rune_production_destroy(r->common_program);
    r->common_program = NULL;
    rune_gl_enable_frame_damage(r, 0);
    return blur_ready ? 1 : 2;
}

static int replace_program(RuneGL *r, RuneGLProduction **slot, int variant, const char *vertex,
                           const char *fragment, char *error, size_t size) {
    RuneGLProduction *p = rune_production_create(&r->gl, r->es, variant, vertex, fragment, error, size);
    if (!p) return 0;
    rune_production_destroy(*slot);
    *slot = p;
    r->damage.valid = 0;
    return 1;
}

int rune_gl_configure_common_frame(RuneGL *r, const char *vertex, const char *fragment, char *error, size_t size) {
    if (!r || r->drawing || !r->production || !vertex || !fragment) return fail(error, size, "Invalid Rune common paint pipeline");
    return replace_program(r, &r->common_program, RUNE_GL_COMMON, vertex, fragment, error, size);
}

int rune_gl_configure_mask_fill(RuneGL *r, const char *vertex, const char *fragment, int unit_windfoil, char *error, size_t size) {
    if (!r || r->drawing || !vertex || !fragment) return fail(error, size, "Invalid Rune glyph mask pipeline");
    return replace_program(r, unit_windfoil ? &r->unit_mask_program : &r->mask_program, RUNE_GL_MASK_FILL, vertex, fragment, error, size);
}

int rune_gl_outline_eligible(const RuneGL *r) {
    return r && !r->drawing && !r->springs.tracks;
}

static int supports_dual_source(const RuneGL *r) {
#ifdef _WIN32
    // This WGL release accepts dual-output programs, then drops draws that use source 1.
    const char *vendor = rune_gl_vendor(r), *version = rune_gl_version(r);
    if (vendor && version && strcmp(vendor, "Parallels and Apple") == 0 &&
        strcmp(version, "3.3 - Build 27.0.3") == 0) return 0;
#endif
    // wgpu's GL adapter requires the blend extension on both desktop GL and ES.
    GLint count = 0;
    r->gl.GetIntegerv(GL_NUM_EXTENSIONS, &count);
    for (GLint i = 0; i < count; ++i) {
        const char *name = (const char *)r->gl.GetStringi(GL_EXTENSIONS, (GLuint)i);
        if (name && (strcmp(name, "GL_EXT_blend_func_extended") == 0 ||
                     (!r->es && strcmp(name, "GL_ARB_blend_func_extended") == 0))) {
            GLint buffers = 0;
            r->gl.GetIntegerv(GL_MAX_DUAL_SOURCE_DRAW_BUFFERS, &buffers);
            return buffers > 0;
        }
    }
    return 0;
}

int rune_gl_configure_outline(RuneGL *r, const char *vertex, const char *fragment, int lcd,
                              char *error, size_t size) {
    if (!r || r->drawing || !vertex || !fragment) return fail(error, size, "Invalid Rune outline pipeline");
    if (lcd && !supports_dual_source(r)) return fail(error, size, "Dual-source text blending is unavailable");
    RuneGLProduction **slot = lcd ? &r->lcd_program : &r->outline_program;
    return replace_program(r, slot, lcd ? RUNE_GL_OUTLINE_LCD : RUNE_GL_OUTLINE, vertex, fragment, error, size);
}

void rune_gl_select_outline(RuneGL *r, int active, int lcd) {
    if (!r || r->drawing) return;
    int outlines = active && r->outline_program && r->outline_texture;
    int dual = outlines && lcd && r->lcd_program;
    if (r->use_outlines != outlines || r->use_lcd != dual) r->damage.valid = 0;
    r->use_outlines = outlines;
    r->use_lcd = dual;
}

void rune_gl_enable_frame_damage(RuneGL *r, int enable) {
    if (!r || r->drawing) return;
    const char *whole = getenv("RUNE_WHOLE_FRAMES");
    r->damage_enabled = enable && !(whole && strcmp(whole, "1") == 0);
    if (!r->damage_enabled) rune_damage_release(&r->damage);
    r->last_damage = -1;
}

const int32_t *rune_gl_last_damage_rects(const RuneGL *r) { return r ? r->last_rects : NULL; }

int rune_gl_last_frame_damage(const RuneGL *r) { return r ? r->last_damage : -1; }

void rune_gl_frame_springs(RuneGL *r, uint32_t tracks, uint32_t ids, float seconds, float fraction) {
    if (r) r->springs = (RuneGLFrameSprings){ tracks, ids, seconds, fraction };
}

void rune_gl_destroy(RuneGL *r) {
    if (!r) return;
    rune_damage_release(&r->damage);
    if (r->production) rune_production_destroy(r->production);
    rune_production_destroy(r->outline_program);
    rune_production_destroy(r->lcd_program);
    rune_production_destroy(r->mask_program);
    rune_production_destroy(r->unit_mask_program);
    rune_production_destroy(r->common_program);
    if (r->glyph_fill_target) r->gl.DeleteFramebuffers(1, &r->glyph_fill_target);
    if (r->glyph_fill_buffer) r->gl.DeleteBuffers(1, &r->glyph_fill_buffer);
    if (r->outline_texture) r->gl.DeleteTextures(1, &r->outline_texture);
    if (r->surfaces) rune_surfaces_destroy(r->surfaces);
    if (r->layers) rune_layers_destroy(r->layers);
    if (r->program) r->gl.DeleteProgram(r->program);
    if (r->vao) r->gl.DeleteVertexArrays(1, &r->vao);
    for (int i = 0; i < instance_ring_slots; ++i) {
        if (r->instance_buffers[i]) r->gl.DeleteBuffers(1, &r->instance_buffers[i]);
    }
    if (r->glyphs.texture) r->gl.DeleteTextures(1, &r->glyphs.texture);
    if (r->images.texture) r->gl.DeleteTextures(1, &r->images.texture);
    AtlasPages *tables[] = { &r->glyph_pages, &r->image_pages };
    for (size_t i = 0; i < 2; i++) {
        for (size_t page = 1; page < tables[i]->count; page++) {
            GLuint tex = tables[i]->extra[page - 1].texture;
            if (tex) r->gl.DeleteTextures(1, &tex);
        }
        free(tables[i]->extra);
    }
    if (r->empty_image) r->gl.DeleteTextures(1, &r->empty_image);
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

void rune_gl_window_rest(RuneGL *r, int all) {
    rune_damage_release(&r->damage);
    rune_layers_window_rest(r->layers, all);
    if (all) {
        for (int i = 0; i < instance_ring_slots; ++i) {
            if (r->instance_buffers[i] && r->instance_capacities[i]) {
                r->gl.BindBuffer(GL_ARRAY_BUFFER, r->instance_buffers[i]);
                r->gl.BufferData(GL_ARRAY_BUFFER, 0, NULL, GL_STREAM_DRAW);
                r->instance_capacities[i] = 0;
            }
        }
        if (r->glyph_fill_buffer && r->glyph_fill_capacity) {
            r->gl.BindBuffer(GL_ARRAY_BUFFER, r->glyph_fill_buffer);
            r->gl.BufferData(GL_ARRAY_BUFFER, 0, NULL, GL_STREAM_DRAW);
            r->glyph_fill_capacity = 0;
        }
        r->gl.Finish();
    }
}

void rune_gl_layer_cache_clear(RuneGL *r) {
    rune_layers_cache_clear(r->layers);
}

RuneGLLayerStorage rune_gl_layer_storage(const RuneGL *r) {
    return r ? rune_layers_storage(r->layers) : (RuneGLLayerStorage){0};
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

int rune_gl_upload_outline_rows(RuneGL *r, int rows, int first, const uint32_t *texels,
                                char *error, size_t size) {
    if (!r || r->drawing || !texels || rows < 1 || rows > 4096 || first < 0 || first >= rows ||
        rows > r->max_texture_size || 1024 > r->max_texture_size)
        return fail(error, size, "Invalid Rune outline storage dimensions");
    const RuneGLAPI *gl = &r->gl;
    gl->ActiveTexture(GL_TEXTURE0 + 4);
    gl->BindSampler(4, 0);
    if (!r->outline_texture) gl->GenTextures(1, &r->outline_texture);
    gl->BindTexture(GL_TEXTURE_2D, r->outline_texture);
    prepare_unpack(gl, 0);
    if (rows > r->outline_rows) {
        int capacity = 1;
        while (capacity < rows) capacity *= 2;
        if (capacity > r->max_texture_size) capacity = rows;
        gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        gl->TexImage2D(GL_TEXTURE_2D, 0, GL_RGBA32UI, 1024, capacity, 0, GL_RGBA_INTEGER, GL_UNSIGNED_INT, NULL);
        if (!check_gl(gl, "Allocating Rune outline texture", error, size)) return 0;
        r->outline_rows = capacity;
        first = 0;
    }
    gl->TexSubImage2D(GL_TEXTURE_2D, 0, 0, first, 1024, rows - first, GL_RGBA_INTEGER, GL_UNSIGNED_INT,
                      texels + (size_t)first * 1024 * 4);
    r->damage.valid = 0;
    return check_gl(gl, "Updating Rune outline texture", error, size);
}

static int upload_region(RuneGL *r, const Atlas *atlas, int channels, int x0, int y0, int x1, int y1,
                         const uint8_t *next, char *error, size_t size) {
    r->damage.valid = 0;
    const RuneGLAPI *gl = &r->gl;
    gl->ActiveTexture(channels == 1 ? GL_TEXTURE0 : GL_TEXTURE1);
    gl->BindTexture(GL_TEXTURE_2D, atlas->texture);
    prepare_unpack(gl, atlas->width);
    size_t start = ((size_t)y0 * atlas->width + x0) * channels;
    gl->TexSubImage2D(GL_TEXTURE_2D, 0, x0, y0, x1 - x0, y1 - y0,
                      channels == 1 ? GL_RED : GL_RGBA, GL_UNSIGNED_BYTE, next + start);
    gl->PixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    return check_gl(gl, "Updating Rune atlas region", error, size);
}

int rune_gl_patch_atlas_region(RuneGL *r, int channels, size_t page, int width, int height,
                               int x0, int y0, int x1, int y1, const uint8_t *pixels, char *error, size_t size) {
    if (!r || r->drawing || !pixels || (channels != 1 && channels != 4))
        return fail(error, size, "Invalid Rune atlas page patch or renderer state");
    const AtlasPages *table = channels == 1 ? &r->glyph_pages : &r->image_pages;
    if (page && page >= table->count) return fail(error, size, "Atlas patch names a missing page");
    const Atlas *base = channels == 1 ? &r->glyphs : &r->images;
    const Atlas *atlas = page ? &table->extra[page - 1] : base;
    if (!atlas->texture || width != atlas->width || height != atlas->height ||
        x0 < 0 || y0 < 0 || x1 > width || y1 > height || x0 >= x1 || y0 >= y1)
        return fail(error, size, "Rune image patch is outside the resident page");
    return upload_region(r, atlas, channels, x0, y0, x1, y1, pixels, error, size);
}

static int patch_atlas(RuneGL *r, const Atlas *atlas, int channels, int width, int height,
                       const uint8_t *previous, const uint8_t *next, char *error, size_t size) {
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
    return upload_region(r, atlas, channels, x0, y0, x1, y1, next, error, size);
}

int rune_gl_patch_atlas(RuneGL *r, int channels, int width, int height,
                        const uint8_t *previous, const uint8_t *next, char *error, size_t size) {
    if (!r || r->drawing || !previous || !next || (channels != 1 && channels != 4))
        return fail(error, size, "Invalid Rune atlas patch or renderer state");
    return patch_atlas(r, channels == 1 ? &r->glyphs : &r->images, channels, width, height, previous, next, error, size);
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

static int empty_texture(RuneGL *r, char *error, size_t size) {
    if (!r->empty_image) {
        Atlas blank = {0};
        uint8_t clear[4] = {0};
        prepare_unpack(&r->gl, 0);
        set_atlas_params(&r->gl, &blank);
        if (!set_atlas(&r->gl, &blank, GL_TEXTURE1, 1, 1, GL_SRGB8_ALPHA8, GL_RGBA, clear, error, size)) {
            r->gl.DeleteTextures(1, &blank.texture);
            return 0;
        }
        r->empty_image = blank.texture;
    }
    return 1;
}

int rune_gl_atlas_page_count(RuneGL *r, int channels, size_t count, char *error, size_t size) {
    if (!r || r->drawing || (channels != 1 && channels != 4) || count > (size_t)INT_MAX || count > SIZE_MAX / sizeof(Atlas))
        return fail(error, size, "Invalid Rune atlas page count or renderer state");
    AtlasPages *table = channels == 1 ? &r->glyph_pages : &r->image_pages;
    size_t old = table->count;
    if (old == count) return 1;
    if (count && channels == 4 && !empty_texture(r, error, size)) return 0;
    if (count > 1 && count > old) {
        Atlas *pages = realloc(table->extra, (count - 1) * sizeof(*pages));
        if (!pages) return fail(error, size, "Could not allocate Rune atlas page slots");
        size_t first = old > 1 ? old - 1 : 0;
        memset(pages + first, 0, (count - 1 - first) * sizeof(*pages));
        table->extra = pages;
    } else {
        for (size_t page = count > 1 ? count : 1; page < old; ++page) {
            if (table->extra[page - 1].texture) {
                if (channels == 1 && table->extra[page - 1].texture == r->glyph_fill_attached)
                    r->glyph_fill_attached = 0;
                r->gl.DeleteTextures(1, &table->extra[page - 1].texture);
            }
        }
        if (count <= 1) {
            free(table->extra);
            table->extra = NULL;
        }
    }
    r->damage.valid = 0;
    table->count = count;
    return 1;
}

int rune_gl_upload_atlas_page(RuneGL *r, int channels, size_t page, int width, int height, int srgb,
                              const uint8_t *previous, const uint8_t *pixels,
                              char *error, size_t size) {
    if (!r || r->drawing || (channels != 1 && channels != 4))
        return fail(error, size, "Invalid Rune atlas page slot or renderer state");
    AtlasPages *table = channels == 1 ? &r->glyph_pages : &r->image_pages;
    if (!page || page >= table->count) return fail(error, size, "Invalid Rune atlas page slot");
    Atlas *atlas = &table->extra[page - 1];
    if (!pixels) {
        if (atlas->texture) {
            if (channels == 1 && atlas->texture == r->glyph_fill_attached)
                r->glyph_fill_attached = 0;
            r->gl.DeleteTextures(1, &atlas->texture);
            *atlas = (Atlas){0};
            r->damage.valid = 0;
        }
        return 1;
    }
    if (width <= 0 || height <= 0 || width > r->max_texture_size || height > r->max_texture_size)
        return fail(error, size, "Rune atlas page exceeds texture limits");
    GLenum internal = channels == 1 ? GL_R8 : (srgb ? GL_SRGB8_ALPHA8 : GL_RGBA8);
    if (previous && atlas->width == width && atlas->height == height && atlas->internal_format == internal)
        return patch_atlas(r, atlas, channels, width, height, previous, pixels, error, size);
    if (!atlas->texture) set_atlas_params(&r->gl, atlas);
    r->damage.valid = 0;
    prepare_unpack(&r->gl, 0);
    return set_atlas(&r->gl, atlas, channels == 1 ? GL_TEXTURE0 : GL_TEXTURE1, width, height, internal,
                     channels == 1 ? GL_RED : GL_RGBA, pixels, error, size);
}

int rune_gl_fill_outline_masks(RuneGL *r, size_t page, int width, int height, const uint8_t *base,
                               const void *instances, size_t count, char *error, size_t size) {
    return rune_gl_fill_outline_masks_for_profile(r, page, width, height, base, instances, count, 0, error, size);
}

int rune_gl_fill_outline_masks_for_profile(RuneGL *r, size_t page, int width, int height, const uint8_t *base,
                                          const void *instances, size_t count, int unit_windfoil, char *error, size_t size) {
    if (!rune_gl_outline_eligible(r)) return fail(error, size, "Rune GPU glyph fills are unavailable");
    RuneGLProduction *program = unit_windfoil ? r->unit_mask_program : r->mask_program;
    if (!program) program = r->outline_program;
    if (!program || !r->outline_texture ||
        (page && page >= r->glyph_pages.count) || width < 1 || height < 1 ||
        width > r->max_texture_size || height > r->max_texture_size ||
        count > INT_MAX || count > PTRDIFF_MAX / 128 || (!instances && count))
        return fail(error, size, "Invalid Rune GPU glyph mask fill");
    const RuneGLAPI *gl = &r->gl;
    Atlas *atlas = page ? &r->glyph_pages.extra[page - 1] : &r->glyphs;
    // A deferred page can be created by its first fill before any CPU atlas upload.
    if (!atlas->texture) set_atlas_params(gl, atlas);
    prepare_unpack(gl, 0);
    int resized = width != atlas->width || height != atlas->height || GL_R8 != atlas->internal_format;
    if (!set_atlas(gl, atlas, GL_TEXTURE0, width, height, GL_R8, GL_RED, base, error, size)) return 0;
    if (resized && r->glyph_fill_attached == atlas->texture) r->glyph_fill_attached = 0;
    if (base) r->damage.valid = 0;
    if (!count) return 1;
    if (!empty_texture(r, error, size)) return 0;
    GLint destination;
    gl->GetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &destination);
    if (!r->glyph_fill_target) {
        gl->GenFramebuffers(1, &r->glyph_fill_target);
        r->glyph_fill_attached = 0;
    }
    gl->BindFramebuffer(GL_DRAW_FRAMEBUFFER, r->glyph_fill_target);
    if (r->glyph_fill_attached != atlas->texture) {
        gl->FramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, atlas->texture, 0);
        if (gl->CheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
            r->glyph_fill_attached = 0;
            gl->BindFramebuffer(GL_DRAW_FRAMEBUFFER, (GLuint)destination);
            return fail(error, size, "The GPU cannot draw into Rune's R8 glyph atlas");
        }
        r->glyph_fill_attached = atlas->texture;
    }
    // Neither float sampler may refer to the R8 attachment, even when the shader
    // dynamically selects the integer outline store instead.
    for (GLuint unit = 0; unit < 2; ++unit) {
        gl->ActiveTexture(GL_TEXTURE0 + unit);
        gl->BindSampler(unit, 0);
        gl->BindTexture(GL_TEXTURE_2D, r->empty_image);
    }
    gl->ActiveTexture(GL_TEXTURE0 + 4);
    gl->BindSampler(4, 0);
    gl->BindTexture(GL_TEXTURE_2D, r->outline_texture);
    gl->Disable(GL_DEPTH_TEST);
    gl->Disable(GL_STENCIL_TEST);
    gl->Disable(GL_CULL_FACE);
    gl->Disable(GL_SCISSOR_TEST);
    gl->Disable(GL_RASTERIZER_DISCARD);
    gl->Disable(GL_BLEND);
    gl->ColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    gl->Viewport(0, 0, width, height);
    if (!r->glyph_fill_buffer) gl->GenBuffers(1, &r->glyph_fill_buffer);
    gl->BindBuffer(GL_ARRAY_BUFFER, r->glyph_fill_buffer);
    size_t fill_bytes = count * 128;
    if (fill_bytes > r->glyph_fill_capacity) {
        size_t cap = r->glyph_fill_capacity ? r->glyph_fill_capacity : 4096;
        while (cap < fill_bytes && cap <= (size_t)PTRDIFF_MAX / 2) cap *= 2;
        if (cap < fill_bytes) cap = fill_bytes;
        gl->BufferData(GL_ARRAY_BUFFER, (GLsizeiptr)cap, NULL, GL_STREAM_DRAW);
        r->glyph_fill_capacity = cap;
    }
    gl->BufferSubData(GL_ARRAY_BUFFER, 0, (GLsizeiptr)fill_bytes, instances);
    rune_production_batch(program, r->glyph_fill_buffer, width, height, 0, 0,
                          0, count, 0, 0, 1, &r->springs);
    gl->BindFramebuffer(GL_DRAW_FRAMEBUFFER, (GLuint)destination);
    r->damage.valid = 0;
    return check_gl(gl, "Filling Rune GPU glyph masks", error, size);
}

/* Select once per existing texture-page batch. Mixed batches stay on the
 * general program so alternating borders and labels don't split painter order
 * into an extra GL draw for every primitive. */
static int common_frame_batch(const void *instances, size_t first, size_t count) {
    const uint8_t *bytes = (const uint8_t *)instances + first * 128;
    for (size_t i = 0; i < count; ++i, bytes += 128) {
        const float *p = (const float *)bytes;
        if (p[16] != 0) return 0;
        if (p[17] == 0) {
            if (p[4] < 0 || p[5] < 0 || p[6] < 0 || p[7] < 0) return 0;
        } else if (p[17] == 2) {
            if (p[4] != 0 || p[7] != 0 || p[22] != 0) return 0;
        } else return 0;
        uint32_t fade[4];
        memcpy(fade, bytes + 112, sizeof(fade));
        if (fade[0] || fade[1] || fade[3]) return 0;
    }
    return 1;
}

static void draw_bound_batch(RuneGL *r, const void *instances, GLuint glyph_texture, GLuint image_texture, int production, int width, int height, int srgb_blend,
                       int in_layer, size_t start, size_t count) {
    if (!count) return;
    const RuneGLAPI *gl = &r->gl;
    gl->ActiveTexture(GL_TEXTURE0);
    gl->BindTexture(GL_TEXTURE_2D, glyph_texture);
    gl->ActiveTexture(GL_TEXTURE1);
    gl->BindTexture(GL_TEXTURE_2D, image_texture);
    gl->Enable(GL_BLEND);
    gl->BlendEquation(GL_FUNC_ADD);
    gl->BlendFunc(GL_ONE, (production && rune_layers_additive(r->layers)) ? GL_ONE : GL_ONE_MINUS_SRC_ALPHA);
    if (production) {
        int x, y;
        rune_layers_target_geometry(r->layers, &x, &y, &width, &height);
        gl->Viewport(0, 0, width, height);
        RuneGLProduction *program = r->production;
        if (r->common_program && !r->springs.tracks && common_frame_batch(instances, start, count)) {
            program = r->common_program;
        } else if (r->use_outlines && !r->springs.tracks) {
            int dual = r->use_lcd && r->opaque_root && !in_layer && !rune_layers_additive(r->layers);
            program = dual ? r->lcd_program : r->outline_program;
            if (dual) gl->BlendFunc(GL_ONE, GL_ONE_MINUS_SRC1_COLOR);
            gl->ActiveTexture(GL_TEXTURE0 + 4);
            gl->BindSampler(4, 0);
            gl->BindTexture(GL_TEXTURE_2D, r->outline_texture);
            gl->ActiveTexture(GL_TEXTURE1);
        }
        rune_production_batch(program, r->instance_buffers[r->instance_slot], width, height, x, y, start, count,
                              srgb_blend, in_layer, 0, &r->springs);
        return;
    }
    gl->UseProgram(r->program);
    gl->Uniform2f(r->viewport_uniform, (float)width, (float)height);
    gl->BindVertexArray(r->vao);
    gl->BindBuffer(GL_ARRAY_BUFFER, r->instance_buffers[r->instance_slot]);
    for (GLuint slot = 0; slot < primitive_slots; slot++) {
        uintptr_t offset = start * PRIMITIVE_BYTES + slot * 4 * sizeof(float);
        gl->VertexAttribPointer(slot, 4, GL_FLOAT, GL_FALSE, PRIMITIVE_BYTES, (const void *)offset);
    }
    gl->DrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, (GLsizei)count);
}

/* Glyphs and images use page-local texels and independent bindings. Keep intervening
 * primitives in their original painter order until one of the bindings changes. */
static void draw_batch(RuneGL *r, const void *instances, int production, int width, int height, int srgb_blend,
                       int in_layer, size_t start, size_t count) {
    if (!count) return;
    GLuint glyph = r->glyphs.texture, image = r->images.texture;
    size_t first = start, end = start + count;
    if (r->image_pages.count || r->glyph_pages.count) {
        const size_t stride = production ? 128 : PRIMITIVE_BYTES;
        for (size_t i = start; i < end; ++i) {
            const float *instance = (const float *)((const uint8_t *)instances + i * stride);
            const int is_glyph = instance[17] == 2;
            if (!is_glyph && instance[17] != 7) continue;
            const AtlasPages *table = is_glyph ? &r->glyph_pages : &r->image_pages;
            if (!table->count) continue;
            float page = instance[is_glyph && production ? 18 : 16];
            GLuint base = is_glyph ? r->glyphs.texture : r->images.texture;
            GLuint wanted = is_glyph || page < 1.0f ? base : r->empty_image;
            if (page >= 1.0f && (double)page < (double)table->count) {
                GLuint resident = table->extra[(size_t)page - 1].texture;
                if (resident) wanted = resident;
            }
            GLuint *bound = is_glyph ? &glyph : &image;
            if (*bound == wanted) continue;
            if (i != first)
                draw_bound_batch(r, instances, glyph, image, production, width, height, srgb_blend, in_layer, first, i - first);
            first = i;
            *bound = wanted;
        }
    }
    draw_bound_batch(r, instances, glyph, image, production, width, height, srgb_blend, in_layer, first, end - first);
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

    r->opaque_root = clear[3] >= 1.0f;
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
    if (glyphs || images) r->damage.valid = 0;
    int glyph_resized = gw != r->glyphs.width || gh != r->glyphs.height || GL_R8 != r->glyphs.internal_format;
    if (!set_atlas(gl, &r->glyphs, GL_TEXTURE0, gw, gh, GL_R8, GL_RED, glyphs, error, size) ||
        !set_atlas(gl, &r->images, GL_TEXTURE1, iw, ih, (!production && srgb_blend) ? GL_RGBA8 : GL_SRGB8_ALPHA8,
                   GL_RGBA, images, error, size)) return 0;
    if (glyph_resized && r->glyph_fill_attached == r->glyphs.texture) r->glyph_fill_attached = 0;
    int spring_frame = production && r->springs.tracks && r->springs.ids;
    int retained = spring_frame && r->reuse_spring_instances && count == r->spring_instance_count;
    r->reuse_spring_instances = 0;
    r->spring_instance_count = 0;
    RuneDamageRect rects[4];
    int damage = -1;
    if (production && r->damage_enabled && !draw_count && !spring_frame && !r->effect_hook)
        damage = rune_damage_plan(&r->damage, instances, count, width, height, clear, srgb_blend, rects);
    else
        r->damage.valid = 0;
    if (count && !retained && damage != 0) {
        r->instance_slot = (r->instance_slot + 1) % instance_ring_slots;
        size_t needed = count * stride;
        gl->BindBuffer(GL_ARRAY_BUFFER, r->instance_buffers[r->instance_slot]);
        if (needed > r->instance_capacities[r->instance_slot]) {
            size_t cap = r->instance_capacities[r->instance_slot] ? r->instance_capacities[r->instance_slot] : 4096;
            while (cap < needed && cap <= (size_t)PTRDIFF_MAX / 2) cap *= 2;
            if (cap < needed) cap = needed;
            gl->BufferData(GL_ARRAY_BUFFER, (GLsizeiptr)cap, NULL, GL_STREAM_DRAW);
            r->instance_capacities[r->instance_slot] = cap;
        }
        gl->BufferSubData(GL_ARRAY_BUFFER, 0, (GLsizeiptr)needed, instances);
    }
    r->drawing = 1;
    int success = rune_layers_frame(r->layers, width, height, srgb_blend, production, error, size);
    if (!success) goto done;

    if (damage >= 0) {
        rune_layers_cache_begin(r->layers);
        gl->Enable(GL_SCISSOR_TEST);
        for (int i = 0; i < damage; i++) {
            RuneDamageRect rect = rects[i];
            gl->Scissor(rect.left, height - rect.bottom, rect.right - rect.left, rect.bottom - rect.top);
            rune_layers_clear_root(r->layers, clear, r->glyphs.texture);
            RuneDamageRange ranges[8];
            int used = rune_damage_ranges(&r->damage, rect, ranges);
            for (int j = 0; j < used; ++j) {
                draw_batch(r, instances, 1, width, height, srgb_blend, 0, ranges[j].first, ranges[j].count);
            }
        }
        gl->Disable(GL_SCISSOR_TEST);
        goto present;
    }
    rune_layers_clear_root(r->layers, clear, r->glyphs.texture);
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
            draw_batch(r, instances, production, width, height, srgb_blend, depth > 0, first, i - first);
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
        draw_batch(r, instances, production, width, height, srgb_blend, depth > 0, first, i - first);
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
    draw_batch(r, instances, production, width, height, srgb_blend, depth > 0, first, count - first);
present:
    success = rune_layers_present(r->layers, (GLuint)destination, error, size);
    if (success && r->check_errors) success = check_gl(gl, "Drawing Rune frame", error, size);
    if (success) rune_surfaces_prune(r->surfaces, draws, draw_count);
done:
    r->last_damage = success ? damage : -1;
    for (int i = 0; i < r->last_damage; ++i) {
        int32_t *out = r->last_rects + i * 4;
        out[0] = rects[i].left; out[1] = rects[i].top; out[2] = rects[i].right; out[3] = rects[i].bottom;
    }
    if (!success) r->damage.valid = 0;
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
