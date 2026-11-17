#if defined(__ANDROID__)
#include "RuneDesktopText.h"
#include <android/log.h>
#include <android/native_activity.h>
#include <jni.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// Only the process class loader and JavaVM outlive activity recreation. JNIEnv and
// local references belong to one thread. Line instances own their own global ref.
static JavaVM *vm;
static jclass bridge;
static jmethodID constructor, configure, get_metrics, get_cell, get_caret, get_mask;
static jmethodID get_has_color;
static jmethodID register_file, register_bytes;
static pthread_mutex_t init_lock = PTHREAD_MUTEX_INITIALIZER;
static atomic_bool ready;
static atomic_bool bundled_fonts;

struct RuneDesktopLine {
    jobject layout;
    RuneDesktopLineMetrics metrics;
    int32_t length;
    int32_t indices[];  // UTF-8 byte boundary -> Java UTF-16 index; negative inside scalar.
};

static int clear_exception(JNIEnv *env) {
    if (!(*env)->ExceptionCheck(env)) return 0;
    (*env)->ExceptionClear(env);
    return 1;
}

void rune_android_text_attach(void *raw) {
    ANativeActivity *activity = raw;
    if (!activity || !activity->env || atomic_load_explicit(&ready, memory_order_acquire)) return;
    pthread_mutex_lock(&init_lock);
    if (atomic_load_explicit(&ready, memory_order_acquire)) {
        pthread_mutex_unlock(&init_lock);
        return;
    }
    JNIEnv *e = activity->env;
    if ((*e)->PushLocalFrame(e, 16) != JNI_OK) {
        clear_exception(e);
        pthread_mutex_unlock(&init_lock);
        return;
    }
    jclass activity_class = (*e)->GetObjectClass(e, activity->clazz);
    if (!activity_class) goto fail;
    jmethodID loader_id = (*e)->GetMethodID(e, activity_class, "getClassLoader", "()Ljava/lang/ClassLoader;");
    if (!loader_id) goto fail;
    jobject loader = (*e)->CallObjectMethod(e, activity->clazz, loader_id);
    if (!loader || clear_exception(e)) goto fail;
    jclass loader_class = (*e)->GetObjectClass(e, loader);
    if (!loader_class) goto fail;
    jmethodID load = (*e)->GetMethodID(e, loader_class, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
    if (!load) goto fail;
    jstring name = (*e)->NewStringUTF(e, "dev.rune.RuneText");
    if (!name) goto fail;
    jclass local = (jclass)(*e)->CallObjectMethod(e, loader, load, name);
    if (!local || clear_exception(e)) goto fail;
#define METHOD(field, java_name, sig) if (!(field = (*e)->GetMethodID(e, local, java_name, sig))) goto fail
#define STATIC(field, java_name, sig) if (!(field = (*e)->GetStaticMethodID(e, local, java_name, sig))) goto fail
    METHOD(constructor, "<init>", "([B[BFIZZI)V");
    METHOD(configure, "configure", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V");
    METHOD(get_metrics, "metrics", "()[F");
    METHOD(get_cell, "cell", "(II)J");
    METHOD(get_caret, "caret", "(I)F");
    METHOD(get_mask, "mask", "(IIIIZ)[B");
    METHOD(get_has_color, "hasColor", "()Z");
    STATIC(register_file, "registerFile", "([B)Z");
    STATIC(register_bytes, "registerBytes", "([B)Z");
    jmethodID initialize;
    STATIC(initialize, "initialize", "(Landroid/content/Context;)Z");
#undef STATIC
#undef METHOD
    jboolean has_fonts = (*e)->CallStaticBooleanMethod(e, local, initialize, activity->clazz);
    if (clear_exception(e)) goto fail;
    bridge = (jclass)(*e)->NewGlobalRef(e, local);
    if (!bridge) goto fail;
    vm = activity->vm;
    atomic_store(&bundled_fonts, has_fonts == JNI_TRUE);
    atomic_store_explicit(&ready, 1, memory_order_release);
    goto done;
fail:
    clear_exception(e);
    __android_log_write(ANDROID_LOG_ERROR, "SwiftRune", "Android text initialization failed; package dev.rune.RuneText in the application DEX");
done:
    (*e)->PopLocalFrame(e, NULL);
    pthread_mutex_unlock(&init_lock);
}

int32_t rune_android_bundled_fonts_ready(void) { return atomic_load(&bundled_fonts); }

typedef struct { JNIEnv *env; int attached; } Call;
static Call begin_call(void) {
    Call call = {0};
    if (!atomic_load_explicit(&ready, memory_order_acquire)) return call;
    jint status = (*vm)->GetEnv(vm, (void **)&call.env, JNI_VERSION_1_6);
    if (status == JNI_EDETACHED && (*vm)->AttachCurrentThread(vm, &call.env, NULL) == JNI_OK)
        call.attached = 1;
    if (!call.env) return call;
    if ((*call.env)->PushLocalFrame(call.env, 12) != JNI_OK) {
        clear_exception(call.env);
        if (call.attached) (*vm)->DetachCurrentThread(vm);
        call.env = NULL;
    }
    return call;
}

static void end_call(Call c) {
    if (!c.env) return;
    clear_exception(c.env);
    (*c.env)->PopLocalFrame(c.env, NULL);
    if (c.attached) (*vm)->DetachCurrentThread(vm);
}

static jbyteArray bytes(JNIEnv *e, const void *data, size_t size) {
    if (size > INT_MAX || (size && !data)) return NULL;
    jbyteArray result = (*e)->NewByteArray(e, (jsize)size);
    if (result && size) (*e)->SetByteArrayRegion(e, result, 0, (jsize)size, data);
    return clear_exception(e) ? NULL : result;
}

static int add_font(jmethodID method, const void *data, size_t size, Call call) {
    JNIEnv *e = call.env;
    jbyteArray input = bytes(e, data, size);
    jboolean ok = input && (*e)->CallStaticBooleanMethod(e, bridge, method, input);
    int result = !clear_exception(e) && ok;
    end_call(call);
    return result;
}

int32_t rune_desktop_register_font_file(const char *path) {
    if (!path) return 0;
    Call c = begin_call();
    return c.env ? add_font(register_file, path, strlen(path), c) : 0;
}
int32_t rune_desktop_register_font_bytes(const uint8_t *data, uint32_t length) {
    Call c = begin_call();
    return c.env ? add_font(register_bytes, data, length, c) : 0;
}

static int map_indices(RuneDesktopLine *line, const uint8_t *s) {
    int32_t j = 0, i = 0, length = line->length;
    while (i < length) {
        unsigned b = s[i];
        int n = b < 128 ? 1 : (b >= 0xc2 && b <= 0xdf ? 2 :
                (b >= 0xe0 && b <= 0xef ? 3 : (b >= 0xf0 && b <= 0xf4 ? 4 : 0)));
        if (!n || n > length - i) return 0;
        if (n > 1 && ((b == 0xe0 && s[i+1] < 0xa0) || (b == 0xed && s[i+1] >= 0xa0) ||
                      (b == 0xf0 && s[i+1] < 0x90) || (b == 0xf4 && s[i+1] >= 0x90))) return 0;
        line->indices[i] = j;
        for (int k = 1; k < n; k++) {
            if ((s[i+k] & 0xc0) != 0x80) return 0;
            line->indices[i+k] = -1;
        }
        i += n;
        j += n == 4 ? 2 : 1;
    }
    line->indices[length] = j;
    return 1;
}

static int refresh_metrics(JNIEnv *e, RuneDesktopLine *line) {
    jfloatArray values = (jfloatArray)(*e)->CallObjectMethod(e, line->layout, get_metrics);
    float fields[10];
    if (!values || clear_exception(e) || (*e)->GetArrayLength(e, values) != 10) return 0;
    (*e)->GetFloatArrayRegion(e, values, 0, 10, fields);
    if (clear_exception(e)) return 0;
    for (int i = 0; i < 10; i++) {
        if (!isfinite(fields[i]) || fabs((double)fields[i]) >= INT_MAX) return 0;
    }
    line->metrics = (RuneDesktopLineMetrics){fields[0], fields[1], fields[2], (int)fields[3],
                                              (int)fields[4], (int)fields[5], (int)fields[6],
                                              fields[7], fields[8], fields[9]};
    return 1;
}

RuneDesktopLine *rune_desktop_line_create(const char *utf8, int32_t length, const char *family,
                                         float size, int32_t weight, int32_t italic,
                                         int32_t mono, int32_t direction) {
    if (length < 0 || (!utf8 && length) || !isfinite(size) || size <= 0) return NULL;
    size_t count = (size_t)length + 1;
    if (count > (SIZE_MAX - sizeof(RuneDesktopLine)) / sizeof(int32_t)) return NULL;
    Call call = begin_call();
    JNIEnv *e = call.env;
    if (!e) return NULL;
    RuneDesktopLine *line = calloc(1, sizeof(*line) + count * sizeof(int32_t));
    if (!line) goto fail;
    line->length = length;
    if (!map_indices(line, (const uint8_t *)utf8)) goto fail;
    jbyteArray text = bytes(e, utf8, (size_t)length);
    if (!text) goto fail;
    jbyteArray font = bytes(e, family, family ? strlen(family) : 0);
    if (!font) goto fail;
    jobject local = (*e)->NewObject(e, bridge, constructor, text, font, (jfloat)size, (jint)weight,
                                     (jboolean)!!italic, (jboolean)!!mono, (jint)direction);
    if (!local || clear_exception(e)) goto fail;
    line->layout = (*e)->NewGlobalRef(e, local);
    if (!line->layout || !refresh_metrics(e, line)) goto fail;
    end_call(call);
    return line;
fail:
    if (line && line->layout) (*e)->DeleteGlobalRef(e, line->layout);
    free(line);
    end_call(call);
    return NULL;
}

void rune_desktop_line_configure(RuneDesktopLine *line, const char *language,
                                 const char *features, const char *variations) {
    if (!line) return;
    Call c = begin_call();
    JNIEnv *e = c.env;
    if (!e) return;
    // These inputs contain BCP-47 tags and CSS font settings (ASCII).
    jstring lang = (*e)->NewStringUTF(e, language ? language : "");
    if (!lang) goto done;
    jstring feat = (*e)->NewStringUTF(e, features ? features : "");
    if (!feat) goto done;
    jstring var = (*e)->NewStringUTF(e, variations ? variations : "");
    if (!var) goto done;
    (*e)->CallVoidMethod(e, line->layout, configure, lang, feat, var);
    if (!clear_exception(e)) refresh_metrics(e, line);
done:
    end_call(c);
}

void rune_desktop_line_destroy(RuneDesktopLine *line) {
    if (!line) return;
    Call call = begin_call();
    if (call.env) (*call.env)->DeleteGlobalRef(call.env, line->layout);
    end_call(call);
    free(line);
}
RuneDesktopLineMetrics rune_desktop_line_metrics(const RuneDesktopLine *line) {
    return line ? line->metrics : (RuneDesktopLineMetrics){0};
}

float rune_desktop_line_caret(const RuneDesktopLine *line, int32_t byte) {
    if (!line || byte < 0 || byte > line->length || line->indices[byte] < 0) return 0;
    Call call = begin_call();
    JNIEnv *e = call.env;
    if (!e) return 0;
    float x = (*e)->CallFloatMethod(e, line->layout, get_caret, line->indices[byte]);
    if (clear_exception(e)) x = 0;
    end_call(call);
    return x;
}

int32_t rune_desktop_line_cell(const RuneDesktopLine *line, int32_t byte, int32_t end,
                              float *left, float *advance) {
    if (left) *left = 0;
    if (advance) *advance = 0;
    if (!line || byte < 0 || end <= byte || end > line->length ||
        line->indices[byte] < 0 || line->indices[end] < 0) return 0;
    Call call = begin_call();
    JNIEnv *e = call.env;
    if (!e) return 0;
    uint64_t packed = (uint64_t)(*e)->CallLongMethod(e, line->layout, get_cell,
                                                     line->indices[byte], line->indices[end]);
    if (clear_exception(e)) { end_call(call); return 0; }
    uint32_t high = (uint32_t)(packed >> 32), low = (uint32_t)packed;
    float x, width;
    memcpy(&x, &high, sizeof(x)); memcpy(&width, &low, sizeof(width));
    if (left) *left = x;
    if (advance) *advance = fabsf(width);
    end_call(call);
    return signbit(width) ? -1 : 1;
}

int32_t rune_desktop_line_has_color(const RuneDesktopLine *line) {
    if (!line) return 0;
    Call call = begin_call();
    JNIEnv *e = call.env;
    if (!e) return 0;
    int has = (*e)->CallBooleanMethod(e, line->layout, get_has_color);
    if (clear_exception(e)) has = 0;
    end_call(call);
    return has;
}

static int32_t raster(const RuneDesktopLine *line, int32_t x, int32_t y,
                      int32_t width, int32_t height, uint8_t *pixels, int color) {
    if (!line || !pixels || width <= 0 || height <= 0 || width > INT_MAX / height / 4) return 0;
    Call call = begin_call();
    JNIEnv *e = call.env;
    if (!e) return 0;
    int count = width * height * (color ? 4 : 1);
    jbyteArray result = (jbyteArray)(*e)->CallObjectMethod(e, line->layout, get_mask, x, y, width, height, (jboolean)color);
    int ok = result && !clear_exception(e) && (*e)->GetArrayLength(e, result) == count;
    if (ok) {
        (*e)->GetByteArrayRegion(e, result, 0, count, (jbyte *)pixels);
        ok = !clear_exception(e);
    }
    end_call(call);
    return ok;
}
int32_t rune_desktop_line_mask(const RuneDesktopLine *line, int32_t x, int32_t y,
                              int32_t width, int32_t height, uint8_t *pixels) {
    return raster(line, x, y, width, height, pixels, 0);
}
int32_t rune_desktop_line_color(const RuneDesktopLine *line, int32_t x, int32_t y,
                               int32_t width, int32_t height, uint8_t *pixels) {
    return raster(line, x, y, width, height, pixels, 1);
}
#endif
