#if defined(__ANDROID__)
#include "AndroidBitmap.h"
#include <android/bitmap.h>
#include <android/native_activity.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Activity and JNIEnv are thread-local. The VM and this global class reference
// survive Activity recreation and can be used from the image cache's workers.
static JavaVM *vm;
static _Atomic(jclass) decoder_class;
static jmethodID decode_bitmap;
static jmethodID recycle_bitmap;
static pthread_mutex_t attach_lock = PTHREAD_MUTEX_INITIALIZER;

void rune_image_android_attach(void *raw) {
    ANativeActivity *activity = raw;
    if (!activity || !activity->vm || !activity->env || !activity->clazz || atomic_load(&decoder_class))
        return;
    JNIEnv *env = activity->env;
    pthread_mutex_lock(&attach_lock);
    if (atomic_load(&decoder_class)) goto done;
    if ((*env)->PushLocalFrame(env, 8) != JNI_OK) goto done;
    jclass activity_class = (*env)->GetObjectClass(env, activity->clazz);
    if (!activity_class) goto pop;
    jmethodID get_loader = (*env)->GetMethodID(env, activity_class, "getClassLoader", "()Ljava/lang/ClassLoader;");
    if (!get_loader) goto pop;
    jobject loader = (*env)->CallObjectMethod(env, activity->clazz, get_loader);
    if ((*env)->ExceptionCheck(env) || !loader) goto pop;
    jclass loader_class = (*env)->GetObjectClass(env, loader);
    if (!loader_class) goto pop;
    jmethodID load = (*env)->GetMethodID(env, loader_class, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
    if (!load) goto pop;
    jstring name = (*env)->NewStringUTF(env, "dev.rune.RuneImages");
    if (!name) goto pop;
    jclass local = (jclass)(*env)->CallObjectMethod(env, loader, load, name);
    if ((*env)->ExceptionCheck(env) || !local) goto pop;
    decode_bitmap = (*env)->GetStaticMethodID(env, local, "decode", "([BII[I)Landroid/graphics/Bitmap;");
    if (!decode_bitmap) goto pop;
    jclass bitmap = (*env)->FindClass(env, "android/graphics/Bitmap");
    if (!bitmap) goto pop;
    recycle_bitmap = (*env)->GetMethodID(env, bitmap, "recycle", "()V");
    if (!recycle_bitmap) goto pop;
    vm = activity->vm;
    atomic_store(&decoder_class, (jclass)(*env)->NewGlobalRef(env, local));
pop:
    (*env)->PopLocalFrame(env, NULL);
done:
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    pthread_mutex_unlock(&attach_lock);
}

static uint8_t unpremultiply(uint8_t color, uint8_t alpha) {
    if (alpha == 0) return 0;
    unsigned straight = ((unsigned)color * 255 + alpha / 2) / alpha;
    return straight > 255 ? 255 : (uint8_t)straight;
}

static int emit_bitmap(const AndroidBitmapInfo *info, const uint8_t *pixels,
                       int orientation, int premultiplied, RuneImageEmit emit, void *context) {
    if (orientation < 1 || orientation > 8) orientation = 1;
    if (orientation == 1 && !premultiplied)
        return emit(context, info->width, info->height, pixels, info->stride, 0.1);
    int swap_axes = orientation >= 5;
    int flip_x = orientation == 2 || orientation == 3 || orientation == 7 || orientation == 8;
    int flip_y = orientation == 3 || orientation == 4 || orientation == 6 || orientation == 7;
    uint32_t width = swap_axes ? info->height : info->width;
    uint32_t height = swap_axes ? info->width : info->height;
    size_t row_bytes = width * 4u;
    uint8_t *output = malloc(row_bytes * height);
    if (!output) return 0;
    for (uint32_t y = 0; y < info->height; ++y) {
        const uint8_t *source = pixels + (size_t)y * info->stride;
        uint32_t sy = flip_y ? info->height - 1 - y : y;
        for (uint32_t x = 0; x < info->width; ++x, source += 4) {
            uint32_t sx = flip_x ? info->width - 1 - x : x;
            size_t index = swap_axes ? (size_t)sx * width + sy : (size_t)sy * width + sx;
            uint8_t *pixel = output + index * 4;
            if (premultiplied && source[3] != 255) {
                for (unsigned c = 0; c < 3; ++c) pixel[c] = unpremultiply(source[c], source[3]);
                pixel[3] = source[3];
            } else {
                memcpy(pixel, source, 4);
            }
        }
    }
    int result = emit(context, width, height, output, row_bytes, 0.1);
    free(output);
    return result;
}

int rune_android_bitmap_decode(const uint8_t *data, size_t size, uint32_t max_dimension,
                               uint32_t *loop_count, RuneImageEmit emit, void *context,
                               char *error, size_t error_size) {
    const char *reason = "Empty or oversized encoded image";
    jclass cls = atomic_load(&decoder_class);
    if (!data || !size || size > INT_MAX || !loop_count || !emit) goto fail;
    *loop_count = size >= 6 && (!memcmp(data, "GIF87a", 6) || !memcmp(data, "GIF89a", 6)) ? UINT32_MAX : 0;
    reason = "Android bitmap decoder requires AndroidApp.attach and dev.rune.RuneImages";
    if (!cls) goto fail;
    JNIEnv *env = NULL;
    jint state = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6);
    int detached = state == JNI_EDETACHED;
    reason = "Could not attach the image decoder thread to Android";
    if ((detached && (*vm)->AttachCurrentThread(vm, &env, NULL) != JNI_OK) || !env) goto fail;
    int result = 0;
    reason = "Could not allocate Android image buffers";
    if ((*env)->PushLocalFrame(env, 4) != JNI_OK) goto end_thread;
    jobject bitmap = NULL;
    jbyteArray encoded = (*env)->NewByteArray(env, (jsize)size);
    if (!encoded) goto end_frame;
    (*env)->SetByteArrayRegion(env, encoded, 0, (jsize)size, (const jbyte *)data);
    if ((*env)->ExceptionCheck(env)) goto end_frame;
    jintArray metadata = (*env)->NewIntArray(env, 2);
    if (!metadata) goto end_frame;
    jint limit = max_dimension > RUNE_IMAGE_MAX_SIDE ? RUNE_IMAGE_MAX_SIDE : max_dimension;
    bitmap = (*env)->CallStaticObjectMethod(env, cls, decode_bitmap, encoded, limit,
                                            (jint)RUNE_IMAGE_MAX_SIDE, metadata);
    reason = "BitmapFactory could not decode the image within Rune's dimensions";
    if ((*env)->ExceptionCheck(env) || !bitmap) goto end_frame;
    jint fields[2];
    (*env)->GetIntArrayRegion(env, metadata, 0, 2, fields);
    if ((*env)->ExceptionCheck(env)) goto end_frame;
    AndroidBitmapInfo info;
    void *pixels = NULL;
    reason = "Android bitmap did not provide a bounded RGBA8 image";
    if (AndroidBitmap_getInfo(env, bitmap, &info) != ANDROID_BITMAP_RESULT_SUCCESS ||
        info.format != ANDROID_BITMAP_FORMAT_RGBA_8888 || !info.width || !info.height ||
        info.width > RUNE_IMAGE_MAX_SIDE || info.height > RUNE_IMAGE_MAX_SIDE ||
        (uint64_t)info.stride * info.height > RUNE_IMAGE_MAX_BYTES ||
        info.stride < info.width * 4 || AndroidBitmap_lockPixels(env, bitmap, &pixels) != ANDROID_BITMAP_RESULT_SUCCESS)
        goto end_frame;
    reason = "Could not deliver the decoded Android image";
    if (pixels) result = emit_bitmap(&info, pixels, fields[0], fields[1], emit, context);
    AndroidBitmap_unlockPixels(env, bitmap);
end_frame:
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    if (bitmap) (*env)->CallVoidMethod(env, bitmap, recycle_bitmap);
    (*env)->PopLocalFrame(env, NULL);
end_thread:
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    if (detached) (*vm)->DetachCurrentThread(vm);
    if (result) return 1;
fail:
    if (error && error_size) snprintf(error, error_size, "%s", reason);
    return 0;
}
#endif
