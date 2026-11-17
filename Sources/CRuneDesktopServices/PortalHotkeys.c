#if defined(__linux__) && !defined(__ANDROID__)
#include "RuneDesktopHotkeys.h"
#include <gio/gio.h>
#include <string.h>

#define PORTAL_NAME "org.freedesktop.portal.Desktop"
#define PORTAL_PATH "/org/freedesktop/portal/desktop"
#define SHORTCUTS "org.freedesktop.portal.GlobalShortcuts"
#define REQUEST "org.freedesktop.portal.Request"
#define SESSION "org.freedesktop.portal.Session"
#define RPC_TIMEOUT_MS 5000
#define CONSENT_TIMEOUT_MS 120000

typedef struct {
    GMainLoop *loop;
    GThread *thread;
    GDBusConnection *bus;
    char *owner, *sender_path;
    guint activated, closed;
    guint64 serial;
    GHashTable *sessions;  /* Rune id -> owned portal object path */
    RuneHotkeySink sink;
    void *context;
} PortalHotkeys;

static int error_status(GError *error) {
    if (!error) return RUNE_HOTKEY_FAILED;
    g_autofree gchar *name = g_dbus_error_get_remote_error(error);
    if (g_strcmp0(name, "org.freedesktop.portal.Error.NotAllowed") == 0 ||
        g_strcmp0(name, "org.freedesktop.portal.Error.Cancelled") == 0)
        return RUNE_HOTKEY_DENIED;
    if (g_strcmp0(name, "org.freedesktop.portal.Error.Exist") == 0) return RUNE_HOTKEY_CONFLICT;
    if (g_strcmp0(name, "org.freedesktop.portal.Error.InvalidArgument") == 0) return RUNE_HOTKEY_INVALID;
    if (g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_SERVICE_UNKNOWN) ||
        g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_NAME_HAS_NO_OWNER) ||
        g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_INTERFACE) ||
        g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD) ||
        g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_OBJECT)) return RUNE_HOTKEY_UNSUPPORTED;
    return RUNE_HOTKEY_FAILED;
}

static char *preferred_trigger(uint8_t mods, const char *key) {
    static const struct { const char *key, *symbol; } named[] = {
        {"escape","Escape"}, {"enter","Return"}, {"space","space"}, {"tab","Tab"},
        {"backspace","BackSpace"}, {"delete","Delete"}, {"insert","Insert"}, {"home","Home"},
        {"end","End"}, {"pageup","Prior"}, {"pagedown","Next"}, {"left","Left"}, {"right","Right"},
        {"up","Up"}, {"down","Down"}, {"minus","minus"}, {"equal","equal"}, {"comma","comma"},
        {"period","period"}, {"slash","slash"}, {"semicolon","semicolon"}, {"quote","apostrophe"},
        {"bracketleft","bracketleft"}, {"bracketright","bracketright"}, {"backslash","backslash"},
        {"backquote","grave"}
    };
    if (!key || (mods & ~15)) return NULL;
    char function[4];
    const char *symbol = NULL;
    if (key[0] && !key[1] && (g_ascii_islower(key[0]) || g_ascii_isdigit(key[0]))) {
        symbol = key;
    } else if (key[0] == 'f' && g_ascii_isdigit(key[1]) && key[1] != '0') {
        guint64 number;
        if (g_ascii_string_to_unsigned(key + 1, 10, 1, 24, &number, NULL)) {
            g_snprintf(function, sizeof function, "F%u", (unsigned)number);
            symbol = function;
        }
    } else {
        for (size_t i = 0; i < G_N_ELEMENTS(named); ++i) {
            if (g_str_equal(key, named[i].key)) { symbol = named[i].symbol; break; }
        }
    }
    if (!symbol) return NULL;
    return g_strconcat(mods & 1 ? "CTRL+" : "", mods & 2 ? "ALT+" : "",
                       mods & 4 ? "SHIFT+" : "", mods & 8 ? "LOGO+" : "", symbol, NULL);
}

