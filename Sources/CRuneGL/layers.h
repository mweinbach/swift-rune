#ifndef RUNE_GL_LAYERS_H
#define RUNE_GL_LAYERS_H

#include "gl_api.h"
#include "RuneGLLayerCache.h"

typedef struct RuneGLLayers RuneGLLayers;

void rune_layers_cache_budget(RuneGLLayers *layers, uint64_t bytes);
void rune_layers_cache_clear(RuneGLLayers *layers);
void rune_layers_window_rest(RuneGLLayers *layers, int all);
RuneGLLayerStorage rune_layers_storage(const RuneGLLayers *layers);
RuneGLLayerCacheStats rune_layers_cache_stats(RuneGLLayers *layers);
int rune_layers_cache_contains(RuneGLLayers *layers, RuneGLCachedLayer id);
size_t rune_layers_cache_entries(RuneGLLayers *layers, RuneGLCachedLayer *out, size_t capacity);
void rune_layers_cache_begin(RuneGLLayers *layers);
int rune_layers_cache_composite(RuneGLLayers *layers, const float *marker, const void *instance128);

RuneGLLayers *rune_layers_create(const RuneGLAPI *gl, int es, const char *vertex,
                                 const char *fragment, char *error, size_t capacity);
void rune_layers_destroy(RuneGLLayers *layers);
int rune_layers_configure_present(RuneGLLayers *layers, const char *vertex, const char *fragment,
                                  char *error, size_t capacity);
int rune_layers_configure_blur(RuneGLLayers *layers, const char *vertex, const char *fragment,
                               char *error, size_t capacity);
int rune_layers_frame(RuneGLLayers *layers, int width, int height, int srgb_blend, int production,
                      char *error, size_t capacity);
void rune_layers_clear_root(RuneGLLayers *layers, const float *clear, GLuint atlas);
int rune_layers_marker(RuneGLLayers *layers, int kind, const float *primitive,
                       char *error, size_t capacity);
int rune_layers_frame_marker(RuneGLLayers *layers, int kind, const float *adapted36,
                             const void *instance128, char *error, size_t capacity);
int rune_layers_additive(const RuneGLLayers *layers);
int rune_layers_plan(RuneGLLayers *layers, const void *instances, size_t count, int width, int height,
                     char *error, size_t capacity);
void rune_layers_target_geometry(const RuneGLLayers *layers, int *x, int *y, int *width, int *height);
int rune_layers_should_skip(RuneGLLayers *layers, const void *instance128);
int rune_layers_effect_begin(RuneGLLayers *layers, const void *instance128, GLuint *effect_fbo,
                            GLuint *backdrop_tex, int clip_xywh[4], char *error, size_t capacity);
void rune_layers_effect_end(RuneGLLayers *layers, const int clip_xywh[4], int commit);
int rune_layers_present(RuneGLLayers *layers, unsigned framebuffer, char *error, size_t capacity);

#endif
