#if defined(__ANDROID__)
#include "CRuneAndroid.h"
#include <android/asset_manager.h>
#include <android/choreographer.h>
#include <android/configuration.h>
#include <android/input.h>
#include <android/looper.h>
#include <android/log.h>
#include <android/native_activity.h>
#include <android/native_window.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/timerfd.h>
#include <unistd.h>

typedef struct {
    ANativeActivity *activity;
    ALooper *looper;
    AChoreographer *choreographer;
    AInputQueue *queue;
    ANativeWindow *window;
    AConfiguration *configuration;
    RuneAndroidCallbacks callbacks;
    void *state;
    EGLDisplay display;
    EGLContext context;
    EGLSurface surface;
    int wake_fd, timer_fd, idle_fd, gpu_fd, resumed, scheduled, frame_requested;
    int32_t last_mouse_buttons;
    int presented;
} Host;

void rune_android_present_rgba(void *raw, const uint8_t *pixels, int32_t width, int32_t height) {
    ANativeWindow *window = raw;
    if (!window || !pixels || width <= 0 || height <= 0 ||
        ANativeWindow_setBuffersGeometry(window, width, height, WINDOW_FORMAT_RGBA_8888) != 0)
        return;
    ANativeWindow_Buffer buf;
    if (ANativeWindow_lock(window, &buf, NULL) != 0)
        return;
    if (buf.bits && buf.format == WINDOW_FORMAT_RGBA_8888 && buf.width == width && buf.height == height) {
        for (int y = 0; y < height; y++)
            memcpy((uint8_t *)buf.bits + (size_t)y * buf.stride * 4, pixels + (size_t)y * width * 4,
                   (size_t)width * 4);
    }
    ANativeWindow_unlockAndPost(window);
}

void rune_android_log(const char *message) { __android_log_write(ANDROID_LOG_INFO, "SwiftRune", message); }
void rune_android_finish(void *activity) { ANativeActivity_finish(activity); }
void rune_android_keyboard(void *activity, int32_t show) {
    if (show)
        ANativeActivity_showSoftInput(activity, ANATIVEACTIVITY_SHOW_SOFT_INPUT_IMPLICIT);
    else
        ANativeActivity_hideSoftInput(activity, 0);
}

void *rune_android_resolve(const char *name) {
    // eglGetProcAddress need only provide extension symbols on EGL 1.4.
    void *core = dlsym(RTLD_DEFAULT, name);
    return core ? core : (void *)eglGetProcAddress(name);
}

char *rune_android_read_shader(void *raw, const char *name) {
    if (!name || strchr(name, '/') || strchr(name, '\\'))
        return NULL;
    char path[256];
    if (snprintf(path, sizeof(path), "GL/%s", name) >= (int)sizeof(path))
        return NULL;
    AAsset *asset = AAssetManager_open(((ANativeActivity *)raw)->assetManager, path, AASSET_MODE_BUFFER);
    if (!asset)
        return NULL;
    off_t length = AAsset_getLength(asset);
    char *bytes = length > 0 ? malloc((size_t)length + 1) : NULL;
    if (bytes && AAsset_read(asset, bytes, length) == length)
        bytes[length] = 0;
    else {
        free(bytes);
        bytes = NULL;
    }
    AAsset_close(asset);
    return bytes;
}
void rune_android_free_string(char *value) { free(value); }

// Android's default EGLDisplay is shared by activities and the Java UI toolkit.
// Keep its initialization for the process lifetime. Each Rune host owns only
// its context and window surface and never terminates another client's display.
static EGLDisplay process_display = EGL_NO_DISPLAY;

