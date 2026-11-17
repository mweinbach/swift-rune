#if defined(__linux__) && !defined(__ANDROID__)
#include "linux_drag_internal.h"
#include <SDL.h>
#include <SDL_syswm.h>
#include <gdk/gdkx.h>
#include <gtk/gtk.h>
#include "x11_drag_icon.h"
#include <stdlib.h>
#include <string.h>

/* GTK manages the XDND selection, including incremental transfers, protocol
   negotiation, pointer/keyboard grabs, target acknowledgement and timeout.
   Source widgets are invisible; Rune's SDL windows own all visible content. */
typedef struct {
    RuneLinuxDrag base;
    GtkWidget *widget;
    GdkDisplay *previous_default;
    gulong display_watch;
    GdkDragContext *context;
    Window window;
    Display *display;
    uint32_t window_id;
    const RuneMimeData *offered;
    int within_app, result, failed, owns_button;
} X11Drag;

/* Window registration, GDK callbacks and polling run on the SDL host thread. */
static GSList *windows;

/* After a GDK grab SDL2 can miss motion on re-entry and stamp its next
   mouse buttons with stale coordinates. SDL reports each core XButtonEvent
   just before translating it. Match the original record to the queued
   button; a later global cursor query could observe a different event. */
static struct {
    X11Drag *owner;
    SDL_threadID thread;
    XButtonEvent button;
    Uint32 window_id;
    Uint8 previous_state;
    int pressed;
} recovery;

static int SDLCALL recover_position(void *unused, SDL_Event *event);

static void stop_recovery(void) {
    if (!recovery.owner) return;
    SDL_DelEventWatch(recover_position, NULL);
    if (recovery.previous_state == SDL_DISABLE) SDL_EventState(SDL_SYSWMEVENT, SDL_DISABLE);
    recovery.owner = NULL;
}

static int SDLCALL recover_position(void *unused, SDL_Event *event) {
    (void)unused;
    if (event->type != SDL_SYSWMEVENT && event->type != SDL_MOUSEBUTTONDOWN &&
        event->type != SDL_MOUSEBUTTONUP && event->type != SDL_MOUSEMOTION) return 1;
    if (SDL_ThreadID() != recovery.thread) return 1;
    if (event->type == SDL_SYSWMEVENT) {
        recovery.button.type = 0;
        if (event->syswm.msg->subsystem != SDL_SYSWM_X11) return 1;
        XEvent *native = &event->syswm.msg->msg.x11.event;
        if (native->type != ButtonPress && native->type != ButtonRelease) return 1;
        for (GSList *p = windows; p; p = p->next) {
            X11Drag *window = p->data;
            if (window->window == native->xbutton.window && window->display == native->xbutton.display) {
                recovery.button = native->xbutton;
                recovery.window_id = window->window_id;
                break;
            }
        }
    } else if (event->type == SDL_MOUSEMOTION) {
        if (recovery.pressed && recovery.window_id == event->motion.windowID) stop_recovery();
    } else if (recovery.button.type == (event->type == SDL_MOUSEBUTTONDOWN ? ButtonPress : ButtonRelease) &&
               recovery.window_id == event->button.windowID) {
        unsigned button = recovery.button.button;
        if (button >= 8) button -= 8 - SDL_BUTTON_X1;
        else if (button >= 4) return 1;  /* X11 wheel events are separate in SDL. */
        if (button != event->button.button) return 1;
        int current = event->button.x == recovery.button.x && event->button.y == recovery.button.y;
        event->button.x = recovery.button.x;
        event->button.y = recovery.button.y;
        recovery.button.type = 0;
        if (event->type == SDL_MOUSEBUTTONDOWN) recovery.pressed = 1;
        else if (recovery.pressed && current) stop_recovery();
    }
    return 1;
}

