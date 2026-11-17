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
#endif
