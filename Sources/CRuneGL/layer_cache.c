#include "layer_cache.h"
#include <math.h>
#include <stdlib.h>

/* Keep hot lookups independent of painter order. The LRU contains exactly
 * the textures charged to the byte budget. The frame pins textures referenced
 * by its markers before admitting new ones, since the runtime may have omitted
 * those markers' cached children already. */
enum { CACHE_BUCKETS = 521 };
typedef struct Entry {
    struct Entry *newer, *older, *next_hash;
    RuneGLCachedLayer id;
    GLuint texture;
    uint64_t bytes, pinned_frame;
} Entry;

struct RuneLayerCache {
    const RuneGLAPI *gl;
    Entry *newest, *oldest, *buckets[CACHE_BUCKETS];
    GLuint read_fbo, write_fbo;
    uint64_t budget, frame;
    RuneGLLayerCacheStats stats;
};

static uint64_t unpack_key(const float lanes[4]) {
    uint64_t result = 0;
    for (int i = 0; i < 4; i++) {
        uint64_t lane = (uint64_t)roundf(fminf(65535, fmaxf(0, lanes[i])));
        result |= lane << (16 * i);
    }
    return result;
}

RuneGLCachedLayer rune_cache_key(const float *p) {
    return (RuneGLCachedLayer){unpack_key(p + 4), unpack_key(p + 20)};
}

static unsigned int bucket(uint64_t key) {
    return (unsigned int)(key % CACHE_BUCKETS);
}

static Entry *find_key(const RuneLayerCache *cache, uint64_t key) {
    for (Entry *e = cache->buckets[bucket(key)]; e; e = e->next_hash)
        if (e->id.key == key) return e;
    return NULL;
}

static void unlink_lru(RuneLayerCache *cache, Entry *e) {
    if (e->newer) e->newer->older = e->older; else cache->newest = e->older;
    if (e->older) e->older->newer = e->newer; else cache->oldest = e->newer;
}

static void mark_newest(RuneLayerCache *cache, Entry *e) {
    e->older = cache->newest;
    e->newer = NULL;
    if (e->older) e->older->newer = e; else cache->oldest = e;
    cache->newest = e;
}

static void evict(RuneLayerCache *cache, Entry *e) {
    Entry **link = &cache->buckets[bucket(e->id.key)];
    while (*link != e) link = &(*link)->next_hash;
    *link = e->next_hash;
    unlink_lru(cache, e);
    cache->gl->DeleteTextures(1, &e->texture);
    cache->stats.bytes -= e->bytes;
    cache->stats.count--;
    cache->stats.evictions++;
    cache->stats.generation++;
    free(e);
}

RuneLayerCache *rune_cache_create(const RuneGLAPI *gl) {
    RuneLayerCache *cache = calloc(1, sizeof(*cache));
    if (cache) { cache->gl = gl; cache->budget = 64u * 1024u * 1024u; }
    return cache;
}

void rune_cache_clear(RuneLayerCache *cache) {
    while (cache->oldest) evict(cache, cache->oldest);
}

void rune_cache_destroy(RuneLayerCache *cache) {
    if (!cache) return;
    rune_cache_clear(cache);
    cache->gl->DeleteFramebuffers(1, &cache->read_fbo);
    cache->gl->DeleteFramebuffers(1, &cache->write_fbo);
    free(cache);
}

void rune_cache_budget(RuneLayerCache *cache, uint64_t bytes) {
    cache->budget = bytes;
    while (cache->stats.bytes > bytes) evict(cache, cache->oldest);
}

RuneGLLayerCacheStats rune_cache_stats(const RuneLayerCache *cache) { return cache->stats; }
uint64_t rune_cache_budget_bytes(const RuneLayerCache *cache) { return cache->budget; }

int rune_cache_contains(const RuneLayerCache *cache, RuneGLCachedLayer id) {
    Entry *e = find_key(cache, id.key);
    return e && e->id.signature == id.signature;
}

size_t rune_cache_entries(const RuneLayerCache *cache, RuneGLCachedLayer *out, size_t capacity) {
    size_t count = (size_t)cache->stats.count;
    if (out && capacity) {
        size_t i = 0;
        for (Entry *e = cache->newest; e && i < capacity; e = e->older) out[i++] = e->id;
    }
    return count;
}