static void start_recovery(X11Drag *drag) {
    stop_recovery();
    recovery.owner = drag;
    recovery.thread = SDL_ThreadID();
    recovery.button.type = 0;
    recovery.pressed = 0;
    recovery.previous_state = SDL_EventState(SDL_SYSWMEVENT, SDL_ENABLE);
    SDL_AddEventWatch(recover_position, NULL);
}

static int own_destination(X11Drag *drag, GdkDragContext *context) {
    if (drag->within_app) return 0;
    GdkWindow *dest = gdk_drag_context_get_dest_window(context);
    if (!dest) return 0;
    Window destination = GDK_WINDOW_XID(dest);
    for (GSList *p = windows; p; p = p->next) {
        X11Drag *window = p->data;
        if (window->display == drag->display && window->window == destination) return 1;
    }
    return 0;
}

static void send_data(GtkWidget *widget, GdkDragContext *context,
                      GtkSelectionData *selection, guint index, guint time, gpointer user) {
    (void)widget; (void)time;
    X11Drag *drag = user;
    if (own_destination(drag, context)) return;
    size_t size = 0;
    const uint8_t *bytes = rune_mime_bytes(drag->offered, index, &size);
    const char *type = rune_mime_type(drag->offered, index);
    if (!bytes || !type || size > G_MAXINT) return;
    if (!strcmp(type, "text/plain;charset=utf-8"))
        gtk_selection_data_set_text(selection, (const gchar *)bytes, (gint)size);
    else
        gtk_selection_data_set(selection, gtk_selection_data_get_target(selection), 8, bytes, (gint)size);
}

static gboolean drag_failed(GtkWidget *widget, GdkDragContext *context, GtkDragResult result, gpointer user) {
    (void)widget; (void)context; (void)result;
    ((X11Drag *)user)->failed = 1;
    return FALSE;
}

static void release_sdl_button(X11Drag *drag) {
    if (!drag->owns_button) return;
    drag->owns_button = 0;
    start_recovery(drag);
    int x, y;
    if (!(SDL_GetMouseState(&x, &y) & SDL_BUTTON_LMASK)) return;
    /* GDK consumes the physical release while its drag grab is active.
       Return it to SDL's local X event queue to clear SDL's pressed state
       and release its normal capture before the next click. */
    XEvent event = {0};
    event.xbutton.type = ButtonRelease;
    event.xbutton.display = drag->display;
    event.xbutton.window = drag->window;
    event.xbutton.root = DefaultRootWindow(drag->display);
    event.xbutton.same_screen = True;
    event.xbutton.button = Button1;
    event.xbutton.state = Button1Mask;
    event.xbutton.x = x;
    event.xbutton.y = y;
    /* GDK may have taken the pointer across a window boundary. SDL ignores
       grab-induced LeaveNotify events and can retain the old window/position;
       restore the missed crossing after releasing SDL's grab. */
    Window root, child;
    int root_x, root_y, client_x, client_y;
    unsigned int mask;
    if (XQueryPointer(drag->display, drag->window, &root, &child,
                      &root_x, &root_y, &client_x, &client_y, &mask)) {
        XWindowAttributes bounds;
        if (XGetWindowAttributes(drag->display, drag->window, &bounds) &&
            (client_x < 0 || client_y < 0 || client_x >= bounds.width || client_y >= bounds.height)) {
            XEvent crossed = {0};
            crossed.xcrossing.type = LeaveNotify;
            crossed.xcrossing.display = drag->display;
            crossed.xcrossing.window = drag->window;
            crossed.xcrossing.root = root;
            crossed.xcrossing.x = client_x;
            crossed.xcrossing.y = client_y;
            crossed.xcrossing.x_root = root_x;
            crossed.xcrossing.y_root = root_y;
            crossed.xcrossing.same_screen = True;
            crossed.xcrossing.mode = NotifyNormal;
            crossed.xcrossing.detail = NotifyNonlinear;
            XPutBackEvent(drag->display, &crossed);
        }
    }
    XPutBackEvent(drag->display, &event);
}

