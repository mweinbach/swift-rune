#ifndef RUNE_WIN_LAZY_GL_H
#define RUNE_WIN_LAZY_GL_H
#ifdef _WIN32
#include <windows.h>
#include <GL/gl.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GL_RESULT(type, name, params, args, missing) type APIENTRY rune_lazy_##name params;
#define GL_COMMAND(name, params, args) void APIENTRY rune_lazy_##name params;
#include "LazyGLEntries.inc"
#undef GL_RESULT
#undef GL_COMMAND

PROC rune_win_system_gl_export(const char *name);

#ifdef __cplusplus
}
#endif
#endif
#endif
