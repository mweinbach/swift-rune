#include "RuneGLPass.h"
#include "gl_api.h"
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RUNE_GL_UNIFORM_BUFFER 0x8A11
#define RUNE_GL_UNIFORM_BLOCK_DATA_SIZE 0x8A40
#define RUNE_GL_RGBA32F 0x8814
#define RUNE_GL_R32F 0x822E
#define RUNE_GL_PIXEL_PACK_BUFFER 0x88EB
#define RUNE_GL_PACK_ALIGNMENT 0x0D05
#define RUNE_GL_PACK_ROW_LENGTH 0x0D02
#define RUNE_GL_PACK_SKIP_ROWS 0x0D03
#define RUNE_GL_PACK_SKIP_PIXELS 0x0D04
#define RUNE_GL_ONE_MINUS_SRC_COLOR 0x0301
#define RUNE_GL_TEXTURE_MAX_LEVEL 0x813D
#define RUNE_GL_LINEAR_MIPMAP_LINEAR 0x2703

struct RuneGLPassDevice {
    RuneGLAPI gl;
    GLuint vao, uniforms, transparent;
    GLint max_size;
    int es;
    GLuint (RUNE_GL_CALL *GetUniformBlockIndex)(GLuint, const GLchar *);
    void (RUNE_GL_CALL *GetActiveUniformBlockiv)(GLuint, GLuint, GLenum, GLint *);
    void (RUNE_GL_CALL *BindBufferBase)(GLenum, GLuint, GLuint);
    void (RUNE_GL_CALL *ReadPixels)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *);
    void (RUNE_GL_CALL *CopyTexSubImage2D)(GLenum, GLint, GLint, GLint, GLint, GLint, GLsizei, GLsizei);
};

struct RuneGLPassProgram {
    GLuint name;
    GLint block_size;
    unsigned sampler_mask;
};

static int fail(char *error, size_t size, const char *message) {
    if (error && size) snprintf(error, size, "%s", message);
    return 0;
}

static int check(const RuneGLPassDevice *d, char *error, size_t size, const char *label) {
    GLenum code = d->gl.GetError();
    if (code == GL_NO_ERROR) return 1;
    if (error && size) snprintf(error, size, "%s: GL error 0x%x", label, code);
    return 0;
}