static int close_object(PortalHotkeys *s, const char *path, const char *interface) {
    g_autoptr(GError) error = NULL;
    g_autoptr(GVariant) result = g_dbus_connection_call_sync(s->bus, s->owner, path, interface,
        "Close", NULL, G_VARIANT_TYPE_UNIT, G_DBUS_CALL_FLAGS_NO_AUTO_START, RPC_TIMEOUT_MS, NULL, &error);
    // A session or portal process which already disappeared also releases the binding.
    if (result || g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_OBJECT) ||
        g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_NAME_HAS_NO_OWNER) ||
        g_error_matches(error, G_DBUS_ERROR, G_DBUS_ERROR_SERVICE_UNKNOWN) ||
        g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CLOSED))
        return RUNE_HOTKEY_OK;
    return error_status(error);
}

typedef struct { gboolean done; guint status; GVariant *values; } Response;

static void on_response(GDBusConnection *bus, const char *sender, const char *path,
                        const char *interface, const char *signal, GVariant *args, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)interface; (void)signal;
    Response *response = data;
    if (!response->done && g_variant_is_of_type(args, G_VARIANT_TYPE("(ua{sv})"))) {
        g_variant_get(args, "(u@a{sv})", &response->status, &response->values);
        response->done = TRUE;
    }
}

static gboolean end_wait(gpointer data) {
    ((Response *)data)->done = TRUE;
    return G_SOURCE_REMOVE;
}

static void on_owner_change(GDBusConnection *bus, const char *sender, const char *path,
                            const char *interface, const char *signal, GVariant *args, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)interface; (void)signal;
    const char *name, *old, *current;
    g_variant_get(args, "(&s&s&s)", &name, &old, &current);
    if (!current[0]) end_wait(data);
}

/* Subscribe before the call. The Response signal may arrive before its method reply.
   A private context keeps further register/close commands out of this consent wait. */
static int request(PortalHotkeys *s, const char *method, const char *token, GVariant *body,
                   GVariant **values) {
    g_autoptr(GMainContext) context = g_main_context_new();
    g_main_context_push_thread_default(context);
    Response response = {.status = G_MAXUINT};
    g_autofree char *path = g_strdup_printf(PORTAL_PATH "/request/%s/%s", s->sender_path, token);
    guint sub = g_dbus_connection_signal_subscribe(s->bus, s->owner, REQUEST, "Response",
        path, NULL, G_DBUS_SIGNAL_FLAGS_NONE, on_response, &response, NULL);
    guint owner = g_dbus_connection_signal_subscribe(s->bus, "org.freedesktop.DBus", "org.freedesktop.DBus",
        "NameOwnerChanged", "/org/freedesktop/DBus", s->owner, G_DBUS_SIGNAL_FLAGS_NONE, on_owner_change,
        &response, NULL);
    g_autoptr(GError) error = NULL;
    g_autoptr(GVariant) reply = g_dbus_connection_call_sync(s->bus, s->owner, PORTAL_PATH, SHORTCUTS, method,
        body, G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NO_AUTO_START, RPC_TIMEOUT_MS, NULL, &error);
    const char *expected_path = NULL;
    if (reply) g_variant_get(reply, "(&o)", &expected_path);
    int status = error_status(error);
    if (g_strcmp0(expected_path, path) == 0) {
        GSource *timeout = g_timeout_source_new(CONSENT_TIMEOUT_MS);
        g_source_set_callback(timeout, end_wait, &response, NULL);
        g_source_attach(timeout, context);
        while (!response.done) g_main_context_iteration(context, TRUE);
        g_source_destroy(timeout);
        g_source_unref(timeout);
        status = response.status == 0 ? RUNE_HOTKEY_OK :
                 response.status == 1 ? RUNE_HOTKEY_DENIED : RUNE_HOTKEY_FAILED;
    }
    g_dbus_connection_signal_unsubscribe(s->bus, sub);
    g_dbus_connection_signal_unsubscribe(s->bus, owner);
    if (!response.values) close_object(s, expected_path ? expected_path : path, REQUEST);
    g_main_context_pop_thread_default(context);
    if (status == RUNE_HOTKEY_OK) *values = response.values;
    else g_clear_pointer(&response.values, g_variant_unref);
    return status;
}

