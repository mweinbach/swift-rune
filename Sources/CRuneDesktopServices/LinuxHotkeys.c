#if defined(__linux__) && !defined(__ANDROID__)
#include "RuneDesktopHotkeys.h"
#include <errno.h>
#include <linux/input-event-codes.h>
#include <poll.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <unistd.h>
#include <xcb/xcb.h>

typedef struct {
    xcb_window_t root;
    uint16_t modifiers;
} Grab;

typedef struct Binding {
    struct Binding *next;
    uint32_t id;
    xcb_keycode_t code;
    size_t count;
    Grab grabs[];
} Binding;

typedef struct {
    xcb_connection_t *connection;
    pthread_t listener;
    pthread_mutex_t lock;
    int wake;
    atomic_bool stopping;
    atomic_bool free_on_exit;
    Binding *bindings;
    RuneHotkeySink sink;
    void *context;
} Manager;

/* Linux Xorg and Xwayland expose evdev scancodes offset by 8. Like the Rune
   shortcut syntax, these names identify physical US positions across layouts. */
static xcb_keycode_t physical_code(const char *name) {
    static const uint8_t letters[] = {
        KEY_A, KEY_B, KEY_C, KEY_D, KEY_E, KEY_F, KEY_G, KEY_H, KEY_I, KEY_J,
        KEY_K, KEY_L, KEY_M, KEY_N, KEY_O, KEY_P, KEY_Q, KEY_R, KEY_S, KEY_T,
        KEY_U, KEY_V, KEY_W, KEY_X, KEY_Y, KEY_Z
    };
    static const uint8_t digits[] = {KEY_0, KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9};
    static const struct { const char *name; uint8_t code; } named[] = {
        {"escape", KEY_ESC}, {"enter", KEY_ENTER}, {"space", KEY_SPACE}, {"tab", KEY_TAB},
        {"backspace", KEY_BACKSPACE}, {"delete", KEY_DELETE}, {"insert", KEY_INSERT},
        {"home", KEY_HOME}, {"end", KEY_END}, {"pageup", KEY_PAGEUP}, {"pagedown", KEY_PAGEDOWN},
        {"left", KEY_LEFT}, {"right", KEY_RIGHT}, {"up", KEY_UP}, {"down", KEY_DOWN},
        {"minus", KEY_MINUS}, {"equal", KEY_EQUAL}, {"comma", KEY_COMMA}, {"period", KEY_DOT},
        {"slash", KEY_SLASH}, {"semicolon", KEY_SEMICOLON}, {"quote", KEY_APOSTROPHE},
        {"bracketleft", KEY_LEFTBRACE}, {"bracketright", KEY_RIGHTBRACE}, {"backslash", KEY_BACKSLASH},
        {"backquote", KEY_GRAVE},
    };
    if (!name || !name[0]) return 0;
    if (name[1] == '\0') {
        if (name[0] >= 'a' && name[0] <= 'z') return letters[name[0] - 'a'] + 8;
        if (name[0] >= '0' && name[0] <= '9') return digits[name[0] - '0'] + 8;
    }
    if (name[0] == 'f' && name[1] >= '1' && name[1] <= '9') {
        int n = name[1] - '0';
        if (name[2]) {
            if (name[2] < '0' || name[2] > '9' || name[3]) return 0;
            n = n * 10 + name[2] - '0';
        }
        if (n <= 10) return KEY_F1 + n - 1 + 8;
        if (n <= 12) return KEY_F11 + n - 11 + 8;
        if (n <= 24) return KEY_F13 + n - 13 + 8;
        return 0;
    }
    for (size_t i = 0; i < sizeof(named) / sizeof(named[0]); i++)
        if (strcmp(named[i].name, name) == 0) return named[i].code + 8;
    return 0;
}

