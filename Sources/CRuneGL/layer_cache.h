#ifndef RUNE_GL_PRIVATE_LAYER_CACHE_H
#define RUNE_GL_PRIVATE_LAYER_CACHE_H
#include "gl_api.h"
#include "RuneGLLayerCache.h"

typedef struct RuneLayerCache RuneLayerCache;
RuneLayerCache *rune_cache_create(const RuneGLAPI *gl);
void rune_cache_destroy(RuneLayerCache *cache);
void rune_cache_clear(RuneLayerCache *cache);
void rune_cache_budget(RuneLayerCache *cache, uint64_t budget);
uint64_t rune_cache_budget_bytes(const RuneLayerCache *cache);
RuneGLLayerCacheStats rune_cache_stats(const RuneLayerCache *cache);
size_t rune_cache_entries(const RuneLayerCache *cache, RuneGLCachedLayer *out, size_t capacity);
int rune_cache_contains(const RuneLayerCache *cache, RuneGLCachedLayer id);
void rune_cache_begin(RuneLayerCache *cache);
int rune_cache_pin(RuneLayerCache *cache, RuneGLCachedLayer id);
RuneGLCachedLayer rune_cache_key(const float *instance128);
GLuint rune_cache_lookup(RuneLayerCache *cache, RuneGLCachedLayer key);
void rune_cache_record_pass(RuneLayerCache *cache);
/* Transfers ownership of the source texture on success when adopt is true. */
int rune_cache_store(RuneLayerCache *cache, RuneGLCachedLayer key, GLenum format, GLuint source_texture,
                     int source_x, int source_y, int width, int height, int adopt);
#endif
