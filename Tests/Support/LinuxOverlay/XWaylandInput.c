/* A private Weston/XWayland server supplies actual 2x X11 events. */
#include "CRuneLinux.h"
#include <SDL2/SDL.h>
#include <X11/Xlib.h>
#include <X11/extensions/XTest.h>
#include <stdio.h>
#include <string.h>

struct Sample { RuneOverlayEventKind kind; int code, down; double x, y; };
static struct Sample samples[16];
static int count;

static int record(void *unused, const RuneOverlayEvent *e) {
    (void)unused;
    if (e->kind == RuneOverlayMotion || e->kind == RuneOverlayLeave || e->kind == RuneOverlayButton) {
        if (count < 16) samples[count++] = (struct Sample){e->kind, e->code, e->active, e->x, e->y};
    }
    return 1;
}

static void pump(void) {
    /* XSync flushes the sending connection. GTK reads on a separate display. */
    for (int i = 0; i < 15; i++) { rune_overlay_pump(); SDL_Delay(4); }
}

/* The server may report both an enter and a motion at the same position.
 * They represent the same position observation to the overlay runtime. */
static int events(const char *action, const struct Sample *expected, int length) {
    int sample = 0;
    for (int i = 0; i < count; i++) {
        struct Sample a = samples[i];
        if (i && a.kind == RuneOverlayMotion && samples[i-1].kind == a.kind &&
            a.x == samples[i-1].x && a.y == samples[i-1].y) continue;
        if (sample < length) {
            struct Sample b = expected[sample++];
            if (a.kind == b.kind && a.code == b.code && a.down == b.down &&
                (a.kind == RuneOverlayLeave || (a.x == b.x && a.y == b.y))) continue;
        }
        fprintf(stderr, "%s: unexpected event %d/%d/%d at %.1f,%.1f\n", action, a.kind, a.code, a.down, a.x, a.y);
        return 0;
    }
    if (sample != length) { fprintf(stderr, "%s: missing event %d of %d\n", action, sample+1, length); return 0; }
    return 1;
}
static void point(Display *d, int x, int y) {
    count = 0;
    XTestFakeMotionEvent(d, -1, x, y, 0);
    XSync(d, False); pump();
}
static void button(Display *d, int code, int down) {
    count = 0;
    XTestFakeButtonEvent(d, code, down, 0);
    XSync(d, False); pump();
}

int main(void) {
    if (SDL_Init(SDL_INIT_VIDEO) != 0 || strcmp(SDL_GetCurrentVideoDriver(), "wayland")) return 1;
    if (rune_overlay_new("denied-XWayland", 0, NULL, record)) return 2;
    RuneLinuxOverlay *overlay = rune_overlay_new("opted-in-XWayland", 1, NULL, record);
    if (!overlay) { fprintf(stderr, "%s\n", rune_overlay_error()); return 3; }
    if (rune_overlay_backend(overlay) != RuneOverlayXWayland || rune_overlay_has_keys(overlay) ||
        !rune_overlay_make_current(overlay)) return 4;
    RuneOverlayRect display_size;
    rune_overlay_monitor(overlay, 0, 0, NULL, &display_size);
    rune_overlay_place(overlay, (RuneOverlayRect){10, 10, 100, 50}, 0, 0);
    rune_overlay_input(overlay, 1, NULL, 0);
    rune_overlay_show(overlay, 1, 0);
    pump();
    Display *display = XOpenDisplay(NULL);
    Window window = rune_overlay_xid(overlay);
    XWindowAttributes geometry;
    if (!display || !window || !XGetWindowAttributes(display, window, &geometry) ||
        geometry.width != 200 || geometry.height != 100 || !geometry.override_redirect) return 5;

    int ox = 0, oy = 0; Window child;
    if (!XTranslateCoordinates(display, window, DefaultRootWindow(display), 0, 0, &ox, &oy, &child)) return 5;
    struct Sample move = {RuneOverlayMotion, 0, 0, 20, 10}, far = {RuneOverlayMotion, 0, 0, 130, 10};
    struct Sample leave = {.kind = RuneOverlayLeave};
    struct Sample primary[] = {move, {RuneOverlayButton, 1, 1, 20, 10}};
    struct Sample secondary[] = {move, {RuneOverlayButton, 3, 0, 20, 10}};
    struct Sample outside[] = {far, {RuneOverlayButton, 1, 0, 130, 10}, leave};
    point(display, ox+40, oy+20);
    int passed = events("2x motion", &move, 1);
    button(display, 1, 1);
    passed &= events("primary press", primary, 2);
    point(display, ox+260, oy+20);
    passed &= events("held crossing", &far, 1);
    button(display, 1, 0);
    passed &= events("outside release", outside, 3);
    point(display, ox+40, oy+20);
    button(display, 3, 1);
    button(display, 3, 0);
    passed &= events("secondary release", secondary, 2);
    button(display, 4, 1);
    passed &= events("wheel press", NULL, 0);
    button(display, 4, 0);
    point(display, ox+260, oy+20);
    passed &= events("unheld crossing", &leave, 1);
    XCloseDisplay(display);
    rune_overlay_free(overlay);
    SDL_Quit();
    if (passed) puts("XWayland 2x pointer positions, button ordering and held-release checks passed");
    return passed ? 0 : 6;
}
