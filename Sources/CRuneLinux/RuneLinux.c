#ifdef __linux__
#include "CRuneLinux.h"
#include "LinuxNotificationWindow.h"
#include "LinuxWindowGeometry.h"
#include "RuneNotifyLinuxFocus.h"
#include "../CSDL2/shim.h"
#include <stdlib.h>

struct RuneLinuxWindow {
    SDL_Window *window;
    SDL_GLContext context;
    uint32_t id, wake;
    bool right_alt_held, right_alt_is_altgr;
    unsigned keymap_generation;
};

static uint32_t group_wake_type;
static unsigned keymap_generation;
static int (*resolve_altgr)(uint32_t window_id);

void rune_linux_set_altgr_resolver(int (*resolve)(uint32_t window_id)) {
    resolve_altgr = resolve;
}

uint32_t rune_linux_group_begin(void) {
    if (SDL_InitSubSystem(SDL_INIT_VIDEO) < 0) return 0;
    group_wake_type = SDL_RegisterEvents(1);
    if (group_wake_type == (uint32_t)-1) {
        SDL_QuitSubSystem(SDL_INIT_VIDEO);
        group_wake_type = 0;
        SDL_SetError("No SDL event ID available for window wakes");
    }
    return group_wake_type;
}

void rune_linux_group_end(void) {
    rune_linux_release_input_region();
    group_wake_type = 0;
    SDL_QuitSubSystem(SDL_INIT_VIDEO);
}

static RuneLinuxWindow *fail_open(RuneLinuxWindow *host) {
    char error[512];
    SDL_strlcpy(error, SDL_GetError(), sizeof error);
    rune_linux_close(host);
    SDL_SetError("%s", error);
    return NULL;
}

RuneLinuxWindow *rune_linux_open(const char *title, RuneLinuxWindowOptions options) {
    RuneLinuxWindow *host = calloc(1, sizeof *host);
    if (!host) { SDL_OutOfMemory(); return NULL; }
    if (SDL_InitSubSystem(SDL_INIT_VIDEO) < 0) { free(host); return NULL; }
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    SDL_GL_SetAttribute(SDL_GL_RED_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_GREEN_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_BLUE_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_ALPHA_SIZE, 8);
    Uint32 flags = SDL_WINDOW_OPENGL | SDL_WINDOW_ALLOW_HIGHDPI | SDL_WINDOW_HIDDEN;
    if (options.resizable) flags |= SDL_WINDOW_RESIZABLE;
    if (options.borderless) flags |= SDL_WINDOW_BORDERLESS;
    if (options.alwaysOnTop) flags |= SDL_WINDOW_ALWAYS_ON_TOP;
    if (options.maximized) flags |= SDL_WINDOW_MAXIMIZED;
    if (options.fullScreen) flags |= SDL_WINDOW_FULLSCREEN_DESKTOP;
    // Allocate the first GL drawable at the bounded size, before SDL applies resize hints.
    int width = SDL_max(options.width, options.minWidth);
    int height = SDL_max(options.height, options.minHeight);
    if (options.maxWidth > 0 && options.maxHeight > 0) {
        width = SDL_min(width, options.maxWidth);
        height = SDL_min(height, options.maxHeight);
    }
    host->window = SDL_CreateWindow(title, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                    width, height, flags);
    if (!host->window) return fail_open(host);
    host->context = SDL_GL_CreateContext(host->window);
    if (!host->context) return fail_open(host);
    host->id = SDL_GetWindowID(host->window);
    SDL_SetWindowData(host->window, "RuneLinuxWindow", host);
    host->wake = group_wake_type ? group_wake_type : SDL_RegisterEvents(1);
    if (host->wake == (Uint32)-1) { SDL_SetError("No available SDL event IDs"); return fail_open(host); }
    SDL_GL_SetSwapInterval(1);
    SDL_SetWindowMinimumSize(host->window, options.minWidth, options.minHeight);
    if (options.maxWidth > 0 && options.maxHeight > 0)
        SDL_SetWindowMaximumSize(host->window, options.maxWidth, options.maxHeight);
#if SDL_VERSION_ATLEAST(2, 0, 22)
    SDL_SetHint(SDL_HINT_IME_SUPPORT_EXTENDED_TEXT, "1");
#endif
    SDL_StartTextInput();
    rune_notify_linux_window_opened(host->id, host->wake, rune_linux_wake);
    if (options.visible) SDL_ShowWindow(host->window);
    return host;
}