static int bind_shortcut(PortalHotkeys *s, guint32 id, const char *trigger) {
    if (g_hash_table_contains(s->sessions, GUINT_TO_POINTER(id))) return RUNE_HOTKEY_CONFLICT;
    g_autofree char *create = g_strdup_printf("rune_%" G_GUINT64_FORMAT, ++s->serial);
    GVariantBuilder options;
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&options, "{sv}", "handle_token", g_variant_new_string(create));
    g_variant_builder_add(&options, "{sv}", "session_handle_token", g_variant_new_string(create));
    g_autoptr(GVariant) created = NULL;
    int status = request(s, "CreateSession", create, g_variant_new("(a{sv})", &options), &created);
    if (status != RUNE_HOTKEY_OK) return status;
    const char *session = NULL;
    /* The portal specifies a string here for compatibility with historical implementations. */
    if (!g_variant_lookup(created, "session_handle", "&s", &session) &&
        !g_variant_lookup(created, "session_handle", "&o", &session)) return RUNE_HOTKEY_FAILED;
    if (!g_variant_is_object_path(session)) return RUNE_HOTKEY_FAILED;

    g_autofree char *bind = g_strdup_printf("%s_bind", create);
    g_autofree char *description = g_strconcat("Shortcut ", trigger, NULL);
    char key[11];
    g_snprintf(key, sizeof key, "%u", id);
    GVariantBuilder properties, shortcuts;
    g_variant_builder_init(&properties, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&properties, "{sv}", "description", g_variant_new_string(description));
    g_variant_builder_add(&properties, "{sv}", "preferred_trigger", g_variant_new_string(trigger));
    g_variant_builder_init(&shortcuts, G_VARIANT_TYPE("a(sa{sv})"));
    g_variant_builder_add(&shortcuts, "(sa{sv})", key, &properties);
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&options, "{sv}", "handle_token", g_variant_new_string(bind));

    g_autoptr(GVariant) bound = NULL;
    status = request(s, "BindShortcuts", bind, g_variant_new("(oa(sa{sv})sa{sv})",
                     session, &shortcuts, "", &options), &bound);
    if (status == RUNE_HOTKEY_OK) {
        /* Portal consent can succeed while binding a different set or no triggers. */
        g_autoptr(GVariant) bindings = g_variant_lookup_value(bound, "shortcuts", G_VARIANT_TYPE("a(sa{sv})"));
        status = RUNE_HOTKEY_DENIED;
        if (bindings) {
            GVariantIter iter;
            g_variant_iter_init(&iter, bindings);
            const char *name;
            while (g_variant_iter_next(&iter, "(&sa{sv})", &name, NULL)) {
                if (g_str_equal(name, key)) { status = RUNE_HOTKEY_OK; break; }
            }
        }
    }
    if (status == RUNE_HOTKEY_OK) g_hash_table_insert(s->sessions, GUINT_TO_POINTER(id), g_strdup(session));
    else close_object(s, session, SESSION);
    return status;
}

static void on_activated(GDBusConnection *bus, const char *sender, const char *path,
                         const char *interface, const char *signal, GVariant *args, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)interface; (void)signal;
    if (!g_variant_is_of_type(args, G_VARIANT_TYPE("(osta{sv})"))) return;
    PortalHotkeys *s = data;
    const char *session, *key, *token = NULL;
    guint64 id, timestamp;
    g_autoptr(GVariant) options = NULL;
    g_variant_get(args, "(&o&st@a{sv})", &session, &key, &timestamp, &options);
    if (!g_ascii_string_to_unsigned(key, 10, 0, G_MAXUINT32, &id, NULL) ||
        g_strcmp0(session, g_hash_table_lookup(s->sessions, GUINT_TO_POINTER((guint)id))) != 0) return;
    g_variant_lookup(options, "activation_token", "&s", &token);
    s->sink(s->context, (uint32_t)id, token);
}