static void release_surface(Host *h) {
    if (h->display != EGL_NO_DISPLAY) {
        const EGLDisplay previous_display = eglGetCurrentDisplay();
        const EGLContext previous_context = eglGetCurrentContext();
        const EGLSurface previous_draw = eglGetCurrentSurface(EGL_DRAW);
        const EGLSurface previous_read = eglGetCurrentSurface(EGL_READ);
        if (h->context != EGL_NO_CONTEXT) {
            int current = h->surface != EGL_NO_SURFACE &&
                          eglMakeCurrent(h->display, h->surface, h->surface, h->context);
            h->callbacks.release_gpu(h->state, current);
            if (current)
                eglMakeCurrent(h->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        }
        if (h->surface != EGL_NO_SURFACE)
            eglDestroySurface(h->display, h->surface);
        if (h->context != EGL_NO_CONTEXT)
            eglDestroyContext(h->display, h->context);
        if (previous_context != EGL_NO_CONTEXT && previous_context != h->context)
            eglMakeCurrent(previous_display, previous_draw, previous_read, previous_context);
    }
    h->display = EGL_NO_DISPLAY;
    h->context = EGL_NO_CONTEXT;
    h->surface = EGL_NO_SURFACE;
}

static int create_surface(Host *h) {
    const EGLint attrs[] = {EGL_SURFACE_TYPE,
                            EGL_WINDOW_BIT,
                            EGL_RENDERABLE_TYPE,
                            EGL_OPENGL_ES3_BIT_KHR,
                            EGL_RED_SIZE,
                            8,
                            EGL_GREEN_SIZE,
                            8,
                            EGL_BLUE_SIZE,
                            8,
                            EGL_ALPHA_SIZE,
                            8,
                            EGL_NONE};
    const EGLint context_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    EGLConfig config;
    EGLint count, format;
    if (process_display == EGL_NO_DISPLAY) {
        EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        if (display == EGL_NO_DISPLAY || !eglInitialize(display, NULL, NULL))
            goto failed;
        process_display = display;
    }
    h->display = process_display;
    if (!eglBindAPI(EGL_OPENGL_ES_API) || !eglChooseConfig(h->display, attrs, &config, 1, &count) || !count ||
        !eglGetConfigAttrib(h->display, config, EGL_NATIVE_VISUAL_ID, &format) ||
        ANativeWindow_setBuffersGeometry(h->window, 0, 0, format) != 0)
        goto failed;
    h->context = eglCreateContext(h->display, config, EGL_NO_CONTEXT, context_attrs);
    h->surface = eglCreateWindowSurface(h->display, config, h->window, NULL);
    if (h->context == EGL_NO_CONTEXT || h->surface == EGL_NO_SURFACE ||
        !eglMakeCurrent(h->display, h->surface, h->surface, h->context))
        goto failed;
    eglSwapInterval(h->display, 1);
    __android_log_print(ANDROID_LOG_INFO, "SwiftRune", "GLES renderer: %s (%s)", glGetString(GL_RENDERER),
                        glGetString(GL_VERSION));
    return 1;
failed:
    __android_log_print(ANDROID_LOG_ERROR, "SwiftRune", "EGL window initialization failed (0x%x)",
                        eglGetError());
    release_surface(h);
    return 0;
}

static void schedule_frame(Host *h);
static void post_vsync(Host *h);

static int can_prepare_text(Host *h) {
    return h->state && h->presented && h->resumed && !h->frame_requested && h->surface != EGL_NO_SURFACE;
}

static void schedule_text_idle(Host *h) {
    if (can_prepare_text(h) && h->callbacks.text_idle && h->callbacks.text_idle(h->state, 0))
        rune_android_wake(h->idle_fd);
}

static void schedule_gpu_poll(Host *h) {
    // Only drivers without EGL fence sync need another looper turn. This
    // timer is independent of the application's next frame deadline.
    struct itimerspec timer = {.it_value = {.tv_nsec = 4000000}};
    timerfd_settime(h->gpu_fd, 0, &timer, NULL);
}

static int on_gpu_poll(int fd, int events, void *data) {
    if (!(events & ALOOPER_EVENT_INPUT)) return 0;
    uint64_t ignored;
    while (read(fd, &ignored, sizeof(ignored)) < 0 && errno == EINTR) {}
    Host *h = data;
    if (!h->state || h->surface == EGL_NO_SURFACE || !h->callbacks.poll_gpu(h->state, 0)) return 1;
    EGLDisplay previous_display = eglGetCurrentDisplay();
    EGLContext previous_context = eglGetCurrentContext();
    EGLSurface previous_draw = eglGetCurrentSurface(EGL_DRAW);
    EGLSurface previous_read = eglGetCurrentSurface(EGL_READ);
    int switch_context = previous_context != h->context || previous_draw != h->surface || previous_read != h->surface;
    if (switch_context && !eglMakeCurrent(h->display, h->surface, h->surface, h->context)) {
        release_surface(h);
        if (h->resumed && create_surface(h)) schedule_frame(h);
        return 1;
    }
    if (h->callbacks.poll_gpu(h->state, 1)) schedule_gpu_poll(h);
    if (switch_context) {
        if (previous_context == EGL_NO_CONTEXT)
            eglMakeCurrent(h->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        else
            eglMakeCurrent(previous_display, previous_draw, previous_read, previous_context);
    }
    return 1;
}

// CoreFoundation uses this libdispatch descriptor to drain DispatchQueue.main.
// Android owns the main loop, so register the same descriptor with its ALooper.
// The registration lives with the process main queue, including between activities.
static void (*drain_dispatch)(void *);

static int dispatch_ready(int fd, int events, void *data) {
    (void)fd;
    (void)data;
    if (!(events & ALOOPER_EVENT_INPUT))
        return 0;
    drain_dispatch(NULL);
    return 1;
}

static void attach_main_queue(ALooper *looper) {
    if (drain_dispatch)
        return;
    int (*get_handle)(void) = (int (*)(void))dlsym(RTLD_DEFAULT, "_dispatch_get_main_queue_handle_4CF");
    void (*drain)(void *) = (void (*)(void *))dlsym(RTLD_DEFAULT, "_dispatch_main_queue_callback_4CF");
    if (get_handle && drain) {
        int fd = get_handle();
        if (fd >= 0 && ALooper_addFd(looper, fd, ALOOPER_POLL_CALLBACK, ALOOPER_EVENT_INPUT, dispatch_ready,
                                     NULL) >= 0) {
            drain_dispatch = drain;
            return;
        }
    }
    rune_android_log("Swift main-queue descriptor unavailable for the Android looper");
}

static void draw(Host *h) {
    if (!h->state || !h->resumed || !h->window || h->surface == EGL_NO_SURFACE)
        return;
    h->frame_requested = 0;
    if (!eglMakeCurrent(h->display, h->surface, h->surface, h->context)) {
        EGLint error = eglGetError();
        __android_log_print(ANDROID_LOG_ERROR, "SwiftRune", "Could not bind EGL context (0x%x)", error);
        release_surface(h);
        if (error == EGL_CONTEXT_LOST && create_surface(h))
            schedule_frame(h);
        return;
    }
    EGLint w = 0, height = 0;
    if (!eglQuerySurface(h->display, h->surface, EGL_WIDTH, &w) ||
        !eglQuerySurface(h->display, h->surface, EGL_HEIGHT, &height) || w <= 0 || height <= 0)
        return;
    int dpi = AConfiguration_getDensity(h->configuration);
    float density = dpi > 0 && dpi < ACONFIGURATION_DENSITY_ANY ? dpi / 160.0f : 1.0f;
    double delay = h->callbacks.frame(h->state, w, height, density,
                                      AConfiguration_getUiModeNight(h->configuration) ==
                                          ACONFIGURATION_UI_MODE_NIGHT_YES);
    if (!isfinite(delay))
        return; // The renderer failed and requested activity shutdown.
    if (!eglSwapBuffers(h->display, h->surface)) {
        EGLint error = eglGetError();
        __android_log_print(ANDROID_LOG_ERROR, "SwiftRune", "EGL swap failed (0x%x)", error);
        release_surface(h);
        if (error == EGL_CONTEXT_LOST && create_surface(h))
            schedule_frame(h);
        return;
    }
    if (!h->presented) {
        h->presented = 1;
        h->callbacks.presented(h->state);
        __android_log_print(ANDROID_LOG_INFO, "SwiftRune", "Presented first Rune frame (%d x %d)", w, height);
    }
    struct itimerspec timer = {0};
    if (isfinite(delay) && delay > 0) {
        delay = fmin(delay, 86400.0);
        timer.it_value.tv_sec = (time_t)delay;
        timer.it_value.tv_nsec = (long)((delay - timer.it_value.tv_sec) * 1e9);
        if (!timer.it_value.tv_sec && !timer.it_value.tv_nsec)
            timer.it_value.tv_nsec = 1;
    }
    timerfd_settime(h->timer_fd, 0, &timer, NULL);
    if (delay == 0)
        post_vsync(h);
    if (h->callbacks.poll_gpu && h->callbacks.poll_gpu(h->state, 1)) schedule_gpu_poll(h);
    schedule_text_idle(h);
}

static void on_frame(long time_ns, void *data) {
    (void)time_ns;
    Host *h = data;
    h->scheduled = 0;
    // NativeActivity can be destroyed with a frame already posted. Keep only the
    // small C host until that callback drains; all window and Swift resources are gone.
    if (!h->state) {
        free(h);
        return;
    }
    draw(h);
}

static void post_vsync(Host *h) {
    if (h->scheduled || !h->resumed || h->surface == EGL_NO_SURFACE)
        return;
    h->scheduled = 1;
    // Available on API 24; ignore the timestamp (32-bit overflow on armeabi-v7a).
    if (__builtin_available(android 24, *)) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        AChoreographer_postFrameCallback(h->choreographer, on_frame, h);
#pragma clang diagnostic pop
    }
}

static void schedule_frame(Host *h) {
    h->frame_requested = 1;
    post_vsync(h);
}

// Run on a separate looper turn after the swap. A ready input queue, frame timer,
// or wake descriptor can precede its callback in this same looper dispatch.
static int on_text_idle(int fd, int events, void *data) {
    if (!(events & ALOOPER_EVENT_INPUT))
        return 0;
    uint64_t count;
    ssize_t size;
    do {
        size = read(fd, &count, sizeof(count));
    } while (size < 0 && errno == EINTR);
    if (size != sizeof(count))
        return 1;
    Host *h = data;
    if (!can_prepare_text(h) || (h->queue && AInputQueue_hasEvents(h->queue) > 0))
        return 1;
    struct pollfd frames[] = {{h->wake_fd, POLLIN, 0}, {h->timer_fd, POLLIN, 0}};
    int ready;
    do {
        ready = poll(frames, 2, 0);
    } while (ready < 0 && errno == EINTR);
    if (ready == 0 && h->callbacks.text_idle(h->state, 1))
        rune_android_wake(fd);
    return 1;
}

static int on_wake(int fd, int events, void *data) {
    if (!(events & ALOOPER_EVENT_INPUT))
        return 0;
    uint64_t ignored;
    while (read(fd, &ignored, sizeof(ignored)) < 0 && errno == EINTR) {
    }
    schedule_frame(data);
    return 1;
}
void rune_android_wake(int32_t fd) {
    uint64_t one = 1;
    while (write(fd, &one, sizeof(one)) < 0 && errno == EINTR) {
    }
}
void rune_android_close_wake(int32_t fd) { close(fd); }

uint32_t rune_android_compose_key(void *raw, uint32_t accent, uint32_t character) {
    JNIEnv *env = ((ANativeActivity *)raw)->env;
    jclass map = (*env)->FindClass(env, "android/view/KeyCharacterMap");
    uint32_t result = 0;
    if (map) {
        jmethodID method = (*env)->GetStaticMethodID(env, map, "getDeadChar", "(II)I");
        if (method) result = (uint32_t)(*env)->CallStaticIntMethod(env, map, method, (jint)accent, (jint)character);
        (*env)->DeleteLocalRef(env, map);
    }
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return 0;
    }
    return result;
}

