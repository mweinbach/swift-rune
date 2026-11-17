#if defined(__linux__) && !defined(__ANDROID__)
#include "linux_tray_model.h"

#define ITEM "org.kde.StatusNotifierItem"
#define MENU "com.canonical.dbusmenu"
#define WATCHER "org.kde.StatusNotifierWatcher"
#define ITEM_PATH "/StatusNotifierItem"
#define MENU_PATH "/MenuBar"
#define WATCHER_PATH "/StatusNotifierWatcher"

#define IN(t) "<arg type='" t "' direction='in'/>"
#define OUT(t) "<arg type='" t "' direction='out'/>"
#define METHOD(n, args) "<method name='" n "'>" args "</method>"
#define PROP(n, t) "<property name='" n "' type='" t "' access='read'/>"
static const char tray_xml[] =
    "<node><interface name='" ITEM "'>"
    METHOD("Activate", IN("i") IN("i")) METHOD("SecondaryActivate", IN("i") IN("i"))
    METHOD("ContextMenu", IN("i") IN("i")) METHOD("Scroll", IN("i") IN("s"))
    METHOD("ProvideXdgActivationToken", IN("s"))
    PROP("Category","s") PROP("Id","s") PROP("Title","s") PROP("Status","s") PROP("WindowId","i")
    PROP("IconName","s") PROP("IconPixmap","a(iiay)") PROP("ToolTip","(sa(iiay)ss)")
    PROP("ItemIsMenu","b") PROP("Menu","o")
    "<signal name='NewToolTip'/><signal name='NewTitle'/><signal name='NewIcon'/>"
    "</interface><interface name='" MENU "'>"
    METHOD("GetLayout", IN("i") IN("i") IN("as") OUT("u") OUT("(ia{sv}av)"))
    METHOD("GetGroupProperties", IN("ai") IN("as") OUT("a(ia{sv})"))
    METHOD("GetProperty", IN("i") IN("s") OUT("v"))
    METHOD("Event", IN("i") IN("s") IN("v") IN("u"))
    METHOD("EventGroup", IN("a(isvu)") OUT("ai"))
    METHOD("AboutToShow", IN("i") OUT("b"))
    METHOD("AboutToShowGroup", IN("ai") OUT("ai") OUT("ai"))
    PROP("Version","u") PROP("TextDirection","s") PROP("Status","s") PROP("IconThemePath","as")
    "<signal name='LayoutUpdated'><arg type='u'/><arg type='i'/></signal>"
    "</interface></node>";

static void free_update(gpointer data);

struct RuneLinuxTray {
    GMainContext *context;
    GMainLoop *loop;
    GThread *thread;
    GMutex ready_lock;
    GCond ready_cond;
    gboolean ready;
    GError *error;
    gint closing;
    GDBusConnection *bus;
    GSource *connect_timeout;
    GAsyncQueue *updates;
    GDBusNodeInfo *info;
    guint item_object, menu_object, watch, revision;
    char *token;
    RuneLinuxTraySpec *spec;
    RuneLinuxTrayEvent event;
    RuneLinuxTrayRelease release;
    void *observer;
    gatomicrefcount references;  /* external owner and worker */
};

static GVariant *property(GDBusConnection *bus, const gchar *sender, const gchar *path, const gchar *interface,
                          const gchar *name, GError **error, gpointer data) {
    (void)bus; (void)sender; (void)path;
    RuneLinuxTray *tray = data;
    RuneLinuxTraySpec *spec = tray->spec;
    if (g_str_equal(interface, ITEM)) {
        if (g_str_equal(name, "Category")) return g_variant_new_string("ApplicationStatus");
        if (g_str_equal(name, "Id")) return g_variant_new_string(spec->id);
        if (g_str_equal(name, "Title")) return g_variant_new_string(spec->title);
        if (g_str_equal(name, "Status")) return g_variant_new_string("Active");
        if (g_str_equal(name, "WindowId")) return g_variant_new_int32(0);
        if (g_str_equal(name, "IconName")) return g_variant_new_string(spec->icon_name);
        if (g_str_equal(name, "IconPixmap")) return g_variant_ref(spec->pixmaps);
        if (g_str_equal(name, "ItemIsMenu")) return g_variant_new_boolean(FALSE);
        if (g_str_equal(name, "Menu")) return g_variant_new_object_path(MENU_PATH);
        if (g_str_equal(name, "ToolTip"))
            return g_variant_new("(s@a(iiay)ss)", "", g_variant_new_array(G_VARIANT_TYPE("(iiay)"), NULL, 0), spec->tooltip, "");
    } else {
        if (g_str_equal(name, "Version")) return g_variant_new_uint32(3);
        if (g_str_equal(name, "TextDirection")) return g_variant_new_string("ltr");
        if (g_str_equal(name, "Status")) return g_variant_new_string("normal");
        if (g_str_equal(name, "IconThemePath")) return g_variant_new_strv(NULL, 0);
    }
    g_set_error_literal(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY, "Unknown tray property");
    return NULL;
}

