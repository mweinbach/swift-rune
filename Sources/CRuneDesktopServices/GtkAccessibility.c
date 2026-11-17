#if defined(__linux__) && !defined(__ANDROID__)
#include "GtkAccessibility.h"
#include "CRuneLinuxA11y.h"
#include <gtk/gtk.h>

/* GtkFileChooserNative uses either an external portal or a local GtkWindow.
   GTK yields the process ATK root to Rune, so its local windows need to join that root. */
static void publish(GtkWidget *widget, gboolean visible) {
    if (GTK_IS_WINDOW(widget) && gtk_window_get_window_type(GTK_WINDOW(widget)) == GTK_WINDOW_TOPLEVEL)
        rune_ax_toolkit_window(gtk_widget_get_accessible(widget), visible);
}

static gboolean window_visibility(GSignalInvocationHint *hint, guint argc, const GValue *args, gpointer visible) {
    (void)hint;
    if (argc) publish(g_value_get_object(args), GPOINTER_TO_INT(visible));
    return TRUE;
}

void rune_ax_watch_gtk_toplevels(void) {
    static gboolean installed;
    if (installed || g_strcmp0(atk_get_toolkit_name(), "Rune") != 0) return;
    installed = TRUE;
    g_signal_add_emission_hook(g_signal_lookup("map", GTK_TYPE_WIDGET), 0, window_visibility, GINT_TO_POINTER(TRUE), NULL);
    g_signal_add_emission_hook(g_signal_lookup("unmap", GTK_TYPE_WIDGET), 0, window_visibility, GINT_TO_POINTER(FALSE), NULL);
    GList *windows = gtk_window_list_toplevels();
    for (GList *item = windows; item; item = item->next) {
        GtkWidget *widget = GTK_WIDGET(item->data);
        if (gtk_widget_get_mapped(widget)) publish(widget, TRUE);
    }
    g_list_free(windows);
}
#endif
