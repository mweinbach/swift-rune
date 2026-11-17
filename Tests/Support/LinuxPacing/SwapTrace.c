// Capture completed SDL swaps in a separate process. Tests can also supply a
// deterministic display clock on Xvfb, which has no physical high-refresh monitor.
#define _GNU_SOURCE
#include <SDL2/SDL.h>
#include <dlfcn.h>
#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static FILE *trace;
static const char *mode;
static int refresh;
static int64_t next_tick_ns;

__attribute__((constructor)) static void setup(void) {
    const char *path = getenv("RUNE_TEST_SWAP_TRACE");
    if (path) trace = fopen(path, "w");
    mode = getenv("RUNE_TEST_SWAP_MODE");
    const char *hz = getenv("RUNE_TEST_DISPLAY_HZ");
    if (hz) refresh = atoi(hz);
}

static bool simulated(const char *value) {
    return mode && strcmp(mode, value) == 0;
}

static int64_t monotonic_ns(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (int64_t)now.tv_sec * 1000000000 + now.tv_nsec;
}

int SDL_GL_SetSwapInterval(int interval) {
    static int (*real)(int);
    if (!real) real = dlsym(RTLD_NEXT, "SDL_GL_SetSwapInterval");
    if (mode) real(0); // The synthetic clock supplies this test's vblank.
    const int result = simulated("timer") ? -1 : simulated("vsync") ? 0 : real(interval);
    if (trace) { fprintf(trace, "set_interval %d %d\n", interval, result); fflush(trace); }
    return result;
}

int SDL_GL_GetSwapInterval(void) {
    static int (*real)(void);
    if (!real) real = dlsym(RTLD_NEXT, "SDL_GL_GetSwapInterval");
    const int result = simulated("timer") ? 0 : simulated("vsync") ? 1 : real();
    if (trace) { fprintf(trace, "get_interval %d\n", result); fflush(trace); }
    return result;
}

int SDL_GetCurrentDisplayMode(int display, SDL_DisplayMode *out) {
    static int (*real)(int, SDL_DisplayMode *);
    if (!real) real = dlsym(RTLD_NEXT, "SDL_GetCurrentDisplayMode");
    const int result = real(display, out);
    if (result == 0 && mode) out->refresh_rate = refresh;
    return result;
}

int SDL_WaitEventTimeout(SDL_Event *event, int timeout) {
    static int (*real)(SDL_Event *, int);
    if (!real) real = dlsym(RTLD_NEXT, "SDL_WaitEventTimeout");
    if (trace && timeout > 0) {
        fprintf(trace, "wait %" PRId64 " %d\n", monotonic_ns(), timeout);
        fflush(trace);
    }
    return real(event, timeout);
}

void SDL_GL_SwapWindow(SDL_Window *window) {
    static void (*real)(SDL_Window *);
    if (!real) real = dlsym(RTLD_NEXT, "SDL_GL_SwapWindow");
    real(window);
    if (simulated("vsync") && refresh > 0) {
        const int64_t period = 1000000000 / refresh;
        const int64_t now = monotonic_ns();
        if (!next_tick_ns) next_tick_ns = now + period;
        else if (next_tick_ns <= now) next_tick_ns += ((now - next_tick_ns) / period + 1) * period;
        const struct timespec tick = {next_tick_ns / 1000000000, next_tick_ns % 1000000000};
        while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &tick, NULL) == EINTR) {}
        next_tick_ns += period;
    }
    if (trace) { fprintf(trace, "present %" PRId64 "\n", monotonic_ns()); fflush(trace); }
}
