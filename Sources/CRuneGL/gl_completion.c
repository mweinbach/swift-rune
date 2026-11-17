#if defined(__linux__)

#include "gl_api.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

typedef struct Completion {
    struct Completion *next, *next_origin;
    void *user;
    void (*finished)(void *, int);
    EGLSyncKHR egl;
    void *gl;
    int result;
} Completion;

struct RuneGLCompletion {
    RuneGL *renderer;
    EGLDisplay display;
    PFNEGLCREATESYNCKHRPROC create_khr;
    PFNEGLCLIENTWAITSYNCKHRPROC wait_khr;
    PFNEGLDESTROYSYNCKHRPROC destroy_khr;
    PFNEGLCREATESYNCPROC create_core;
    PFNEGLCLIENTWAITSYNCPROC wait_core;
    PFNEGLDESTROYSYNCPROC destroy_core;
    pthread_t receiver;
    pthread_cond_t changed;
    pthread_mutex_t lock;
    Completion *head, *tail;
    Completion *origin_head, *origin_tail;
    int closed, lost, detached;
};

static int has_extension(const char *names, const char *name) {
    if (!names) return 0;
    size_t n = strlen(name);
    const char *p = names;
    while ((p = strstr(p, name)) != NULL) {
        if ((p == names || p[-1] == ' ') && (p[n] == ' ' || !p[n])) return 1;
        p += n;
    }
    return 0;
}

static void *egl_function(const char *name) {
    void *fn = dlsym(RTLD_DEFAULT, name);
    return fn ? fn : (void *)eglGetProcAddress(name);
}

static void configure_egl(RuneGLCompletion *q) {
    q->display = eglGetCurrentDisplay();
    if (q->display == EGL_NO_DISPLAY || eglGetCurrentContext() == EGL_NO_CONTEXT) return;
    if (has_extension(eglQueryString(q->display, EGL_EXTENSIONS), "EGL_KHR_fence_sync")) {
        q->create_khr = (PFNEGLCREATESYNCKHRPROC)egl_function("eglCreateSyncKHR");
        q->wait_khr = (PFNEGLCLIENTWAITSYNCKHRPROC)egl_function("eglClientWaitSyncKHR");
        q->destroy_khr = (PFNEGLDESTROYSYNCKHRPROC)egl_function("eglDestroySyncKHR");
        if (q->create_khr && q->wait_khr && q->destroy_khr) return;
        q->create_khr = NULL;
    }
    const char *version = eglQueryString(q->display, EGL_VERSION);
    if (version && strncmp(version, "1.5", 3) >= 0) {
        q->create_core = (PFNEGLCREATESYNCPROC)egl_function("eglCreateSync");
        q->wait_core = (PFNEGLCLIENTWAITSYNCPROC)egl_function("eglClientWaitSync");
        q->destroy_core = (PFNEGLDESTROYSYNCPROC)egl_function("eglDestroySync");
        if (!q->wait_core || !q->destroy_core) q->create_core = NULL;
    }
}

static void release_egl(RuneGLCompletion *q, Completion *job) {
    if (q->create_khr) q->destroy_khr(q->display, job->egl);
    else q->destroy_core(q->display, job->egl);
    job->egl = EGL_NO_SYNC_KHR;
}

static void dispose(RuneGLCompletion *q) {
    pthread_cond_destroy(&q->changed);
    pthread_mutex_destroy(&q->lock);
    free(q);
}

static void *receive(void *raw) {
    RuneGLCompletion *q = raw;
    pthread_mutex_lock(&q->lock);
    for (;;) {
        Completion *job = q->head;
        if (!job && q->closed) break;
        if (!job || job->gl) {
            pthread_cond_wait(&q->changed, &q->lock);
            continue;
        }
        if (job->egl) {
            int lost = q->lost;
            pthread_mutex_unlock(&q->lock);
            EGLint status = EGL_FALSE;
            if (!lost) {
                // A bounded wait lets context loss interrupt an unsignalled fence.
                const EGLTimeKHR timeout = 10000000;
                status = q->create_khr ? q->wait_khr(q->display, job->egl, 0, timeout)
                                       : q->wait_core(q->display, job->egl, 0, timeout);
            }
            pthread_mutex_lock(&q->lock);
            if (status == EGL_TIMEOUT_EXPIRED_KHR && !q->lost) continue;
            release_egl(q, job);
            job->result = status == EGL_CONDITION_SATISFIED_KHR;
        }
        q->head = job->next;
        if (!q->head) q->tail = NULL;
        int completed = !q->lost && job->result;
        pthread_mutex_unlock(&q->lock);
        job->finished(job->user, completed);
        free(job);
        pthread_mutex_lock(&q->lock);
    }
    int detached = q->detached;
    pthread_mutex_unlock(&q->lock);
    if (q->create_khr || q->create_core) eglReleaseThread();
    if (detached) dispose(q);
    return NULL;
}

