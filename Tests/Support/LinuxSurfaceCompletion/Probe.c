#include "CRuneGL.h"
#include "CRuneGLCompletion.h"
#include <SDL.h>
#include <epoxy/egl.h>
#include <epoxy/gl.h>
#include <epoxy/glx.h>
#include <errno.h>
#include <pthread.h>
#include <semaphore.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void require(int passed, const char *message) {
    if (!passed) {
        fprintf(stderr, "FAIL %s\n", message);
        exit(1);
    }
}

static char *shader(const char *path) {
    FILE *file = fopen(path, "rb");
    require(file != NULL && fseek(file, 0, SEEK_END) == 0, path);
    long length = ftell(file);
    require(length > 0 && fseek(file, 0, SEEK_SET) == 0, path);
    char *bytes = calloc((size_t)length + 1, 1);
    require(bytes && fread(bytes, 1, (size_t)length, file) == (size_t)length, path);
    fclose(file);
    return bytes;
}

typedef struct {
    GLuint buffer;
    GLsync marker;
    unsigned char color[4];
} Readback;

// Queue the read into a PBO. Check its independent GL fence before mapping it so
// the assertion cannot accidentally succeed because a synchronous read waited.
static Readback enqueue_pixels(int green) {
    Readback image = {.color = {green ? 0 : 255, green ? 255 : 0, 0, 255}};
    glViewport(0, 0, 32, 32);
    glClearColor(green ? 0.f : 1.f, green ? 1.f : 0.f, 0.f, 1.f);
    glClear(GL_COLOR_BUFFER_BIT);
    glGenBuffers(1, &image.buffer);
    glBindBuffer(GL_PIXEL_PACK_BUFFER, image.buffer);
    glBufferData(GL_PIXEL_PACK_BUFFER, 4, NULL, GL_STREAM_READ);
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    image.marker = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    require(image.marker != NULL && glGetError() == GL_NO_ERROR, "enqueue pixel readback");
    return image;
}

static void check_pixels(Readback image) {
    GLenum result = glClientWaitSync(image.marker, 0, 0);
    require(result == GL_ALREADY_SIGNALED || result == GL_CONDITION_SATISFIED,
            "callback preceded independent GPU fence");
    glDeleteSync(image.marker);
    glBindBuffer(GL_PIXEL_PACK_BUFFER, image.buffer);
    const void *bytes = glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, 4, GL_MAP_READ_BIT);
    require(bytes != NULL && memcmp(bytes, image.color, 4) == 0, "red/green GPU pixel");
    require(glUnmapBuffer(GL_PIXEL_PACK_BUFFER), "unmap readback");
    glDeleteBuffers(1, &image.buffer);
}

typedef enum { idle, drain, loss } Scenario;
typedef struct {
    RuneGLCompletion *queue;
    pthread_t owner;
    sem_t entered, release, delivered;
    atomic_int count;
    int result[2];
    Scenario scenario;
} Check;
typedef struct { Check *check; int index; } Ticket;

static void observe(void *context, int completed) {
    Ticket *ticket = context;
    Check *c = ticket->check;
    require(!pthread_equal(pthread_self(), c->owner), "callback blocked the rendering thread");
    if (ticket->index == 0 && c->scenario != drain) {
        require(sem_post(&c->entered) == 0, "enter first callback");
        int result;
        do { result = sem_wait(&c->release); } while (result != 0 && errno == EINTR);
        require(result == 0, "release callback");
        if (c->scenario == loss) rune_gl_completion_destroy(c->queue, 1);
    }
    require(atomic_fetch_add(&c->count, 1) == ticket->index, "completion order");
    c->result[ticket->index] = completed;
    require(sem_post(&c->delivered) == 0, "deliver callback");
}

static void wait_event(sem_t *event, RuneGLCompletion *origin_queue) {
    for (;;) {
        if (!origin_queue) {
            int result;
            do { result = sem_wait(event); } while (result != 0 && errno == EINTR);
            require(result == 0, "idle completion");
            return;
        }
        if (sem_trywait(event) == 0) return;
        require(errno == EAGAIN || errno == EINTR, "wait for callback");
        (void)rune_gl_completion_poll(origin_queue);
        SDL_Delay(1);
    }
}

