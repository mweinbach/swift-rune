#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "LazyGL.h"
#include <stdint.h>
#include <stdlib.h>
#include "include/CRuneWin32.h"

typedef struct CompletionJob {
    void *fence, *context;
    RuneWinGLCompleted finish;
    int completed;
    struct CompletionJob *next;
} CompletionJob;

typedef struct {
    CompletionJob *first, *last;
} Jobs;

typedef GLenum (APIENTRY *ClientWait)(void *, GLbitfield, uint64_t);
typedef void (APIENTRY *DeleteSync)(void *);

struct RuneWinGLCompletion {
    SRWLOCK lock;
    CONDITION_VARIABLE work;
    HANDLE thread;
    DWORD thread_id;
    LONG references;
    int closing, lost, timer;
    HWND window;
    HDC dc;
    HGLRC source;
    ClientWait wait;
    DeleteSync release;
    Jobs pending, ready;
    struct RuneWinGLCompletion *next;
};

// Window timers may already be queued when canceled. Resolve each callback against live owners.
static SRWLOCK registry_lock = SRWLOCK_INIT;
static RuneWinGLCompletion *workers;

static void append(Jobs *jobs, CompletionJob *job) {
    job->next = NULL;
    if (jobs->last) jobs->last->next = job; else jobs->first = job;
    jobs->last = job;
}

static CompletionJob *pop(Jobs *jobs) {
    CompletionJob *job = jobs->first;
    if (job) {
        jobs->first = job->next;
        if (!jobs->first) jobs->last = NULL;
    }
    return job;
}

static void release_worker(RuneWinGLCompletion *w) {
    if (InterlockedDecrement(&w->references) == 0) {
        CloseHandle(w->thread);
        free(w);
    }
}

static DWORD WINAPI run(LPVOID context) {
    RuneWinGLCompletion *w = context;
    for (;;) {
        AcquireSRWLockExclusive(&w->lock);
        while (!w->ready.first && !w->closing)
            SleepConditionVariableSRW(&w->work, &w->lock, INFINITE, 0);
        CompletionJob *job = pop(&w->ready);
        int lost = w->lost;
        ReleaseSRWLockExclusive(&w->lock);
        if (!job) break;
        job->finish(job->context, job->completed && !lost);
        free(job);
    }
    release_worker(w);
    return 0;
}

// Only the original GL context polls its own fences. Some WGL drivers share textures but
// reject GLsync objects from another context. A zero-timeout poll never waits for the GPU.
static void poll(RuneWinGLCompletion *w, int drain) {
    AcquireSRWLockExclusive(&w->lock);
    while (w->pending.first) {
        CompletionJob *job = w->pending.first;
        GLenum result = w->wait(job->fence, 0, drain ? UINT64_C(10000000) : 0);
        if (result == 0x911B /* GL_TIMEOUT_EXPIRED */) {
            if (drain) continue;
            break;
        }
        w->release(job->fence);
        job->fence = NULL;
        job->completed = result == 0x911A || result == 0x911C;
        append(&w->ready, pop(&w->pending));
        WakeConditionVariable(&w->work);
    }
    if (!w->pending.first && w->timer) {
        KillTimer(w->window, (UINT_PTR)w);
        w->timer = 0;
    }
    ReleaseSRWLockExclusive(&w->lock);
}

static void CALLBACK poll_timer(HWND window, UINT message, UINT_PTR id, DWORD time) {
    (void)message; (void)time;
    AcquireSRWLockShared(&registry_lock);
    for (RuneWinGLCompletion *w = workers; w; w = w->next) {
        if ((UINT_PTR)w != id || w->window != window) continue;
        HGLRC previous = rune_lazy_wglGetCurrentContext();
        HDC dc = rune_lazy_wglGetCurrentDC();
        if (previous == w->source) poll(w, 0);
        else if (rune_lazy_wglMakeCurrent(w->dc, w->source)) {
            poll(w, 0);
            rune_lazy_wglMakeCurrent(dc, previous);
        }
        break;
    }
    ReleaseSRWLockShared(&registry_lock);
}

void rune_win_gl_completion_poll_current(void) {
    HGLRC current = rune_lazy_wglGetCurrentContext();
    AcquireSRWLockShared(&registry_lock);
    for (RuneWinGLCompletion *w = workers; w; w = w->next)
        if (w->source == current) poll(w, 0);
    ReleaseSRWLockShared(&registry_lock);
}

RuneWinGLCompletion *rune_win_gl_completion_create(void) {
    HDC dc = rune_lazy_wglGetCurrentDC();
    HGLRC gl = rune_lazy_wglGetCurrentContext();
    HWND window = dc ? WindowFromDC(dc) : NULL;
    if (!gl || !window) return NULL;
    RuneWinGLCompletion *w = calloc(1, sizeof(*w));
    if (!w) return NULL;
    w->window = window;
    w->dc = dc;
    w->source = gl;
    w->wait = (ClientWait)rune_win_gl_proc("glClientWaitSync");
    w->release = (DeleteSync)rune_win_gl_proc("glDeleteSync");
    if (!w->wait || !w->release) { free(w); return NULL; }
    w->references = 2;
    w->thread = CreateThread(NULL, 0, run, w, 0, &w->thread_id);
    if (!w->thread) { free(w); return NULL; }
    AcquireSRWLockExclusive(&registry_lock);
    w->next = workers;
    workers = w;
    ReleaseSRWLockExclusive(&registry_lock);
    return w;
}

int rune_win_gl_completion_submit(RuneWinGLCompletion *w, void *fence, void *context, RuneWinGLCompleted finish) {
    if (!w || !fence || !finish || rune_lazy_wglGetCurrentContext() != w->source) return 0;
    CompletionJob *job = malloc(sizeof(*job));
    if (!job) return 0;
    *job = (CompletionJob){fence, context, finish, 0, NULL};
    AcquireSRWLockExclusive(&w->lock);
    if (w->closing) { ReleaseSRWLockExclusive(&w->lock); free(job); return 0; }
    // An immediately signaled fence can invoke a callback that closes its own worker.
    InterlockedIncrement(&w->references);
    append(&w->pending, job);
    ReleaseSRWLockExclusive(&w->lock);
    poll(w, 0);
    AcquireSRWLockExclusive(&w->lock);
    int needs_timer = w->pending.first && !w->timer;
    if (needs_timer) w->timer = SetTimer(w->window, (UINT_PTR)w, USER_TIMER_MINIMUM, poll_timer) != 0;
    int timer_failed = needs_timer && !w->timer;
    ReleaseSRWLockExclusive(&w->lock);
    if (timer_failed) poll(w, 1);
    release_worker(w);
    return 1;
}

void rune_win_gl_completion_destroy(RuneWinGLCompletion *w, int context_lost) {
    if (!w) return;
    AcquireSRWLockExclusive(&registry_lock);
    RuneWinGLCompletion **link = &workers;
    while (*link && *link != w) link = &(*link)->next;
    if (*link) *link = w->next;
    ReleaseSRWLockExclusive(&registry_lock);

    if (!context_lost && rune_lazy_wglGetCurrentContext() == w->source) poll(w, 1);
    AcquireSRWLockExclusive(&w->lock);
    if (w->timer) KillTimer(w->window, (UINT_PTR)w);
    w->lost = context_lost;
    w->closing = 1;
    while (w->pending.first) append(&w->ready, pop(&w->pending));
    WakeConditionVariable(&w->work);
    ReleaseSRWLockExclusive(&w->lock);
    if (GetCurrentThreadId() != w->thread_id) WaitForSingleObject(w->thread, INFINITE);
    release_worker(w);
}
#endif
