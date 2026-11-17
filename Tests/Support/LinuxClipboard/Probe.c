/* Two focused SDL windows exchange the real Wayland clipboard in run.sh's private compositor. */
#include "RuneDesktopServices.h"
#include <SDL.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define REQUIRE(condition) do { if (!(condition)) { \
    fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition); return 1; \
} } while (0)

static const char plain[] = "text/plain;charset=utf-8";
static const char text[] = "Rune \xf0\x9f\xa6\x8a";
static const char html[] = "<b>Rune</b>";
static const uint8_t binary[] = {0, 0xef, 0, 0xac};

static int contains(const RuneMimeData *list, const char *type, const void *expected, size_t length) {
    for (size_t i = 0; i < rune_mime_count(list); ++i) {
        if (!strcmp(type, rune_mime_type(list, i))) {
            size_t size = 0;
            const void *bytes = rune_mime_bytes(list, i, &size);
            return size == length && !memcmp(bytes, expected, size);
        }
    }
    return 0;
}

static int mark(const char *name) {
    FILE *file = fopen(name, "w");
    return file && fclose(file) == 0;
}

static void primary_reply(void *context, const uint8_t *bytes, size_t count) {
    const char expected[] = "other\0selection\n\xe7\x8c\xab";
    int valid = bytes && count == sizeof(expected) - 1 && !memcmp(bytes, expected, count);
    if (SDL_getenv("RUNE_TEST_PRIMARY_MISSING")) valid = !bytes && !count;
    SDL_AtomicSet(context, valid ? 1 : -1);
}

/* The other process uses xclip or wl-clipboard, never Rune. */
static int primary_exchange(SDL_Window *window) {
    int focused = 0, read_pending = 0;
    SDL_atomic_t reply = {0};
    int64_t revision = -1;
    Uint64 deadline = SDL_GetTicks64() + 15000;
    while (SDL_GetTicks64() < deadline) {
        rune_desktop_linux_pump();
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            if (!focused && SDL_GetKeyboardFocus() == window) {
                REQUIRE(mark("primary.focus"));
                focused = 1;
            }
            if (event.type != SDL_KEYDOWN || revision >= 0) continue;
            RuneMimeData *payload = rune_mime_create();
            REQUIRE(rune_mime_add(payload, plain, (const uint8_t *)text, strlen(text)));
            revision = rune_clipboard_write(payload, 1);
            rune_mime_free(payload);
            REQUIRE(revision >= 0);
            const uint8_t value[] = "Rune\0selection\n\xf0\x9f\xa6\x8a";
            rune_linux_primary_write(value, sizeof(value) - 1);
            REQUIRE(mark("primary.write"));
        }
        if (!read_pending && access("external.write", F_OK) == 0) {
            read_pending = 1;
            rune_linux_primary_read(primary_reply, &reply);
            REQUIRE(mark("primary.requested"));
        }
        int answered = SDL_AtomicGet(&reply);
        if (answered) {
            REQUIRE(answered == 1);
            REQUIRE(revision == rune_clipboard_revision());
            REQUIRE(rune_clipboard_clear(revision));
            return 0;
        }
        SDL_Delay(4);
    }
    fprintf(stderr, "PRIMARY transfer timed out\n");
    return 1;
}

int main(int argc, char **argv) {
    REQUIRE(argc == 2 && (!strcmp(argv[1], "owner") || !strcmp(argv[1], "reader") || !strcmp(argv[1], "primary")));
    int owner = !strcmp(argv[1], "owner");
    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        fprintf(stderr, "SDL video initialization failed: %s\n", SDL_GetError());
        return 1;
    }
    REQUIRE(!strcmp(SDL_GetCurrentVideoDriver(), "wayland") ||
            (!strcmp(argv[1], "primary") && !strcmp(SDL_GetCurrentVideoDriver(), "x11")));
    SDL_Window *window = SDL_CreateWindow(argv[1], 0, 0, 200, 120, SDL_WINDOW_HIDDEN);
    REQUIRE(window);
    rune_desktop_linux_connect(SDL_GetWindowID(window));
    SDL_ShowWindow(window);
    SDL_Surface *surface = SDL_GetWindowSurface(window);
    REQUIRE(surface && SDL_FillRect(surface, NULL, 0x224466) == 0 && SDL_UpdateWindowSurface(window) == 0);
    if (!strcmp(argv[1], "primary")) {
        int result = primary_exchange(window);
        rune_desktop_linux_disconnect();
        SDL_DestroyWindow(window);
        SDL_Quit();
        return result;
    }

    int64_t revision = -1;
    int focused = 0, finished = 0;
    Uint64 deadline = SDL_GetTicks64() + 30000;
    while (!finished && SDL_GetTicks64() < deadline) {
        rune_desktop_linux_pump();
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            if (!focused && SDL_GetKeyboardFocus() == window) {
                REQUIRE(mark(owner ? "owner.focus" : "reader.focus"));
                focused = 1;
            }
            if (event.type != SDL_KEYDOWN || revision >= 0) continue;
            if (!owner) {
                RuneMimeData *before = rune_clipboard_read();
                REQUIRE(contains(before, plain, text, strlen(text)));
                REQUIRE(contains(before, "text/html", html, strlen(html)));
                REQUIRE(contains(before, "application/x-rune-test", binary, sizeof(binary)));
                REQUIRE(contains(before, "x-kde-passwordManagerHint", "secret", 6));
                rune_mime_free(before);
            }
            RuneMimeData *payload = rune_mime_create();
            REQUIRE(rune_mime_add(payload, plain, (const uint8_t *)text, strlen(text)));
            if (owner) {
                REQUIRE(rune_mime_add(payload, "text/html", (const uint8_t *)html, strlen(html)));
                REQUIRE(rune_mime_add(payload, "application/x-rune-test", binary, sizeof(binary)));
            }
            revision = rune_clipboard_write(payload, owner);
            rune_mime_free(payload);
            REQUIRE(revision >= 0 && mark(owner ? "owner.write" : "reader.write"));
        }
        if (owner && revision >= 0 && access("reader.write", F_OK) == 0) {
            REQUIRE(!rune_clipboard_clear(revision));
            REQUIRE(mark("owner.checked"));
            finished = 1;
        } else if (!owner && revision >= 0 && access("owner.checked", F_OK) == 0) {
            RuneMimeData *replacement = rune_clipboard_read();
            REQUIRE(contains(replacement, plain, text, strlen(text)));
            REQUIRE(!contains(replacement, "x-kde-passwordManagerHint", "secret", 6));
            rune_mime_free(replacement);
            REQUIRE(rune_clipboard_clear(revision));
            finished = 1;
        }
        SDL_Delay(4);
    }
    rune_desktop_linux_disconnect();
    SDL_DestroyWindow(window);
    SDL_Quit();
    REQUIRE(finished);
    return 0;
}