const char *rune_linux_error(void) { return SDL_GetError(); }
void rune_linux_close(RuneLinuxWindow *host) {
    rune_notify_linux_window_closed(host->id);
    rune_linux_refresh_frame_input(host->window, true);
    if (!group_wake_type) rune_linux_release_input_region();
    if (host->context) SDL_GL_DeleteContext(host->context);
    if (host->window) SDL_DestroyWindow(host->window);
    free(host);
    SDL_QuitSubSystem(SDL_INIT_VIDEO);
}
void *rune_linux_gl_proc(const char *name) { return SDL_GL_GetProcAddress(name); }
bool rune_linux_make_current(RuneLinuxWindow *host) { return SDL_GL_MakeCurrent(host->window, host->context) == 0; }
void rune_linux_present(RuneLinuxWindow *host) { SDL_GL_SwapWindow(host->window); }
uint32_t rune_linux_id(RuneLinuxWindow *host) { return host->id; }
uint32_t rune_linux_wake_type(RuneLinuxWindow *host) { return host->wake; }
void rune_linux_wake(uint32_t id, uint32_t type) {
    SDL_Event event = {0};
    event.type = type;
    event.user.windowID = id;
    SDL_PushEvent(&event);
}
void rune_linux_size(RuneLinuxWindow *host, int *w, int *h, int *pixelW, int *pixelH) {
    SDL_GetWindowSize(host->window, w, h);
    SDL_GL_GetDrawableSize(host->window, pixelW, pixelH);
}
void rune_linux_set_title(RuneLinuxWindow *host, const char *title) { SDL_SetWindowTitle(host->window, title); }
void rune_linux_set_size(RuneLinuxWindow *host, int w, int h) { SDL_SetWindowSize(host->window, w, h); }
void rune_linux_center(RuneLinuxWindow *host) { SDL_SetWindowPosition(host->window, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED); }
void rune_linux_show(RuneLinuxWindow *host) { SDL_ShowWindow(host->window); }
void rune_linux_hide(RuneLinuxWindow *host) { SDL_HideWindow(host->window); }
void rune_linux_focus(RuneLinuxWindow *host) {
    rune_linux_activate(host, NULL);
}
void rune_linux_activate(RuneLinuxWindow *host, const char *activation_token) {
    rune_linux_activate_notification_window(host->window, activation_token);
}
void rune_linux_minimize(RuneLinuxWindow *host) { SDL_MinimizeWindow(host->window); }
void rune_linux_topmost(RuneLinuxWindow *host, bool on) { SDL_SetWindowAlwaysOnTop(host->window, on ? SDL_TRUE : SDL_FALSE); }
void rune_linux_flash(RuneLinuxWindow *host, bool on) { SDL_FlashWindow(host->window, on ? SDL_FLASH_UNTIL_FOCUSED : SDL_FLASH_CANCEL); }
void rune_linux_set_ime_rect(int x, int y, int w, int h) {
    SDL_Rect rect = { x, y, w, h };
    SDL_SetTextInputRect(&rect);
}
void rune_linux_free(void *data) { SDL_free(data); }

static unsigned translate_modifiers(unsigned m) {
    return (m & KMOD_SHIFT ? RuneLinuxShift : 0) | (m & KMOD_CTRL ? RuneLinuxControl : 0)
        | (m & KMOD_ALT ? RuneLinuxAlt : 0) | (m & KMOD_GUI ? RuneLinuxSuper : 0)
        | (m & KMOD_MODE ? RuneLinuxAltGr : 0);
}

