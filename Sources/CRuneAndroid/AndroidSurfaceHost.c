#if defined(__ANDROID__)
#include "CRuneAndroid.h"
#include <android/asset_manager.h>
#include <android/asset_manager_jni.h>
#include <android/looper.h>
#include <android/log.h>
#include <android/native_activity.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <jni.h>
#include <math.h>
#include <poll.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/timerfd.h>
#include <unistd.h>

extern EGLDisplay rune_android_shared_egl_display(void);
extern void rune_android_attach_main_queue(ALooper *looper);

struct RuneAndroidSurface {
    JavaVM *vm;
    ALooper *looper;
    jobject view_ref;
    jobject context_ref;
    jobject assets_ref;
    AAssetManager *assets;
    jmethodID request_frame_method;
    jmethodID close_requested_method;
    jmethodID keyboard_method;
    jmethodID attach_handle_method;

    // ANativeActivity-compatible shims for RuneText/RuneImages (Context) and AndroidSemanticBridge (View).
    ANativeActivity context_shim;
    ANativeActivity semantics_shim;

    ANativeWindow *window;
    EGLDisplay display;
    EGLContext context;
    EGLSurface surface;

    RuneAndroidSurfaceCallbacks callbacks;
    void *state;
    int attached;
    int bound_to_view;
    int visible;
    int presented;
    int frame_requested;
    int32_t width;
    int32_t height;
    int32_t density_dpi;
    float density;
    int32_t dark;

    int wake_fd;
    int idle_fd;
    int gpu_fd;
};

static _Atomic(RuneAndroidSurfaceFactoryResolver) surface_factory_resolver = NULL;

void rune_android_surface_set_factory_resolver(RuneAndroidSurfaceFactoryResolver resolver) {
    atomic_store_explicit(&surface_factory_resolver, resolver, memory_order_release);
}

