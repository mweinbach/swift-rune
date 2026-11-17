#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include "LazyGL.h"

// The import table would otherwise load opengl32 even for a window that stays
// on the CPU for its lifetime. Cache only system exports here. Driver extension
// addresses belong to the calling thread's current WGL context.
static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
static HMODULE library;
static struct {
#define GL_RESULT(type, name, params, args, missing) type (APIENTRY *name) params;
#define GL_COMMAND(name, params, args) void (APIENTRY *name) params;
#include "LazyGLEntries.inc"
#undef GL_RESULT
#undef GL_COMMAND
} api;

static BOOL CALLBACK load_gl(PINIT_ONCE init, PVOID parameter, PVOID *context) {
    (void)init; (void)parameter; (void)context;
    library = LoadLibraryExW(L"opengl32.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (library) {
#define GL_RESULT(type, name, params, args, missing) api.name = (type (APIENTRY *) params)GetProcAddress(library, #name);
#define GL_COMMAND(name, params, args) GL_RESULT(void, name, params, args, 0)
#include "LazyGLEntries.inc"
#undef GL_RESULT
#undef GL_COMMAND
    }
    return TRUE;
}

PROC rune_win_system_gl_export(const char *name) {
    InitOnceExecuteOnce(&once, load_gl, NULL, NULL);
    return library && name ? GetProcAddress(library, name) : NULL;
}

#define GL_RESULT(type, name, params, args, missing)       \
    type APIENTRY rune_lazy_##name params {                \
        InitOnceExecuteOnce(&once, load_gl, NULL, NULL);   \
        return api.name ? api.name args : missing;         \
    }
#define GL_COMMAND(name, params, args)                     \
    void APIENTRY rune_lazy_##name params {                \
        InitOnceExecuteOnce(&once, load_gl, NULL, NULL);   \
        if (api.name) api.name args;                       \
    }
#include "LazyGLEntries.inc"
#undef GL_RESULT
#undef GL_COMMAND
#endif