static void menu_event(RuneLinuxTray *tray, GVariant *args) {
    gint id;
    const gchar *kind;
    g_variant_get_child(args, 0, "i", &id);
    g_variant_get_child(args, 1, "&s", &kind);
    if (!g_str_equal(kind, "clicked") || id < 1 || (guint)id > tray->spec->items->len || g_atomic_int_get(&tray->closing)) return;
    RuneTrayEntry *item = g_ptr_array_index(tray->spec->items, id-1);
    if (item->id && item->enabled) {
        /* A callback may update the menu or remove its own tray. */
        g_autofree gchar *picked = g_strdup(item->id);
        tray->event(tray->observer, picked, NULL);
    }
}

static GVariant *group_properties(RuneLinuxTraySpec *spec, GVariant *args) {
    g_autoptr(GVariant) ids = g_variant_get_child_value(args, 0);
    gsize count;
    const gint32 *requested = g_variant_get_fixed_array(ids, &count, sizeof(gint32));
    GVariantBuilder rows;
    g_variant_builder_init(&rows, G_VARIANT_TYPE("a(ia{sv})"));
    for (gsize k = 0; k < (count ? count : spec->items->len); k++) {
        gint id = count ? requested[k] : (gint)k+1;
        g_variant_builder_add(&rows, "(i@a{sv})", id, rune_tray_menu_properties(spec, id));
    }
    return g_variant_new("(@a(ia{sv}))", g_variant_builder_end(&rows));
}

static void method(GDBusConnection *bus, const gchar *sender, const gchar *path, const gchar *interface,
                   const gchar *name, GVariant *args, GDBusMethodInvocation *call, gpointer data) {
    (void)bus; (void)sender; (void)path;
    RuneLinuxTray *tray = data;
    GVariant *reply = NULL;
    if (g_str_equal(interface, ITEM)) {
        if (g_str_equal(name, "ProvideXdgActivationToken")) {
            g_free(tray->token);
            g_variant_get(args, "(s)", &tray->token);
        } else if (g_str_equal(name, "Activate") && !g_atomic_int_get(&tray->closing)) {
            g_autofree gchar *token = g_steal_pointer(&tray->token);
            tray->event(tray->observer, NULL, token);
        }
    } else if (g_str_equal(name, "GetLayout")) {
        gint id;
        g_variant_get_child(args, 0, "i", &id);
        reply = g_variant_new("(u@(ia{sv}av))", tray->revision, rune_tray_menu_layout(tray->spec, id));
    } else if (g_str_equal(name, "GetGroupProperties")) {
        reply = group_properties(tray->spec, args);
    } else if (g_str_equal(name, "GetProperty")) {
        gint id;
        const char *key;
        g_variant_get(args, "(i&s)", &id, &key);
        g_autoptr(GVariant) props = g_variant_ref_sink(rune_tray_menu_properties(tray->spec, id));
        g_autoptr(GVariant) value = g_variant_lookup_value(props, key, NULL);
        if (!value) {
            g_dbus_method_invocation_return_error_literal(call, G_DBUS_ERROR, G_DBUS_ERROR_INVALID_ARGS, "No such menu property");
            return;
        }
        reply = g_variant_new("(v)", value);
    } else if (g_str_equal(name, "Event")) {
        menu_event(tray, args);
    } else if (g_str_equal(name, "EventGroup")) {
        g_autoptr(GVariant) batch = g_variant_get_child_value(args, 0);
        GVariantIter events;
        g_variant_iter_init(&events, batch);
        GVariant *event;
        while ((event = g_variant_iter_next_value(&events))) {
            menu_event(tray, event);
            g_variant_unref(event);
        }
        reply = g_variant_new("(@ai)", g_variant_new_array(G_VARIANT_TYPE_INT32, NULL, 0));
    } else if (g_str_equal(name, "AboutToShow")) {
        reply = g_variant_new("(b)", FALSE);
    } else if (g_str_equal(name, "AboutToShowGroup")) {
        reply = g_variant_new("(@ai@ai)", g_variant_new_array(G_VARIANT_TYPE_INT32, NULL, 0),
                              g_variant_new_array(G_VARIANT_TYPE_INT32, NULL, 0));
    }
    g_dbus_method_invocation_return_value(call, reply);
}

static const GDBusInterfaceVTable vtable = {.method_call = method, .get_property = property};

