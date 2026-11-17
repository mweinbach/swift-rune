#ifndef RUNE_GL_LAYER_CACHE_H
#define RUNE_GL_LAYER_CACHE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct RuneGL RuneGL;
typedef struct { uint64_t key, signature; } RuneGLCachedLayer;
typedef struct {
    /* Resident textures, their bytes, and cumulative cache admissions. */
    uint64_t count, bytes, allocations, hits, misses, evictions, passes, generation;
    /* Live retained and isolated scope storage, excluding parked targets, the
     * presentation target and filter scratch. Allocation count is cumulative. */
    uint64_t active_count, active_bytes, target_allocations;
} RuneGLLayerCacheStats;

/* Cache entries belong to the current renderer. The caller clears them before
 * assigning the renderer to a different runtime. All operations run with its
 * context current. Querying with a null result returns the required count. */
void rune_gl_layer_cache_budget(RuneGL *renderer, uint64_t bytes);
void rune_gl_layer_cache_clear(RuneGL *renderer);
RuneGLLayerCacheStats rune_gl_layer_cache_stats(RuneGL *renderer);
int rune_gl_layer_cache_contains(RuneGL *renderer, RuneGLCachedLayer layer);
size_t rune_gl_layer_cache_entries(RuneGL *renderer, RuneGLCachedLayer *out, size_t capacity);

#ifdef __cplusplus
}
#endif
#endif