/* SDL2 reports the physical right Alt bit even when the active layout uses it
   as a level selector. Consult the native keymap once per press or map change. */
static bool right_alt_is_altgr(const SDL_KeyboardEvent *key) {
    if (!(key->keysym.mod & KMOD_RALT) && key->keysym.scancode != SDL_SCANCODE_RALT) return false;
    SDL_Window *window = SDL_GetWindowFromID(key->windowID);
    RuneLinuxWindow *host = window ? SDL_GetWindowData(window, "RuneLinuxWindow") : NULL;
    if (!host || !resolve_altgr) return false;
    if (!(key->keysym.mod & KMOD_RALT)) {
        host->right_alt_held = false;
        return false;
    }
    if (!host->right_alt_held || host->keymap_generation != keymap_generation ||
        (key->keysym.scancode == SDL_SCANCODE_RALT && !key->repeat)) {
        host->right_alt_is_altgr = resolve_altgr(key->windowID) != 0;
        host->right_alt_held = true;
        host->keymap_generation = keymap_generation;
    }
    return host->right_alt_is_altgr;
}

static RuneLinuxEventKind translate_window(SDL_WindowEvent w, RuneLinuxEvent *out) {
    switch (w.event) {
    case SDL_WINDOWEVENT_CLOSE: return RuneLinuxClose;
    case SDL_WINDOWEVENT_ENTER:
        return RuneLinuxExposed;
    case SDL_WINDOWEVENT_EXPOSED:
        rune_linux_refresh_frame_input(SDL_GetWindowFromID(w.windowID), false);
        return RuneLinuxExposed;
    case SDL_WINDOWEVENT_SIZE_CHANGED:
#if SDL_VERSION_ATLEAST(2, 0, 18)
    case SDL_WINDOWEVENT_DISPLAY_CHANGED:
#endif
        return RuneLinuxResized;
    case SDL_WINDOWEVENT_MOVED:
        out->x = w.data1; out->y = w.data2;
        return RuneLinuxMoved;
    case SDL_WINDOWEVENT_LEAVE: return RuneLinuxLeave;
    case SDL_WINDOWEVENT_FOCUS_GAINED:
    case SDL_WINDOWEVENT_FOCUS_LOST:
        out->active = w.event == SDL_WINDOWEVENT_FOCUS_GAINED;
        rune_notify_linux_window_focus(w.windowID, out->active);
        return RuneLinuxFocus;
    case SDL_WINDOWEVENT_SHOWN:
    case SDL_WINDOWEVENT_RESTORED:
    case SDL_WINDOWEVENT_MAXIMIZED:
    case SDL_WINDOWEVENT_HIDDEN:
    case SDL_WINDOWEVENT_MINIMIZED:
        out->active = w.event != SDL_WINDOWEVENT_HIDDEN && w.event != SDL_WINDOWEVENT_MINIMIZED;
        if (out->active) rune_linux_refresh_frame_input(SDL_GetWindowFromID(w.windowID), false);
        rune_notify_linux_window_visible(w.windowID, out->active);
        return RuneLinuxVisibility;
    default: return RuneLinuxIgnored;
    }
}