void rune_cache_begin(RuneLayerCache *cache) {
    cache->frame++;
    cache->stats.passes = 0;
}

int rune_cache_pin(RuneLayerCache *cache, RuneGLCachedLayer id) {
    Entry *e = find_key(cache, id.key);
    if (!e || e->id.signature != id.signature) return 0;
    e->pinned_frame = cache->frame;
    return 1;
}

GLuint rune_cache_lookup(RuneLayerCache *cache, RuneGLCachedLayer id) {
    Entry *e = find_key(cache, id.key);
    if (!e || e->id.signature != id.signature) {
        cache->stats.misses++;
        return 0;
    }
    unlink_lru(cache, e);
    mark_newest(cache, e);
    cache->stats.hits++;
    return e->texture;
}

void rune_cache_record_pass(RuneLayerCache *cache) { cache->stats.passes++; }

static GLuint copy_region(RuneLayerCache *cache, GLenum format, GLuint source,
                          int x, int y, int width, int height) {
    const RuneGLAPI *gl = cache->gl;
    if (!cache->read_fbo) gl->GenFramebuffers(1, &cache->read_fbo);
    if (!cache->write_fbo) gl->GenFramebuffers(1, &cache->write_fbo);
    GLuint texture = 0;
    gl->GenTextures(1, &texture);
    gl->ActiveTexture(GL_TEXTURE0);
    gl->BindTexture(GL_TEXTURE_2D, texture);
    gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    gl->TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    gl->TexImage2D(GL_TEXTURE_2D, 0, (GLint)format, width, height, 0, GL_RGBA,
                   format == GL_RGBA16F ? GL_HALF_FLOAT : GL_UNSIGNED_BYTE, NULL);
    gl->BindFramebuffer(GL_READ_FRAMEBUFFER, cache->read_fbo);
    gl->FramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, source, 0);
    gl->BindFramebuffer(GL_DRAW_FRAMEBUFFER, cache->write_fbo);
    gl->FramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
    int complete = gl->CheckFramebufferStatus(GL_READ_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE &&
                   gl->CheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
    if (complete) {
        gl->Disable(GL_SCISSOR_TEST);
        gl->BlitFramebuffer(x, y, x + width, y + height, 0, 0, width, height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
    }
    gl->FramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, 0, 0);
    gl->FramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, 0, 0);
    if (!complete) { gl->DeleteTextures(1, &texture); return 0; }
    cache->stats.target_allocations++;
    return texture;
}

int rune_cache_store(RuneLayerCache *cache, RuneGLCachedLayer id, GLenum format, GLuint source,
                     int x, int y, int width, int height, int adopt) {
    if (width <= 0 || height <= 0) return 0;
    const uint64_t bytes = (uint64_t)width * (uint64_t)height * (format == GL_RGBA16F ? 8u : 4u);
    if (bytes > cache->budget) return 0;
    Entry *old = find_key(cache, id.key);
    if (old) {
        // Two conflicting signatures for one key can coexist in caller-built
        // frames. Keep any earlier texture still needed later in the frame.
        if (old->pinned_frame == cache->frame) return 0;
        evict(cache, old);
    }
    Entry *candidate = cache->oldest;
    while (cache->stats.bytes > cache->budget - bytes) {
        while (candidate && candidate->pinned_frame == cache->frame) candidate = candidate->newer;
        if (!candidate) return 0;
        Entry *next = candidate->newer;
        evict(cache, candidate);
        candidate = next;
    }
    Entry *e = calloc(1, sizeof(*e));
    if (!e) return 0;
    e->texture = adopt ? source : copy_region(cache, format, source, x, y, width, height);
    if (!e->texture) { free(e); return 0; }
    e->id = id;
    e->bytes = bytes;
    e->pinned_frame = cache->frame;
    unsigned int index = bucket(id.key);
    e->next_hash = cache->buckets[index];
    cache->buckets[index] = e;
    mark_newest(cache, e);
    cache->stats.allocations++;
    cache->stats.generation++;
    cache->stats.count++;
    cache->stats.bytes += bytes;
    return 1;
}
