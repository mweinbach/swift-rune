#if defined(__linux__) && !defined(__ANDROID__)
#define _POSIX_C_SOURCE 200809L
#include "RuneNotifyLinuxFocus.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

struct Window {
    uint32_t id, event;
    RuneNotifyLinuxWake wake;
    int visible, was_shown;
    struct Window *next;
};

/* Most recently focused windows come first. Never expose SDL window pointers
 * across the notification thread and the UI event loop. */
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static struct Window *windows;
static uint32_t focused_id, requested_id;
static char *requested_token;

static struct Window **slot(uint32_t id) {
    struct Window **p = &windows;
    while (*p && (*p)->id != id) p = &(*p)->next;
    return p;
}

static struct Window *activation_target(void) {
    struct Window *hidden = NULL;
    for (struct Window *w = windows; w; w = w->next) {
        if (w->visible) return w;
        if (!hidden && w->was_shown) hidden = w;
    }
    return hidden;
}

void rune_notify_linux_window_opened(uint32_t id, uint32_t event, RuneNotifyLinuxWake wake) {
    if (!id || !wake) return;
    struct Window *w = calloc(1, sizeof *w);
    if (!w) return;
    w->id = id;
    w->event = event;
    w->wake = wake;
    pthread_mutex_lock(&lock);
    struct Window **p = slot(id);
    if (!*p) *p = w;
    else free(w);
    pthread_mutex_unlock(&lock);
}

void rune_notify_linux_window_closed(uint32_t id) {
    if (!id) return;
    RuneNotifyLinuxWake wake = NULL;
    uint32_t next_id = 0, event = 0;
    pthread_mutex_lock(&lock);
    struct Window **p = slot(id);
    if (*p) {
        struct Window *closed = *p;
        *p = closed->next;
        free(closed);
    }
    if (focused_id == id) focused_id = 0;
    if (requested_id == id) {
        struct Window *w = activation_target();
        requested_id = w ? w->id : 0;
        if (w) {
            wake = w->wake;
            next_id = w->id;
            event = w->event;
        } else {
            free(requested_token);
            requested_token = NULL;
        }
    }
    pthread_mutex_unlock(&lock);
    if (wake) wake(next_id, event);
}

void rune_notify_linux_window_visible(uint32_t id, int visible) {
    pthread_mutex_lock(&lock);
    struct Window *w = *slot(id);
    if (w) {
        w->visible = visible;
        if (visible) w->was_shown = 1;
        if (!visible && focused_id == id) focused_id = 0;
    }
    pthread_mutex_unlock(&lock);
}

void rune_notify_linux_window_focus(uint32_t id, int focused) {
    pthread_mutex_lock(&lock);
    struct Window **p = slot(id);
    if (*p && focused) {
        struct Window *w = *p;
        *p = w->next;
        w->next = windows;
        windows = w;
        focused_id = id;
    } else if (focused_id == id) {
        focused_id = 0;
    }
    pthread_mutex_unlock(&lock);
}

int rune_notify_linux_app_focused(void) {
    pthread_mutex_lock(&lock);
    int focused = focused_id != 0;
    pthread_mutex_unlock(&lock);
    return focused;
}

void rune_notify_linux_bring_to_front(const char *token) {
    RuneNotifyLinuxWake wake = NULL;
    uint32_t id = 0, event = 0;
    pthread_mutex_lock(&lock);
    struct Window *w = activation_target();
    if (w) {
        id = requested_id = w->id;
        wake = w->wake;
        event = w->event;
        free(requested_token);
        requested_token = token ? strdup(token) : NULL;
    }
    pthread_mutex_unlock(&lock);
    if (wake) wake(id, event);
}

int rune_notify_linux_take_activation(uint32_t id, char **token) {
    pthread_mutex_lock(&lock);
    int requested = id != 0 && id == requested_id;
    *token = NULL;
    if (requested) {
        *token = requested_token;
        requested_token = NULL;
        requested_id = 0;
    }
    pthread_mutex_unlock(&lock);
    return requested;
}
#endif