static void clear_exception(JNIEnv *env) {
    if (env && (*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
    }
}

static JNIEnv *surface_env(RuneAndroidSurface *s) {
    if (!s || !s->vm) return NULL;
    JNIEnv *env = NULL;
    if ((*s->vm)->GetEnv(s->vm, (void **)&env, JNI_VERSION_1_6) == JNI_OK && env) {
        s->context_shim.env = env;
        s->semantics_shim.env = env;
        return env;
    }
    return NULL;
}

static void release_surface_egl(RuneAndroidSurface *s) {
    if (!s) return;
    if (s->display != EGL_NO_DISPLAY) {
        const EGLDisplay previous_display = eglGetCurrentDisplay();
        const EGLContext previous_context = eglGetCurrentContext();
        const EGLSurface previous_draw = eglGetCurrentSurface(EGL_DRAW);
        const EGLSurface previous_read = eglGetCurrentSurface(EGL_READ);
        if (s->context != EGL_NO_CONTEXT) {
            int current = s->surface != EGL_NO_SURFACE &&
                          eglMakeCurrent(s->display, s->surface, s->surface, s->context);
            if (s->attached && s->state && s->callbacks.release_gpu) {
                s->callbacks.release_gpu(s->state, current);
            }
            if (current) {
                eglMakeCurrent(s->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            }
        }
        if (s->surface != EGL_NO_SURFACE) {
            eglDestroySurface(s->display, s->surface);
        }
        if (s->context != EGL_NO_CONTEXT) {
            eglDestroyContext(s->display, s->context);
        }
        if (previous_context != EGL_NO_CONTEXT && previous_context != s->context) {
            eglMakeCurrent(previous_display, previous_draw, previous_read, previous_context);
        }
    }
    s->display = EGL_NO_DISPLAY;
    s->context = EGL_NO_CONTEXT;
    s->surface = EGL_NO_SURFACE;
}

static int create_surface_egl(RuneAndroidSurface *s) {
    if (!s || !s->window) return 0;
    const EGLint attrs[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_NONE
    };
    const EGLint context_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    const EGLDisplay previous_display = eglGetCurrentDisplay();
    const EGLContext previous_context = eglGetCurrentContext();
    const EGLSurface previous_draw = eglGetCurrentSurface(EGL_DRAW);
    const EGLSurface previous_read = eglGetCurrentSurface(EGL_READ);
    EGLConfig config;
    EGLint count = 0;
    EGLint format = 0;

    s->display = rune_android_shared_egl_display();
    if (s->display == EGL_NO_DISPLAY) goto failed;
    if (!eglBindAPI(EGL_OPENGL_ES_API) ||
        !eglChooseConfig(s->display, attrs, &config, 1, &count) ||
        !count ||
        !eglGetConfigAttrib(s->display, config, EGL_NATIVE_VISUAL_ID, &format) ||
        ANativeWindow_setBuffersGeometry(s->window, 0, 0, format) != 0) {
        goto failed;
    }
    s->context = eglCreateContext(s->display, config, EGL_NO_CONTEXT, context_attrs);
    s->surface = eglCreateWindowSurface(s->display, config, s->window, NULL);
    if (s->context == EGL_NO_CONTEXT ||
        s->surface == EGL_NO_SURFACE ||
        !eglMakeCurrent(s->display, s->surface, s->surface, s->context)) {
        goto failed;
    }
    eglSwapInterval(s->display, 1);
    __android_log_print(ANDROID_LOG_INFO, "SwiftRune", "RuneSurfaceView GLES renderer: %s (%s)",
                        glGetString(GL_RENDERER), glGetString(GL_VERSION));
    if (previous_context != EGL_NO_CONTEXT && previous_context != s->context) {
        eglMakeCurrent(previous_display, previous_draw, previous_read, previous_context);
    }
    return 1;
failed:
    __android_log_print(ANDROID_LOG_ERROR, "SwiftRune", "RuneSurfaceView EGL initialization failed (0x%x)",
                        eglGetError());
    release_surface_egl(s);
    if (previous_context != EGL_NO_CONTEXT) {
        eglMakeCurrent(previous_display, previous_draw, previous_read, previous_context);
    }
    return 0;
}

static int can_prepare_surface_text(RuneAndroidSurface *s) {
    return s && s->attached && s->state && s->presented && s->visible &&
           !s->frame_requested && s->surface != EGL_NO_SURFACE;
}

static void schedule_surface_text_idle(RuneAndroidSurface *s) {
    if (can_prepare_surface_text(s) && s->callbacks.text_idle && s->callbacks.text_idle(s->state, 0)) {
        rune_android_wake(s->idle_fd);
    }
}

static void schedule_surface_gpu_poll(RuneAndroidSurface *s) {
    if (!s || s->gpu_fd < 0) return;
    struct itimerspec timer = {.it_value = {.tv_nsec = 4000000}};
    timerfd_settime(s->gpu_fd, 0, &timer, NULL);
}

static int on_surface_wake(int fd, int events, void *data) {
    if (!(events & ALOOPER_EVENT_INPUT)) return 0;
    uint64_t ignored = 0;
    while (read(fd, &ignored, sizeof(ignored)) < 0 && errno == EINTR) {}
    RuneAndroidSurface *s = data;
    if (!s || !s->attached) return 1;
    s->frame_requested = 1;
    rune_android_surface_request_frame(s);
    return 1;
}

static int on_surface_text_idle(int fd, int events, void *data) {
    if (!(events & ALOOPER_EVENT_INPUT)) return 0;
    uint64_t count = 0;
    ssize_t size = 0;
    do {
        size = read(fd, &count, sizeof(count));
    } while (size < 0 && errno == EINTR);
    if (size != (ssize_t)sizeof(count)) return 1;
    RuneAndroidSurface *s = data;
    if (!can_prepare_surface_text(s) || !s->callbacks.text_idle) return 1;
    struct pollfd wakes[] = {{s->wake_fd, POLLIN, 0}};
    int ready = 0;
    do {
        ready = poll(wakes, 1, 0);
    } while (ready < 0 && errno == EINTR);
    if (ready == 0 && s->callbacks.text_idle(s->state, 1)) {
        rune_android_wake(fd);
    }
    return 1;
}

static int on_surface_gpu_poll(int fd, int events, void *data) {
    if (!(events & ALOOPER_EVENT_INPUT)) return 0;
    uint64_t ignored = 0;
    while (read(fd, &ignored, sizeof(ignored)) < 0 && errno == EINTR) {}
    RuneAndroidSurface *s = data;
    if (!s || !s->attached || !s->state || s->surface == EGL_NO_SURFACE ||
        !s->callbacks.poll_gpu || !s->callbacks.poll_gpu(s->state, 0)) {
        return 1;
    }
    EGLDisplay previous_display = eglGetCurrentDisplay();
    EGLContext previous_context = eglGetCurrentContext();
    EGLSurface previous_draw = eglGetCurrentSurface(EGL_DRAW);
    EGLSurface previous_read = eglGetCurrentSurface(EGL_READ);
    int switch_context = previous_context != s->context ||
                         previous_draw != s->surface ||
                         previous_read != s->surface;
    if (switch_context && !eglMakeCurrent(s->display, s->surface, s->surface, s->context)) {
        release_surface_egl(s);
        if (s->visible && s->window && create_surface_egl(s)) {
            rune_android_surface_request_frame(s);
        }
        return 1;
    }
    if (s->callbacks.poll_gpu(s->state, 1)) {
        schedule_surface_gpu_poll(s);
    }
    if (switch_context) {
        if (previous_context == EGL_NO_CONTEXT) {
            eglMakeCurrent(s->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        } else {
            eglMakeCurrent(previous_display, previous_draw, previous_read, previous_context);
        }
    }
    return 1;
}

static void destroy_surface_host(RuneAndroidSurface *s) {
    if (!s) return;
    if (s->looper) {
        if (s->wake_fd >= 0) ALooper_removeFd(s->looper, s->wake_fd);
        if (s->idle_fd >= 0) ALooper_removeFd(s->looper, s->idle_fd);
        if (s->gpu_fd >= 0) ALooper_removeFd(s->looper, s->gpu_fd);
    }
    if (s->wake_fd >= 0) { close(s->wake_fd); s->wake_fd = -1; }
    if (s->idle_fd >= 0) { close(s->idle_fd); s->idle_fd = -1; }
    if (s->gpu_fd >= 0) { close(s->gpu_fd); s->gpu_fd = -1; }

    release_surface_egl(s);
    if (s->window) {
        ANativeWindow_release(s->window);
        s->window = NULL;
    }

    if (s->attached && s->state && s->callbacks.destroy) {
        void *state = s->state;
        s->state = NULL;
        s->attached = 0;
        s->callbacks.destroy(state);
    } else {
        s->state = NULL;
        s->attached = 0;
    }

    JNIEnv *env = surface_env(s);
    if (env) {
        if (s->view_ref) (*env)->DeleteGlobalRef(env, s->view_ref);
        if (s->context_ref) (*env)->DeleteGlobalRef(env, s->context_ref);
        if (s->assets_ref) (*env)->DeleteGlobalRef(env, s->assets_ref);
        clear_exception(env);
    }
    s->view_ref = NULL;
    s->context_ref = NULL;
    s->assets_ref = NULL;
    s->context_shim.clazz = NULL;
    s->semantics_shim.clazz = NULL;
    free(s);
}

static int register_surface_natives(JNIEnv *env, jobject view_obj);

static RuneAndroidSurface *allocate_surface_host(
    JNIEnv *env,
    jobject view_obj,
    jobject context_obj,
    jobject assets_obj,
    int32_t density_dpi,
    float density,
    int32_t dark,
    int bound_to_view
) {
    ALooper *looper = ALooper_forThread();
    if (!env || !view_obj || !context_obj || !assets_obj || !looper) return NULL;
    JavaVM *vm = NULL;
    if ((*env)->GetJavaVM(env, &vm) != JNI_OK || !vm) return NULL;

    RuneAndroidSurface *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->vm = vm;
    s->looper = looper;
    s->display = EGL_NO_DISPLAY;
    s->context = EGL_NO_CONTEXT;
    s->surface = EGL_NO_SURFACE;
    s->wake_fd = -1;
    s->idle_fd = -1;
    s->gpu_fd = -1;
    s->bound_to_view = bound_to_view;
    s->density_dpi = density_dpi > 0 ? density_dpi : 160;
    s->density = density > 0.0f ? density : (float)s->density_dpi / 160.0f;
    s->dark = dark ? 1 : 0;

    s->view_ref = (*env)->NewGlobalRef(env, view_obj);
    s->context_ref = (*env)->NewGlobalRef(env, context_obj);
    s->assets_ref = (*env)->NewGlobalRef(env, assets_obj);
    s->assets = AAssetManager_fromJava(env, assets_obj);

    jclass view_cls = (*env)->GetObjectClass(env, view_obj);
    if (!s->view_ref || !s->context_ref || !s->assets_ref || !s->assets || !view_cls) {
        if (view_cls) (*env)->DeleteLocalRef(env, view_cls);
        clear_exception(env);
        destroy_surface_host(s);
        return NULL;
    }

    s->request_frame_method = (*env)->GetMethodID(env, view_cls, "requestFrameFromNative", "()V");
    s->close_requested_method = (*env)->GetMethodID(env, view_cls, "onRuneCloseRequested", "()V");
    s->keyboard_method = (*env)->GetMethodID(env, view_cls, "setSoftKeyboardVisible", "(Z)V");
    s->attach_handle_method = (*env)->GetMethodID(env, view_cls, "attachNativeHandle", "(J)V");
    (*env)->DeleteLocalRef(env, view_cls);
    if (!s->request_frame_method || !s->close_requested_method ||
        !s->keyboard_method || !s->attach_handle_method || (*env)->ExceptionCheck(env)) {
        clear_exception(env);
        destroy_surface_host(s);
        return NULL;
    }

    s->context_shim.vm = vm;
    s->context_shim.env = env;
    s->context_shim.clazz = s->context_ref;
    s->context_shim.assetManager = s->assets;

    s->semantics_shim.vm = vm;
    s->semantics_shim.env = env;
    s->semantics_shim.clazz = s->view_ref;
    s->semantics_shim.assetManager = s->assets;

    s->wake_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    s->idle_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    s->gpu_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
    if (s->wake_fd < 0 || s->idle_fd < 0 || s->gpu_fd < 0 ||
        ALooper_addFd(s->looper, s->wake_fd, ALOOPER_POLL_CALLBACK, ALOOPER_EVENT_INPUT, on_surface_wake, s) < 0 ||
        ALooper_addFd(s->looper, s->idle_fd, ALOOPER_POLL_CALLBACK, ALOOPER_EVENT_INPUT, on_surface_text_idle, s) < 0 ||
        ALooper_addFd(s->looper, s->gpu_fd, ALOOPER_POLL_CALLBACK, ALOOPER_EVENT_INPUT, on_surface_gpu_poll, s) < 0) {
        destroy_surface_host(s);
        return NULL;
    }

    rune_android_attach_main_queue(s->looper);
    return s;
}

void *rune_android_surface_create_from_jni(
    void *jni_env,
    void *surface_view,
    void *context,
    void *asset_manager,
    void *java_surface
) {
    JNIEnv *env = jni_env;
    jobject view_obj = surface_view;
    jobject context_obj = context;
    jobject assets_obj = asset_manager;
    if (!env || !view_obj || !context_obj || !assets_obj) return NULL;
    register_surface_natives(env, view_obj);
    RuneAndroidSurface *s = allocate_surface_host(env, view_obj, context_obj, assets_obj, 160, 1.0f, 0, 0);
    if (!s) return NULL;
    if (java_surface) {
        s->window = ANativeWindow_fromSurface(env, (jobject)java_surface);
        if (s->window) {
            s->width = ANativeWindow_getWidth(s->window);
            s->height = ANativeWindow_getHeight(s->window);
        }
    }
    return s;
}

void rune_android_surface_destroy(void *raw) {
    destroy_surface_host((RuneAndroidSurface *)raw);
}

int32_t rune_android_surface_attach(
    void *raw,
    void *native_window,
    void *state,
    RuneAndroidSurfaceCallbacks callbacks
) {
    RuneAndroidSurface *s = raw;
    if (!s || !state || s->attached || s->wake_fd < 0) return -1;
    int writer = fcntl(s->wake_fd, F_DUPFD_CLOEXEC, 0);
    if (writer < 0) return -1;

    s->state = state;
    s->callbacks = callbacks;
    s->attached = 1;

    if (native_window && native_window != s->window) {
        if (s->window) {
            release_surface_egl(s);
            ANativeWindow_release(s->window);
        }
        s->window = (ANativeWindow *)native_window;
        ANativeWindow_acquire(s->window);
        s->width = ANativeWindow_getWidth(s->window);
        s->height = ANativeWindow_getHeight(s->window);
    }

    if (s->callbacks.config_changed) {
        s->callbacks.config_changed(s->state, s->density_dpi, s->density, s->dark);
    }
    if (s->window && s->callbacks.surface_changed) {
        s->callbacks.surface_changed(s->state, s->width, s->height);
    }

    if (!s->bound_to_view) {
        JNIEnv *env = surface_env(s);
        if (env && s->view_ref && s->attach_handle_method) {
            s->bound_to_view = 1;
            (*env)->CallVoidMethod(env, s->view_ref, s->attach_handle_method, (jlong)(intptr_t)s);
            clear_exception(env);
        }
    }

    return writer;
}

void rune_android_surface_request_frame(void *raw) {
    RuneAndroidSurface *s = raw;
    JNIEnv *env = surface_env(s);
    if (!env || !s->view_ref || !s->request_frame_method) return;
    (*env)->CallVoidMethod(env, s->view_ref, s->request_frame_method);
    clear_exception(env);
}

void rune_android_surface_request_close(void *raw) {
    RuneAndroidSurface *s = raw;
    JNIEnv *env = surface_env(s);
    if (!env || !s->view_ref || !s->close_requested_method) return;
    (*env)->CallVoidMethod(env, s->view_ref, s->close_requested_method);
    clear_exception(env);
}

void rune_android_surface_keyboard(void *raw, int32_t show) {
    RuneAndroidSurface *s = raw;
    JNIEnv *env = surface_env(s);
    if (!env || !s->view_ref || !s->keyboard_method) return;
    (*env)->CallVoidMethod(env, s->view_ref, s->keyboard_method, (jboolean)(show != 0));
    clear_exception(env);
}

void *rune_android_surface_context_shim(void *raw) {
    RuneAndroidSurface *s = raw;
    if (!s) return NULL;
    surface_env(s);
    return &s->context_shim;
}

void *rune_android_surface_semantics_shim(void *raw) {
    RuneAndroidSurface *s = raw;
    if (!s) return NULL;
    surface_env(s);
    return &s->semantics_shim;
}

char *rune_android_surface_read_shader(void *raw, const char *name) {
    RuneAndroidSurface *s = raw;
    if (!s || !s->assets || !name || strchr(name, '/') || strchr(name, '\\')) return NULL;
    char path[256];
    if (snprintf(path, sizeof(path), "GL/%s", name) >= (int)sizeof(path)) return NULL;
    AAsset *asset = AAssetManager_open(s->assets, path, AASSET_MODE_BUFFER);
    if (!asset) return NULL;
    off_t length = AAsset_getLength(asset);
    char *bytes = length > 0 ? malloc((size_t)length + 1) : NULL;
    if (bytes && AAsset_read(asset, bytes, length) == length) {
        bytes[length] = 0;
    } else {
        free(bytes);
        bytes = NULL;
    }
    AAsset_close(asset);
    return bytes;
}

uint32_t rune_android_surface_compose_key(void *raw, uint32_t accent, uint32_t character) {
    RuneAndroidSurface *s = raw;
    JNIEnv *env = surface_env(s);
    if (!env) return 0;
    jclass map = (*env)->FindClass(env, "android/view/KeyCharacterMap");
    uint32_t result = 0;
    if (map) {
        jmethodID method = (*env)->GetStaticMethodID(env, map, "getDeadChar", "(II)I");
        if (method) {
            result = (uint32_t)(*env)->CallStaticIntMethod(env, map, method, (jint)accent, (jint)character);
        }
        (*env)->DeleteLocalRef(env, map);
    }
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return 0;
    }
    return result;
}

// MARK: - JNI Entry Points for dev.rune.RuneSurfaceView

static RuneAndroidSurface *surface_from_handle(JNIEnv *env, jobject thiz, jlong handle) {
    RuneAndroidSurface *s = (RuneAndroidSurface *)(intptr_t)handle;
    if (!s || !s->view_ref) return NULL;
    if (!(*env)->IsSameObject(env, thiz, s->view_ref)) return NULL;
    s->context_shim.env = env;
    s->semantics_shim.env = env;
    return s;
}

JNIEXPORT jlong JNICALL Java_dev_rune_RuneSurfaceView_nativeCreate(
    JNIEnv *env,
    jobject thiz,
    jobject app_context,
    jobject assets,
    jstring factory_name,
    jint density_dpi,
    jfloat density,
    jboolean dark
) {
    if (!app_context || !assets || !factory_name) return 0;
    const char *name = (*env)->GetStringUTFChars(env, factory_name, NULL);
    if (!name || !*name) {
        if (name) (*env)->ReleaseStringUTFChars(env, factory_name, name);
        return 0;
    }

    RuneAndroidSurface *s = allocate_surface_host(env, thiz, app_context, assets, density_dpi, density, dark ? 1 : 0, 1);
    if (!s) {
        (*env)->ReleaseStringUTFChars(env, factory_name, name);
        return 0;
    }

    int32_t resolved = 0;
    RuneAndroidSurfaceFactoryResolver resolver = atomic_load_explicit(&surface_factory_resolver, memory_order_acquire);
    if (resolver) {
        resolved = resolver(s, name);
    }
    if (!s->attached && !resolved) {
        void (*factory_fn)(void *) = (void (*)(void *))dlsym(RTLD_DEFAULT, name);
        if (factory_fn) {
            factory_fn(s);
        }
    }
    (*env)->ReleaseStringUTFChars(env, factory_name, name);

    if (!s->attached) {
        __android_log_write(ANDROID_LOG_ERROR, "SwiftRune",
                            "RuneSurfaceView factory did not call AndroidApp.attachView(to:...)");
        destroy_surface_host(s);
        return 0;
    }
    return (jlong)(intptr_t)s;
}

JNIEXPORT void JNICALL Java_dev_rune_RuneSurfaceView_nativeDestroy(
    JNIEnv *env,
    jobject thiz,
    jlong handle
) {
    RuneAndroidSurface *s = surface_from_handle(env, thiz, handle);
    if (!s) return;
    destroy_surface_host(s);
}

JNIEXPORT jboolean JNICALL Java_dev_rune_RuneSurfaceView_nativeOnSurfaceCreated(
    JNIEnv *env,
    jobject thiz,
    jlong handle,
    jobject java_surface
) {
    RuneAndroidSurface *s = surface_from_handle(env, thiz, handle);
    if (!s || !java_surface) return JNI_FALSE;
    ANativeWindow *next = ANativeWindow_fromSurface(env, java_surface);
    if (!next) return JNI_FALSE;

    if (s->window && s->window != next) {
        release_surface_egl(s);
        ANativeWindow_release(s->window);
        s->window = next;
    } else if (s->window == next) {
        ANativeWindow_release(next);
    } else {
        s->window = next;
    }

    s->width = ANativeWindow_getWidth(s->window);
    s->height = ANativeWindow_getHeight(s->window);
    if (s->surface == EGL_NO_SURFACE && !create_surface_egl(s)) {
        return JNI_FALSE;
    }
    if (s->attached && s->state && s->callbacks.surface_changed) {
        s->callbacks.surface_changed(s->state, s->width, s->height);
    }
    return JNI_TRUE;
}

JNIEXPORT void JNICALL Java_dev_rune_RuneSurfaceView_nativeOnSurfaceChanged(
    JNIEnv *env,
    jobject thiz,
    jlong handle,
    jobject java_surface,
    jint width,
    jint height,
    jfloat density,
    jboolean dark
) {
    RuneAndroidSurface *s = surface_from_handle(env, thiz, handle);
    if (!s) return;
    if (java_surface) {
        ANativeWindow *next = ANativeWindow_fromSurface(env, java_surface);
        if (next) {
            if (s->window != next) {
                release_surface_egl(s);
                if (s->window) ANativeWindow_release(s->window);
                s->window = next;
                create_surface_egl(s);
            } else {
                ANativeWindow_release(next);
                if (s->surface == EGL_NO_SURFACE) create_surface_egl(s);
            }
        }
    }
    s->width = width;
    s->height = height;
    int32_t next_dark = dark ? 1 : 0;
    float next_density = density > 0.0f ? density : s->density;
    if (s->attached && s->state && s->callbacks.config_changed &&
        (next_density != s->density || next_dark != s->dark)) {
        s->density = next_density;
        s->density_dpi = (int32_t)lroundf(next_density * 160.0f);
        s->dark = next_dark;
        s->callbacks.config_changed(s->state, s->density_dpi, s->density, s->dark);
    } else {
        s->density = next_density;
        s->dark = next_dark;
    }
    if (s->attached && s->state && s->callbacks.surface_changed) {
        s->callbacks.surface_changed(s->state, s->width, s->height);
    }
}

JNIEXPORT void JNICALL Java_dev_rune_RuneSurfaceView_nativeOnSurfaceDestroyed(
    JNIEnv *env,
    jobject thiz,
    jlong handle
) {
    RuneAndroidSurface *s = surface_from_handle(env, thiz, handle);
    if (!s) return;
    release_surface_egl(s);
    if (s->window) {
        ANativeWindow_release(s->window);
        s->window = NULL;
    }
    if (s->attached && s->state && s->callbacks.surface_destroyed) {
        s->callbacks.surface_destroyed(s->state);
    }
}

JNIEXPORT jdouble JNICALL Java_dev_rune_RuneSurfaceView_nativeDrawFrame(
    JNIEnv *env,
    jobject thiz,
    jlong handle,
    jint width,
    jint height,
    jfloat density,
    jboolean dark
) {
    RuneAndroidSurface *s = surface_from_handle(env, thiz, handle);
    if (!s || !s->attached || !s->state || !s->visible || !s->window || !s->callbacks.frame) {
        return -1.0;
    }
    if (s->surface == EGL_NO_SURFACE && !create_surface_egl(s)) {
        return -1.0;
    }
    s->frame_requested = 0;

    const EGLDisplay previous_display = eglGetCurrentDisplay();
    const EGLContext previous_context = eglGetCurrentContext();
    const EGLSurface previous_draw = eglGetCurrentSurface(EGL_DRAW);
    const EGLSurface previous_read = eglGetCurrentSurface(EGL_READ);
    int switch_context = previous_context != s->context ||
                         previous_draw != s->surface ||
                         previous_read != s->surface;

    if (switch_context && !eglMakeCurrent(s->display, s->surface, s->surface, s->context)) {
        EGLint error = eglGetError();
        __android_log_print(ANDROID_LOG_ERROR, "SwiftRune", "RuneSurfaceView could not bind EGL context (0x%x)", error);
        release_surface_egl(s);
        if (error == EGL_CONTEXT_LOST && create_surface_egl(s)) {
            return 0.0;
        }
        return -1.0;
    }

    EGLint w = 0;
    EGLint h = 0;
    if (!eglQuerySurface(s->display, s->surface, EGL_WIDTH, &w) ||
        !eglQuerySurface(s->display, s->surface, EGL_HEIGHT, &h) ||
        w <= 0 || h <= 0) {
        w = width;
        h = height;
    }
    if (w <= 0 || h <= 0) {
        if (switch_context && previous_context != EGL_NO_CONTEXT) {
            eglMakeCurrent(previous_display, previous_draw, previous_read, previous_context);
        }
        return -1.0;
    }

    s->width = w;
    s->height = h;
    s->density = density > 0.0f ? density : 1.0f;
    s->dark = dark ? 1 : 0;

    double delay = s->callbacks.frame(s->state, w, h, s->density, s->dark);
    if (!isfinite(delay)) {
        if (switch_context && previous_context != EGL_NO_CONTEXT) {
            eglMakeCurrent(previous_display, previous_draw, previous_read, previous_context);
        }
        return delay;
    }

    if (!eglSwapBuffers(s->display, s->surface)) {
        EGLint error = eglGetError();
        __android_log_print(ANDROID_LOG_ERROR, "SwiftRune", "RuneSurfaceView EGL swap failed (0x%x)", error);
        release_surface_egl(s);
        if (error == EGL_CONTEXT_LOST && create_surface_egl(s)) {
            return 0.0;
        }
        return -1.0;
    }

    if (!s->presented) {
        s->presented = 1;
        if (s->callbacks.presented) {
            s->callbacks.presented(s->state);
        }
    }

    if (s->callbacks.poll_gpu && s->callbacks.poll_gpu(s->state, 1)) {
        schedule_surface_gpu_poll(s);
    }

    if (switch_context && previous_context != EGL_NO_CONTEXT) {
        eglMakeCurrent(previous_display, previous_draw, previous_read, previous_context);
    }

    schedule_surface_text_idle(s);
    return delay;
}

JNIEXPORT void JNICALL Java_dev_rune_RuneSurfaceView_nativeOnMotion(
    JNIEnv *env,
    jobject thiz,
    jlong handle,
    jint action,
    jint pointer_id,
    jboolean is_mouse,
    jint buttons,
    jint meta,
    jfloat x,
    jfloat y,
    jfloat hscroll,
    jfloat vscroll
) {
    RuneAndroidSurface *s = surface_from_handle(env, thiz, handle);
    if (!s || !s->attached || !s->state || !s->callbacks.motion) return;
    RuneAndroidMotion m = {
        .action = action,
        .id = pointer_id,
        .mouse = is_mouse ? 1 : 0,
        .buttons = buttons,
        .meta = meta,
        .x = x,
        .y = y,
        .hscroll = hscroll,
        .vscroll = vscroll
    };
    s->callbacks.motion(s->state, m);
    schedule_surface_text_idle(s);
}

JNIEXPORT jboolean JNICALL Java_dev_rune_RuneSurfaceView_nativeOnKey(
    JNIEnv *env,
    jobject thiz,
    jlong handle,
    jint action,
    jint keycode,
    jint meta,
    jint repeat_count,
    jint unicode_char
) {
    RuneAndroidSurface *s = surface_from_handle(env, thiz, handle);
    if (!s || !s->attached || !s->state || !s->callbacks.key) return JNI_FALSE;
    int32_t handled = s->callbacks.key(s->state, action, keycode, meta, repeat_count, (uint32_t)unicode_char);
    if (handled) {
        schedule_surface_text_idle(s);
    }
    return handled ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL Java_dev_rune_RuneSurfaceView_nativeOnFocusChanged(
    JNIEnv *env,
    jobject thiz,
    jlong handle,
    jboolean focused
) {
    RuneAndroidSurface *s = surface_from_handle(env, thiz, handle);
    if (!s || !s->attached || !s->state || !s->callbacks.focus) return;
    s->callbacks.focus(s->state, focused ? 1 : 0);
}

JNIEXPORT void JNICALL Java_dev_rune_RuneSurfaceView_nativeOnVisibilityChanged(
    JNIEnv *env,
    jobject thiz,
    jlong handle,
    jboolean visible
) {
    RuneAndroidSurface *s = surface_from_handle(env, thiz, handle);
    if (!s) return;
    s->visible = visible ? 1 : 0;
    if (s->attached && s->state && s->callbacks.visible) {
        s->callbacks.visible(s->state, s->visible);
    }
}

JNIEXPORT void JNICALL Java_dev_rune_RuneSurfaceView_nativeOnConfigurationChanged(
    JNIEnv *env,
    jobject thiz,
    jlong handle,
    jint density_dpi,
    jfloat density,
    jboolean dark
) {
    RuneAndroidSurface *s = surface_from_handle(env, thiz, handle);
    if (!s) return;
    s->density_dpi = density_dpi > 0 ? density_dpi : 160;
    s->density = density > 0.0f ? density : (float)s->density_dpi / 160.0f;
    s->dark = dark ? 1 : 0;
    if (s->attached && s->state && s->callbacks.config_changed) {
        s->callbacks.config_changed(s->state, s->density_dpi, s->density, s->dark);
    }
}

JNIEXPORT void JNICALL Java_dev_rune_RuneSurfaceView_nativeOnSafeAreaInsetsChanged(
    JNIEnv *env,
    jobject thiz,
    jlong handle,
    jfloat top,
    jfloat right,
    jfloat bottom,
    jfloat left
) {
    RuneAndroidSurface *s = surface_from_handle(env, thiz, handle);
    if (!s || !s->attached || !s->state || !s->callbacks.safe_area) return;
    s->callbacks.safe_area(s->state, top, right, bottom, left);
}

JNIEXPORT void JNICALL Java_dev_rune_RuneSurfaceView_nativeOnSuspendInput(
    JNIEnv *env,
    jobject thiz,
    jlong handle
) {
    RuneAndroidSurface *s = surface_from_handle(env, thiz, handle);
    if (!s || !s->attached || !s->state || !s->callbacks.suspend_input) return;
    s->callbacks.suspend_input(s->state);
}

static int register_surface_natives(JNIEnv *env, jobject view_obj) {
    if (!env || !view_obj) return 0;
    jclass cls = (*env)->GetObjectClass(env, view_obj);
    if (!cls) return 0;
    jmethodID declared = (*env)->GetMethodID(env, cls, "runeHostClass", "()Ljava/lang/Class;");
    jclass host = declared ? (jclass)(*env)->CallObjectMethod(env, view_obj, declared) : NULL;
    if (!host || (*env)->ExceptionCheck(env)) {
        clear_exception(env);
        (*env)->DeleteLocalRef(env, cls);
        return 0;
    }
    JNINativeMethod methods[] = {
        {"nativeCreate", "(Landroid/content/Context;Landroid/content/res/AssetManager;Ljava/lang/String;IFZ)J",
         (void *)Java_dev_rune_RuneSurfaceView_nativeCreate},
        {"nativeDestroy", "(J)V", (void *)Java_dev_rune_RuneSurfaceView_nativeDestroy},
        {"nativeOnSurfaceCreated", "(JLandroid/view/Surface;)Z",
         (void *)Java_dev_rune_RuneSurfaceView_nativeOnSurfaceCreated},
        {"nativeOnSurfaceChanged", "(JLandroid/view/Surface;IIFZ)V",
         (void *)Java_dev_rune_RuneSurfaceView_nativeOnSurfaceChanged},
        {"nativeOnSurfaceDestroyed", "(J)V", (void *)Java_dev_rune_RuneSurfaceView_nativeOnSurfaceDestroyed},
        {"nativeDrawFrame", "(JIIFZ)D", (void *)Java_dev_rune_RuneSurfaceView_nativeDrawFrame},
        {"nativeOnMotion", "(JIIZIIFFFF)V", (void *)Java_dev_rune_RuneSurfaceView_nativeOnMotion},
        {"nativeOnKey", "(JIIIII)Z", (void *)Java_dev_rune_RuneSurfaceView_nativeOnKey},
        {"nativeOnFocusChanged", "(JZ)V", (void *)Java_dev_rune_RuneSurfaceView_nativeOnFocusChanged},
        {"nativeOnVisibilityChanged", "(JZ)V", (void *)Java_dev_rune_RuneSurfaceView_nativeOnVisibilityChanged},
        {"nativeOnConfigurationChanged", "(JIFZ)V",
         (void *)Java_dev_rune_RuneSurfaceView_nativeOnConfigurationChanged},
        {"nativeOnSafeAreaInsetsChanged", "(JFFFF)V",
         (void *)Java_dev_rune_RuneSurfaceView_nativeOnSafeAreaInsetsChanged},
        {"nativeOnSuspendInput", "(J)V", (void *)Java_dev_rune_RuneSurfaceView_nativeOnSuspendInput},
    };
    int ok = (*env)->RegisterNatives(env, host, methods, (jint)(sizeof(methods) / sizeof(methods[0]))) == JNI_OK;
    if (!ok) clear_exception(env);
    (*env)->DeleteLocalRef(env, host);
    (*env)->DeleteLocalRef(env, cls);
    return ok;
}
#endif
