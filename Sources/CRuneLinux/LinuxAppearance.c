#ifdef __linux__
#include "CRuneLinux.h"
#include <gio/gio.h>

#define PORTAL "org.freedesktop.portal.Desktop"
#define PATH "/org/freedesktop/portal/desktop"
#define SETTINGS "org.freedesktop.portal.Settings"
#define APPEARANCE "org.freedesktop.appearance"

struct RuneLinuxAppearance {
    // GIO invokes these callbacks on the creating thread's main context.
    guint refs, watch, signal, ownerGeneration, changedSinceRead;
    gboolean dirty, closed;
    GDBusConnection *bus;
    GSettings *desktop, *accessibility;
    RuneLinuxPreferences portal;
};

static const RuneLinuxPreferences no_preferences = {.dark = -1, .reducedMotion = -1, .increasedContrast = -1};
static const char *keys[] = {"color-scheme", "reduced-motion", "contrast", "accent-color"};

static void release(gpointer data) {
    RuneLinuxAppearance *s = data;
    if (--s->refs == 0) g_free(s);
}

static void apply(struct RuneLinuxAppearance *s, guint index, GVariant *value) {
    if (index == 3 && g_variant_is_of_type(value, G_VARIANT_TYPE("(ddd)"))) {
        g_variant_get(value, "(ddd)", &s->portal.red, &s->portal.green, &s->portal.blue);
        s->portal.hasAccent = s->portal.red >= 0 && s->portal.red <= 1
                            && s->portal.green >= 0 && s->portal.green <= 1
                            && s->portal.blue >= 0 && s->portal.blue <= 1;
    } else if (index < 3 && g_variant_is_of_type(value, G_VARIANT_TYPE_UINT32)) {
        guint32 number = g_variant_get_uint32(value);
        if (index == 0) s->portal.dark = number == 1 ? 1 : number == 2 ? 0 : -1;
        if (index == 1) s->portal.reducedMotion = number == 1;
        if (index == 2) s->portal.increasedContrast = number == 1;
    } else return;
    s->dirty = TRUE;
}

static void portal_changed(GDBusConnection *bus, const gchar *sender, const gchar *path,
                           const gchar *interface, const gchar *signal, GVariant *args, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)interface; (void)signal;
    if (!g_variant_is_of_type(args, G_VARIANT_TYPE("(ssv)"))) return;
    const char *ns, *key;
    GVariant *value;
    g_variant_get(args, "(&s&sv)", &ns, &key, &value);
    if (g_str_equal(ns, APPEARANCE)) {
        RuneLinuxAppearance *s = data;
        for (guint i = 0; i < G_N_ELEMENTS(keys); ++i) {
            if (g_str_equal(keys[i], key)) {
                s->changedSinceRead |= 1u << i;
                apply(s, i, value);
                break;
            }
        }
    }
    g_variant_unref(value);
}

struct InitialRead { RuneLinuxAppearance *state; guint generation; };

static void read_finished(GObject *source, GAsyncResult *res, gpointer data) {
    struct InitialRead *read = data;
    RuneLinuxAppearance *s = read->state;
    GVariant *result = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), res, NULL);
    if (result && !s->closed && s->ownerGeneration == read->generation) {
        GVariant *all = g_variant_get_child_value(result, 0);
        GVariant *values = g_variant_lookup_value(all, APPEARANCE, G_VARIANT_TYPE("a{sv}"));
        if (values) {
            for (guint i = 0; i < G_N_ELEMENTS(keys); ++i) {
                if (s->changedSinceRead & (1u << i)) continue;
                GVariant *value = g_variant_lookup_value(values, keys[i], NULL);
                if (value) { apply(s, i, value); g_variant_unref(value); }
            }
            g_variant_unref(values);
        }
        g_variant_unref(all);
    }
    if (result) g_variant_unref(result);
    release(s);
    g_free(read);
}