static int lock_modifiers(xcb_connection_t *connection, unsigned *mask) {
    const xcb_setup_t *setup = xcb_get_setup(connection);
    xcb_get_keyboard_mapping_cookie_t keyboard_request = xcb_get_keyboard_mapping(
        connection, setup->min_keycode, setup->max_keycode - setup->min_keycode + 1);
    xcb_get_modifier_mapping_cookie_t modifiers_request = xcb_get_modifier_mapping(connection);
    xcb_get_keyboard_mapping_reply_t *keyboard = xcb_get_keyboard_mapping_reply(connection, keyboard_request, NULL);
    xcb_get_modifier_mapping_reply_t *modifiers = xcb_get_modifier_mapping_reply(connection, modifiers_request, NULL);
    bool success = keyboard && modifiers;
    if (success) {
        const xcb_keysym_t *symbols = xcb_get_keyboard_mapping_keysyms(keyboard);
        const xcb_keycode_t *codes = xcb_get_modifier_mapping_keycodes(modifiers);
        *mask = XCB_MOD_MASK_LOCK;
        for (int mod = 0; mod < 8; mod++) {
            for (int key = 0; key < modifiers->keycodes_per_modifier; key++) {
                int code = codes[mod * modifiers->keycodes_per_modifier + key];
                if (code < setup->min_keycode || code > setup->max_keycode) continue;
                int start = (code - setup->min_keycode) * keyboard->keysyms_per_keycode;
                for (int i = 0; i < keyboard->keysyms_per_keycode; i++) {
                    xcb_keysym_t symbol = symbols[start + i];
                    if (symbol == 0xff7f || symbol == 0xff14) /* Num_Lock, Scroll_Lock */
                        *mask |= 1u << mod;
                }
            }
        }
    }
    free(keyboard);
    free(modifiers);
    return success ? RUNE_HOTKEY_OK : RUNE_HOTKEY_FAILED;
}

static void wake_listener(Manager *manager) {
    uint64_t one = 1;
    while (write(manager->wake, &one, sizeof(one)) < 0 && errno == EINTR) {}
}

static void destroy(Manager *manager) {
    /* Closing the private connection releases every remaining grab. */
    xcb_disconnect(manager->connection);
    close(manager->wake);
    while (manager->bindings) {
        Binding *next = manager->bindings->next;
        free(manager->bindings);
        manager->bindings = next;
    }
    pthread_mutex_destroy(&manager->lock);
    free(manager);
}

typedef struct {
    bool down[256];
    xcb_keycode_t first;
    xcb_keycode_t released;
    xcb_timestamp_t released_at;
    uint16_t release_state;
} Held;

/* Servers send either repeated presses or synthetic release/press pairs
   sharing a timestamp. Releasing the grab's first key also returns all other
   release events to their original windows. */
static bool first_press(Held *held, const xcb_key_press_event_t *event, bool pressed) {
    xcb_keycode_t code = event->detail;
    if (held->released) {
        xcb_keycode_t released = held->released;
        held->released = 0;
        if (pressed && released == code && held->released_at == event->time && held->release_state == event->state)
            return false;
        if (held->first == released) {
            memset(held->down, 0, sizeof(held->down));
            held->first = 0;
        } else {
            held->down[released] = false;
        }
    }
    if (!pressed) {
        held->released = code;
        held->released_at = event->time;
        held->release_state = event->state;
        return false;
    }
    if (held->down[code]) return false;
    if (!held->first) held->first = code;
    held->down[code] = true;
    return true;
}

static void dispatch(Manager *manager, const xcb_key_press_event_t *event) {
    uint32_t id = 0;
    bool found = false;
    pthread_mutex_lock(&manager->lock);
    for (Binding *binding = manager->bindings; binding && !found; binding = binding->next) {
        if (binding->code != event->detail) continue;
        for (size_t i = 0; i < binding->count; i++) {
            Grab grab = binding->grabs[i];
            if (grab.root == event->root && grab.modifiers == (event->state & 0xff)) {
                id = binding->id;
                found = true;
                break;
            }
        }
    }
    pthread_mutex_unlock(&manager->lock);
    if (found) manager->sink(manager->context, id, NULL);
}

