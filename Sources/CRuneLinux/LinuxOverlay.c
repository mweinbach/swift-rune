#if defined(__linux__) && !defined(__ANDROID__)
#include "CRuneLinux.h"
#include "../CSDL2/shim.h"
#include <gtk/gtk.h>
#include <gdk/gdkx.h>
#include <gdk/gdkwayland.h>
#include <wayland-client.h>
#include <EGL/egl.h>
#include <RuneLinuxGPUSelection.h>
#include <X11/extensions/XInput2.h>
#include <X11/extensions/shape.h>
#include <glib-unix.h>
#include <dlfcn.h>
#include <math.h>
#include <string.h>

/* gtk-layer-shell manages the custom wl_surface role and configure handshake
 * before GDK attaches a GL buffer. X11 installations do not require the library. */
struct LayerShell {
    void *library;
    gboolean (*supported)(void);
    void (*init)(GtkWindow *);
    void (*set_namespace)(GtkWindow *, const char *);
    void (*set_layer)(GtkWindow *, int);
    void (*set_zone)(GtkWindow *, int);
    void (*set_anchor)(GtkWindow *, int, gboolean);
    void (*set_margin)(GtkWindow *, int, int);
    void (*set_monitor)(GtkWindow *, GdkMonitor *);
    void (*set_keyboard)(GtkWindow *, int);
    guint (*version)(void);
};
static struct LayerShell layer;
static gboolean load_layer(void) {
    if (layer.library) return layer.supported && layer.supported();
    layer.library = dlopen("libgtk-layer-shell.so.0", RTLD_LOCAL | RTLD_NOW);
    if (!layer.library) return FALSE;
#define LOAD(field, symbol) layer.field = dlsym(layer.library, "gtk_layer_" symbol)
    LOAD(init, "init_for_window"); LOAD(set_namespace, "set_namespace"); LOAD(set_layer, "set_layer");
    LOAD(set_zone, "set_exclusive_zone"); LOAD(set_anchor, "set_anchor"); LOAD(set_margin, "set_margin");
    LOAD(set_monitor, "set_monitor"); LOAD(set_keyboard, "set_keyboard_mode");
    LOAD(version, "get_protocol_version");
    if (layer.init && layer.set_namespace && layer.set_layer && layer.set_zone && layer.set_anchor &&
        layer.set_margin && layer.set_monitor && layer.set_keyboard)
        LOAD(supported, "is_supported");
#undef LOAD
    return layer.supported && layer.supported();
}

struct RuneLinuxOverlay {
    int checked_display_gpu;
    GtkWidget *window, *area;
    GdkDisplay *display;
    GdkMonitor *monitor;
    gulong geometry_signal, monitors_signal, removed_signal;
    RuneOverlayBackend backend;
    RuneOverlayDispatch dispatch;
    void *context;
    guint timer, gpu_timer, fade, watch;
    Display *motion_display;
    gint64 fade_start;
    double fade_length, opacity_from, opacity_to;
    gboolean follow, mapped, all, closing, observe_regions, pointer_inside, drawing, left_on_release;
    GdkEventSequence *touch;
    int level;
    cairo_region_t *input;
};
/* GDK and SDL keep independent TLS caches. Clear both before returning from
 * the GTK context to a regular SDL window on the same event-loop thread. */
