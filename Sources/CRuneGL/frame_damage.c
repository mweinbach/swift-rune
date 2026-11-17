#include "frame_damage.h"

#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum { stride = 128, max_rects = 4, many = 256, block_size = 32 };
typedef struct {
    const unsigned char *instance;
    uint64_t hash;
    ptrdiff_t difference;
} Entry;

static const unsigned char *item(const unsigned char *items, size_t i) { return items + i * stride; }

static uint64_t hash_instance(const unsigned char *p) {
    uint64_t hash = UINT64_C(14695981039346656037);
    for (size_t i = 0; i < stride; i += 4) {
        uint32_t word;
        memcpy(&word, p + i, sizeof word);
        hash = (hash ^ word) * UINT64_C(1099511628211);
    }
    hash ^= hash >> 33;
    hash *= UINT64_C(0xff51afd7ed558ccd);
    return hash ^ (hash >> 33);
}

/* Hashes select buckets. Always compare the complete instance, including the packed clip. */
static Entry *entry(Entry *table, size_t capacity, const unsigned char *p) {
    uint64_t h = hash_instance(p);
    size_t i = (size_t)h & (capacity - 1);
    while (table[i].instance && (table[i].hash != h || memcmp(table[i].instance, p, stride)))
        i = (i + 1) & (capacity - 1);
    table[i].instance = p;
    table[i].hash = h;
    return table + i;
}

static int64_t area(RuneDamageRect r) { return (int64_t)(r.right - r.left) * (r.bottom - r.top); }

static RuneDamageRect join(RuneDamageRect a, RuneDamageRect b) {
    return (RuneDamageRect){a.left < b.left ? a.left : b.left, a.top < b.top ? a.top : b.top,
                            a.right > b.right ? a.right : b.right, a.bottom > b.bottom ? a.bottom : b.bottom};
}

static int near(RuneDamageRect a, RuneDamageRect b) {
    return (int64_t)a.left <= (int64_t)b.right + 16 && (int64_t)b.left <= (int64_t)a.right + 16 &&
           (int64_t)a.top <= (int64_t)b.bottom + 16 && (int64_t)b.top <= (int64_t)a.bottom + 16;
}

static void add(RuneDamageRect *rects, int *n, RuneDamageRect r) {
    for (;;) {
        int best = -1;
        int64_t growth = INT64_MAX;
        for (int i = 0; i < *n; i++) {
            if (near(r, rects[i])) { best = i; break; }
            int64_t cost = area(join(r, rects[i])) - area(rects[i]);
            if (*n == max_rects && cost < growth) { best = i; growth = cost; }
        }
        if (best < 0) { rects[(*n)++] = r; return; }
        r = join(r, rects[best]);
        rects[best] = rects[--(*n)];
    }
}

static int bounds(const unsigned char *bytes, int width, int height, RuneDamageRect *result) {
    float p[28];
    memcpy(p, bytes, sizeof p);
    float kind = p[17];
    double grow = 1.0 + p[18] * 2.0;
    if (kind == 1) grow = 1.0 + p[18] * 3.0;
    if (kind == 2 || kind == 3 || (kind >= 5 && kind <= 7)) grow = 1.0;
    if (!isfinite(grow) || grow < 0 || !isfinite(p[0]) || !isfinite(p[1]) ||
        !isfinite(p[2]) || p[2] < 0 || !isfinite(p[3]) || p[3] < 0) return 0;
    double x0 = p[0] - grow, y0 = p[1] - grow;
    double x1 = (double)p[0] + p[2] + grow, y1 = (double)p[1] + p[3] + grow;
    if (kind == 2 && p[16] != 0) {
        double radius = hypot(p[2] + 2.0, p[3] + 2.0) / 2.0;
        double cx = p[0] + p[2] / 2.0, cy = p[1] + p[3] / 2.0;
        x0 = cx - radius; y0 = cy - radius; x1 = cx + radius; y1 = cy + radius;
    }
    for (int i = 24; i < 28; i++) if (isnan(p[i])) return 0;
    x0 = fmax(0, floor(fmax(x0, p[24]) - 1.0));
    y0 = fmax(0, floor(fmax(y0, p[25]) - 1.0));
    x1 = fmin(width, ceil(fmin(x1, p[26]) + 1.0));
    y1 = fmin(height, ceil(fmin(y1, p[27]) + 1.0));
    *result = x1 > x0 && y1 > y0 ? (RuneDamageRect){(int)x0, (int)y0, (int)x1, (int)y1} : (RuneDamageRect){0};
    return 1;
}

