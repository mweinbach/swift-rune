#include "production.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct RuneGLProduction {
    const RuneGLAPI *gl;
    GLuint program, vao;
    GLint viewport, origin, srgb_blend, in_layer;
    GLint spring_first, spring_time;
};

enum { frame_stride = 128, frame_slots = 8 };

RuneGLProduction *rune_production_create(const RuneGLAPI *gl, int es, const char *vs,
                                         const char *fs, char *error, size_t capacity) {
    RuneGLProduction *p = calloc(1, sizeof(*p));
    if (!p) {
        if (error && capacity) snprintf(error, capacity, "Cannot allocate Rune GL frame pipeline");
        return NULL;
    }
    p->gl = gl;
    p->program = rune_gl_program(gl, es, vs, fs, error, capacity);
    if (!p->program) {
        free(p);
        return NULL;
    }
    gl->UseProgram(p->program);
    p->viewport = gl->GetUniformLocation(p->program, "uViewport");
    p->origin = gl->GetUniformLocation(p->program, "uOrigin");
    p->srgb_blend = gl->GetUniformLocation(p->program, "uSRGBBlend");
    p->in_layer = gl->GetUniformLocation(p->program, "uInLayer");
    GLint glyph = gl->GetUniformLocation(p->program, "uGlyphAtlas");
    GLint image = gl->GetUniformLocation(p->program, "uImageAtlas");
    if (p->viewport < 0 || p->origin < 0 || p->srgb_blend < 0 || p->in_layer < 0 || glyph < 0 || image < 0) {
        if (error && capacity) snprintf(error, capacity, "Rune GL frame shader interface mismatch");
        rune_production_destroy(p);
        return NULL;
    }
    gl->Uniform1i(glyph, 0);
    gl->Uniform1i(image, 1);
    p->spring_first = gl->GetUniformLocation(p->program, "uSpringFirst");
    if (p->spring_first >= 0) {
        p->spring_time = gl->GetUniformLocation(p->program, "uSpringTime");
        GLint tracks = gl->GetUniformLocation(p->program, "uSpringTracks");
        GLint ids = gl->GetUniformLocation(p->program, "uSpringIDs");
        if (p->spring_time < 0 || tracks < 0 || ids < 0) {
            if (error && capacity) snprintf(error, capacity, "Rune GL spring shader interface mismatch");
            rune_production_destroy(p);
            return NULL;
        }
        gl->Uniform1i(tracks, 2);
        gl->Uniform1i(ids, 3);
    }
    gl->GenVertexArrays(1, &p->vao);
    gl->BindVertexArray(p->vao);
    for (GLuint i = 0; i < frame_slots; ++i) {
        gl->EnableVertexAttribArray(i);
        gl->VertexAttribDivisor(i, 1);
    }
    return p;
}

void rune_production_destroy(RuneGLProduction *p) {
    if (!p) return;
    if (p->vao) p->gl->DeleteVertexArrays(1, &p->vao);
    if (p->program) p->gl->DeleteProgram(p->program);
    free(p);
}

void rune_production_batch(RuneGLProduction *p, GLuint buffer, int width, int height,
                           int origin_x, int origin_y, size_t first, size_t count,
                           int srgb_blend, int in_layer, const RuneGLFrameSprings *springs) {
    if (!count) return;
    const RuneGLAPI *gl = p->gl;
    gl->UseProgram(p->program);
    gl->BindVertexArray(p->vao);
    gl->BindBuffer(GL_ARRAY_BUFFER, buffer);
    uintptr_t offset = first * frame_stride;
    for (GLuint slot = 0; slot < 7; ++slot) {
        gl->VertexAttribPointer(slot, 4, GL_FLOAT, GL_FALSE, frame_stride,
                                (const void *)(offset + slot * 16));
    }
    /* Bit-exact uint attributes preserve packed half floats and corner radii. */
    gl->VertexAttribIPointer(7, 4, 0x1405 /* GL_UNSIGNED_INT */, frame_stride,
                             (const void *)(offset + 112));
    gl->Uniform2f(p->viewport, (float)width, (float)height);
    gl->Uniform2f(p->origin, (float)origin_x, (float)origin_y);
    gl->Uniform1i(p->srgb_blend, srgb_blend);
    gl->Uniform1i(p->in_layer, in_layer);
    if (p->spring_first >= 0) {
        int active = springs->tracks && springs->ids;
        gl->Uniform1i(p->spring_first, active ? (GLint)first : -1);
        if (active) {
            gl->Uniform2f(p->spring_time, springs->seconds, springs->fraction);
            gl->ActiveTexture(GL_TEXTURE0 + 2);
            gl->BindSampler(2, 0);
            gl->BindTexture(GL_TEXTURE_2D, springs->tracks);
            gl->ActiveTexture(GL_TEXTURE0 + 3);
            gl->BindSampler(3, 0);
            gl->BindTexture(GL_TEXTURE_2D, springs->ids);
            gl->ActiveTexture(GL_TEXTURE1); /* draw_batch leaves the image atlas active. */
        }
    }
    gl->DrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, (GLsizei)count);
}

int rune_production_marker(const void *instance, float converted[36]) {
    const float *src = (const float *)instance;
    const float kind = src[17];
    if (kind != 8 && kind != 9 && kind != 12 && kind != 13) return 0;
    memset(converted, 0, sizeof(float) * 36);
    /* The pass scheduler shares its rectangle/opacity/blur fields across the
     * two ABIs. The layer shader receives the untouched production marker too. */
    memcpy(converted, src, sizeof(float) * 4);
    converted[24] = src[24];
    converted[25] = src[25];
    converted[26] = src[26] - src[24];
    converted[27] = src[27] - src[25];
    if (kind == 8) {
        converted[16] = src[11];
        converted[18] = src[16];
        converted[19] = src[18];
        converted[34] = src[13];
        return 8;
    }
    if (kind == 13) {
        converted[16] = src[16];
        memcpy(converted + 4, src + 4, sizeof(float) * 4);
        return 12;
    }
    return kind == 12 ? 13 : 9;
}
