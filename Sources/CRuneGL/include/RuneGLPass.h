#ifndef RUNE_GL_PASS_H
#define RUNE_GL_PASS_H
#include "CRuneGL.h"
#include "RuneGLPassTimer.h"
#ifdef __cplusplus
extern "C" {
#endif

// Effect passes use a current GL 3.3 or GLES 3 context. Resource names belong to that context.
// Every draw binds its target, textures, VAO, program and blend state.
typedef struct RuneGLPassDevice RuneGLPassDevice;
typedef struct RuneGLPassProgram RuneGLPassProgram;
typedef enum {
    RuneGLPassReplace, RuneGLPassPremultipliedOver, RuneGLPassScreen, RuneGLPassAdd
} RuneGLPassBlend;
typedef enum { RuneGLPassRGBA8, RuneGLPassRGBA16F, RuneGLPassRGBA32F, RuneGLPassR8, RuneGLPassR32F } RuneGLPassFormat;
typedef struct { uint32_t texture, framebuffer; int width, height; } RuneGLPassTarget;
RuneGLPassDevice *rune_gl_pass_open(RuneGLResolve resolve, char *error, size_t error_size);
void rune_gl_pass_close(RuneGLPassDevice *device);
/* After context loss, drop the CPU allocation without issuing GL commands. */
void rune_gl_pass_abandon(RuneGLPassDevice *device);
uint32_t rune_gl_pass_current_framebuffer(const RuneGLPassDevice *device);
const char *rune_gl_pass_adapter(const RuneGLPassDevice *device);
// GLSL bodies omit #version. Optional std140 uniform block named RunePass (binding 0).
// Sampled 2D textures are named uTex0 ... uTex15. Vertices are a four-vertex triangle strip.
RuneGLPassProgram *rune_gl_pass_program(RuneGLPassDevice *device, const char *vertex, const char *fragment,
                                       char *error, size_t error_size);
// A null device releases only the CPU program wrapper after context loss.
void rune_gl_pass_delete_program(RuneGLPassDevice *device, RuneGLPassProgram *program);
int rune_gl_pass_draw(RuneGLPassDevice *device, const RuneGLPassProgram *program, uint32_t framebuffer,
                      int width, int height, const uint32_t *textures, size_t texture_count,
                      const void *uniforms, size_t uniform_bytes, RuneGLPassBlend blend,
                      char *error, size_t error_size);
// Same state and resources as rune_gl_pass_draw, with gl_InstanceID in [0, instances).
int rune_gl_pass_draw_instances(RuneGLPassDevice *device, const RuneGLPassProgram *program, uint32_t framebuffer,
                                int width, int height, const uint32_t *textures, size_t texture_count,
                                const void *uniforms, size_t uniform_bytes, RuneGLPassBlend blend, int instances,
                                char *error, size_t error_size);
// Null data allocates storage. Float formats accept packed 32-bit source floats. Row 0 is GL's bottom row.
uint32_t rune_gl_pass_texture(RuneGLPassDevice *device, RuneGLPassFormat format, int width, int height,
                             const void *data, int linear, char *error, size_t error_size);
// Allocate a texture with trilinear sampling and an explicit number of levels.
uint32_t rune_gl_pass_mip_texture(RuneGLPassDevice *device, RuneGLPassFormat format, int width, int height,
                                  int levels, char *error, size_t error_size);
// Copy the complete source color attachment into the previously allocated level of another texture.
int rune_gl_pass_copy_mip(RuneGLPassDevice *device, RuneGLPassTarget source, uint32_t texture, int level,
                          char *error, size_t error_size);
int rune_gl_pass_update_texture(RuneGLPassDevice *device, uint32_t texture, RuneGLPassFormat format,
                               int width, int height, const void *data, char *error, size_t error_size);
void rune_gl_pass_delete_texture(RuneGLPassDevice *device, uint32_t texture);
int rune_gl_pass_target(RuneGLPassDevice *device, RuneGLPassFormat format, int width, int height,
                        int linear, RuneGLPassTarget *target, char *error, size_t error_size);
void rune_gl_pass_delete_target(RuneGLPassDevice *device, RuneGLPassTarget *target);
void rune_gl_pass_bind_target(RuneGLPassDevice *device, RuneGLPassTarget target);
void rune_gl_pass_clear(RuneGLPassDevice *device, RuneGLPassTarget target, float r, float g, float b, float a);
int rune_gl_pass_read(const RuneGLPassDevice *device, RuneGLPassTarget target,
                      uint8_t *rgba, size_t count, char *error, size_t error_size);
#ifdef __cplusplus
}
#endif
#endif
