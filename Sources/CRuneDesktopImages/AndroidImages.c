#ifdef __ANDROID__
// Request newer declarations from the NDK for the dlsym signatures.
#ifndef __ANDROID_UNAVAILABLE_SYMBOLS_ARE_WEAK__
#define __ANDROID_UNAVAILABLE_SYMBOLS_ARE_WEAK__ 1
#endif
#include "CRuneDesktopImages.h"
#include "AndroidBitmap.h"
#include <android/data_space.h>
#include <android/imagedecoder.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// libjnigraphics added AImageDecoder in API 30 and animation in API 31.
// Resolve these groups at runtime so the same binary loads on API 24.
#define IMAGE_DECODER_API(F) \
    F(AImageDecoder, createFromBuffer) F(AImageDecoder, delete) \
    F(AImageDecoder, getHeaderInfo) F(AImageDecoderHeaderInfo, getWidth) F(AImageDecoderHeaderInfo, getHeight) \
    F(AImageDecoder, setAndroidBitmapFormat) F(AImageDecoder, setDataSpace) F(AImageDecoder, setTargetSize) \
    F(AImageDecoder, setUnpremultipliedRequired) F(AImageDecoder, decodeImage)
#define IMAGE_ANIMATION_API(F) \
    F(AImageDecoder, isAnimated) F(AImageDecoder, getRepeatCount) F(AImageDecoder, advanceFrame) F(AImageDecoder, rewind) \
    F(AImageDecoderFrameInfo, create) F(AImageDecoderFrameInfo, delete) F(AImageDecoder, getFrameInfo) \
    F(AImageDecoderFrameInfo, getDuration)
static struct {
#define DECLARE(type, name) __typeof__(&type##_##name) type##_##name;
    IMAGE_DECODER_API(DECLARE)
    IMAGE_ANIMATION_API(DECLARE)
#undef DECLARE
    bool available, has_animation;
} api;
static pthread_once_t initialized = PTHREAD_ONCE_INIT;

static void load_api(void) {
    void *library = dlopen("libjnigraphics.so", RTLD_LOCAL | RTLD_NOW);
    if (!library) return;
#define LOAD(type, name) if (!(api.type##_##name = dlsym(library, #type "_" #name))) return;
    IMAGE_DECODER_API(LOAD)
    api.available = true;
    IMAGE_ANIMATION_API(LOAD)
    api.has_animation = true;
#undef LOAD
}

static int failure(char *error, size_t capacity, const char *stage, int status) {
    if (error && capacity) {
        if (status == ANDROID_IMAGE_DECODER_SUCCESS) snprintf(error, capacity, "%s", stage);
        else snprintf(error, capacity, "%s (Android decoder status %d)", stage, status);
    }
    return 0;
}

static void fit(int32_t *width, int32_t *height, uint32_t limit) {
    int32_t longest = *width > *height ? *width : *height;
    if (!limit || (uint32_t)longest <= limit) return;
    *width = (int32_t)(((int64_t)*width * limit + longest / 2) / longest);
    *height = (int32_t)(((int64_t)*height * limit + longest / 2) / longest);
    if (!*width) *width = 1;
    if (!*height) *height = 1;
}

static void straighten(uint8_t *out, const uint8_t *in, size_t size) {
    for (size_t i = 0; i < size; i += 4) {
        unsigned alpha = in[i + 3];
        for (size_t j = i; j < i + 3; ++j) {
            unsigned value = alpha ? (in[j] * 255u + alpha / 2) / alpha : 0;
            out[j] = (uint8_t)(value < 255 ? value : 255);
        }
        out[i + 3] = (uint8_t)alpha;
    }
}

// Count before emitting: the Swift cache retains a first still image if the
// complete set of canvases and mip chains exceeds its animation budget.
static int count_frames(AImageDecoder *decoder, int32_t w, int32_t h, bool animated, uint32_t *count) {
    *count = 1;
    if (!animated) return ANDROID_IMAGE_DECODER_SUCCESS;
    int status;
    while ((status = api.AImageDecoder_advanceFrame(decoder)) == ANDROID_IMAGE_DECODER_SUCCESS) {
        ++*count;
        if (!rune_image_animation_fits((uint32_t)w, (uint32_t)h, *count)) {
            *count = 1;
            break;
        }
    }
    if (status != ANDROID_IMAGE_DECODER_SUCCESS && status != ANDROID_IMAGE_DECODER_FINISHED) return status;
    return api.AImageDecoder_rewind(decoder);
}