RuneGLPassDevice *rune_gl_pass_open(RuneGLResolve resolve, char *error, size_t size) {
    RuneGLPassDevice *d = calloc(1, sizeof(*d));
    if (!d) { fail(error, size, "Cannot allocate GL pass device"); return NULL; }
    if (!rune_gl_load_api(&d->gl, resolve, error, size)) { free(d); return NULL; }
#define LOAD(name) do { \
    void *address = resolve("gl" #name); \
    if (!address) { fail(error, size, "Missing GL entry point gl" #name); free(d); return NULL; } \
    memcpy(&d->name, &address, sizeof(d->name)); \
} while (0)
    LOAD(GetUniformBlockIndex);
    LOAD(GetActiveUniformBlockiv);
    LOAD(BindBufferBase);
    LOAD(ReadPixels);
    LOAD(CopyTexSubImage2D);
#undef LOAD
    const char *version = (const char *)d->gl.GetString(GL_VERSION);
    if (!version) { free(d); fail(error, size, "GL passes require a current context"); return NULL; }
    d->es = strncmp(version, "OpenGL ES", 9) == 0;
    d->gl.GetIntegerv(GL_MAX_TEXTURE_SIZE, &d->max_size);
    d->gl.GenVertexArrays(1, &d->vao);
    d->gl.GenBuffers(1, &d->uniforms);
    if (!d->vao || !d->uniforms || !check(d, error, size, "GL pass initialization")) {
        rune_gl_pass_close(d); return NULL;
    }
    const uint8_t transparent[4] = {0};
    d->transparent = rune_gl_pass_texture(d, RuneGLPassRGBA8, 1, 1, transparent, 0, error, size);
    if (!d->transparent) { rune_gl_pass_close(d); return NULL; }
    return d;
}

void rune_gl_pass_close(RuneGLPassDevice *d) {
    if (!d) return;
    d->gl.DeleteTextures(1, &d->transparent);
    d->gl.DeleteBuffers(1, &d->uniforms);
    d->gl.DeleteVertexArrays(1, &d->vao);
    free(d);
}

void rune_gl_pass_abandon(RuneGLPassDevice *d) { free(d); }

uint32_t rune_gl_pass_current_framebuffer(const RuneGLPassDevice *d) {
    GLint id = 0;
    if (d) d->gl.GetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &id);
    return (GLuint)id;
}

const char *rune_gl_pass_adapter(const RuneGLPassDevice *d) {
    return d ? (const char *)d->gl.GetString(GL_RENDERER) : "";
}

RuneGLPassProgram *rune_gl_pass_program(RuneGLPassDevice *d, const char *vertex, const char *fragment,
                                       char *error, size_t size) {
    if (!d || !vertex || !fragment) { fail(error, size, "Missing GL pass shader"); return NULL; }
    RuneGLPassProgram *p = calloc(1, sizeof(*p));
    if (!p) { fail(error, size, "Cannot allocate GL pass program"); return NULL; }
    p->name = rune_gl_program(&d->gl, d->es, vertex, fragment, error, size);
    if (!p->name) { free(p); return NULL; }
    GLuint block = d->GetUniformBlockIndex(p->name, "RunePass");
    if (block != UINT_MAX) {
        d->GetActiveUniformBlockiv(p->name, block, RUNE_GL_UNIFORM_BLOCK_DATA_SIZE, &p->block_size);
    }
    d->gl.UseProgram(p->name);
    char name[8];
    for (int i = 0; i < 16; ++i) {
        snprintf(name, sizeof(name), "uTex%d", i);
        GLint location = d->gl.GetUniformLocation(p->name, name);
        if (location >= 0) {
            p->sampler_mask |= 1u << i;
            d->gl.Uniform1i(location, i);
        }
    }
    if (!check(d, error, size, "GL pass shader uniforms")) { rune_gl_pass_delete_program(d, p); return NULL; }
    return p;
}

void rune_gl_pass_delete_program(RuneGLPassDevice *d, RuneGLPassProgram *p) {
    if (!p) return;
    if (d) d->gl.DeleteProgram(p->name);
    free(p);
}

static int dimensions(const RuneGLPassDevice *d, int w, int h) {
    return d && w > 0 && h > 0 && w <= d->max_size && h <= d->max_size;
}

int rune_gl_pass_draw_instances(RuneGLPassDevice *d, const RuneGLPassProgram *p, GLuint framebuffer,
                      int w, int h, const GLuint *textures, size_t nt,
                      const void *uniforms, size_t bytes, RuneGLPassBlend blend, int instances, char *error, size_t size) {
    if (instances < 0 || !p || !dimensions(d, w, h) || nt > 16 || (nt && !textures) ||
        bytes < (size_t)p->block_size || bytes > PTRDIFF_MAX || (bytes && !uniforms) ||
        blend < RuneGLPassReplace || blend > RuneGLPassAdd) {
        return fail(error, size, "Invalid GL pass dimensions, textures, blend or uniform block");
    }
    const RuneGLAPI *gl = &d->gl;
    gl->BindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    gl->Viewport(0, 0, w, h);
    gl->Disable(GL_DEPTH_TEST);
    gl->Disable(GL_STENCIL_TEST);
    gl->Disable(GL_SCISSOR_TEST);
    gl->Disable(GL_CULL_FACE);
    gl->Disable(GL_RASTERIZER_DISCARD);
    if (!d->es) gl->Disable(GL_FRAMEBUFFER_SRGB);
    gl->ColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    if (blend == RuneGLPassReplace) {
        gl->Disable(GL_BLEND);
    } else {
        gl->Enable(GL_BLEND);
        gl->BlendEquation(GL_FUNC_ADD);
        GLenum dest = blend == RuneGLPassAdd ? GL_ONE :
            blend == RuneGLPassScreen ? RUNE_GL_ONE_MINUS_SRC_COLOR : GL_ONE_MINUS_SRC_ALPHA;
        gl->BlendFunc(GL_ONE, dest);
    }
    gl->UseProgram(p->name);
    gl->BindVertexArray(d->vao);
    if (p->block_size) {
        gl->BindBuffer(RUNE_GL_UNIFORM_BUFFER, d->uniforms);
        gl->BufferData(RUNE_GL_UNIFORM_BUFFER, (GLsizeiptr)bytes, uniforms, GL_STREAM_DRAW);
        d->BindBufferBase(RUNE_GL_UNIFORM_BUFFER, 0, d->uniforms);
    }
    for (size_t i = 0; i < 16; ++i) {
        if (!(p->sampler_mask & (1u << i))) continue;
        gl->BindSampler((GLuint)i, 0);
        gl->ActiveTexture(GL_TEXTURE0 + (GLenum)i);
        gl->BindTexture(GL_TEXTURE_2D, (i < nt && textures[i]) ? textures[i] : d->transparent);
    }
    gl->DrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, instances);
    return check(d, error, size, "GL effect draw");
}

