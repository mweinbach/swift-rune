#ifndef RUNE_DESKTOP_IMAGES_H
#define RUNE_DESKTOP_IMAGES_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RUNE_IMAGE_MAX_SIDE 8192u
#define RUNE_IMAGE_MAX_BYTES (256u * 1024u * 1024u)

/* Retained UI frames have a straight RGBA canvas plus the premultiplied mip chain. */
static inline int rune_image_animation_fits(uint32_t width, uint32_t height, uint32_t frames) {
    if (!width || !height || width > RUNE_IMAGE_MAX_SIDE || height > RUNE_IMAGE_MAX_SIDE)
        return 0;
    uint64_t bytes = (uint64_t)width * height * 4;
    for (;;) {
        bytes += (uint64_t)width * height * 4;
        if (width == 1 && height == 1) break;
        width = width > 1 ? width / 2 : 1;
        height = height > 1 ? height / 2 : 1;
    }
    return frames <= RUNE_IMAGE_MAX_BYTES / bytes;
}

/* Pixels are straight-alpha sRGB RGBA and remain valid for the callback only. */
typedef int (*RuneImageEmit)(void *context, uint32_t width, uint32_t height,
                             const uint8_t *straight_rgba, size_t row_bytes,
                             double duration_seconds);

/* A zero max_dimension preserves the original size. GIF reports its raw
 * repeat count, UINT32_MAX when absent, and zero for unlimited repetition.
 * WebP reports its total play count. Return zero to stop frame delivery. */
int rune_image_decode(const uint8_t *data, size_t size, uint32_t max_dimension,
                      uint32_t *loop_count, RuneImageEmit emit, void *context,
                      char *error, size_t error_size);

#ifdef __ANDROID__
/* Binds the framework bitmap decoder to this application's class loader. */
void rune_image_android_attach(void *activity);
#endif

#ifdef __cplusplus
}
#endif
#endif