static void *listen_keys(void *opaque) {
    Manager *manager = opaque;
    struct pollfd descriptors[] = {
        {xcb_get_file_descriptor(manager->connection), POLLIN, 0},
        {manager->wake, POLLIN, 0}
    };
    Held held = {0};
    while (!atomic_load(&manager->stopping)) {
        xcb_generic_event_t *event;
        while (!atomic_load(&manager->stopping) && (event = xcb_poll_for_event(manager->connection))) {
            unsigned type = event->response_type & 0x7f;
            if (type == XCB_KEY_PRESS || type == XCB_KEY_RELEASE) {
                xcb_key_press_event_t *key = (xcb_key_press_event_t *)event;
                if (first_press(&held, key, type == XCB_KEY_PRESS))
                    dispatch(manager, key);
            }
            free(event);
        }
        if (atomic_load(&manager->stopping) || xcb_connection_has_error(manager->connection)) break;
        int result = poll(descriptors, 2, -1);
        if (result < 0 && errno == EINTR) continue;
        if (result < 0 || descriptors[0].revents & (POLLERR | POLLHUP | POLLNVAL)) break;
        if (descriptors[1].revents & POLLIN) {
            uint64_t count;
            while (read(manager->wake, &count, sizeof(count)) < 0 && errno == EINTR) {}
        }
    }
    if (atomic_load(&manager->free_on_exit)) destroy(manager);
    return NULL;
}

void *rune_x11_hotkeys_open(RuneHotkeySink sink, void *context, int *status) {
    if (status) *status = RUNE_HOTKEY_FAILED;
    if (!sink) return NULL;
    Manager *manager = calloc(1, sizeof(*manager));
    if (!manager) return NULL;
    manager->connection = xcb_connect(NULL, NULL);
    if (xcb_connection_has_error(manager->connection)) {
        xcb_disconnect(manager->connection);
        free(manager);
        if (status) *status = RUNE_HOTKEY_UNSUPPORTED;
        return NULL;
    }
    manager->sink = sink;
    manager->context = context;
    atomic_init(&manager->stopping, false);
    atomic_init(&manager->free_on_exit, false);
    manager->wake = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    if (manager->wake < 0 || pthread_mutex_init(&manager->lock, NULL) != 0) {
        if (manager->wake >= 0) close(manager->wake);
        xcb_disconnect(manager->connection);
        free(manager);
        return NULL;
    }
    if (pthread_create(&manager->listener, NULL, listen_keys, manager) != 0) {
        destroy(manager);
        return NULL;
    }
    if (status) *status = RUNE_HOTKEY_OK;
    return manager;
}

static int release_grabs(Manager *manager, const Binding *binding) {
    int result = RUNE_HOTKEY_OK;
    for (size_t i = 0; i < binding->count; i++) {
        Grab grab = binding->grabs[i];
        xcb_generic_error_t *error = xcb_request_check(manager->connection,
            xcb_ungrab_key_checked(manager->connection, binding->code, grab.root, grab.modifiers));
        if (error) result = RUNE_HOTKEY_FAILED;
        free(error);
    }
    return xcb_connection_has_error(manager->connection) ? RUNE_HOTKEY_FAILED : result;
}