static RuneLinuxEventKind translate(const SDL_Event *e, RuneLinuxEvent *out) {
    if (e->type == SDL_QUIT) return RuneLinuxQuit;
    if (e->type >= SDL_USEREVENT) {
        out->windowID = e->user.windowID;
        if (e->type == group_wake_type && out->windowID == 0) return RuneLinuxWake;
        SDL_Window *window = SDL_GetWindowFromID(out->windowID);
        RuneLinuxWindow *host = window ? SDL_GetWindowData(window, "RuneLinuxWindow") : NULL;
        if (!host || e->type != host->wake) return RuneLinuxIgnored;
        char *token;
        if (rune_notify_linux_take_activation(out->windowID, &token)) {
            rune_linux_activate(host, token);
            free(token);
        }
        return RuneLinuxWake;
    }
    out->modifiers = translate_modifiers(SDL_GetModState());
    switch (e->type) {
    case SDL_KEYMAPCHANGED:
        ++keymap_generation;
        return RuneLinuxIgnored;
    case SDL_WINDOWEVENT:
        out->windowID = e->window.windowID;
        return translate_window(e->window, out);
    case SDL_KEYDOWN:
    case SDL_KEYUP:
        out->windowID = e->key.windowID;
        out->code = e->key.keysym.sym; out->scan = e->key.keysym.scancode;
        out->modifiers = translate_modifiers(e->key.keysym.mod);
        if (right_alt_is_altgr(&e->key)) out->modifiers |= RuneLinuxAltGr;
        out->active = e->type == SDL_KEYDOWN; out->repeated = e->key.repeat != 0;
        return RuneLinuxKey;
    case SDL_TEXTINPUT:
        out->windowID = e->text.windowID;
        out->text = SDL_strdup(e->text.text);
        return RuneLinuxText;
    case SDL_TEXTEDITING:
        out->windowID = e->edit.windowID;
        out->text = SDL_strdup(e->edit.text); out->start = e->edit.start; out->length = e->edit.length;
        return RuneLinuxPreedit;
#if SDL_VERSION_ATLEAST(2, 0, 22)
    case SDL_TEXTEDITING_EXT:
        out->windowID = e->editExt.windowID;
        out->text = e->editExt.text; out->start = e->editExt.start; out->length = e->editExt.length;
        return RuneLinuxPreedit;
#endif
    case SDL_MOUSEMOTION:
        out->windowID = e->motion.windowID;
        out->x = e->motion.x; out->y = e->motion.y;
        return RuneLinuxMotion;
    case SDL_MOUSEBUTTONDOWN:
    case SDL_MOUSEBUTTONUP:
        out->windowID = e->button.windowID;
        out->x = e->button.x; out->y = e->button.y; out->code = e->button.button;
        out->active = e->type == SDL_MOUSEBUTTONDOWN;
        return RuneLinuxButton;
    case SDL_MOUSEWHEEL: {
        out->windowID = e->wheel.windowID;
        // Like winit's X11/Wayland backends, positive deltas move content right/down.
        float sign = e->wheel.direction == SDL_MOUSEWHEEL_FLIPPED ? -1.f : 1.f;
        out->dx = -sign * e->wheel.preciseX; out->dy = sign * e->wheel.preciseY;
#if SDL_VERSION_ATLEAST(2, 26, 0)
        out->x = e->wheel.mouseX; out->y = e->wheel.mouseY;
#else
        int x, y; SDL_GetMouseState(&x, &y); out->x = x; out->y = y;
#endif
        return RuneLinuxWheel;
    }
    case SDL_DROPBEGIN:
    case SDL_DROPCOMPLETE:
    case SDL_DROPFILE: {
        out->windowID = e->drop.windowID;
        int x, y; SDL_GetMouseState(&x, &y); out->x = x; out->y = y;
        if (e->type == SDL_DROPFILE) { out->text = e->drop.file; return RuneLinuxDropFile; }
        return e->type == SDL_DROPBEGIN ? RuneLinuxDropBegin : RuneLinuxDropEnd;
    }
    case SDL_DROPTEXT: SDL_free(e->drop.file); break;
    }
    return RuneLinuxIgnored;
}

int rune_linux_next_event(int timeoutMs, RuneLinuxEvent *out) {
    SDL_Event event;
    *out = (RuneLinuxEvent){0};
    int got = timeoutMs < 0 ? SDL_WaitEvent(&event) :
              timeoutMs == 0 ? SDL_PollEvent(&event) : SDL_WaitEventTimeout(&event, timeoutMs);
    if (got == 0 && timeoutMs < 0) return -1;
    while (got) {
        out->kind = translate(&event, out);
        if (out->kind != RuneLinuxIgnored) return 1;
        got = SDL_PollEvent(&event);
    }
    return 0;
}
#endif