static void drop_performed(GdkDragContext *context, guint time, gpointer user) {
    (void)context; (void)time;
    release_sdl_button(user);
}

/* GTK 3's managed X11 DND looks up drop targets on the process default
   screen. Select the source display for the native drag and put the previous
   display back when the operation finishes. */
static void default_display_changed(GdkDisplayManager *manager, GParamSpec *spec, gpointer user) {
    (void)spec;
    X11Drag *drag = user;
    if (drag->context && gdk_display_manager_get_default_display(manager) != gtk_widget_get_display(drag->widget))
        gtk_drag_cancel(drag->context);
}

static void restore_display(X11Drag *drag) {
    if (!drag->previous_default) return;
    GdkDisplayManager *manager = gdk_display_manager_get();
    if (drag->display_watch) {
        g_signal_handler_disconnect(manager, drag->display_watch);
        drag->display_watch = 0;
    }
    GdkDisplay *previous = drag->previous_default;
    drag->previous_default = NULL;
    if (!gdk_display_is_closed(previous) &&
        gdk_display_manager_get_default_display(manager) == gtk_widget_get_display(drag->widget))
        gdk_display_manager_set_default_display(manager, previous);
    g_object_unref(previous);
}

static void drag_ended(GtkWidget *widget, GdkDragContext *context, gpointer user) {
    (void)widget;
    X11Drag *drag = user;
    release_sdl_button(drag);
    g_signal_handlers_disconnect_by_func(context, G_CALLBACK(drop_performed), drag);
    drag->result = 0;
    if (!drag->failed && !own_destination(drag, context) && gdk_drag_drop_succeeded(context)) {
        switch (gdk_drag_context_get_selected_action(context)) {
        case GDK_ACTION_COPY: drag->result = 1; break;
        case GDK_ACTION_MOVE: drag->result = 2; break;
        case GDK_ACTION_LINK: drag->result = 4; break;
        default: break;
        }
    }
    drag->offered = NULL;
    drag->context = NULL;
    restore_display(drag);
}

static int ensure_widget(X11Drag *drag) {
    if (drag->widget) return 1;
    /* Register GtkWidget signals before GTK installs its accessibility hooks. */
    gpointer widget_class = g_type_class_ref(GTK_TYPE_WIDGET);
    gboolean ready = gtk_init_check(NULL, NULL);
    g_type_class_unref(widget_class);
    if (!ready) return 0;
    /* An SDL XWayland client can share a process with GTK Wayland windows.
       Bind the drag widget to the X server that owns the source window. */
    const char *name = DisplayString(drag->display);
    GSList *displays = gdk_display_manager_list_displays(gdk_display_manager_get());
    GdkDisplay *display = NULL;
    for (GSList *entry = displays; entry; entry = entry->next) {
        GdkDisplay *candidate = entry->data;
        if (GDK_IS_X11_DISPLAY(candidate) && !strcmp(name, DisplayString(GDK_DISPLAY_XDISPLAY(candidate)))) {
            display = candidate;
            break;
        }
    }
    g_slist_free(displays);
    if (!display) display = gdk_display_open(name);
    if (!display || !GDK_IS_X11_DISPLAY(display)) return 0;
    drag->widget = gtk_invisible_new_for_screen(gdk_display_get_default_screen(display));
    gtk_widget_show(drag->widget);
    g_signal_connect(drag->widget, "drag-data-get", G_CALLBACK(send_data), drag);
    g_signal_connect(drag->widget, "drag-failed", G_CALLBACK(drag_failed), drag);
    g_signal_connect(drag->widget, "drag-end", G_CALLBACK(drag_ended), drag);
    return 1;
}

