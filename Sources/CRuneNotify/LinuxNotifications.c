#include "CRuneNotify.h"
#if defined(__linux__) && !defined(__ANDROID__)
#include <gio/gio.h>
#include <string.h>

#define SERVICE "org.freedesktop.Notifications"
#define OBJECT_PATH "/org/freedesktop/Notifications"
#define TIMEOUT_MS 3000

struct RuneNotifyLinux {
    GDBusConnection *bus;
    GMainContext *context;
    GMainLoop *loop;
    GThread *thread;
    guint signal_subscription, owner_subscription;
    RuneNotifyLinuxEvent event;
};

struct RuneNotifyLinuxMessage {
    char *name, *icon, *title, *body;
    GVariantBuilder hints;
    GPtrArray *actions;
    char *reply_placeholder, *reply_label;
};

static void signal_received(GDBusConnection *bus, const gchar *sender, const gchar *path,
                            const gchar *interface, const gchar *name, GVariant *parameters,
                            gpointer user_data) {
    RuneNotifyLinux *client = user_data;
    guint32 number;
    const char *value;
    (void)bus; (void)path; (void)interface;
    if (!strcmp(name, "NameOwnerChanged") &&
        g_variant_is_of_type(parameters, G_VARIANT_TYPE("(sss)"))) {
        const char *service, *old_owner, *new_owner;
        g_variant_get(parameters, "(&s&s&s)", &service, &old_owner, &new_owner);
        if (*old_owner && !strcmp(service, SERVICE))
            client->event(client, RUNE_NOTIFY_SERVER_GONE, old_owner, 0, "");
    } else if (!strcmp(name, "NotificationClosed") &&
               g_variant_is_of_type(parameters, G_VARIANT_TYPE("(uu)"))) {
        guint32 reason;
        g_variant_get(parameters, "(uu)", &number, &reason);
        client->event(client, RUNE_NOTIFY_CLOSED, sender, number, "");
    } else if (g_variant_is_of_type(parameters, G_VARIANT_TYPE("(us)"))) {
        g_variant_get(parameters, "(u&s)", &number, &value);
        if (!strcmp(name, "ActionInvoked"))
            client->event(client, RUNE_NOTIFY_ACTION, sender, number, value);
        else if (!strcmp(name, "NotificationReplied"))
            client->event(client, RUNE_NOTIFY_REPLIED, sender, number, value);
        else if (!strcmp(name, "ActivationToken"))
            client->event(client, RUNE_NOTIFY_ACTIVATION_TOKEN, sender, number, value);
    }
}

static gpointer run_signals(gpointer data) {
    RuneNotifyLinux *client = data;
    g_main_context_push_thread_default(client->context);
    g_main_loop_run(client->loop);
    g_dbus_connection_signal_unsubscribe(client->bus, client->signal_subscription);
    g_dbus_connection_signal_unsubscribe(client->bus, client->owner_subscription);
    g_main_context_pop_thread_default(client->context);
    return NULL;
}

RuneNotifyLinux *rune_notify_linux_connect(RuneNotifyLinuxEvent event) {
    gchar *address = g_dbus_address_get_for_bus_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    if (!address) return NULL;
    GDBusConnection *bus = g_dbus_connection_new_for_address_sync(address,
        G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION,
        NULL, NULL, NULL);
    g_free(address);
    if (!bus) return NULL;
    RuneNotifyLinux *client = g_new0(RuneNotifyLinux, 1);
    client->bus = bus;
    client->event = event;
    client->context = g_main_context_new();
    client->loop = g_main_loop_new(client->context, FALSE);
    /* Bind subscriptions to this process's own context. RuneNotify also works in
       command-line clients that have no GTK or SDL event loop. */
    g_main_context_push_thread_default(client->context);
    client->signal_subscription = g_dbus_connection_signal_subscribe(bus, SERVICE, SERVICE,
        NULL, OBJECT_PATH, NULL, G_DBUS_SIGNAL_FLAGS_NONE, signal_received, client, NULL);
    client->owner_subscription = g_dbus_connection_signal_subscribe(bus, "org.freedesktop.DBus",
        "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus", SERVICE,
        G_DBUS_SIGNAL_FLAGS_NONE, signal_received, client, NULL);
    g_main_context_pop_thread_default(client->context);
    client->thread = g_thread_new("rune-notifications", run_signals, client);
    return client;
}

static gboolean stop_loop(gpointer data) {
    g_main_loop_quit(data);
    return G_SOURCE_REMOVE;
}

void rune_notify_linux_disconnect(RuneNotifyLinux *client) {
    if (!client) return;
    GSource *stop = g_idle_source_new();
    g_source_set_callback(stop, stop_loop, client->loop, NULL);
    g_source_attach(stop, client->context);
    g_source_unref(stop);
    g_thread_join(client->thread);
    g_main_loop_unref(client->loop);
    g_main_context_unref(client->context);
    g_dbus_connection_close_sync(client->bus, NULL, NULL);
    g_object_unref(client->bus);
    g_free(client);
}

/* The reply identifies the unique daemon connection as well as its capabilities.
   An old numeric ID cannot replace or erase a notification on a restarted server. */
static GDBusMessage *capabilities(RuneNotifyLinux *client) {
    if (!client) return NULL;
    GDBusMessage *request = g_dbus_message_new_method_call(SERVICE, OBJECT_PATH, SERVICE, "GetCapabilities");
    GDBusMessage *reply = g_dbus_connection_send_message_with_reply_sync(client->bus, request,
        G_DBUS_SEND_MESSAGE_FLAGS_NONE, TIMEOUT_MS, NULL, NULL, NULL);
    g_object_unref(request);
    if (reply && (g_dbus_message_get_message_type(reply) != G_DBUS_MESSAGE_TYPE_METHOD_RETURN ||
                  !g_dbus_message_get_sender(reply) || !g_dbus_message_get_body(reply) ||
                  !g_variant_is_of_type(g_dbus_message_get_body(reply), G_VARIANT_TYPE("(as)"))))
        g_clear_object(&reply);
    return reply;
}