static uint32_t unicode_key(Host *h, const AInputEvent *event) {
    // Native key codes are physical; consult Android's active device key character map.
    JNIEnv *env = h->activity->env;
    jclass klass = (*env)->FindClass(env, "android/view/KeyCharacterMap");
    uint32_t result = 0;
    if (klass) {
        jmethodID load = (*env)->GetStaticMethodID(env, klass, "load", "(I)Landroid/view/KeyCharacterMap;");
        jmethodID get = (*env)->GetMethodID(env, klass, "get", "(II)I");
        if (load && get) {
            jobject map = (*env)->CallStaticObjectMethod(env, klass, load, AInputEvent_getDeviceId(event));
            if (map) {
                result = (uint32_t)(*env)->CallIntMethod(env, map, get, AKeyEvent_getKeyCode(event),
                                                         AKeyEvent_getMetaState(event));
                (*env)->DeleteLocalRef(env, map);
            }
        }
        (*env)->DeleteLocalRef(env, klass);
    }
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return 0;
    }
    return result;
}

static int send_motion(Host *h, const AInputEvent *event) {
    int action = AMotionEvent_getAction(event);
    size_t count = AMotionEvent_getPointerCount(event);
    size_t first =
        (action & AMOTION_EVENT_ACTION_POINTER_INDEX_MASK) >> AMOTION_EVENT_ACTION_POINTER_INDEX_SHIFT;
    action &= AMOTION_EVENT_ACTION_MASK;
    size_t end = first + 1;
    if (action == AMOTION_EVENT_ACTION_MOVE || action == AMOTION_EVENT_ACTION_CANCEL) {
        first = 0;
        end = count;
    }
    if (action == AMOTION_EVENT_ACTION_POINTER_DOWN)
        action = AMOTION_EVENT_ACTION_DOWN;
    if (action == AMOTION_EVENT_ACTION_POINTER_UP)
        action = AMOTION_EVENT_ACTION_UP;
    if (action > AMOTION_EVENT_ACTION_HOVER_EXIT || end > count)
        return 0;
    int32_t buttons = AMotionEvent_getButtonState(event);
    for (size_t i = first; i < end; ++i) {
        int mouse = AMotionEvent_getToolType(event, i) == AMOTION_EVENT_TOOL_TYPE_MOUSE;
        RuneAndroidMotion m = {.action = action,
                               .id = AMotionEvent_getPointerId(event, i),
                               .mouse = mouse,
                               .buttons = action == AMOTION_EVENT_ACTION_UP && mouse ? h->last_mouse_buttons
                                                                                     : buttons,
                               .meta = AMotionEvent_getMetaState(event),
                               .x = AMotionEvent_getX(event, i),
                               .y = AMotionEvent_getY(event, i),
                               .hscroll = AMotionEvent_getAxisValue(event, AMOTION_EVENT_AXIS_HSCROLL, i),
                               .vscroll = AMotionEvent_getAxisValue(event, AMOTION_EVENT_AXIS_VSCROLL, i)};
        h->callbacks.motion(h->state, m);
        if (mouse)
            h->last_mouse_buttons = buttons;
    }
    return 1;
}