int rune_gl_pass_draw(RuneGLPassDevice *d, const RuneGLPassProgram *p, GLuint framebuffer,
                      int w, int h, const GLuint *textures, size_t nt, const void *uniforms, size_t bytes,
                      RuneGLPassBlend blend, char *error, size_t size) {
    return rune_gl_pass_draw_instances(d, p, framebuffer, w, h, textures, nt, uniforms, bytes, blend, 1, error, size);
}

typedef struct { GLint storage; GLenum format, type; } PixelFormat;
static PixelFormat pixel_format(RuneGLPassFormat type) {
    switch (type) {
    case RuneGLPassRGBA16F: return (PixelFormat){ GL_RGBA16F, GL_RGBA, GL_FLOAT };
    case RuneGLPassRGBA32F: return (PixelFormat){ RUNE_GL_RGBA32F, GL_RGBA, GL_FLOAT };
    case RuneGLPassRGBA8: return (PixelFormat){ GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE };
    case RuneGLPassR32F: return (PixelFormat){ RUNE_GL_R32F, GL_RED, GL_FLOAT };
    case RuneGLPassR8: return (PixelFormat){ GL_R8, GL_RED, GL_UNSIGNED_BYTE };
    default: return (PixelFormat){ 0, 0, 0 };
    }
}

static void unpack(const RuneGLAPI *gl) {
    gl->BindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    gl->PixelStorei(GL_UNPACK_ALIGNMENT, 1);
    gl->PixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    gl->PixelStorei(GL_UNPACK_SKIP_ROWS, 0);
    gl->PixelStorei(GL_UNPACK_SKIP_PIXELS, 0);
}

GLuint rune_gl_pass_texture(RuneGLPassDevice *d, RuneGLPassFormat type, int w, int h,
                            const void *data, int linear, char *error, size_t size) {
    PixelFormat pixel = pixel_format(type);
    if (!pixel.storage || !dimensions(d, w, h)) return fail(error, size, "Invalid GL texture dimensions or format");
    const RuneGLAPI *gl = &d->gl;
    GLuint texture = 0;
    gl->GenTextures(1, &texture);
    gl->BindTexture(GL_TEXTURE_2D, texture);
    unpack(gl);
    gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, linear ? GL_LINEAR : GL_NEAREST);
    gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, linear ? GL_LINEAR : GL_NEAREST);
    gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    gl->TexImage2D(GL_TEXTURE_2D, 0, pixel.storage, w, h, 0, pixel.format, pixel.type, data);
    if (!check(d, error, size, "GL texture allocation")) { gl->DeleteTextures(1, &texture); return 0; }
    return texture;
}

GLuint rune_gl_pass_mip_texture(RuneGLPassDevice *d, RuneGLPassFormat format, int w, int h,
                                int levels, char *error, size_t size) {
    int maximum = 0;
    for (int extent = w > h ? w : h; extent > 0; extent >>= 1) ++maximum;
    if (levels < 1 || levels > maximum) return fail(error, size, "Invalid GL mip count");
    GLuint texture = rune_gl_pass_texture(d, format, w, h, NULL, 1, error, size);
    if (!texture) return 0;
    PixelFormat pixel = pixel_format(format);
    const RuneGLAPI *gl = &d->gl;
    for (int level = 1; level < levels; ++level) {
        w = w > 1 ? w / 2 : 1;
        h = h > 1 ? h / 2 : 1;
        gl->TexImage2D(GL_TEXTURE_2D, level, pixel.storage, w, h, 0, pixel.format, pixel.type, NULL);
    }
    gl->TexParameteri(GL_TEXTURE_2D, RUNE_GL_TEXTURE_MAX_LEVEL, levels - 1);
    gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, RUNE_GL_LINEAR_MIPMAP_LINEAR);
    if (!check(d, error, size, "GL mip texture allocation")) {
        gl->DeleteTextures(1, &texture);
        return 0;
    }
    return texture;
}

int rune_gl_pass_copy_mip(RuneGLPassDevice *d, RuneGLPassTarget source, GLuint texture, int level,
                          char *error, size_t size) {
    if (!texture || source.texture == texture || level < 0 || !dimensions(d, source.width, source.height)) {
        return fail(error, size, "Invalid GL mip source or destination");
    }
    GLint previous = 0;
    d->gl.GetIntegerv(0x8CAA /* GL_READ_FRAMEBUFFER_BINDING */, &previous);
    d->gl.BindFramebuffer(GL_READ_FRAMEBUFFER, source.framebuffer);
    d->gl.BindTexture(GL_TEXTURE_2D, texture);
    d->CopyTexSubImage2D(GL_TEXTURE_2D, level, 0, 0, 0, 0, source.width, source.height);
    d->gl.BindFramebuffer(GL_READ_FRAMEBUFFER, (GLuint)previous);
    return check(d, error, size, "GL mip copy");
}

