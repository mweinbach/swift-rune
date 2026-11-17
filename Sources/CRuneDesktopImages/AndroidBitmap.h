#ifndef RUNE_ANDROID_BITMAP_H
#define RUNE_ANDROID_BITMAP_H

#include "CRuneDesktopImages.h"

int rune_android_bitmap_decode(const uint8_t *data, size_t size, uint32_t max_dimension,
                               uint32_t *loop_count, RuneImageEmit emit, void *context,
                               char *error, size_t error_size);

#endif