static int add_instance(RuneDamageRect *rects, int *n, const unsigned char *bytes, int width, int height) {
    RuneDamageRect rect;
    if (!bounds(bytes, width, height, &rect)) return 0;
    if (rect.right > rect.left) add(rects, n, rect);
    return 1;
}

/* A few independent edits can bracket thousands of identical instances. Identify those
 * edits directly before building the multiset for insertions and general reordering. */
static int sparse_edits(const unsigned char *old, const unsigned char *items, size_t count,
                        int w, int h, RuneDamageRect *rects, int *n) {
    size_t changed[8], edits = 0;
    for (size_t i = 0; i < count; i++) {
        if (!memcmp(item(old, i), item(items, i), stride)) continue;
        if (edits == sizeof changed / sizeof changed[0]) return 0;
        changed[edits++] = i;
    }
    for (size_t a = 0; a < edits; a++) {
        const unsigned char *before = item(old, changed[a]);
        for (size_t b = 0; b < edits; b++) {
            if (a != b && !memcmp(before, item(items, changed[b]), stride)) return 0;
        }
    }
    for (size_t a = 0; a < edits; a++) {
        if (!add_instance(rects, n, item(old, changed[a]), w, h) ||
            !add_instance(rects, n, item(items, changed[a]), w, h)) { *n = -1; break; }
    }
    return 1;
}

static int diff(RuneDamageHistory *h, const unsigned char *old, size_t old_n, const unsigned char *new_items,
                size_t new_n, int w, int height, RuneDamageRect *rects) {
    int n = 0;
    // A large scrolling/replaced stream usually differs throughout. A conservative whole draw
    // after this small sample avoids hashing thousands of quads to discover that result.
    if (old_n == new_n && old_n > many) {
        unsigned different = 0;
        for (size_t k = 0; k < 16; ++k) {
            size_t index = k * ((old_n - 1) / 15);
            different += memcmp(item(old, index), item(new_items, index), stride) != 0;
        }
        if (different == 16) return -1;
    }
    if (old_n <= 1 && new_n <= 1) {
        if (old_n && !add_instance(rects, &n, old, w, height)) return -1;
        if (new_n && !add_instance(rects, &n, new_items, w, height)) return -1;
    } else if (old_n == new_n && sparse_edits(old, new_items, old_n, w, height, rects, &n)) {
        if (n < 0) return -1;
    } else {
        if (new_n > old_n && new_n - old_n > many) return -1;
        size_t cap = 8;
        if (old_n > SIZE_MAX / 4 - new_n) return -1;
        while (cap < 2 * (old_n + new_n)) cap *= 2;
        if (cap > SIZE_MAX / sizeof(Entry)) return -1;
        if (h->table_capacity < cap) {
            Entry *table = realloc(h->table, cap * sizeof(Entry));
            if (!table) return -1;
            h->table = table;
            h->table_capacity = cap;
        }
        Entry *table = h->table;
        memset(table, 0, cap * sizeof *table);
        for (size_t i = 0; i < old_n; i++) entry(table, cap, item(old, i))->difference++;
        size_t added = 0;
        for (size_t i = 0; i < new_n; i++) {
            if (--entry(table, cap, item(new_items, i))->difference < 0 && ++added > many) return -1;
        }
        /* Reordered unchanged primitives may cover each other anywhere. Primitives whose
         * counts differ are safe to remove from both order sequences: their bounds are dirty. */
        size_t i = 0, j = 0;
        while (i < old_n || j < new_n) {
            while (i < old_n && entry(table, cap, item(old, i))->difference) i++;
            while (j < new_n && entry(table, cap, item(new_items, j))->difference) j++;
            if (i == old_n || j == new_n) {
                if (i != old_n || j != new_n) return -1;
                break;
            }
            if (memcmp(item(old, i++), item(new_items, j++), stride)) return -1;
        }
        for (size_t k = 0; k < cap; k++) {
            if (table[k].difference && !add_instance(rects, &n, table[k].instance, w, height)) return -1;
        }
    }
    int64_t pixels = 0;
    for (int k = 0; k < n; k++) pixels += area(rects[k]);
    return pixels > 0.6 * w * height ? -1 : n;
}

/* Small consecutive paint-order blocks bound a scissor replay without sorting or changing
 * texture-page ordering. Most blocks survive a sparse update byte-for-byte. */