RuneGLCompletion *rune_gl_completion_create(RuneGL *renderer) {
    if (!rune_gl_current_api(renderer)) return NULL;
    RuneGLCompletion *q = calloc(1, sizeof(*q));
    if (!q) return NULL;
    q->renderer = renderer;
    configure_egl(q);
    if (pthread_mutex_init(&q->lock, NULL)) { free(q); return NULL; }
    if (pthread_cond_init(&q->changed, NULL)) {
        pthread_mutex_destroy(&q->lock);
        free(q);
        return NULL;
    }
    if (pthread_create(&q->receiver, NULL, receive, q)) { dispose(q); return NULL; }
    return q;
}

int rune_gl_completion_submit(RuneGLCompletion *q, void *user, void (*finished)(void *, int)) {
    if (!q || !finished) return 0;
    Completion *job = calloc(1, sizeof(*job));
    if (!job) return 0;
    job->user = user;
    job->finished = finished;
    pthread_mutex_lock(&q->lock);
    if (q->closed) {
        pthread_mutex_unlock(&q->lock);
        free(job);
        return 0;
    }
    if (q->create_khr) job->egl = q->create_khr(q->display, EGL_SYNC_FENCE_KHR, NULL);
    else if (q->create_core) job->egl = q->create_core(q->display, EGL_SYNC_FENCE, NULL);
    if (job->egl) rune_gl_current_api(q->renderer)->Flush();
    else {
        job->gl = rune_gl_submit_fence(q->renderer);
        if (!job->gl) {
            pthread_mutex_unlock(&q->lock);
            free(job);
            return 0;
        }
    }
    if (job->gl) {
        if (q->origin_tail) q->origin_tail->next_origin = job;
        else q->origin_head = job;
        q->origin_tail = job;
    }
    if (q->tail) q->tail->next = job;
    else q->head = job;
    q->tail = job;
    pthread_cond_signal(&q->changed);
    pthread_mutex_unlock(&q->lock);
    return 1;
}

// GLsync objects belong to the originating context. Complete them in submission
// order and let the receiver deliver the callbacks after the lock is released.
static int poll_origin(RuneGLCompletion *q, int wait, int lost) {
    while (q->origin_head) {
        Completion *job = q->origin_head;
        if (!lost) {
            int result = rune_gl_surface_wait(q->renderer, job->gl, wait);
            if (!result) break;
            rune_gl_surface_fence_free(q->renderer, job->gl);
            job->result = result > 0;
        }
        job->gl = NULL;
        q->origin_head = job->next_origin;
    }
    if (!q->origin_head) q->origin_tail = NULL;
    pthread_cond_signal(&q->changed);
    return q->origin_head != NULL;
}

int rune_gl_completion_needs_poll(RuneGLCompletion *q) {
    if (!q) return 0;
    pthread_mutex_lock(&q->lock);
    int pending = q->origin_head != NULL;
    pthread_mutex_unlock(&q->lock);
    return pending;
}

int rune_gl_completion_poll(RuneGLCompletion *q) {
    if (!q) return 0;
    pthread_mutex_lock(&q->lock);
    int pending = poll_origin(q, 0, 0);
    pthread_mutex_unlock(&q->lock);
    return pending;
}

void rune_gl_completion_destroy(RuneGLCompletion *q, int context_lost) {
    if (!q) return;
    pthread_mutex_lock(&q->lock);
    q->closed = 1;
    q->lost = context_lost;
    poll_origin(q, 1, context_lost);
    if (pthread_equal(q->receiver, pthread_self())) {
        // An observer may discard its renderer. Release native fences before
        // the caller tears down its EGLDisplay, then finish releasing users.
        if (context_lost) {
            for (Completion *job = q->head; job; job = job->next)
                if (job->egl) release_egl(q, job);
        }
        q->detached = 1;
        pthread_detach(q->receiver);
        pthread_mutex_unlock(&q->lock);
        return;
    }
    pthread_mutex_unlock(&q->lock);
    pthread_join(q->receiver, NULL);
    dispose(q);
}
#endif