static int begin(RuneLinuxDrag *backend, const RuneMimeData *items, unsigned ops, int within_app) {
    X11Drag *drag = (X11Drag *)backend;
    if (drag->context || !rune_mime_count(items)) return 0;
    if (!(SDL_GetGlobalMouseState(NULL, NULL) & SDL_BUTTON_LMASK)) return 0;
    GdkDragAction actions = 0;
    if (ops & (1u | 8u)) actions |= GDK_ACTION_COPY;
    if (ops & 2u) actions |= GDK_ACTION_MOVE;
    if (ops & 4u) actions |= GDK_ACTION_LINK;
    if (!actions || !ensure_widget(drag)) return 0;
    GtkTargetList *targets = gtk_target_list_new(NULL, 0);
    for (guint i = 0; i < rune_mime_count(items); ++i) {
        const char *type = rune_mime_type(items, i);
        if (!strcmp(type, "text/plain;charset=utf-8"))
            gtk_target_list_add_text_targets(targets, i);
        else
            gtk_target_list_add(targets, gdk_atom_intern(type, FALSE), 0, i);
    }

    /* A held button implicitly grabs the pointer on SDL's X connection. GDK
       owns a separate connection and must acquire that grab for the drag. */
    SDL_CaptureMouse(SDL_FALSE);
    XUngrabPointer(drag->display, CurrentTime);
    XSync(drag->display, False);
    drag->offered = items;
    drag->failed = 0;
    drag->result = -1;
    drag->within_app = within_app;
    GdkDisplay *source_display = gtk_widget_get_display(drag->widget);
    GdkDisplayManager *manager = gdk_display_manager_get();
    GdkDisplay *previous = gdk_display_manager_get_default_display(manager);
    if (previous != source_display) {
        drag->previous_default = g_object_ref(previous);
        gdk_display_manager_set_default_display(manager, source_display);
        drag->display_watch = g_signal_connect(manager, "notify::default-display",
                                                G_CALLBACK(default_display_changed), drag);
    }
    drag->context = gtk_drag_begin_with_coordinates(drag->widget, targets, actions, 1, NULL, -1, -1);
    gtk_target_list_unref(targets);
    if (drag->context && backend->preview) rune_x11_drag_icon(drag->context, backend->preview);
    if (!drag->context) {
        restore_display(drag);
        drag->offered = NULL;
    } else {
        drag->owns_button = 1;
        g_signal_connect(drag->context, "drop-performed", G_CALLBACK(drop_performed), drag);
    }
    return drag->context != NULL;
}

static int poll(RuneLinuxDrag *backend) {
    X11Drag *drag = (X11Drag *)backend;
    for (int i = 0; i < 32 && drag->context && g_main_context_iteration(NULL, FALSE); ++i) {}
    return drag->result;
}

static void destroy(RuneLinuxDrag *backend) {
    X11Drag *drag = (X11Drag *)backend;
    if (drag->context) gtk_drag_cancel(drag->context);
    if (recovery.owner == drag) stop_recovery();
    restore_display(drag);
    windows = g_slist_remove(windows, drag);
    if (drag->widget) {
        g_signal_handlers_disconnect_by_data(drag->widget, drag);
        gtk_widget_destroy(drag->widget);
    }
    free(drag);
}

RuneLinuxDrag *rune_x11_drag_open(uint32_t window_id) {
    SDL_Window *window = SDL_GetWindowFromID(window_id);
    SDL_SysWMinfo info;
    SDL_VERSION(&info.version);
    if (!window || !SDL_GetWindowWMInfo(window, &info) || info.subsystem != SDL_SYSWM_X11) return NULL;
    X11Drag *drag = calloc(1, sizeof *drag);
    if (!drag) return NULL;
    drag->base.begin = begin;
    drag->base.poll = poll;
    drag->base.destroy = destroy;
    drag->display = info.info.x11.display;
    drag->window = info.info.x11.window;
    drag->window_id = window_id;
    windows = g_slist_prepend(windows, drag);
    return &drag->base;
}
#endif