static void clear_gl_context(void) {
    if (!gdk_gl_context_get_current()) return;
    gdk_gl_context_clear_current();
    SDL_GL_MakeCurrent(NULL, NULL);
}
static guint host_count;
static GList *shown_x11;
/* Preserve recency among peers while keeping higher Rune overlay levels above them. */
static void restack(RuneLinuxOverlay *s) {
    if (s->backend == RuneOverlayLayer || !s->mapped) return;
    shown_x11 = g_list_remove(shown_x11, s);
    shown_x11 = g_list_append(shown_x11, s);
    for (int level = 25; level <= 27; level++) {
        for (GList *link = shown_x11; link; link = link->next) {
            RuneLinuxOverlay *other = link->data;
            if (other->display == s->display && other->level == level)
                gdk_window_raise(gtk_widget_get_window(other->window));
        }
    }
}
void rune_overlay_level(RuneLinuxOverlay *s, int level) {
    if (s->level == level) return;
    s->level = level;
    restack(s);
}
static char error_message[384];
static const char *fail(const char *message) {
    g_strlcpy(error_message, message, sizeof error_message);
    return error_message;
}
const char *rune_overlay_error(void) { return error_message; }
static int send_event(RuneLinuxOverlay *s, RuneOverlayEvent event) {
    return !s->closing && s->dispatch ? s->dispatch(s->context, &event) : 0;
}
static gboolean draw(GtkGLArea *area, GdkGLContext *context, gpointer data) {
    (void)context;
    GtkWidget *widget = GTK_WIDGET(area);
    RuneLinuxOverlay *s = data;
    s->drawing = TRUE;
    send_event(s, (RuneOverlayEvent){.kind = RuneOverlayDraw, .width = gtk_widget_get_allocated_width(widget),
               .height = gtk_widget_get_allocated_height(widget), .scale = gtk_widget_get_scale_factor(widget)});
    s->drawing = FALSE;
    return TRUE;
}
static void unrealize(GtkGLArea *area, gpointer data) {
    ((RuneLinuxOverlay *)data)->checked_display_gpu = 0;
    gtk_gl_area_make_current(area);
    send_event(data, (RuneOverlayEvent){.kind = RuneOverlayGLGone, .active = !gtk_gl_area_get_error(area)});
}
static guint mods(guint state) {
    return ((state & GDK_SHIFT_MASK) ? RuneLinuxShift : 0) | ((state & GDK_CONTROL_MASK) ? RuneLinuxControl : 0) |
           ((state & GDK_MOD1_MASK) ? RuneLinuxAlt : 0) | ((state & GDK_SUPER_MASK) ? RuneLinuxSuper : 0);
}
static gboolean input_event(GtkWidget *widget, GdkEvent *e, gpointer data) {
    RuneLinuxOverlay *s = data;
    RuneOverlayEvent ev = {0};
    GdkModifierType state = 0;
    gdk_event_get_state(e, &state);
    ev.modifiers = mods(state);
    gdk_event_get_coords(e, &ev.x, &ev.y);
    switch (e->type) {
        case GDK_ENTER_NOTIFY: s->left_on_release = FALSE; ev.kind = RuneOverlayMotion; break;
        case GDK_MOTION_NOTIFY: ev.kind = RuneOverlayMotion; break;
        case GDK_LEAVE_NOTIFY:
            if (state & (GDK_BUTTON1_MASK | GDK_BUTTON2_MASK | GDK_BUTTON3_MASK)) return TRUE;
            if (e->crossing.mode != GDK_CROSSING_NORMAL && ev.x >= 0 && ev.y >= 0 &&
                ev.x < gtk_widget_get_allocated_width(widget) && ev.y < gtk_widget_get_allocated_height(widget)) return TRUE;
            if (s->left_on_release) { s->left_on_release = FALSE; return TRUE; }
            ev.kind = RuneOverlayLeave;
            break;
        case GDK_BUTTON_PRESS: case GDK_BUTTON_RELEASE: {
            /* GDK has converted native device pixels to surface points, including
             * for a 2x XWayland display. Position must arrive before the click. */
            if (e->button.button >= 4 && e->button.button <= 7) return FALSE;
            ev.kind = RuneOverlayMotion;
            send_event(s, ev);
            ev.kind = RuneOverlayButton; ev.active = e->type == GDK_BUTTON_PRESS; ev.code = e->button.button;
            int handled = send_event(s, ev);
            if (!ev.active && (ev.x < 0 || ev.y < 0 || ev.x >= gtk_widget_get_allocated_width(widget) ||
                              ev.y >= gtk_widget_get_allocated_height(widget))) {
                s->left_on_release = TRUE;
                send_event(s, (RuneOverlayEvent){.kind = RuneOverlayLeave});
            }
            return handled;
        }
        case GDK_TOUCH_BEGIN:
            if (s->touch) return TRUE;
            s->touch = e->touch.sequence;
            ev.kind = RuneOverlayMotion; send_event(s, ev);
            ev.kind = RuneOverlayButton; ev.code = 1; ev.active = 1;
            break;
        case GDK_TOUCH_UPDATE:
            if (s->touch != e->touch.sequence) return TRUE;
            ev.kind = RuneOverlayMotion;
            break;
        case GDK_TOUCH_END: case GDK_TOUCH_CANCEL:
            if (s->touch != e->touch.sequence) return TRUE;
            s->touch = NULL;
            ev.kind = e->type == GDK_TOUCH_END ? RuneOverlayButton : RuneOverlayLost;
            ev.code = 1;
            send_event(s, ev);
            send_event(s, (RuneOverlayEvent){.kind = RuneOverlayLeave});
            return TRUE;
        case GDK_SCROLL:
            ev.kind = RuneOverlayWheel;
            ev.active = gdk_event_get_scroll_deltas(e, &ev.dx, &ev.dy);
            if (!ev.active) {
                switch (e->scroll.direction) {
                    case GDK_SCROLL_UP: ev.dy = -1; break; case GDK_SCROLL_DOWN: ev.dy = 1; break;
                    case GDK_SCROLL_LEFT: ev.dx = -1; break; case GDK_SCROLL_RIGHT: ev.dx = 1; break;
                    default: break;
                }
            }
            break;
        case GDK_KEY_PRESS: case GDK_KEY_RELEASE:
            ev.kind = RuneOverlayKey; ev.active = e->type == GDK_KEY_PRESS;
            ev.code = e->key.keyval; ev.unicode = gdk_keyval_to_unicode(e->key.keyval);
            /* GDK reports the pre-transition state on the modifier's own event. */
            if (e->key.is_modifier) {
                guint bit = 0;
                switch (e->key.keyval) {
                    case GDK_KEY_Shift_L: case GDK_KEY_Shift_R: bit = RuneLinuxShift; break;
                    case GDK_KEY_Control_L: case GDK_KEY_Control_R: bit = RuneLinuxControl; break;
                    case GDK_KEY_Alt_L: case GDK_KEY_Alt_R: bit = RuneLinuxAlt; break;
                    case GDK_KEY_Super_L: case GDK_KEY_Super_R: bit = RuneLinuxSuper; break;
                }
                if (ev.active) ev.modifiers |= bit; else ev.modifiers &= ~bit;
            }
            break;
        case GDK_CONFIGURE: send_event(s, (RuneOverlayEvent){.kind = RuneOverlayGeometry}); return FALSE;
        case GDK_FOCUS_CHANGE: ev.kind = RuneOverlayFocus; ev.active = e->focus_change.in; break;
        case GDK_GRAB_BROKEN: if (e->grab_broken.keyboard) return FALSE; ev.kind = RuneOverlayLost; break;
        case GDK_DELETE: ev.kind = RuneOverlayClosed; break;
        default: return FALSE;
    }
    int handled = send_event(data, ev);
    return e->type == GDK_TOUCH_BEGIN || e->type == GDK_TOUCH_UPDATE || handled;
}
static void monitor_changed(GdkMonitor *monitor, GParamSpec *spec, gpointer data) {
    (void)monitor; (void)spec;
    send_event(data, (RuneOverlayEvent){.kind = RuneOverlayMonitor});
}
static void monitors_changed(GdkDisplay *display, GdkMonitor *monitor, gpointer data) {
    (void)display; (void)monitor;
    send_event(data, (RuneOverlayEvent){.kind = RuneOverlayMonitor});
}
static GdkMonitor *pointer_monitor(RuneLinuxOverlay *s) {
    GdkSeat *seat = gdk_display_get_default_seat(s->display);
    GdkDevice *mouse = seat ? gdk_seat_get_pointer(seat) : NULL;
    if (!mouse) return NULL;
    int x, y;
    gdk_device_get_position(mouse, NULL, &x, &y);
    return gdk_display_get_monitor_at_point(s->display, x, y);
}
void rune_overlay_monitor(RuneLinuxOverlay *s, int index, int under_pointer, const char *name, RuneOverlayRect *out) {
    GdkMonitor *m = NULL;
    int count = gdk_display_get_n_monitors(s->display);
    if (index >= 0 && index < count) m = gdk_display_get_monitor(s->display, index);
    if (name && *name) for (int i = 0; i < count; i++) {
        GdkMonitor *test = gdk_display_get_monitor(s->display, i);
        const char *sdl_name = i < SDL_GetNumVideoDisplays() ? SDL_GetDisplayName(i) : NULL;
        if (g_strcmp0(name, gdk_monitor_get_model(test)) == 0 || g_strcmp0(name, sdl_name) == 0) { m = test; break; }
    }
    if (under_pointer && s->backend == RuneOverlayX11) m = pointer_monitor(s);
    if (!m) m = gdk_display_get_primary_monitor(s->display);
    if (!m && count) m = gdk_display_get_monitor(s->display, 0);
    if (m != s->monitor) {
        if (s->monitor) { g_signal_handler_disconnect(s->monitor, s->geometry_signal); g_object_unref(s->monitor); }
        s->monitor = m ? g_object_ref(m) : NULL;
        if (m) s->geometry_signal = g_signal_connect(m, "notify::geometry", G_CALLBACK(monitor_changed), s);
        if (s->backend == RuneOverlayLayer) layer.set_monitor(GTK_WINDOW(s->window), m);
    }
    GdkRectangle r = {0, 0, 1, 1};
    if (m) gdk_monitor_get_geometry(m, &r);
    *out = (RuneOverlayRect){r.x, r.y, r.width, r.height};
}
/* A private X connection avoids consuming GTK/SDL events. Raw motion only
 * wakes following multi-output overlays. No rendering is scheduled within an output. */