static int on_input(int fd, int events, void *data) {
    (void)fd;
    Host *h = data;
    if (!(events & ALOOPER_EVENT_INPUT))
        return 0;
    AInputEvent *event;
    while (AInputQueue_getEvent(h->queue, &event) >= 0) {
        if (AInputQueue_preDispatchEvent(h->queue, event))
            continue;
        int handled = 0;
        switch (AInputEvent_getType(event)) {
        case AINPUT_EVENT_TYPE_MOTION:
            handled = send_motion(h, event);
            break;
        case AINPUT_EVENT_TYPE_KEY:
            handled = h->callbacks.key(h->state, AKeyEvent_getAction(event), AKeyEvent_getKeyCode(event),
                                       AKeyEvent_getMetaState(event), AKeyEvent_getRepeatCount(event),
                                       unicode_key(h, event));
            break;
        }
        AInputQueue_finishEvent(h->queue, event, handled);
        if (handled)
            schedule_frame(h);
    }
    schedule_text_idle(h);
    return 1;
}

static void queue_created(ANativeActivity *a, AInputQueue *queue) {
    Host *h = a->instance;
    h->queue = queue;
    AInputQueue_attachLooper(queue, h->looper, ALOOPER_POLL_CALLBACK, on_input, h);
}
static void queue_destroyed(ANativeActivity *a, AInputQueue *queue) {
    AInputQueue_detachLooper(queue);
    ((Host *)a->instance)->queue = NULL;
}
static void window_created(ANativeActivity *a, ANativeWindow *window) {
    Host *h = a->instance;
    h->window = window;
    if (create_surface(h))
        schedule_frame(h);
    else
        ANativeActivity_finish(a);
}
static void window_destroyed(ANativeActivity *a, ANativeWindow *window) {
    (void)window;
    Host *h = a->instance;
    h->callbacks.suspend_input(h->state);
    release_surface(h);
    h->window = NULL;
}
static void resized(ANativeActivity *a, ANativeWindow *window) {
    (void)window;
    schedule_frame(a->instance);
}
static void redraw(ANativeActivity *a, ANativeWindow *window) {
    (void)window;
    draw(a->instance);
}
static void focus(ANativeActivity *a, int focused) {
    Host *h = a->instance;
    h->callbacks.focus(h->state, focused);
    if (!focused)
        h->callbacks.suspend_input(h->state);
    else
        schedule_frame(h);
}
static void config(ANativeActivity *a) {
    Host *h = a->instance;
    AConfiguration_fromAssetManager(h->configuration, a->assetManager);
    schedule_frame(h);
}
static void resume(ANativeActivity *a) {
    Host *h = a->instance;
    h->resumed = 1;
    h->callbacks.visible(h->state, 1);
    schedule_frame(h);
}
static void pause_host(ANativeActivity *a) {
    Host *h = a->instance;
    h->resumed = 0;
    h->callbacks.visible(h->state, 0);
    h->callbacks.suspend_input(h->state);
}
static void destroy(ANativeActivity *a) {
    Host *h = a->instance;
    if (h->queue)
        AInputQueue_detachLooper(h->queue);
    release_surface(h);
    ALooper_removeFd(h->looper, h->wake_fd);
    ALooper_removeFd(h->looper, h->timer_fd);
    ALooper_removeFd(h->looper, h->idle_fd);
    ALooper_removeFd(h->looper, h->gpu_fd);
    close(h->wake_fd);
    close(h->timer_fd);
    close(h->idle_fd);
    close(h->gpu_fd);
    AConfiguration_delete(h->configuration);
    h->callbacks.destroy(h->state);
    h->state = NULL;
    a->instance = NULL;
    if (!h->scheduled)
        free(h);
}