int rune_notify_linux_connected(RuneNotifyLinux *client) {
    return client && !g_dbus_connection_is_closed(client->bus);
}

int rune_notify_linux_available(RuneNotifyLinux *client) {
    GDBusMessage *reply = capabilities(client);
    if (!reply) return 0;
    g_object_unref(reply);
    return 1;
}

RuneNotifyLinuxMessage *rune_notify_linux_message(const char *name, const char *desktop_entry,
    const char *icon, const char *title, const char *body, uint8_t urgency,
    int silent, const char *sound, const char *category) {
    RuneNotifyLinuxMessage *m = g_new0(RuneNotifyLinuxMessage, 1);
    m->name = g_strdup(name); m->icon = g_strdup(icon);
    m->title = g_strdup(title); m->body = g_strdup(body);
    m->actions = g_ptr_array_new_with_free_func(g_free);
    g_variant_builder_init(&m->hints, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&m->hints, "{sv}", "urgency", g_variant_new_byte(urgency));
    if (*desktop_entry) g_variant_builder_add(&m->hints, "{sv}", "desktop-entry", g_variant_new_string(desktop_entry));
    if (silent) g_variant_builder_add(&m->hints, "{sv}", "suppress-sound", g_variant_new_boolean(TRUE));
    if (*sound) g_variant_builder_add(&m->hints, "{sv}", "sound-name", g_variant_new_string(sound));
    if (*category) g_variant_builder_add(&m->hints, "{sv}", "category", g_variant_new_string(category));
    return m;
}

void rune_notify_linux_action(RuneNotifyLinuxMessage *m, const char *key,
                             const char *label, const char *reply_placeholder) {
    if (reply_placeholder) {
        if (m->reply_label) return; /* The inline-reply extension allows one field. */
        m->reply_label = g_strdup(label);
        m->reply_placeholder = g_strdup(reply_placeholder);
    } else {
        g_ptr_array_add(m->actions, g_strdup(key));
        g_ptr_array_add(m->actions, g_strdup(label));
    }
}

uint32_t rune_notify_linux_post(RuneNotifyLinux *client, RuneNotifyLinuxMessage *m,
    const char *prior_owner, uint32_t prior_number, char **posted_owner) {
    *posted_owner = NULL;
    GDBusMessage *reply = capabilities(client);
    if (!reply) return 0;
    const char *owner = g_dbus_message_get_sender(reply);
    GVariant *caps = g_variant_get_child_value(g_dbus_message_get_body(reply), 0);
    const char **flags = g_variant_get_strv(caps, NULL);
    GVariantBuilder actions;
    g_variant_builder_init(&actions, G_VARIANT_TYPE_STRING_ARRAY);
    if (g_strv_contains(flags, "actions")) {
        g_variant_builder_add(&actions, "s", "default");
        g_variant_builder_add(&actions, "s", "");
        for (guint i = 0; i < m->actions->len; i++)
            g_variant_builder_add(&actions, "s", (char *)g_ptr_array_index(m->actions, i));
    }
    if (m->reply_label && g_strv_contains(flags, "inline-reply")) {
        g_variant_builder_add(&actions, "s", "inline-reply");
        g_variant_builder_add(&actions, "s", m->reply_label);
        g_variant_builder_add(&m->hints, "{sv}", "x-kde-reply-placeholder-text", g_variant_new_string(m->reply_placeholder));
        g_variant_builder_add(&m->hints, "{sv}", "x-kde-reply-submit-button-text", g_variant_new_string(m->reply_label));
    }
    char *body = g_strv_contains(flags, "body-markup") ? g_markup_escape_text(m->body, -1) : g_strdup(m->body);
    guint32 replace = prior_owner && !strcmp(owner, prior_owner) ? prior_number : 0;
    GVariant *response = g_dbus_connection_call_sync(client->bus, owner, OBJECT_PATH, SERVICE,
        "Notify", g_variant_new("(susss@as@a{sv}i)", m->name, replace, m->icon, m->title, body,
           g_variant_builder_end(&actions), g_variant_builder_end(&m->hints), -1),
        G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, TIMEOUT_MS, NULL, NULL);
    guint32 number = 0;
    if (response) {
        g_variant_get(response, "(u)", &number);
        if (number) *posted_owner = g_strdup(owner);
        g_variant_unref(response);
    }
    g_free(body); g_free(flags); g_variant_unref(caps); g_object_unref(reply);
    return number;
}

int rune_notify_linux_remove(RuneNotifyLinux *client, const char *owner, uint32_t number) {
    GVariant *reply = g_dbus_connection_call_sync(client->bus, owner, OBJECT_PATH, SERVICE,
        "CloseNotification", g_variant_new("(u)", number), G_VARIANT_TYPE_UNIT,
        G_DBUS_CALL_FLAGS_NO_AUTO_START, TIMEOUT_MS, NULL, NULL);
    if (!reply) return 0;
    g_variant_unref(reply);
    return 1;
}

void rune_notify_linux_message_free(RuneNotifyLinuxMessage *m) {
    if (!m) return;
    g_free(m->name); g_free(m->icon); g_free(m->title); g_free(m->body);
    g_free(m->reply_placeholder); g_free(m->reply_label);
    g_ptr_array_unref(m->actions); g_variant_builder_clear(&m->hints); g_free(m);
}

void rune_notify_linux_free_string(char *value) { g_free(value); }
#endif
