#ifndef RUNE_GL_FRAME_DAMAGE_H
#define RUNE_GL_FRAME_DAMAGE_H

#include <stddef.h>

typedef struct { int left, top, right, bottom; } RuneDamageRect;
typedef struct {
    unsigned char *last;
    size_t count, capacity;
    RuneDamageRect *blocks;
    size_t block_capacity;
    int blocks_valid;
    void *table;
    size_t table_capacity;
    int valid, width, height, srgb;
    float clear[4];
} RuneDamageHistory;

/* -1 redraws the whole root, 0 only presents it, 1..4 scissor replay to the rectangles. */
int rune_damage_plan(RuneDamageHistory *history, const void *instances, size_t count,
                     int width, int height, const float *clear, int srgb, RuneDamageRect rects[4]);
typedef struct { size_t first, count; } RuneDamageRange;
/* Up to eight ordered instance ranges intersecting this scissor. */
int rune_damage_ranges(const RuneDamageHistory *history, RuneDamageRect rect, RuneDamageRange out[8]);
void rune_damage_release(RuneDamageHistory *history);

#endif