static void appeared(GDBusConnection *bus, const gchar *name, const gchar *owner, gpointer data) {
    (void)name;
    RuneLinuxAppearance *s = data;
    if (s->closed) return;
    s->changedSinceRead = 0;
    struct InitialRead *read = g_new(struct InitialRead, 1);
    read->state = s; read->generation = ++s->ownerGeneration; ++s->refs;
    const char *names[] = {APPEARANCE, NULL};
    g_dbus_connection_call(bus, owner, PATH, SETTINGS, "ReadAll", g_variant_new("(^as)", names),
                           G_VARIANT_TYPE("(a{sa{sv}})"), G_DBUS_CALL_FLAGS_NONE, 3000, NULL, read_finished, read);
}

static void vanished(GDBusConnection *bus, const gchar *name, gpointer data) {
    (void)bus; (void)name;
    RuneLinuxAppearance *s = data;
    ++s->ownerGeneration;
    s->portal = no_preferences;
    s->dirty = TRUE;
}

static void local_changed(GSettings *settings, const gchar *key, gpointer data) {
    (void)settings;
    if (g_str_equal(key, "color-scheme") || g_str_equal(key, "enable-animations") || g_str_equal(key, "high-contrast"))
        ((RuneLinuxAppearance *)data)->dirty = TRUE;
}

static GSettings *local_settings(const char *id, RuneLinuxAppearance *s) {
    GSettingsSchemaSource *source = g_settings_schema_source_get_default();
    GSettingsSchema *schema = source ? g_settings_schema_source_lookup(source, id, TRUE) : NULL;
    if (!schema) return NULL;
    GSettings *settings = g_settings_new_full(schema, NULL, NULL);
    g_settings_schema_unref(schema);
    g_signal_connect(settings, "changed", G_CALLBACK(local_changed), s);
    return settings;
}

static gboolean has_key(GSettings *settings, const char *key) {
    if (!settings) return FALSE;
    GSettingsSchema *schema = NULL;
    g_object_get(settings, "settings-schema", &schema, NULL);
    gboolean found = g_settings_schema_has_key(schema, key);
    g_settings_schema_unref(schema);
    return found;
}

RuneLinuxAppearance *rune_linux_appearance_open(void) {
    RuneLinuxAppearance *s = g_new0(RuneLinuxAppearance, 1);
    s->refs = 1; s->dirty = TRUE; s->portal = no_preferences;
    s->desktop = local_settings("org.gnome.desktop.interface", s);
    s->accessibility = local_settings("org.gnome.desktop.a11y.interface", s);
    s->bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    if (s->bus) {
        s->refs += 2;
        s->signal = g_dbus_connection_signal_subscribe(s->bus, PORTAL, SETTINGS, "SettingChanged", PATH, APPEARANCE,
                                                       G_DBUS_SIGNAL_FLAGS_NONE, portal_changed, s, release);
        s->watch = g_bus_watch_name_on_connection(s->bus, PORTAL, G_BUS_NAME_WATCHER_FLAGS_AUTO_START,
                                                  appeared, vanished, s, release);
    }
    return s;
}

bool rune_linux_appearance_take(RuneLinuxAppearance *s, RuneLinuxPreferences *out) {
    if (!s || !s->dirty) return false;
    s->dirty = FALSE;
    *out = s->portal;
    if (out->dark < 0 && has_key(s->desktop, "color-scheme")) {
        gchar *scheme = g_settings_get_string(s->desktop, "color-scheme");
        if (g_str_equal(scheme, "prefer-dark")) out->dark = 1;
        else if (g_str_equal(scheme, "prefer-light")) out->dark = 0;
        g_free(scheme);
    }
    if (out->reducedMotion < 0 && has_key(s->desktop, "enable-animations"))
        out->reducedMotion = !g_settings_get_boolean(s->desktop, "enable-animations");
    if (out->increasedContrast < 0 && has_key(s->accessibility, "high-contrast"))
        out->increasedContrast = g_settings_get_boolean(s->accessibility, "high-contrast");
    return true;
}

void rune_linux_appearance_close(RuneLinuxAppearance *s) {
    if (!s) return;
    s->closed = TRUE;
    ++s->ownerGeneration;
    if (s->watch) g_bus_unwatch_name(s->watch);
    if (s->signal) g_dbus_connection_signal_unsubscribe(s->bus, s->signal);
    g_clear_object(&s->bus);
    g_clear_object(&s->desktop);
    g_clear_object(&s->accessibility);
    release(s);
}
#endif
