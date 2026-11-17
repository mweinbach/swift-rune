#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

/* Restrict only the test process's view of the real compositor registry.
   The independent client still sees the entire seat. Dispatcher data stays
   identical to a normal listener, including wl_proxy_get_user_data(). */
static int global_event(const void *implementation, void *target, uint32_t opcode,
                        const struct wl_message *message, union wl_argument *args) {
    (void)opcode;
    const struct wl_registry_listener *listener = implementation;
    void *data = wl_proxy_get_user_data(target);
    if (!strcmp(message->name, "global_remove")) {
        listener->global_remove(data, target, args[0].u);
        return 0;
    }
    const char *name = args[1].s;
    const char *only = getenv("RUNE_TEST_PRIMARY_PROTOCOL");
    if (!strcmp(name, "zwp_primary_selection_device_manager_v1") ||
        !strcmp(name, "ext_data_control_manager_v1") || !strcmp(name, "zwlr_data_control_manager_v1")) {
        if (!strcmp(only, "wlr-v1")) {
            if (strcmp(name, "zwlr_data_control_manager_v1")) return 0;
            fputs("Probe advertised zwlr_data_control_manager_v1 version 1\n", stderr);
            listener->global(data, target, args[0].u, name, 1);
            return 0;
        }
        if (strcmp(name, only)) return 0;
    }
    listener->global(data, target, args[0].u, name, args[2].u);
    return 0;
}

int wl_proxy_add_listener(struct wl_proxy *proxy, void (**listener)(void), void *data) {
    if (!strcmp(wl_proxy_get_class(proxy), "wl_registry") && getenv("RUNE_TEST_PRIMARY_PROTOCOL")) {
        return wl_proxy_add_dispatcher(proxy, global_event, listener, data);
    }
    typedef int (*AddListener)(struct wl_proxy *, void (**)(void), void *);
    AddListener real = (AddListener)dlsym(RTLD_NEXT, "wl_proxy_add_listener");
    return real(proxy, listener, data);
}
