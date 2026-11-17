#ifndef RUNE_GL_API_H
#define RUNE_GL_API_H

#include "CRuneGL.h"
#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32) && !defined(_WIN64)
#define RUNE_GL_CALL __stdcall
#else
#define RUNE_GL_CALL
#endif

/* The renderer loads its entry points from the current platform context.
 * OpenGL 3.3 and GLES 3.0 use the same ABI for these functions. */
typedef unsigned int GLenum;
typedef unsigned int GLuint;
typedef unsigned int GLbitfield;
typedef int GLint;
typedef int GLsizei;
typedef unsigned char GLboolean;
typedef unsigned char GLubyte;
typedef float GLfloat;
typedef ptrdiff_t GLsizeiptr;
typedef ptrdiff_t GLintptr;
typedef char GLchar;

#define GL_FALSE 0
#define GL_TRUE 1
#define GL_ZERO 0
#define GL_ONE 1
#define GL_NO_ERROR 0
#define GL_VENDOR 0x1F00
#define GL_RENDERER 0x1F01
#define GL_VERSION 0x1F02
#define GL_MAJOR_VERSION 0x821B
#define GL_MINOR_VERSION 0x821C
#define GL_MAX_TEXTURE_SIZE 0x0D33
#define GL_ARRAY_BUFFER 0x8892
#define GL_STREAM_DRAW 0x88E0
#define GL_FLOAT 0x1406
#define GL_UNSIGNED_BYTE 0x1401
#define GL_HALF_FLOAT 0x140B
#define GL_VERTEX_SHADER 0x8B31
#define GL_FRAGMENT_SHADER 0x8B30
#define GL_LINK_STATUS 0x8B82
#define GL_COMPILE_STATUS 0x8B81
#define GL_TEXTURE_2D 0x0DE1
#define GL_TEXTURE_MAG_FILTER 0x2800
#define GL_TEXTURE_MIN_FILTER 0x2801
#define GL_TEXTURE_WRAP_S 0x2802
#define GL_TEXTURE_WRAP_T 0x2803
#define GL_NEAREST 0x2600
#define GL_LINEAR 0x2601
#define GL_CLAMP_TO_EDGE 0x812F
#define GL_TEXTURE0 0x84C0
#define GL_TEXTURE1 0x84C1
#define GL_RGBA 0x1908
#define GL_RED 0x1903
#define GL_R8 0x8229
#define GL_RGBA8 0x8058
#define GL_SRGB8_ALPHA8 0x8C43
#define GL_RGBA16F 0x881A
#define GL_UNPACK_ALIGNMENT 0x0CF5
#define GL_UNPACK_ROW_LENGTH 0x0CF2
#define GL_UNPACK_SKIP_PIXELS 0x0CF4
#define GL_UNPACK_SKIP_ROWS 0x0CF3
#define GL_PIXEL_UNPACK_BUFFER 0x88EC
#define GL_TRIANGLE_STRIP 0x0005
#define GL_TRIANGLES 0x0004
#define GL_BLEND 0x0BE2
#define GL_DEPTH_TEST 0x0B71
#define GL_STENCIL_TEST 0x0B90
#define GL_SCISSOR_TEST 0x0C11
#define GL_CULL_FACE 0x0B44
#define GL_RASTERIZER_DISCARD 0x8C89
#define GL_FRAMEBUFFER_SRGB 0x8DB9
#define GL_ONE_MINUS_SRC_ALPHA 0x0303
#define GL_FUNC_ADD 0x8006
#define GL_FRAMEBUFFER 0x8D40
#define GL_DRAW_FRAMEBUFFER 0x8CA9
#define GL_READ_FRAMEBUFFER 0x8CA8
#define GL_FRAMEBUFFER_BINDING 0x8CA6
#define GL_DRAW_FRAMEBUFFER_BINDING 0x8CA6
#define GL_READ_FRAMEBUFFER_BINDING 0x8CAA
#define GL_FRAMEBUFFER_COMPLETE 0x8CD5
#define GL_COLOR_ATTACHMENT0 0x8CE0
#define GL_COLOR_BUFFER_BIT 0x00004000
#define GL_FRAMEBUFFER_ATTACHMENT_COLOR_ENCODING 0x8210
#define GL_SRGB 0x8C40
#define GL_BACK 0x0405

typedef struct {
#define RUNE_GL_FN(result, name, params) result (RUNE_GL_CALL *name) params;
#include "gl_functions.inc"
#undef RUNE_GL_FN
} RuneGLAPI;

int rune_gl_load_api(RuneGLAPI *gl, RuneGLResolve resolve, char *error, size_t size);

const RuneGLAPI *rune_gl_current_api(const RuneGL *renderer);

/* Compiles and links shader bodies with a matching GLSL / GLSL ES prefix. */
GLuint rune_gl_program(const RuneGLAPI *gl, int es, const char *vertex,
                       const char *fragment, char *error, size_t capacity);

#endif