static void watcher_appeared(GDBusConnection *bus, const gchar *name, const gchar *owner, gpointer data) {
    (void)name; (void)data;
    g_dbus_connection_call(bus, owner, WATCHER_PATH, WATCHER, "RegisterStatusNotifierItem",
        g_variant_new("(s)", g_dbus_connection_get_unique_name(bus)), G_VARIANT_TYPE_UNIT,
        G_DBUS_CALL_FLAGS_NO_AUTO_START, 5000, NULL, NULL, NULL);
}

static void ready(RuneLinuxTray *tray, GError *error) {
    g_mutex_lock(&tray->ready_lock);
    tray->error = error;
    tray->ready = TRUE;
    g_cond_signal(&tray->ready_cond);
    g_mutex_unlock(&tray->ready_lock);
    if (error) g_main_loop_quit(tray->loop);
}

static void connected(GObject *object, GAsyncResult *result, gpointer data) {
    (void)object;
    RuneLinuxTray *tray = data;
    GError *error = NULL;
    g_source_destroy(tray->connect_timeout);
    tray->bus = g_dbus_connection_new_for_address_finish(result, &error);
    if (g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) {
        g_clear_error(&error);
        error = g_error_new_literal(G_IO_ERROR, G_IO_ERROR_TIMED_OUT, "Session bus connection timed out");
    }
    if (tray->bus) {
        g_dbus_connection_set_exit_on_close(tray->bus, FALSE);
        tray->info = g_dbus_node_info_new_for_xml(tray_xml, &error);
        if (tray->info) tray->item_object = g_dbus_connection_register_object(tray->bus, ITEM_PATH,
            tray->info->interfaces[0], &vtable, tray, NULL, &error);
        if (tray->item_object) tray->menu_object = g_dbus_connection_register_object(tray->bus, MENU_PATH,
            tray->info->interfaces[1], &vtable, tray, NULL, &error);
        if (tray->menu_object) tray->watch = g_bus_watch_name_on_connection(tray->bus, WATCHER,
            G_BUS_NAME_WATCHER_FLAGS_NONE, watcher_appeared, NULL, tray, NULL);
    }
    ready(tray, error);
}

static gboolean cancel_connect(gpointer data) {
    g_cancellable_cancel(data);
    return G_SOURCE_REMOVE;
}

static void tray_unref(RuneLinuxTray *tray) {
    if (!g_atomic_ref_count_dec(&tray->references)) return;
    g_clear_error(&tray->error);
    g_cond_clear(&tray->ready_cond);
    g_mutex_clear(&tray->ready_lock);
    g_async_queue_unref(tray->updates);
    g_main_loop_unref(tray->loop);
    g_main_context_unref(tray->context);
    g_free(tray->token);
    rune_tray_spec_free(tray->spec);
    tray->release(tray->observer);
    g_free(tray);
}

static gpointer worker(gpointer data) {
    RuneLinuxTray *tray = data;
    g_main_context_push_thread_default(tray->context);
    GError *error = NULL;
    g_autofree gchar *address = g_dbus_address_get_for_bus_sync(G_BUS_TYPE_SESSION, NULL, &error);
    if (address) {
        g_autoptr(GCancellable) cancel = g_cancellable_new();
        tray->connect_timeout = g_timeout_source_new(5000);
        g_source_set_callback(tray->connect_timeout, cancel_connect, cancel, NULL);
        g_source_attach(tray->connect_timeout, tray->context);
        g_dbus_connection_new_for_address(address, G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT |
            G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION, NULL, cancel, connected, tray);
        g_main_loop_run(tray->loop);
        g_clear_pointer(&tray->connect_timeout, g_source_unref);
    } else {
        ready(tray, error);
    }

    if (tray->watch) g_bus_unwatch_name(tray->watch);
    if (tray->bus) {
        if (tray->menu_object) g_dbus_connection_unregister_object(tray->bus, tray->menu_object);
        if (tray->item_object) g_dbus_connection_unregister_object(tray->bus, tray->item_object);
        if (!g_dbus_connection_is_closed(tray->bus)) {
            g_dbus_connection_flush_sync(tray->bus, NULL, NULL);
            g_dbus_connection_close_sync(tray->bus, NULL, NULL);
        }
        g_clear_object(&tray->bus);
    }
    g_clear_pointer(&tray->info, g_dbus_node_info_unref);
    g_main_context_pop_thread_default(tray->context);
    tray_unref(tray);
    return NULL;
}

