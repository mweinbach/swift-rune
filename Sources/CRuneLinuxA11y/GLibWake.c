#define _GNU_SOURCE
#if defined(__linux__) && !defined(__ANDROID__)
#include "GLibWake.h"
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

/* Monitor GLib's descriptors without reading or dispatching them off the SDL thread.
   A wake in either event loop interrupts the other's wait. */
struct RuneGLibWatch {
    RuneA11yWake wake;
    void *context;
    int pipe[2];
    GMutex lock;
    GPollFD *fds;
    guint count;
    gint64 deadline;
    gboolean stopping;
    GThread *thread;
};

static gpointer wait_for_sources(gpointer data) {
    RuneGLibWatch *watch = data;
    for (;;) {
        g_mutex_lock(&watch->lock);
        if (watch->stopping) {
            g_mutex_unlock(&watch->lock);
            return NULL;
        }
        guint count = watch->count;
        GPollFD *fds = g_new(GPollFD, count + 1);
        if (count) memcpy(fds, watch->fds, count * sizeof(*fds));
        fds[count] = (GPollFD){watch->pipe[0], G_IO_IN, 0};
        gint64 deadline = watch->deadline;
        g_mutex_unlock(&watch->lock);

        int timeout = deadline < 0 ? -1 : (int)CLAMP((deadline - g_get_monotonic_time() + 999) / 1000, 0, G_MAXINT);
        int result = g_poll(fds, count + 1, timeout);
        gboolean config_changed = fds[count].revents != 0;
        g_free(fds);
        if (result < 0 && errno == EINTR) continue;
        if (!config_changed) {
            watch->wake(watch->context);
            /* Coalesce readiness until the SDL thread pumps GLib and arms us again. */
            GPollFD cancel = {watch->pipe[0], G_IO_IN, 0};
            while (g_poll(&cancel, 1, -1) < 0 && errno == EINTR) {}
        }
        char bytes[128];
        while (read(watch->pipe[0], bytes, sizeof(bytes)) > 0) {}
    }
}

RuneGLibWatch *rune_glib_watch_new(RuneA11yWake wake, void *context) {
    RuneGLibWatch *watch = g_new0(RuneGLibWatch, 1);
    if (pipe2(watch->pipe, O_CLOEXEC | O_NONBLOCK) != 0) { g_free(watch); return NULL; }
    g_mutex_init(&watch->lock);
    watch->deadline = -1;
    watch->wake = wake;
    watch->context = context;
    watch->thread = g_thread_new("rune-atspi-wait", wait_for_sources, watch);
    return watch;
}

void rune_glib_watch_arm(RuneGLibWatch *watch) {
    GMainContext *context = g_main_context_default();
    if (!g_main_context_acquire(context)) return;
    int priority, timeout, count = 0, capacity = 0;
    GPollFD *fds = NULL;
    gboolean ready = g_main_context_prepare(context, &priority);
    while ((count = g_main_context_query(context, priority, &timeout, fds, capacity)) > capacity) {
        capacity = count;
        fds = g_renew(GPollFD, fds, capacity);
    }
    /* Some GSources arm a native read in prepare. In particular GDK's Wayland
     * source calls wl_display_prepare_read_queue. Complete this nonblocking
     * inspection before returning to code which may synchronously round-trip
     * the same display (for example, mapping a second layer surface). No
     * events have been polled by this thread and callbacks are not dispatched. */
    for (int i = 0; i < count; ++i) fds[i].revents = 0;
    if (g_main_context_check(context, priority, fds, count)) ready = TRUE;
    g_main_context_release(context);
    g_mutex_lock(&watch->lock);
    g_free(watch->fds);
    watch->fds = fds;
    watch->count = count;
    watch->deadline = ready ? 0 : timeout < 0 ? -1 : g_get_monotonic_time() + (gint64)timeout * 1000;
    g_mutex_unlock(&watch->lock);
    (void)write(watch->pipe[1], "a", 1);
}

void rune_glib_watch_free(RuneGLibWatch *watch) {
    g_mutex_lock(&watch->lock);
    watch->stopping = TRUE;
    g_mutex_unlock(&watch->lock);
    (void)write(watch->pipe[1], "q", 1);
    g_thread_join(watch->thread);
    close(watch->pipe[0]);
    close(watch->pipe[1]);
    g_mutex_clear(&watch->lock);
    g_free(watch->fds);
    g_free(watch);
}
#endif