static int register_key(Manager *manager, uint32_t id, xcb_keycode_t code, unsigned base) {
    const xcb_setup_t *setup = xcb_get_setup(manager->connection);
    if (!setup || xcb_connection_has_error(manager->connection)) return RUNE_HOTKEY_FAILED;
    if (code < setup->min_keycode || code > setup->max_keycode) return RUNE_HOTKEY_INVALID;
    unsigned lock_mask;
    int result = lock_modifiers(manager->connection, &lock_mask);
    if (result != RUNE_HOTKEY_OK) return result;
    lock_mask &= ~base;
    unsigned variants[256];
    size_t count = 0;
    /* Iterate subsets in ascending order, grabbing the exact chord first. */
    for (unsigned subset = 0; subset < 256; subset++)
        if (!(subset & ~lock_mask)) variants[count++] = base | subset;
    for (Binding *existing = manager->bindings; existing; existing = existing->next) {
        if (existing->id == id) return RUNE_HOTKEY_CONFLICT;
        if (existing->code == code)
            for (size_t i = 0; i < existing->count; i++)
                for (size_t n = 0; n < count; n++)
                    if (existing->grabs[i].modifiers == variants[n]) return RUNE_HOTKEY_CONFLICT;
    }

    size_t total = xcb_setup_roots_length(setup) * count;
    Binding *binding = calloc(1, sizeof(*binding) + total * sizeof(Grab));
    if (!binding) return RUNE_HOTKEY_FAILED;
    binding->id = id;
    binding->code = code;
    for (xcb_screen_iterator_t screen = xcb_setup_roots_iterator(setup); screen.rem; xcb_screen_next(&screen)) {
        for (size_t i = 0; i < count; i++) {
            xcb_window_t root = screen.data->root;
            xcb_generic_error_t *error = xcb_request_check(manager->connection,
                xcb_grab_key_checked(manager->connection, false, root, variants[i], code,
                                     XCB_GRAB_MODE_ASYNC, XCB_GRAB_MODE_ASYNC));
            if (error || xcb_connection_has_error(manager->connection)) {
                result = error && error->error_code == XCB_ACCESS ? RUNE_HOTKEY_CONFLICT : RUNE_HOTKEY_FAILED;
                free(error);
                release_grabs(manager, binding);
                free(binding);
                return result;
            }
            binding->grabs[binding->count++] = (Grab){root, variants[i]};
        }
    }
    binding->next = manager->bindings;
    manager->bindings = binding;
    return RUNE_HOTKEY_OK;
}

int rune_x11_hotkeys_register(void *opaque, uint32_t id, uint8_t mods, const char *name) {
    Manager *manager = opaque;
    xcb_keycode_t code = physical_code(name);
    if (!manager || !code || (mods & ~15u)) return RUNE_HOTKEY_INVALID;
    unsigned base = 0;
    if (mods & 1) base |= XCB_MOD_MASK_CONTROL;
    if (mods & 2) base |= XCB_MOD_MASK_1;
    if (mods & 4) base |= XCB_MOD_MASK_SHIFT;
    if (mods & 8) base |= XCB_MOD_MASK_4;
    pthread_mutex_lock(&manager->lock);
    int status = register_key(manager, id, code, base);
    pthread_mutex_unlock(&manager->lock);
    /* A synchronous X reply can also queue input on the private connection. */
    wake_listener(manager);
    return status;
}

int rune_x11_hotkeys_unregister(void *opaque, uint32_t id) {
    Manager *manager = opaque;
    if (!manager) return RUNE_HOTKEY_UNKNOWN_ID;
    int status = RUNE_HOTKEY_UNKNOWN_ID;
    pthread_mutex_lock(&manager->lock);
    for (Binding **link = &manager->bindings; *link; link = &(*link)->next) {
        Binding *binding = *link;
        if (binding->id == id) {
            status = release_grabs(manager, binding);
            if (status == RUNE_HOTKEY_OK) {
                *link = binding->next;
                free(binding);
            }
            break;
        }
    }
    pthread_mutex_unlock(&manager->lock);
    wake_listener(manager);
    return status;
}

void rune_x11_hotkeys_close(void *opaque) {
    Manager *manager = opaque;
    if (!manager) return;
    bool self = pthread_equal(manager->listener, pthread_self());
    if (self) atomic_store(&manager->free_on_exit, true);
    atomic_store(&manager->stopping, true);
    wake_listener(manager);
    if (self) {
        pthread_detach(manager->listener);
    } else {
        pthread_join(manager->listener, NULL);
        destroy(manager);
    }
}
#endif