RuneLinuxTray *rune_linux_tray_open(RuneLinuxTraySpec *spec, void *observer, RuneLinuxTrayEvent event,
                                    RuneLinuxTrayRelease release, char *message, size_t capacity) {
    RuneLinuxTray *tray = g_new0(RuneLinuxTray, 1);
    g_atomic_ref_count_init(&tray->references);
    g_atomic_ref_count_inc(&tray->references);
    g_mutex_init(&tray->ready_lock);
    g_cond_init(&tray->ready_cond);
    tray->context = g_main_context_new();
    tray->updates = g_async_queue_new_full(free_update);
    tray->loop = g_main_loop_new(tray->context, FALSE);
    tray->revision = 1;
    tray->spec = spec;
    tray->observer = observer;
    tray->event = event;
    tray->release = release;
    g_mutex_lock(&tray->ready_lock);
    tray->thread = g_thread_try_new("rune-tray", worker, tray, &tray->error);
    if (tray->thread) {
        while (!tray->ready) g_cond_wait(&tray->ready_cond, &tray->ready_lock);
    }
    gboolean failed = tray->error != NULL;
    if (failed && capacity) g_strlcpy(message, tray->error->message, capacity);
    g_mutex_unlock(&tray->ready_lock);
    if (failed) {
        if (tray->thread) g_thread_join(tray->thread);
        else tray_unref(tray);
        tray_unref(tray);
        return NULL;
    }
    return tray;
}

typedef struct {
    RuneLinuxTray *tray;
    RuneLinuxTraySpec *spec;
    char *tooltip;
    gboolean keep_pixels;
} Update;

static void signal_item(RuneLinuxTray *tray, const char *name) {
    g_dbus_connection_emit_signal(tray->bus, NULL, ITEM_PATH, ITEM, name, NULL, NULL);
}

static void apply_update(Update *cmd) {
    RuneLinuxTray *tray = cmd->tray;
    RuneLinuxTraySpec *old = tray->spec, *next = cmd->spec;
    if (g_atomic_int_get(&tray->closing)) return;
    if (cmd->tooltip) {
        if (g_strcmp0(old->tooltip, cmd->tooltip)) {
            g_free(old->tooltip);
            old->tooltip = g_steal_pointer(&cmd->tooltip);
            signal_item(tray, "NewToolTip");
        }
        return;
    }
    if (cmd->keep_pixels) {
        g_variant_unref(next->pixmaps);
        next->pixmaps = g_variant_ref(old->pixmaps);
    }
    tray->spec = next;
    cmd->spec = old;
    if (!rune_tray_menu_equal(old, next))
        g_dbus_connection_emit_signal(tray->bus, NULL, MENU_PATH, MENU, "LayoutUpdated",
                                     g_variant_new("(ui)", ++tray->revision, 0), NULL);
    if (g_strcmp0(old->tooltip, next->tooltip)) signal_item(tray, "NewToolTip");
    if (g_strcmp0(old->title, next->title)) signal_item(tray, "NewTitle");
    if (g_strcmp0(old->icon_name, next->icon_name) ||
        (!cmd->keep_pixels && !g_variant_equal(old->pixmaps, next->pixmaps))) signal_item(tray, "NewIcon");
}

static void free_update(gpointer data) {
    Update *cmd = data;
    if (cmd->spec) rune_tray_spec_free(cmd->spec);
    g_free(cmd->tooltip);
    g_free(cmd);
}

/* A callback on the worker can update its own tray. Draining the FIFO first also applies
   any earlier updates from another caller before resolving a retained icon. */
static gboolean drain_updates(gpointer data) {
    RuneLinuxTray *tray = data;
    Update *cmd;
    while ((cmd = g_async_queue_try_pop(tray->updates))) {
        apply_update(cmd);
        free_update(cmd);
    }
    return G_SOURCE_REMOVE;
}

static void post_update(Update *cmd) {
    RuneLinuxTray *tray = cmd->tray;
    g_async_queue_push(tray->updates, cmd);
    g_main_context_invoke_full(tray->context, G_PRIORITY_DEFAULT, drain_updates, tray, NULL);
}

void rune_linux_tray_update(RuneLinuxTray *tray, RuneLinuxTraySpec *spec, int keep_pixels) {
    Update *cmd = g_new0(Update, 1);
    cmd->keep_pixels = keep_pixels != 0;
    cmd->tray = tray;
    cmd->spec = spec;
    post_update(cmd);
}

void rune_linux_tray_set_tooltip(RuneLinuxTray *tray, const char *tooltip) {
    Update *cmd = g_new0(Update, 1);
    cmd->tray = tray;
    cmd->tooltip = g_strdup(tooltip);
    post_update(cmd);
}

static gboolean stop(gpointer data) {
    g_main_loop_quit(((RuneLinuxTray *)data)->loop);
    return G_SOURCE_REMOVE;
}

void rune_linux_tray_close(RuneLinuxTray *tray) {
    g_atomic_int_set(&tray->closing, TRUE);
    g_main_context_invoke_full(tray->context, G_PRIORITY_DEFAULT, stop, tray, NULL);
    if (tray->thread == g_thread_self()) g_thread_unref(tray->thread);
    else g_thread_join(tray->thread);
    tray_unref(tray);
}
#endif