static void on_session_closed(GDBusConnection *bus, const char *sender, const char *path,
                              const char *interface, const char *signal, GVariant *args, gpointer data) {
    (void)bus; (void)sender; (void)interface; (void)signal; (void)args;
    PortalHotkeys *s = data;
    GHashTableIter iter;
    gpointer session;
    g_hash_table_iter_init(&iter, s->sessions);
    while (g_hash_table_iter_next(&iter, NULL, &session)) {
        if (g_strcmp0(path, session) == 0) {
            // Retain the public ID so its eventual unregister still succeeds.
            g_hash_table_iter_replace(&iter, NULL);
            break;
        }
    }
}

static int connect_portal(PortalHotkeys *s) {
    g_autofree char *address = g_dbus_address_get_for_bus_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    if (!address) return RUNE_HOTKEY_UNSUPPORTED;
    s->bus = g_dbus_connection_new_for_address_sync(address, G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT |
        G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION, NULL, NULL, NULL);
    if (!s->bus) return RUNE_HOTKEY_UNSUPPORTED;
    g_dbus_connection_set_exit_on_close(s->bus, FALSE);
    /* Get(version) also attempts normal D-Bus service activation. */
    g_autoptr(GVariant) result = g_dbus_connection_call_sync(s->bus, PORTAL_NAME, PORTAL_PATH,
        "org.freedesktop.DBus.Properties", "Get", g_variant_new("(ss)", SHORTCUTS, "version"),
        G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, RPC_TIMEOUT_MS, NULL, NULL);
    if (!result) return RUNE_HOTKEY_UNSUPPORTED;
    g_autoptr(GVariant) version = NULL;
    g_variant_get(result, "(v)", &version);
    if (!g_variant_is_of_type(version, G_VARIANT_TYPE_UINT32) || g_variant_get_uint32(version) < 1)
        return RUNE_HOTKEY_UNSUPPORTED;
    g_autoptr(GVariant) owner = g_dbus_connection_call_sync(s->bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus", "GetNameOwner", g_variant_new("(s)", PORTAL_NAME),
        G_VARIANT_TYPE("(s)"), G_DBUS_CALL_FLAGS_NONE, RPC_TIMEOUT_MS, NULL, NULL);
    if (!owner) return RUNE_HOTKEY_UNSUPPORTED;
    g_variant_get(owner, "(s)", &s->owner);
    s->sender_path = g_strdup(g_dbus_connection_get_unique_name(s->bus) + 1);
    g_strdelimit(s->sender_path, ".", '_');
    s->activated = g_dbus_connection_signal_subscribe(s->bus, s->owner, SHORTCUTS, "Activated", PORTAL_PATH,
        NULL, G_DBUS_SIGNAL_FLAGS_NONE, on_activated, s, NULL);
    s->closed = g_dbus_connection_signal_subscribe(s->bus, s->owner, SESSION, "Closed", NULL,
        NULL, G_DBUS_SIGNAL_FLAGS_NONE, on_session_closed, s, NULL);
    return RUNE_HOTKEY_OK;
}

typedef enum { OPEN, BIND, UNBIND, STOP } Operation;
typedef struct {
    PortalHotkeys *s;
    Operation op;
    guint32 id;
    const char *trigger;
    GAsyncQueue *reply;
} Command;

