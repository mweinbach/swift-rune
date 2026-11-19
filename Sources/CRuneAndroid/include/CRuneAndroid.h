#ifndef CRUNEANDROID_H
#define CRUNEANDROID_H
#include <stdint.h>
#include "RuneAndroidSemantics.h"

typedef struct {
    int32_t action;
    int32_t id;
    int32_t mouse;
    int32_t buttons;
    int32_t meta;
    float x, y, hscroll, vscroll;
} RuneAndroidMotion;

typedef struct {
    // Returns seconds until the next frame, zero for next vsync, negative to sleep.
    double (*frame)(void *, int32_t width, int32_t height, float density, int32_t dark);
    void (*presented)(void *);
    // Query (run == 0) or perform one idle turn. Returns whether more work is owed.
    int32_t (*text_idle)(void *, int32_t run);
    // Query (run == 0) or poll pending GLsyncs on the originating context.
    int32_t (*poll_gpu)(void *, int32_t run);
    void (*release_gpu)(void *, int32_t context_current);
    void (*focus)(void *, int32_t active);
    void (*visible)(void *, int32_t active);
    void (*suspend_input)(void *);
    void (*destroy)(void *);
    void (*motion)(void *, RuneAndroidMotion);
    int32_t (*key)(void *, int32_t action, int32_t keycode, int32_t meta, int32_t repeat, uint32_t character);
} RuneAndroidCallbacks;

// Call on the NativeActivity main thread, from ANativeActivity_onCreate. On success,
// returns a duplicated eventfd owned by the caller for thread-safe wakeups.
int32_t rune_android_attach(void *activity, void *state, RuneAndroidCallbacks callbacks);
void rune_android_wake(int32_t fd);
void rune_android_close_wake(int32_t fd);
void *rune_android_resolve(const char *name);
char *rune_android_read_shader(void *activity, const char *name);
void rune_android_free_string(char *value);
void rune_android_log(const char *message);
void rune_android_finish(void *activity);
void rune_android_present_rgba(void *window, const uint8_t *pixels, int32_t width, int32_t height);
uint32_t rune_android_compose_key(void *activity, uint32_t accent, uint32_t key);
void rune_android_keyboard(void *activity, int32_t show);

// MARK: - Embeddable RuneSurfaceView Host

typedef struct RuneAndroidSurface RuneAndroidSurface;

typedef struct {
    // Returns seconds until the next frame, zero for next vsync, negative to sleep.
    double (*frame)(void *, int32_t width, int32_t height, float density, int32_t dark);
    void (*presented)(void *);
    // Query (run == 0) or perform one idle turn. Returns whether more work is owed.
    int32_t (*text_idle)(void *, int32_t run);
    // Query (run == 0) or poll pending GLsyncs on the originating context.
    int32_t (*poll_gpu)(void *, int32_t run);
    void (*release_gpu)(void *, int32_t context_current);
    void (*focus)(void *, int32_t active);
    void (*visible)(void *, int32_t active);
    void (*surface_changed)(void *, int32_t width, int32_t height);
    void (*surface_destroyed)(void *);
    void (*config_changed)(void *, int32_t density_dpi, float density, int32_t dark);
    void (*safe_area)(void *, float top, float right, float bottom, float left);
    void (*suspend_input)(void *);
    void (*destroy)(void *);
    void (*motion)(void *, RuneAndroidMotion);
    int32_t (*key)(void *, int32_t action, int32_t keycode, int32_t meta, int32_t repeat, uint32_t character);
} RuneAndroidSurfaceCallbacks;

// Factory callback invoked when dev.rune.RuneSurfaceView instantiates a named Swift view.
// Return non-zero once rune_android_surface_attach has bound callbacks to `surface`.
typedef int32_t (*RuneAndroidSurfaceFactoryResolver)(void *surface, const char *factory_name);

void rune_android_surface_set_factory_resolver(RuneAndroidSurfaceFactoryResolver resolver);

// Creates a RuneAndroidSurface directly from custom JNI (JNIEnv*, RuneSurfaceView, Context,
// AssetManager, optional android.view.Surface) and binds the handle onto the view.
void *rune_android_surface_create_from_jni(
    void *jni_env,
    void *surface_view,
    void *context,
    void *asset_manager,
    void *java_surface
);
void rune_android_surface_destroy(void *surface);

// Attaches Swift callbacks to a RuneAndroidSurface (and optional ANativeWindow*).
// Returns a duplicated eventfd owned by the caller for thread-safe wakeups (-1 on failure).
int32_t rune_android_surface_attach(
    void *surface,
    void *native_window,
    void *state,
    RuneAndroidSurfaceCallbacks callbacks
);

void rune_android_surface_request_frame(void *surface);
void rune_android_surface_request_close(void *surface);
void rune_android_surface_keyboard(void *surface, int32_t show);

// ANativeActivity-compatible shims for RuneText/RuneImages (Context) and AndroidSemanticBridge (View).
void *rune_android_surface_context_shim(void *surface);
void *rune_android_surface_semantics_shim(void *surface);

char *rune_android_surface_read_shader(void *surface, const char *name);
uint32_t rune_android_surface_compose_key(void *surface, uint32_t accent, uint32_t key);
#endif