int rune_gl_pass_update_texture(RuneGLPassDevice *d, GLuint texture, RuneGLPassFormat type,
                                int w, int h, const void *data, char *error, size_t size) {
    PixelFormat pixel = pixel_format(type);
    if (!texture || !data || !pixel.storage || !dimensions(d, w, h)) return fail(error, size, "Invalid GL texture update");
    d->gl.BindTexture(GL_TEXTURE_2D, texture);
    unpack(&d->gl);
    d->gl.TexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, pixel.format, pixel.type, data);
    return check(d, error, size, "GL texture update");
}

void rune_gl_pass_delete_texture(RuneGLPassDevice *d, GLuint texture) {
    if (d) d->gl.DeleteTextures(1, &texture);
}

int rune_gl_pass_target(RuneGLPassDevice *d, RuneGLPassFormat type, int w, int h, int linear,
                        RuneGLPassTarget *out, char *error, size_t size) {
    if (!out) return fail(error, size, "Missing GL target");
    *out = (RuneGLPassTarget){0};
    GLuint texture = rune_gl_pass_texture(d, type, w, h, NULL, linear, error, size);
    if (!texture) return 0;
    GLuint framebuffer = 0;
    GLint previous = 0;
    d->gl.GetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &previous);
    d->gl.GenFramebuffers(1, &framebuffer);
    d->gl.BindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffer);
    d->gl.FramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
    GLenum status = d->gl.CheckFramebufferStatus(GL_DRAW_FRAMEBUFFER);
    d->gl.BindFramebuffer(GL_DRAW_FRAMEBUFFER, (GLuint)previous);
    if (status != GL_FRAMEBUFFER_COMPLETE || !check(d, error, size, "GL color target")) {
        d->gl.DeleteFramebuffers(1, &framebuffer);
        d->gl.DeleteTextures(1, &texture);
        if (status != GL_FRAMEBUFFER_COMPLETE && error && size) snprintf(error, size, "Unsupported GL color target (0x%x)", status);
        return 0;
    }
    *out = (RuneGLPassTarget){ texture, framebuffer, w, h };
    return 1;
}

void rune_gl_pass_delete_target(RuneGLPassDevice *d, RuneGLPassTarget *target) {
    if (!d || !target) return;
    d->gl.DeleteFramebuffers(1, &target->framebuffer);
    d->gl.DeleteTextures(1, &target->texture);
    *target = (RuneGLPassTarget){0};
}

void rune_gl_pass_bind_target(RuneGLPassDevice *d, RuneGLPassTarget target) {
    if (d) d->gl.BindFramebuffer(GL_FRAMEBUFFER, target.framebuffer);
}

void rune_gl_pass_clear(RuneGLPassDevice *d, RuneGLPassTarget target, float r, float g, float b, float a) {
    if (!d) return;
    d->gl.BindFramebuffer(GL_DRAW_FRAMEBUFFER, target.framebuffer);
    d->gl.Disable(GL_SCISSOR_TEST);
    d->gl.ColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    d->gl.ClearColor(r, g, b, a);
    d->gl.Clear(GL_COLOR_BUFFER_BIT);
}

int rune_gl_pass_read(const RuneGLPassDevice *d, RuneGLPassTarget target, uint8_t *rgba,
                      size_t count, char *error, size_t size) {
    if (!rgba || !dimensions(d, target.width, target.height) ||
        (size_t)target.width > SIZE_MAX / 4 / (size_t)target.height ||
        count != (size_t)target.width * (size_t)target.height * 4) {
        return fail(error, size, "Invalid GL RGBA readback buffer");
    }
    GLint old = 0;
    d->gl.GetIntegerv(0x8CAA /* GL_READ_FRAMEBUFFER_BINDING */, &old);
    d->gl.BindFramebuffer(GL_READ_FRAMEBUFFER, target.framebuffer);
    d->gl.BindBuffer(RUNE_GL_PIXEL_PACK_BUFFER, 0);
    d->gl.PixelStorei(RUNE_GL_PACK_ALIGNMENT, 1);
    d->gl.PixelStorei(RUNE_GL_PACK_ROW_LENGTH, 0);
    d->gl.PixelStorei(RUNE_GL_PACK_SKIP_ROWS, 0);
    d->gl.PixelStorei(RUNE_GL_PACK_SKIP_PIXELS, 0);
    d->ReadPixels(0, 0, target.width, target.height, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    d->gl.BindFramebuffer(GL_READ_FRAMEBUFFER, (GLuint)old);
    return check(d, error, size, "GL RGBA readback");
}