static void update_blocks(RuneDamageHistory *h, const unsigned char *items, size_t count,
                          int w, int height, int same_shape) {
    size_t blocks = (count + block_size - 1) / block_size;
    size_t old_blocks = h->block_capacity;
    if (blocks > old_blocks) {
        RuneDamageRect *new_blocks = realloc(h->blocks, blocks * sizeof *new_blocks);
        if (!new_blocks) { free(h->blocks); h->blocks = NULL; h->block_capacity = 0; return; }
        h->blocks = new_blocks;
        h->block_capacity = blocks;
    }
    for (size_t b = 0; b < blocks; b++) {
        size_t first = b * block_size, end = first + block_size;
        if (end > count) end = count;
        if (same_shape && b < old_blocks && end <= h->count &&
            (end - first == block_size || end == h->count) &&
            !memcmp(item(items, first), item(h->last, first), (end - first) * stride)) continue;
        RuneDamageRect box = {0};
        for (size_t i = first; i < end; ++i) {
            RuneDamageRect r;
            if (!bounds(item(items, i), w, height, &r)) { box = (RuneDamageRect){0, 0, w, height}; break; }
            if (r.right > r.left) box = box.right > box.left ? join(box, r) : r;
        }
        h->blocks[b] = box;
    }
}

int rune_damage_ranges(const RuneDamageHistory *h, RuneDamageRect rect, RuneDamageRange out[8]) {
    if (!h->blocks || h->count <= block_size) {
        out[0] = (RuneDamageRange){0, h->count};
        return h->count ? 1 : 0;
    }
    int n = 0;
    for (size_t first = 0; first < h->count; first += block_size) {
        RuneDamageRect b = h->blocks[first / block_size];
        if (b.right <= rect.left || b.bottom <= rect.top || b.left >= rect.right || b.top >= rect.bottom) continue;
        size_t end = first + block_size;
        if (end > h->count) end = h->count;
        if (n && (n == 8 || first == out[n - 1].first + out[n - 1].count))
            out[n - 1].count = end - out[n - 1].first;
        else
            out[n++] = (RuneDamageRange){first, end - first};
    }
    return n;
}

int rune_damage_plan(RuneDamageHistory *h, const void *instances, size_t count, int w, int height,
                     const float *clear, int srgb, RuneDamageRect rects[4]) {
    const unsigned char *new_items = instances;
    size_t prefix = 0, old_end = h->count, new_end = count;
    int same_shape = h->valid && h->width == w && h->height == height && h->srgb == srgb &&
                     !memcmp(clear, h->clear, sizeof h->clear);
    if (same_shape) {
        while (prefix < old_end && prefix < new_end && !memcmp(item(h->last, prefix), item(new_items, prefix), stride)) prefix++;
        if (prefix == old_end && prefix == new_end) return 0;
        while (old_end > prefix && new_end > prefix && !memcmp(item(h->last, old_end - 1), item(new_items, new_end - 1), stride)) {
            old_end--; new_end--;
        }
    }
    /* The reference shader, layers, backdrop effects, and native/GPU driven content can
     * affect pixels outside flat primitive bounds. Only known flat ABI draws may use this path. */
    for (size_t i = prefix; i < new_end; i++) {
        float kind;
        memcpy(&kind, item(new_items, i) + 17 * sizeof(float), sizeof kind);
        if (!(kind >= 0 && kind <= 11) || (kind >= 8 && kind < 10) || floorf(kind) != kind) {
            h->valid = 0;
            return -1;
        }
    }
    int n = -1;
    if (same_shape) {
        const unsigned char *old = old_end > prefix ? item(h->last, prefix) : NULL;
        const unsigned char *next = new_end > prefix ? item(new_items, prefix) : NULL;
        n = diff(h, old, old_end - prefix, next, new_end - prefix, w, height, rects);
    }
    if (n > 0) {
        update_blocks(h, new_items, count, w, height, same_shape && h->blocks_valid);
        h->blocks_valid = h->blocks != NULL;
    } else {
        h->blocks_valid = 0;
    }
    if (count > h->capacity) {
        unsigned char *larger = realloc(h->last, count * stride);
        if (!larger) { h->valid = 0; return -1; }
        h->last = larger;
        h->capacity = count;
    }
    size_t end_to_copy = count == h->count ? new_end : count;
    if (end_to_copy > prefix)
        memcpy(h->last + prefix * stride, item(new_items, prefix), (end_to_copy - prefix) * stride);
    h->width = w; h->height = height; h->srgb = srgb; h->count = count; h->valid = 1;
    memcpy(h->clear, clear, sizeof h->clear);
    return n;
}

void rune_damage_release(RuneDamageHistory *h) {
    free(h->blocks);
    free(h->last);
    free(h->table);
    memset(h, 0, sizeof *h);
}