int rune_image_decode(const uint8_t *data, size_t size, uint32_t max_dimension,
                      uint32_t *loop_count, RuneImageEmit emit, void *context,
                      char *error, size_t capacity) {
    if (!data || !size || !loop_count || !emit)
        return failure(error, capacity, "Missing image data or output", ANDROID_IMAGE_DECODER_BAD_PARAMETER);
    pthread_once(&initialized, load_api);
    if (!api.available)
        return rune_android_bitmap_decode(data, size, max_dimension, loop_count, emit, context, error, capacity);

    AImageDecoder *decoder = NULL;
    int status = api.AImageDecoder_createFromBuffer(data, size, &decoder);
    if (status != ANDROID_IMAGE_DECODER_SUCCESS)
        return failure(error, capacity, "Could not read encoded image", status);

    const AImageDecoderHeaderInfo *header = api.AImageDecoder_getHeaderInfo(decoder);
    int32_t width = api.AImageDecoderHeaderInfo_getWidth(header);
    int32_t height = api.AImageDecoderHeaderInfo_getHeight(header);
    AImageDecoderFrameInfo *info = NULL;
    uint8_t *canvas = NULL, *straight = NULL;
    const char *stage = "Invalid image dimensions";
    int result = 0;
    if (width <= 0 || height <= 0) goto done;
    int32_t w = width, h = height;
    fit(&w, &h, max_dimension > RUNE_IMAGE_MAX_SIDE ? RUNE_IMAGE_MAX_SIDE : max_dimension);
    if (w > (int32_t)RUNE_IMAGE_MAX_SIDE || h > (int32_t)RUNE_IMAGE_MAX_SIDE) goto done;
    size_t stride = (size_t)w * 4, bytes = stride * (size_t)h;
    if (bytes > RUNE_IMAGE_MAX_BYTES) goto done;

    stage = "Cannot configure sRGB image output";
    status = api.AImageDecoder_setAndroidBitmapFormat(decoder, ANDROID_BITMAP_FORMAT_RGBA_8888);
    if (status != ANDROID_IMAGE_DECODER_SUCCESS) goto done;
    status = api.AImageDecoder_setDataSpace(decoder, ADATASPACE_SRGB);
    if (status != ANDROID_IMAGE_DECODER_SUCCESS) goto done;
    if (w != width || h != height) {
        stage = "Cannot resize image";
        status = api.AImageDecoder_setTargetSize(decoder, w, h);
        if (status != ANDROID_IMAGE_DECODER_SUCCESS) goto done;
    }

    bool animated = api.has_animation && api.AImageDecoder_isAnimated(decoder);
    uint32_t frames;
    stage = "Cannot read animation frames";
    status = count_frames(decoder, w, h, animated, &frames);
    if (status != ANDROID_IMAGE_DECODER_SUCCESS) goto done;
    bool gif = size >= 6 && (!memcmp(data, "GIF87a", 6) || !memcmp(data, "GIF89a", 6));
    *loop_count = gif ? UINT32_MAX : 0;
    if (api.has_animation && (animated || gif)) {
        int32_t repeats = api.AImageDecoder_getRepeatCount(decoder);
        if (repeats < 0) { status = repeats; goto done; }
        if (repeats == ANDROID_IMAGE_DECODER_INFINITE) *loop_count = 0;
        else if (gif) *loop_count = repeats ? (uint32_t)repeats : UINT32_MAX;
        else *loop_count = (uint32_t)repeats + 1;
        info = api.AImageDecoderFrameInfo_create();
        if (!info) goto done;
    }

    // Android resamples/composites alpha in premultiplied space. Preserve the
    // previous composited canvas and convert only the copy handed to Rune.
    bool direct = frames == 1 &&
        api.AImageDecoder_setUnpremultipliedRequired(decoder, true) == ANDROID_IMAGE_DECODER_SUCCESS;
    stage = "Cannot allocate decoded image buffer";
    canvas = calloc(1, bytes);
    if (!direct) straight = malloc(bytes);
    if (!canvas || (!direct && !straight)) goto done;
    for (uint32_t i = 0; i < frames; ++i) {
        double seconds = 0.1;
        if (info) {
            stage = "Cannot read animation timing";
            status = api.AImageDecoder_getFrameInfo(decoder, info);
            if (status != ANDROID_IMAGE_DECODER_SUCCESS) goto done;
            seconds = api.AImageDecoderFrameInfo_getDuration(info) / 1e9;
        }
        stage = "Cannot decode image pixels";
        status = api.AImageDecoder_decodeImage(decoder, canvas, stride, bytes);
        if (status != ANDROID_IMAGE_DECODER_SUCCESS) goto done;
        if (!direct) straighten(straight, canvas, bytes);
        stage = "Image frame rejected";
        if (!emit(context, (uint32_t)w, (uint32_t)h, direct ? canvas : straight, stride, seconds)) goto done;
        if (i + 1 < frames) {
            stage = "Cannot advance animation";
            status = api.AImageDecoder_advanceFrame(decoder);
            if (status != ANDROID_IMAGE_DECODER_SUCCESS) goto done;
        }
    }
    result = 1;
done:
    free(straight);
    free(canvas);
    if (info) api.AImageDecoderFrameInfo_delete(info);
    api.AImageDecoder_delete(decoder);
    return result ? 1 : failure(error, capacity, stage, status);
}
#endif