static void exercise(RuneGL *device, SDL_Window *window, SDL_GLContext gl, int egl, Scenario scenario) {
    Check c = {.owner = pthread_self(), .scenario = scenario};
    require(sem_init(&c.entered, 0, 0) == 0 && sem_init(&c.release, 0, 0) == 0 &&
            sem_init(&c.delivered, 0, 0) == 0, "create callback gates");
    c.queue = rune_gl_completion_create(device);
    require(c.queue != NULL, "create completion queue");
    Ticket tickets[] = {{&c, 0}, {&c, 1}};
    Readback first = enqueue_pixels(0);
    require(rune_gl_completion_submit(c.queue, &tickets[0], observe), "first submit");
    require(rune_gl_completion_needs_poll(c.queue) == !egl, "origin polling required only on GLX");
    if (scenario != drain) {
        wait_event(&c.entered, egl ? NULL : c.queue);
        check_pixels(first);
    }
    Readback second = enqueue_pixels(1);
    require(rune_gl_completion_submit(c.queue, &tickets[1], observe), "second submit");
    if (scenario == drain) {
        rune_gl_completion_destroy(c.queue, 0);
        require(atomic_load(&c.count) == 2, "both callbacks drained before close");
        check_pixels(first);
    } else {
        require(atomic_load(&c.count) == 0, "second submission returned while first callback was held");
        if (scenario == loss) {
            require(SDL_GL_MakeCurrent(window, NULL) == 0, SDL_GetError());
            SDL_GL_DeleteContext(gl);
        }
        require(sem_post(&c.release) == 0, "open first callback gate");
    }
    RuneGLCompletion *poll_queue = scenario == idle && !egl ? c.queue : NULL;
    wait_event(&c.delivered, poll_queue);
    wait_event(&c.delivered, poll_queue);
    require(atomic_load(&c.count) == 2 && c.result[0] == 1 && c.result[1] == (scenario != loss),
            "completion and cancellation results");
    if (scenario != loss) check_pixels(second);
    if (scenario == idle) {
        require(!rune_gl_completion_needs_poll(c.queue), "completed idle frame left an active poll");
        rune_gl_completion_destroy(c.queue, 0);
    }
    sem_destroy(&c.entered);
    sem_destroy(&c.release);
    sem_destroy(&c.delivered);
}

int main(int argc, char **argv) {
    require(argc == 4, "expected glx, egl or gles and two shader files");
    int egl = strcmp(argv[1], "glx") != 0, es = strcmp(argv[1], "gles") == 0;
    require(SDL_Init(SDL_INIT_VIDEO) == 0, SDL_GetError());
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, es ? SDL_GL_CONTEXT_PROFILE_ES : SDL_GL_CONTEXT_PROFILE_CORE);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, es ? 0 : 3);
    SDL_GL_SetAttribute(SDL_GL_ALPHA_SIZE, 8);
    SDL_Window *window = SDL_CreateWindow("Rune completions", 0, 0, 32, 32, SDL_WINDOW_OPENGL | SDL_WINDOW_HIDDEN);
    require(window != NULL, SDL_GetError());
    SDL_GLContext context = SDL_GL_CreateContext(window);
    require(context != NULL, SDL_GetError());
    require(egl ? eglGetCurrentContext() != EGL_NO_CONTEXT : glXGetCurrentContext() != NULL, "expected context API");
    char *vertex = shader(argv[2]), *fragment = shader(argv[3]), error[1024] = {0};
    RuneGL *device = rune_gl_create_device(SDL_GL_GetProcAddress, vertex, fragment, error, sizeof(error));
    free(vertex);
    free(fragment);
    require(device != NULL, error);
    printf("%s %s: %s (%s)\n", SDL_GetCurrentVideoDriver(), argv[1], rune_gl_renderer(device), rune_gl_version(device));
    fflush(stdout);
    exercise(device, window, context, egl, idle);
    exercise(device, window, context, egl, drain);
    exercise(device, window, context, egl, loss);
    rune_gl_abandon(device);
    SDL_DestroyWindow(window);
    SDL_Quit();
    puts("PASS idle GPU completion, callback overlap, ordered drain and context-loss cancellation");
    return 0;
}