static gboolean pointer_changed(gint fd, GIOCondition condition, gpointer data) {
    (void)fd;
    RuneLinuxOverlay *s = data;
    if (condition & (G_IO_ERR | G_IO_HUP)) { s->watch = 0; return G_SOURCE_REMOVE; }
    while (XPending(s->motion_display)) {
        XEvent e;
        XNextEvent(s->motion_display, &e);
        if (e.type == GenericEvent && XGetEventData(s->motion_display, &e.xcookie))
            XFreeEventData(s->motion_display, &e.xcookie);
    }
    if (s->follow && pointer_monitor(s) != s->monitor)
        send_event(s, (RuneOverlayEvent){.kind = RuneOverlayMonitor});
    if (s->observe_regions) {
        GdkWindow *window = gtk_widget_get_window(s->window);
        GdkSeat *seat = gdk_display_get_default_seat(s->display);
        GdkDevice *pointer = seat ? gdk_seat_get_pointer(seat) : NULL;
        if (window && pointer) {
            int x, y, ox, oy;
            GdkModifierType state = 0;
            gdk_device_get_position(pointer, NULL, &x, &y);
            gdk_window_get_origin(window, &ox, &oy);
            x -= ox; y -= oy;
            gboolean inside = x >= 0 && x < gdk_window_get_width(window) && y >= 0 && y < gdk_window_get_height(window);
            if (inside || s->pointer_inside) {
                gdk_device_get_state(pointer, window, NULL, &state);
                send_event(s, (RuneOverlayEvent){.kind = RuneOverlayMotion, .x = x, .y = y, .modifiers = mods(state)});
            }
            s->pointer_inside = inside;
        }
    }
    return G_SOURCE_CONTINUE;
}
static void watch_pointer(RuneLinuxOverlay *s) {
    gboolean needed = s->mapped && s->backend == RuneOverlayX11 &&
                      (s->observe_regions || (s->follow && gdk_display_get_n_monitors(s->display) > 1));
    if (!needed) {
        if (s->watch) { g_source_remove(s->watch); s->watch = 0; }
        if (s->motion_display) { XCloseDisplay(s->motion_display); s->motion_display = NULL; }
        return;
    }
    if (s->motion_display) return;
    Display *d = XOpenDisplay(gdk_display_get_name(s->display));
    if (!d) return;
    int opcode, first, error, major = 2, minor = 0;
    unsigned char mask[XIMaskLen(XI_RawMotion)] = {0};
    XISetMask(mask, XI_RawMotion);
    XIEventMask request = { XIAllMasterDevices, sizeof mask, mask };
    if (!XQueryExtension(d, "XInputExtension", &opcode, &first, &error) || XIQueryVersion(d, &major, &minor) != Success ||
        XISelectEvents(d, DefaultRootWindow(d), &request, 1) != Success) { XCloseDisplay(d); return; }
    XFlush(d);
    s->motion_display = d;
    s->watch = g_unix_fd_add(ConnectionNumber(d), G_IO_IN | G_IO_ERR | G_IO_HUP, pointer_changed, s);
}
void rune_overlay_observe_regions(RuneLinuxOverlay *s, int enabled) {
    s->observe_regions = enabled;
    watch_pointer(s);
}
static GdkDisplay *owned_xdisplay;
static guint fallback_users;
static GdkDisplay *fallback_xdisplay(void) {
    const char *name = g_getenv("DISPLAY");
    if (!name || !*name) return NULL;
    GSList *displays = gdk_display_manager_list_displays(gdk_display_manager_get());
    GdkDisplay *result = NULL;
    for (GSList *p = displays; p; p = p->next) {
        if (GDK_IS_X11_DISPLAY(p->data) && g_strcmp0(gdk_display_get_name(p->data), name) == 0) { result = p->data; break; }
    }
    g_slist_free(displays);
    if (result) return result;
    owned_xdisplay = gdk_display_open(name);
    return owned_xdisplay;
}
RuneLinuxOverlay *rune_overlay_new(const char *name, int allow_xwayland, void *context, RuneOverlayDispatch dispatch) {
    const char *driver = SDL_GetCurrentVideoDriver();
    gboolean wayland = driver && strcmp(driver, "wayland") == 0;
    if (!gdk_display_get_default()) gdk_set_allowed_backends(wayland ? "wayland,x11" : "x11,wayland");
    if (!gtk_init_check(NULL, NULL)) { fail("GTK could not connect to the Linux desktop"); return NULL; }
    GdkDisplay *display = gdk_display_get_default();
    RuneOverlayBackend backend = RuneOverlayX11;
    if (wayland && GDK_IS_WAYLAND_DISPLAY(display) && load_layer()) backend = RuneOverlayLayer;
    else if (wayland) {
        if (!allow_xwayland || !(display = fallback_xdisplay()) || !GDK_IS_X11_DISPLAY(display)) {
            fail("Wayland overlay requires zwlr_layer_shell_v1 and gtk-layer-shell or an eligible XWayland fallback"); return NULL;
        }
        backend = RuneOverlayXWayland;
    } else if (!GDK_IS_X11_DISPLAY(display)) { fail("GTK and SDL must connect to the same X11 desktop"); return NULL; }
    GdkScreen *screen = gdk_display_get_default_screen(display);
    GdkVisual *rgba = gdk_screen_get_rgba_visual(screen);
    if (!rgba) { fail("The Linux overlay display has no alpha-capable visual"); return NULL; }
    if (backend != RuneOverlayLayer) {
        int event, error, major, minor;
        Display *x = GDK_DISPLAY_XDISPLAY(display);
        if (!XShapeQueryExtension(x, &event, &error) || !XShapeQueryVersion(x, &major, &minor) ||
            (major == 1 && minor < 1)) { fail("X11 overlay input requires X Shape 1.1"); return NULL; }
    }
    RuneLinuxOverlay *s = g_new0(RuneLinuxOverlay, 1);
    s->context = context; s->dispatch = dispatch; s->display = display; s->backend = backend;
    s->level = 25;
    if (backend == RuneOverlayXWayland && s->display == owned_xdisplay) ++fallback_users;
    s->window = gtk_window_new(backend == RuneOverlayLayer ? GTK_WINDOW_TOPLEVEL : GTK_WINDOW_POPUP);
    GtkWindow *window = GTK_WINDOW(s->window);
    gtk_window_set_screen(window, screen);
    gtk_widget_set_visual(s->window, rgba);
    gtk_window_set_title(window, name);
    gtk_window_set_decorated(window, FALSE);
    gtk_window_set_resizable(window, FALSE);
    gtk_window_set_accept_focus(window, FALSE);
    gtk_window_set_focus_on_map(window, FALSE);
    gtk_window_set_skip_taskbar_hint(window, TRUE);
    gtk_window_set_skip_pager_hint(window, TRUE);
    gtk_widget_set_app_paintable(s->window, TRUE);
    if (backend == RuneOverlayLayer) {
        layer.init(window); layer.set_namespace(window, name); layer.set_layer(window, 3);
        layer.set_zone(window, 0); layer.set_keyboard(window, 0);
    } else { gtk_window_set_keep_above(window, TRUE); gtk_window_set_type_hint(window, GDK_WINDOW_TYPE_HINT_NOTIFICATION); }
    s->area = gtk_gl_area_new();
    gtk_gl_area_set_required_version(GTK_GL_AREA(s->area), 3, 3);
    gtk_gl_area_set_has_alpha(GTK_GL_AREA(s->area), TRUE);
    gtk_gl_area_set_auto_render(GTK_GL_AREA(s->area), FALSE);
    gtk_container_add(GTK_CONTAINER(window), s->area);
    gtk_widget_set_can_focus(s->area, TRUE);
    GtkCssProvider *css = gtk_css_provider_new();
    gtk_css_provider_load_from_data(css, "* { background-color: transparent; background-image: none; box-shadow: none; border: none; }", -1, NULL);
    gtk_style_context_add_provider(gtk_widget_get_style_context(s->window), GTK_STYLE_PROVIDER(css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    gtk_style_context_add_provider(gtk_widget_get_style_context(s->area), GTK_STYLE_PROVIDER(css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(css);
    gtk_widget_add_events(s->window, GDK_POINTER_MOTION_MASK | GDK_ENTER_NOTIFY_MASK | GDK_LEAVE_NOTIFY_MASK |
        GDK_BUTTON_PRESS_MASK | GDK_BUTTON_RELEASE_MASK | GDK_SCROLL_MASK | GDK_SMOOTH_SCROLL_MASK |
        GDK_KEY_PRESS_MASK | GDK_KEY_RELEASE_MASK | GDK_FOCUS_CHANGE_MASK | GDK_TOUCH_MASK);
    g_signal_connect(s->window, "event", G_CALLBACK(input_event), s);
    g_signal_connect(s->area, "render", G_CALLBACK(draw), s);
    g_signal_connect(s->area, "unrealize", G_CALLBACK(unrealize), s);
    s->monitors_signal = g_signal_connect(display, "monitor-added", G_CALLBACK(monitors_changed), s);
    s->removed_signal = g_signal_connect(display, "monitor-removed", G_CALLBACK(monitors_changed), s);
    gtk_widget_show(s->area);
    gtk_widget_realize(s->window);
    if (host_count++ == 0) rune_linux_register_gl_reset(clear_gl_context);
    rune_overlay_input(s, FALSE, NULL, 0);
    return s;
}
RuneOverlayBackend rune_overlay_backend(RuneLinuxOverlay *s) { return s->backend; }
uint32_t rune_overlay_xid(RuneLinuxOverlay *s) {
    GdkWindow *w = gtk_widget_get_window(s->window);
    return GDK_IS_X11_WINDOW(w) ? (uint32_t)gdk_x11_window_get_xid(w) : 0;
}
int rune_overlay_has_keys(RuneLinuxOverlay *s) { return s->backend == RuneOverlayX11 ||
    (s->backend == RuneOverlayLayer && layer.version && layer.version() >= 4); }
void rune_overlay_park(RuneLinuxOverlay *s) {
    if (gtk_widget_get_realized(s->area)) gtk_widget_unrealize(s->area);
    clear_gl_context();
}
int rune_overlay_origin(RuneLinuxOverlay *s, int32_t *x, int32_t *y, int32_t *primary_x, int32_t *primary_y) {
    if (s->backend != RuneOverlayX11) return 0;
    GdkWindow *w = gtk_widget_get_window(s->window);
    if (!w) return 0;
    Display *display = GDK_DISPLAY_XDISPLAY(s->display);
    Window child;
    int dx, dy;
    Window root = gdk_x11_window_get_xid(gdk_screen_get_root_window(gdk_window_get_screen(w)));
    if (!XTranslateCoordinates(display, gdk_x11_window_get_xid(w), root, 0, 0, &dx, &dy, &child)) return 0;
    SDL_Rect primary = {0};
    SDL_GetDisplayBounds(0, &primary);
    *x = dx; *y = dy; *primary_x = primary.x; *primary_y = primary.y;
    return 1;
}
int rune_overlay_scale(RuneLinuxOverlay *s) {
    return s->monitor ? gdk_monitor_get_scale_factor(s->monitor) : gtk_widget_get_scale_factor(s->area);
}
int rune_overlay_wayland_session(void) {
    const char *driver = SDL_GetCurrentVideoDriver();
    return driver && strcmp(driver, "wayland") == 0;
}
int rune_overlay_make_current(RuneLinuxOverlay *s) {
    if (!gtk_widget_get_realized(s->area)) gtk_widget_realize(s->area);
    gtk_gl_area_make_current(GTK_GL_AREA(s->area));
    GError *error = gtk_gl_area_get_error(GTK_GL_AREA(s->area));
    if (error) { fail(error->message); return 0; }
    if (!gdk_gl_context_get_current()) return 0;
    if (!s->checked_display_gpu && GDK_IS_WAYLAND_DISPLAY(s->display)) {
        if (!rune_gpu_wayland_can_show(eglGetCurrentDisplay())) {
            fail("The current EGL device cannot present this overlay on the Wayland compositor's GPU");
            return 0;
        }
        s->checked_display_gpu = 1;
    }
    return 1;
}
int rune_overlay_uses_gles(RuneLinuxOverlay *s) {
    GdkGLContext *context = gtk_gl_area_get_context(GTK_GL_AREA(s->area));
    return context && gdk_gl_context_get_use_es(context);
}
void *rune_overlay_gl_proc(const char *name) { return (void *)eglGetProcAddress(name); }
void rune_overlay_place(RuneLinuxOverlay *s, RuneOverlayRect r, int full, int follow) {
    s->follow = follow;
    watch_pointer(s);
    if (s->backend == RuneOverlayLayer) {
        GtkWindow *w = GTK_WINDOW(s->window);
        /* GTK_LAYER_SHELL_EDGE_{LEFT,RIGHT,TOP,BOTTOM} are 0,1,2,3. */
        for (int i = 0; i < 4; ++i) {
            layer.set_anchor(w, i, full || i == 0 || i == 2);
            layer.set_margin(w, i, !full && i == 0 ? r.x : !full && i == 2 ? r.y : 0);
        }
    } else {
        GdkRectangle m = {0};
        if (s->monitor) gdk_monitor_get_geometry(s->monitor, &m);
        gtk_window_move(GTK_WINDOW(s->window), (int)CLAMP((gint64)m.x + r.x, G_MININT, G_MAXINT),
                        (int)CLAMP((gint64)m.y + r.y, G_MININT, G_MAXINT));
    }
    gtk_widget_set_size_request(s->area, s->backend == RuneOverlayLayer && full ? 1 : r.width,
       s->backend == RuneOverlayLayer && full ? 1 : r.height);
    gtk_window_resize(GTK_WINDOW(s->window), r.width, r.height);
}
void rune_overlay_input(RuneLinuxOverlay *s, int all, const RuneOverlayRect *rects, int count) {
    cairo_region_t *region = all ? NULL : cairo_region_create();
    for (int i = 0; region && i < count; i++) {
        cairo_rectangle_int_t r = {rects[i].x, rects[i].y, rects[i].width, rects[i].height};
        cairo_region_union_rectangle(region, &r);
    }
    if ((all && s->all) || (region && s->input && cairo_region_equal(region, s->input))) {
        if (region) cairo_region_destroy(region);
        return;
    }
    if (s->input) cairo_region_destroy(s->input);
    s->input = region; s->all = all;
    gtk_widget_input_shape_combine_region(s->window, region);
    if (s->backend == RuneOverlayLayer && s->mapped && !s->drawing) {
        /* GDK defers its cached input shape until the next paint. Commit an
         * input-only change promptly on an idle surface. A frame in progress
         * carries its matching hit regions with its own buffer commit. */
        GdkWindow *w = gtk_widget_get_window(s->window);
        struct wl_surface *surface = gdk_wayland_window_get_wl_surface(w);
        if (surface) {
            struct wl_region *input = NULL;
            if (!all) {
                struct wl_compositor *compositor = gdk_wayland_display_get_wl_compositor(s->display);
                input = wl_compositor_create_region(compositor);
                if (!input) return;
                for (int i = 0; i < count; ++i) wl_region_add(input, rects[i].x, rects[i].y, rects[i].width, rects[i].height);
            }
            wl_surface_set_input_region(surface, input);
            if (input) wl_region_destroy(input);
            wl_surface_commit(surface);
        }
    }
    if (s->mapped && !s->drawing) gdk_display_flush(s->display);
}
void rune_overlay_focus(RuneLinuxOverlay *s) {
    if (!s->mapped || !rune_overlay_has_keys(s)) return;
    gtk_window_set_accept_focus(GTK_WINDOW(s->window), TRUE);
    if (s->backend == RuneOverlayLayer) layer.set_keyboard(GTK_WINDOW(s->window), 2); /* OnDemand */
    else gdk_window_focus(gtk_widget_get_window(s->window), GDK_CURRENT_TIME);
    gtk_widget_grab_focus(s->area);
}
void rune_overlay_redraw(RuneLinuxOverlay *s) { if (s->mapped) gtk_gl_area_queue_render(GTK_GL_AREA(s->area)); }
static gboolean due(gpointer data) {
    RuneLinuxOverlay *s = data; s->timer = 0;
    send_event(s, (RuneOverlayEvent){.kind = RuneOverlayDue});
    return G_SOURCE_REMOVE;
}
static gboolean gpu_due(gpointer data) {
    RuneLinuxOverlay *s = data;
    s->gpu_timer = 0;
    send_event(s, (RuneOverlayEvent){.kind = RuneOverlayPollGPU});
    return G_SOURCE_REMOVE;
}
void rune_overlay_schedule_gpu_poll(RuneLinuxOverlay *s) {
    if (!s->gpu_timer) s->gpu_timer = g_timeout_add(4, gpu_due, s);
}
void rune_overlay_schedule(RuneLinuxOverlay *s, double delay) {
    if (s->timer) { g_source_remove(s->timer); s->timer = 0; }
    if (isfinite(delay) && delay >= 0) s->timer = g_timeout_add((guint)CLAMP(ceil(delay * 1000), 1, G_MAXUINT), due, s);
}
static void unmap(RuneLinuxOverlay *s) {
    s->mapped = FALSE;
    s->touch = NULL;
    shown_x11 = g_list_remove(shown_x11, s);
    watch_pointer(s);
    gtk_widget_hide(s->window);
    gtk_window_set_accept_focus(GTK_WINDOW(s->window), FALSE);
    if (s->backend == RuneOverlayLayer) layer.set_keyboard(GTK_WINDOW(s->window), 0);
}
static gboolean fade_tick(GtkWidget *widget, GdkFrameClock *clock, gpointer data) {
    (void)clock;
    RuneLinuxOverlay *s = data;
    double t = CLAMP((g_get_monotonic_time() - s->fade_start) / (s->fade_length * 1e6), 0.0, 1.0);
    gtk_widget_set_opacity(widget, s->opacity_from + (s->opacity_to - s->opacity_from) * t);
    if (t < 1) return G_SOURCE_CONTINUE;
    s->fade = 0;
    if (s->opacity_to == 0) { unmap(s); send_event(s, (RuneOverlayEvent){.kind = RuneOverlayDue}); }
    return G_SOURCE_REMOVE;
}
void rune_overlay_show(RuneLinuxOverlay *s, int show, double seconds) {
    if (s->fade) { gtk_widget_remove_tick_callback(s->window, s->fade); s->fade = 0; }
    s->opacity_from = s->mapped ? gtk_widget_get_opacity(s->window) : 0;
    s->opacity_to = show ? 1 : 0;
    if (show) {
        if (seconds > 0) gtk_widget_set_opacity(s->window, s->opacity_from);
        s->mapped = TRUE;
        gtk_widget_show(s->window);
        restack(s);
        watch_pointer(s);
        rune_overlay_redraw(s);
    }
    if (seconds > 0 && s->mapped && s->opacity_from != s->opacity_to) {
        s->fade_start = g_get_monotonic_time(); s->fade_length = seconds;
        s->fade = gtk_widget_add_tick_callback(s->window, fade_tick, s, NULL);
    } else {
        gtk_widget_set_opacity(s->window, s->opacity_to);
        if (!show) unmap(s);
    }
}
void rune_overlay_cursor(RuneLinuxOverlay *s, const char *name) {
    GdkCursor *cursor = name ? gdk_cursor_new_from_name(s->display, name) : NULL;
    gdk_window_set_cursor(gtk_widget_get_window(s->window), cursor);
    if (cursor) g_object_unref(cursor);
}
void rune_overlay_image_cursor(RuneLinuxOverlay *s, const uint8_t *rgba, int w, int h, int width, int height, int x, int y) {
    if (!rgba || w <= 0 || h <= 0 || width <= 0 || height <= 0 || w > G_MAXINT / 4) return;
    GdkPixbuf *pixels = gdk_pixbuf_new_from_data(rgba, GDK_COLORSPACE_RGB, TRUE, 8, w, h, w * 4, NULL, NULL);
    GdkPixbuf *scaled = gdk_pixbuf_scale_simple(pixels, width, height, GDK_INTERP_BILINEAR);
    if (scaled) {
        GdkCursor *cursor = gdk_cursor_new_from_pixbuf(s->display, scaled, x, y);
        if (cursor) { gdk_window_set_cursor(gtk_widget_get_window(s->window), cursor); g_object_unref(cursor); }
        g_object_unref(scaled);
    }
    g_object_unref(pixels);
}
void rune_overlay_pump(void) { if (host_count) for (int i = 0; i < 32 && g_main_context_iteration(NULL, FALSE); ++i) {} }
void rune_overlay_free(RuneLinuxOverlay *s) {
    if (!s) return;
    s->closing = TRUE;
    shown_x11 = g_list_remove(shown_x11, s);
    if (s->timer) g_source_remove(s->timer);
    if (s->gpu_timer) g_source_remove(s->gpu_timer);
    if (s->fade) gtk_widget_remove_tick_callback(s->window, s->fade);
    s->mapped = FALSE; watch_pointer(s);
    if (s->input) cairo_region_destroy(s->input);
    if (s->monitor) { g_signal_handler_disconnect(s->monitor, s->geometry_signal); g_object_unref(s->monitor); }
    g_signal_handler_disconnect(s->display, s->monitors_signal);
    g_signal_handler_disconnect(s->display, s->removed_signal);
    gtk_widget_destroy(s->window);
    gdk_display_flush(s->display);
    if (s->backend == RuneOverlayXWayland && s->display == owned_xdisplay && --fallback_users == 0) {
        /* GTK owns a hidden tooltip window per display. Its close callback
         * destroys it after removing that screen's GtkSettings. Detach it
         * from the retiring screen while those settings still exist. */
        GList *toplevels = gtk_window_list_toplevels();
        for (GList *link = toplevels; link; link = link->next) {
            GtkWidget *widget = link->data;
            if (gtk_widget_get_display(widget) == owned_xdisplay &&
                gtk_window_get_type_hint(GTK_WINDOW(widget)) == GDK_WINDOW_TYPE_HINT_TOOLTIP)
                gtk_window_set_screen(GTK_WINDOW(widget), gdk_screen_get_default());
        }
        g_list_free(toplevels);
        gdk_display_close(owned_xdisplay);
        owned_xdisplay = NULL;
    }
    g_free(s);
    if (--host_count == 0) { clear_gl_context(); rune_linux_register_gl_reset(NULL); }
}
#endif
