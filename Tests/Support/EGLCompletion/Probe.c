#include "CRuneGL.h"
#include "CRuneGLCompletion.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static void require(int condition, const char *message) {
    if (!condition) { fprintf(stderr, "%s\n", message); exit(EXIT_FAILURE); }
}

static void *resolve(const char *name) {
    void *address = dlsym(RTLD_DEFAULT, name);
    return address ? address : (void *)eglGetProcAddress(name);
}

static char *shader(const char *path) {
    FILE *input = fopen(path, "rb");
    require(input != NULL, "Missing Rune shader");
    require(fseek(input, 0, SEEK_END) == 0, "Cannot seek shader");
    long length = ftell(input);
    require(length > 0 && fseek(input, 0, SEEK_SET) == 0, "Empty shader");
    char *text = calloc((size_t)length + 1, 1);
    require(text && fread(text, 1, (size_t)length, input) == (size_t)length, "Cannot read shader");
    fclose(input);
    return text;
}

typedef struct {
    RuneGLCompletion *queue;
    pthread_mutex_t lock;
    pthread_cond_t changed;
    int entered, resume, finished, cancel;
} Check;

typedef struct { Check *check; int index; } Ticket;

static void await(Check *c, int *counter, int target, const char *message) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 15;
    while (*counter < target)
        require(pthread_cond_timedwait(&c->changed, &c->lock, &deadline) == 0, message);
}

static void finish(void *opaque, int completed) {
    Ticket *ticket = opaque;
    Check *c = ticket->check;
    require(eglGetCurrentContext() == EGL_NO_CONTEXT, "Completion ran on the rendering context");
    if (ticket->index == 1) {
        require(completed, "First real GPU fence failed");
        pthread_mutex_lock(&c->lock);
        c->entered = 1;
        pthread_cond_signal(&c->changed);
        await(c, &c->resume, 1, "Submitting the second frame stalled on the first observer");
        pthread_mutex_unlock(&c->lock);
        if (c->cancel) rune_gl_completion_destroy(c->queue, 1);
    } else {
        require(completed == !c->cancel, "Queued completion did not honor shutdown mode");
    }
    pthread_mutex_lock(&c->lock);
    require(ticket->index == c->finished + 1, "Observers ran out of order");
    free(ticket);
    ++c->finished;
    pthread_cond_signal(&c->changed);
    pthread_mutex_unlock(&c->lock);
}

static void submit(Check *c, int index) {
    glClearColor(1, index == 1 ? 0 : 0.25f, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    Ticket *ticket = malloc(sizeof(*ticket));
    require(ticket != NULL, "Cannot allocate ticket");
    *ticket = (Ticket){c, index};
    require(rune_gl_completion_submit(c->queue, ticket, finish), "Could not submit the production completion fence");
}

static void check_queue(RuneGL *renderer, int cancel) {
    Check c = {.queue = rune_gl_completion_create(renderer), .cancel = cancel};
    require(c.queue != NULL, "Could not create the production completion queue");
    pthread_mutex_init(&c.lock, NULL);
    pthread_cond_init(&c.changed, NULL);
    submit(&c, 1);
    // No frame, event loop, readback, or fence poll follows the first submission.
    pthread_mutex_lock(&c.lock);
    await(&c, &c.entered, 1, "An idle EGL surface did not deliver its completion");
    pthread_mutex_unlock(&c.lock);
    submit(&c, 2);
    pthread_mutex_lock(&c.lock);
    c.resume = 1;
    pthread_cond_signal(&c.changed);
    pthread_mutex_unlock(&c.lock);
    if (!cancel) rune_gl_completion_destroy(c.queue, 0);
    pthread_mutex_lock(&c.lock);
    await(&c, &c.finished, 2, "Did not release both callback tickets");
    pthread_mutex_unlock(&c.lock);
    pthread_cond_destroy(&c.changed);
    pthread_mutex_destroy(&c.lock);
}

int main(int argc, char **argv) {
    require(argc == 3, "Expected the fullscreen vertex and layer fragment shader paths");
    EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    EGLint major = 0, minor = 0, count = 0;
    require(display != EGL_NO_DISPLAY && eglInitialize(display, &major, &minor), "EGL initialization failed");
    const EGLint attributes[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR,
                                 EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
    EGLConfig config;
    require(eglChooseConfig(display, attributes, &config, 1, &count) && count == 1, "Missing GLES 3 pbuffer config");
    const EGLint dimensions[] = {EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE};
    const EGLint version[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    EGLSurface surface = eglCreatePbufferSurface(display, config, dimensions);
    EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, version);
    require(surface != EGL_NO_SURFACE && context != EGL_NO_CONTEXT &&
            eglMakeCurrent(display, surface, surface, context), "Cannot bind GLES pbuffer");
    printf("EGL %d.%d %s, GLES renderer %s\n", major, minor, eglQueryString(display, EGL_VENDOR), glGetString(GL_RENDERER));
    char *vertex = shader(argv[1]), *fragment = shader(argv[2]);
    char error[1024] = {0};
    RuneGL *renderer = rune_gl_create_device(resolve, vertex, fragment, error, sizeof(error));
    free(vertex);
    free(fragment);
    require(renderer != NULL, error);
    check_queue(renderer, 0);
    check_queue(renderer, 1);
    unsigned char pixel[4] = {0};
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    require(pixel[0] == 255 && pixel[1] == 64 && pixel[2] == 0 && pixel[3] == 255, "Unexpected final RGBA8 pixel");
    rune_gl_destroy(renderer);
    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(display, context);
    eglDestroySurface(display, surface);
    eglTerminate(display);
    puts("PASS idle EGL completion, overlapping submission, ordered drain, callback-initiated cancellation, and RGBA8 readback");
    return EXIT_SUCCESS;
}