static gboolean execute(gpointer data) {
    Command *cmd = data;
    PortalHotkeys *s = cmd->s;
    int status = RUNE_HOTKEY_OK;
    switch (cmd->op) {
    case OPEN: status = connect_portal(s); break;
    case BIND: status = bind_shortcut(s, cmd->id, cmd->trigger); break;
    case UNBIND: {
        gpointer path;
        if (!g_hash_table_lookup_extended(s->sessions, GUINT_TO_POINTER(cmd->id), NULL, &path))
            status = RUNE_HOTKEY_UNKNOWN_ID;
        else if (path)
            status = close_object(s, path, SESSION);
        if (status == RUNE_HOTKEY_OK) g_hash_table_remove(s->sessions, GUINT_TO_POINTER(cmd->id));
        break;
    }
    case STOP:
        if (s->activated) g_dbus_connection_signal_unsubscribe(s->bus, s->activated);
        if (s->closed) g_dbus_connection_signal_unsubscribe(s->bus, s->closed);
        GHashTableIter iter;
        gpointer path;
        g_hash_table_iter_init(&iter, s->sessions);
        while (g_hash_table_iter_next(&iter, NULL, &path)) {
            if (path) close_object(s, path, SESSION);
        }
        g_main_loop_quit(s->loop);
        break;
    }
    g_async_queue_push(cmd->reply, GINT_TO_POINTER(status + 1));
    return G_SOURCE_REMOVE;
}

static int run_command(PortalHotkeys *s, Operation op, guint32 id, const char *trigger) {
    g_autoptr(GAsyncQueue) queue = g_async_queue_new();
    Command command = {s, op, id, trigger, queue};
    g_main_context_invoke(g_main_loop_get_context(s->loop), execute, &command);
    return GPOINTER_TO_INT(g_async_queue_pop(queue)) - 1;
}

static gpointer run_portal(gpointer data) {
    PortalHotkeys *s = data;
    GMainContext *context = g_main_loop_get_context(s->loop);
    g_main_context_push_thread_default(context);
    g_main_loop_run(s->loop);
    if (s->bus) g_dbus_connection_close_sync(s->bus, NULL, NULL);
    g_clear_object(&s->bus);
    g_main_context_pop_thread_default(context);
    return NULL;
}

void *rune_portal_hotkeys_open(RuneHotkeySink sink, void *context, int *status) {
    if (status) *status = RUNE_HOTKEY_FAILED;
    if (!sink) return NULL;
    PortalHotkeys *s = g_new0(PortalHotkeys, 1);
    s->sink = sink;
    s->context = context;
    s->sessions = g_hash_table_new_full(g_direct_hash, g_direct_equal, NULL, g_free);
    g_autoptr(GMainContext) dispatch = g_main_context_new();
    s->loop = g_main_loop_new(dispatch, FALSE);
    s->thread = g_thread_try_new("rune-shortcuts", run_portal, s, NULL);
    int opened = s->thread ? run_command(s, OPEN, 0, NULL) : RUNE_HOTKEY_FAILED;
    if (status) *status = opened;
    if (opened != RUNE_HOTKEY_OK) { rune_portal_hotkeys_close(s); return NULL; }
    return s;
}

int rune_portal_hotkeys_register(void *manager, uint32_t id, uint8_t mods, const char *name) {
    if (!manager) return RUNE_HOTKEY_UNSUPPORTED;
    g_autofree char *trigger = preferred_trigger(mods, name);
    return trigger ? run_command(manager, BIND, id, trigger) : RUNE_HOTKEY_INVALID;
}

int rune_portal_hotkeys_unregister(void *manager, uint32_t id) {
    return manager ? run_command(manager, UNBIND, id, NULL) : RUNE_HOTKEY_UNKNOWN_ID;
}

void rune_portal_hotkeys_close(void *manager) {
    PortalHotkeys *s = manager;
    if (!s) return;
    if (s->thread) {
        run_command(s, STOP, 0, NULL);
        g_thread_join(s->thread);
    }
    g_main_loop_unref(s->loop);
    g_hash_table_unref(s->sessions);
    g_free(s->sender_path);
    g_free(s->owner);
    g_free(s);
}
#endif