int32_t rune_android_attach(void *raw, void *state, RuneAndroidCallbacks callbacks) {
    ANativeActivity *a = raw;
    if (!a || !state || a->instance || !a->callbacks || !ALooper_forThread())
        return -1;
    Host *h = calloc(1, sizeof(Host));
    if (!h)
        return -1;
    h->activity = a;
    h->state = state;
    h->callbacks = callbacks;
    h->looper = ALooper_forThread();
    if (__builtin_available(android 24, *))
        h->choreographer = AChoreographer_getInstance();
    h->configuration = AConfiguration_new();
    h->wake_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    h->timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
    h->idle_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    h->gpu_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
    int writer = h->wake_fd >= 0 ? fcntl(h->wake_fd, F_DUPFD_CLOEXEC, 0) : -1;
    if (!h->choreographer || !h->configuration || h->wake_fd < 0 || h->timer_fd < 0 || h->idle_fd < 0 || h->gpu_fd < 0 || writer < 0 ||
        ALooper_addFd(h->looper, h->wake_fd, ALOOPER_POLL_CALLBACK, ALOOPER_EVENT_INPUT, on_wake, h) < 0 ||
        ALooper_addFd(h->looper, h->timer_fd, ALOOPER_POLL_CALLBACK, ALOOPER_EVENT_INPUT, on_wake, h) < 0 ||
        ALooper_addFd(h->looper, h->idle_fd, ALOOPER_POLL_CALLBACK, ALOOPER_EVENT_INPUT, on_text_idle, h) < 0 ||
        ALooper_addFd(h->looper, h->gpu_fd, ALOOPER_POLL_CALLBACK, ALOOPER_EVENT_INPUT, on_gpu_poll, h) < 0) {
        if (h->configuration)
            AConfiguration_delete(h->configuration);
        if (h->wake_fd >= 0) {
            ALooper_removeFd(h->looper, h->wake_fd);
            close(h->wake_fd);
        }
        if (h->timer_fd >= 0) {
            ALooper_removeFd(h->looper, h->timer_fd);
            close(h->timer_fd);
        }
        if (h->idle_fd >= 0) {
            ALooper_removeFd(h->looper, h->idle_fd);
            close(h->idle_fd);
        }
        if (h->gpu_fd >= 0) {
            ALooper_removeFd(h->looper, h->gpu_fd);
            close(h->gpu_fd);
        }
        if (writer >= 0)
            close(writer);
        free(h);
        return -1;
    }
    a->instance = h;
    config(a);
    attach_main_queue(h->looper);
    ANativeActivityCallbacks *cb = a->callbacks;
    cb->onDestroy = destroy;
    cb->onResume = resume;
    cb->onPause = pause_host;
    cb->onWindowFocusChanged = focus;
    cb->onConfigurationChanged = config;
    cb->onNativeWindowCreated = window_created;
    cb->onNativeWindowResized = resized;
    cb->onNativeWindowRedrawNeeded = redraw;
    cb->onNativeWindowDestroyed = window_destroyed;
    cb->onInputQueueCreated = queue_created;
    cb->onInputQueueDestroyed = queue_destroyed;
    return writer;
}
#endif
