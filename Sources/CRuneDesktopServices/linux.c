#if defined(__linux__) && !defined(__ANDROID__)
#include "wayland_clipboard.h"
#include "wayland_drag.h"
#include "GtkAccessibility.h"
#include <gtk/gtk.h>
#include <gdk/gdkx.h>
#include <SDL.h>
#include <SDL_syswm.h>
#include <X11/XKBlib.h>
#include <X11/keysym.h>
#include <string.h>

/* GTK and the AT-SPI bridge share GLib's default context. Every toolkit
   callback stays on the SDL host thread, including clipboard expiry requests
   originating on a Swift timer. */
static GMutex service_lock;
static GThread *owner_thread;
static unsigned hosts;
static int initialized, available;
static GtkClipboard *board;
static struct RuneWaylandBoard *wayland;
int rune_desktop_linux_right_alt_is_altgr(uint32_t window_id) {
    if (wayland) return rune_wayland_board_altgr(wayland);
    SDL_Window *window = SDL_GetWindowFromID(window_id);
    SDL_SysWMinfo info;
    SDL_VERSION(&info.version);
    if (!window || !SDL_GetWindowWMInfo(window, &info) || info.subsystem != SDL_SYSWM_X11) return 0;
    Display *display = info.info.x11.display;
    XkbStateRec state;
    if (XkbGetState(display, XkbUseCoreKbd, &state) != Success) return 0;
    XkbDescPtr map = XkbGetMap(display, XkbAllClientInfoMask, XkbUseCoreKbd);
    if (!map) return 0;
    KeySym symbol = NoSymbol;
    if (XkbGetNames(display, XkbKeyNamesMask, map) == Success && map->names && map->names->keys) {
        for (int code = map->min_key_code; code <= map->max_key_code; ++code) {
            if (memcmp(map->names->keys[code].name, "RALT", XkbKeyNameLength) == 0) {
                unsigned consumed;
                XkbTranslateKeyCode(map, code, XkbBuildCoreState(0, state.group), &consumed, &symbol);
                break;
            }
        }
    }
    XkbFreeKeyboard(map, XkbAllComponentsMask, True);
    return symbol == XK_ISO_Level3_Shift || symbol == XK_ISO_Level5_Shift || symbol == XK_Mode_switch;
}
int rune_wayland_drag_context(uint32_t window_id, struct RuneWaylandDragContext *out) {
    return rune_wayland_board_drag_context(wayland, window_id, out);
}
static RuneMimeData *owned;
static Window owned_window, last_window;
static gint64 revision = 1;
static guint32 last_selection_time;
static SDL_atomic_t sdl_revision;
static GQueue pending = G_QUEUE_INIT;

static Window xowner(void) {
    GdkDisplay *display = gtk_clipboard_get_display(board);
    return XGetSelectionOwner(GDK_DISPLAY_XDISPLAY(display),
                               gdk_x11_get_xatom_by_name_for_display(display, "CLIPBOARD"));
}
static void refresh_owner(void) {
    Window owner = xowner();
    if (owner != last_window) { last_window = owner; ++revision; }
}
static void owner_changed(GtkClipboard *clipboard, GdkEventOwnerChange *event, gpointer unused) {
    (void)clipboard; (void)unused;
    Window previous = last_window;
    refresh_owner();
    if (last_window == previous && (!owned || last_window != owned_window) &&
        event->selection_time != last_selection_time) ++revision;
    last_selection_time = event->selection_time;
}
static int SDLCALL watch_clipboard(void *unused, SDL_Event *event) {
    (void)unused;
    if (event->type == SDL_CLIPBOARDUPDATE) SDL_AtomicAdd(&sdl_revision, 1);
    return 1;
}
static void initialize(void) {
    if (initialized) return;
    initialized = 1;
    /* Xwayland can broker rich MIME between the SDL seat and GTK. */
    gdk_set_allowed_backends("x11,wayland");
    /* AT-SPI may already be active through Rune. GTK installs emission
       hooks for GtkWidget signals during startup; register the class first. */
    gpointer widget_class = g_type_class_ref(GTK_TYPE_WIDGET);
    available = gtk_init_check(NULL, NULL);
    g_type_class_unref(widget_class);
    if (available) rune_ax_watch_gtk_toplevels();
    SDL_AddEventWatch(watch_clipboard, NULL);
    if (available && GDK_IS_X11_DISPLAY(gdk_display_get_default())) {
        board = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
        g_signal_connect(board, "owner-change", G_CALLBACK(owner_changed), NULL);
        refresh_owner();
    }
}

struct Call { GCond cond; int done; void (*work)(void *); void *argument; };
void rune_desktop_linux_connect(uint32_t window_id) {
    if (window_id && !wayland) wayland = rune_wayland_board_open(window_id);
    g_mutex_lock(&service_lock);
    if (!hosts) owner_thread = g_thread_self();
    ++hosts;
    g_mutex_unlock(&service_lock);
}
static void dispatch_pending(void) {
    g_mutex_lock(&service_lock);
    struct Call *call;
    while ((call = g_queue_pop_head(&pending))) {
        g_mutex_unlock(&service_lock);
        call->work(call->argument);
        g_mutex_lock(&service_lock);
        call->done = 1;
        g_cond_signal(&call->cond);
    }
    g_mutex_unlock(&service_lock);
}
void rune_desktop_linux_pump(void) {
    dispatch_pending();
    rune_wayland_board_pump(wayland);
    if (available) for (int i = 0; i < 32 && g_main_context_iteration(NULL, FALSE); ++i) {}
}
void rune_desktop_linux_disconnect(void) {
    g_mutex_lock(&service_lock);
    if (hosts) --hosts;
    int last = !hosts;
    g_mutex_unlock(&service_lock);
    /* Requests accepted before the last window closed must finish. */
    dispatch_pending();
    if (last) {
        rune_wayland_board_close(wayland);
        wayland = NULL;
        if (board && owned) {
            if (rune_mime_find(owned, "x-kde-passwordManagerHint")) rune_clipboard_clear(revision);
            else if (xowner() == owned_window) gtk_clipboard_store(board);
        }
    }
}
static int on_gtk(void (*work)(void *), void *argument) {
    g_mutex_lock(&service_lock);
    if (!owner_thread) owner_thread = g_thread_self();
    if (owner_thread == g_thread_self()) {
        g_mutex_unlock(&service_lock);
        work(argument);
        return 1;
    }
    if (!hosts) { g_mutex_unlock(&service_lock); return 0; }
    struct Call call = {.work = work, .argument = argument};
    g_cond_init(&call.cond);
    g_queue_push_tail(&pending, &call);
    /* The host's idle SDL wait is bounded. */
    while (!call.done) g_cond_wait(&call.cond, &service_lock);
    g_mutex_unlock(&service_lock);
    g_cond_clear(&call.cond);
    return 1;
}

int rune_desktop_linux_call(void (*work)(void *), void *context) {
    return work && on_gtk(work, context);
}

static void get_data(GtkClipboard *clipboard, GtkSelectionData *selection, guint index, gpointer data) {
    (void)clipboard;
    RuneMimeData *list = data;
    if (index >= list->count) return;
    struct RuneMimeEntry *entry = &list->entries[index];
    if (!strcmp(entry->type, RUNE_PLAIN)) {
        gtk_selection_data_set_text(selection, (const char *)entry->bytes, (int)entry->length);
    } else {
        gtk_selection_data_set(selection, gtk_selection_data_get_target(selection), 8,
                               entry->bytes, (int)entry->length);
    }
}
static void lost_selection(GtkClipboard *clipboard, gpointer data) {
    (void)clipboard;
    if (owned == data) { owned = NULL; owned_window = None; }
    rune_mime_free(data);
}
struct Write { const RuneMimeData *list; int concealed; int64_t revision; };
static void write_gtk(void *arg) {
    struct Write *write = arg;
    GtkTargetList *targets = gtk_target_list_new(NULL, 0);
    RuneMimeData *copy = rune_mime_create();
    if (!copy) goto done;
    for (size_t i = 0; i < write->list->count; ++i) {
        const struct RuneMimeEntry *e = &write->list->entries[i];
        if (!rune_mime_add(copy, e->type, e->bytes, e->length)) goto done;
        if (!strcmp(e->type, RUNE_PLAIN)) {
            gtk_target_list_add_text_targets(targets, (guint)i);
        } else {
            gtk_target_list_add(targets, gdk_atom_intern(e->type, FALSE), 0, (guint)i);
        }
    }
    if (write->concealed) {
        static const guint8 secret_hint[] = "secret";
        guint index = (guint)copy->count;
        if (!rune_mime_add(copy, "x-kde-passwordManagerHint", secret_hint, sizeof(secret_hint) - 1)) goto done;
        gtk_target_list_add(targets, gdk_atom_intern_static_string("x-kde-passwordManagerHint"), 0, index);
    }
    gint count = 0;
    GtkTargetEntry *entries = gtk_target_table_new_from_list(targets, &count);
    if (count && gtk_clipboard_set_with_data(board, entries, count, get_data, lost_selection, copy)) {
        owned = copy;
        copy = NULL;
        owned_window = last_window = xowner();
        write->revision = ++revision;
        if (!write->concealed) gtk_clipboard_set_can_store(board, NULL, 0);
    }
    gtk_target_table_free(entries, count);
done:
    rune_mime_free(copy);
    gtk_target_list_unref(targets);
}
static int sdl_seat(void) {
    const char *driver = SDL_GetCurrentVideoDriver();
    return driver && !strcmp(driver, "wayland");
}
static void write_clipboard(void *arg) {
    struct Write *write = arg;
    if (wayland) { write->revision = rune_wayland_board_write(wayland, write->list, write->concealed); return; }
    initialize();
    if (board) { write_gtk(write); return; }
    /* SDL2's Wayland seat offers plain text, without a concealed MIME type or
       an ownership token. Reject concealed writes before exposing the text. */
    const struct RuneMimeEntry *plain = rune_mime_find(write->list, RUNE_PLAIN);
    if (write->concealed || !sdl_seat() || !plain || SDL_SetClipboardText((const char *)plain->bytes)) return;
    write->revision = SDL_AtomicGet(&sdl_revision);
}
int64_t rune_clipboard_write(const RuneMimeData *list, int concealed) {
    if (!list) return -1;
    struct Write write = {list, concealed, -1};
    on_gtk(write_clipboard, &write);
    return write.revision;
}
static void read_gtk(void *result) {
    RuneMimeData *list = result;
    char *text = gtk_clipboard_wait_for_text(board);
    if (text) { rune_mime_add(list, RUNE_PLAIN, (uint8_t *)text, strlen(text)); g_free(text); }
    GdkAtom *targets = NULL;
    gint count = 0;
    if (!gtk_clipboard_wait_for_targets(board, &targets, &count)) return;
    for (int i = 0; i < count && list->count < RUNE_CLIPBOARD_TYPES; ++i) {
        char *type = gdk_atom_name(targets[i]);
        if (!type) continue;
        if ((strchr(type, '/') || !strcmp(type, RUNE_CONCEALED) || !strcmp(type, "x-kde-passwordManagerHint")) &&
            !g_str_has_prefix(type, "text/plain") && !rune_mime_find(list, type)) {
            GtkSelectionData *selection = gtk_clipboard_wait_for_contents(board, targets[i]);
            if (selection) {
                gint length = gtk_selection_data_get_length(selection);
                if (length >= 0) rune_mime_add(list, type, gtk_selection_data_get_data(selection), length);
                gtk_selection_data_free(selection);
            }
        }
        g_free(type);
    }
    g_free(targets);
}
static void read_clipboard(void *arg) {
    RuneMimeData *list = arg;
    if (wayland) { rune_wayland_board_read(wayland, list); return; }
    initialize();
    if (board) read_gtk(list);
    else if (sdl_seat()) {
        char *text = SDL_GetClipboardText();
        if (text) { rune_mime_add(list, RUNE_PLAIN, (const uint8_t *)text, strlen(text)); SDL_free(text); }
    }
}
RuneMimeData *rune_clipboard_read(void) {
    RuneMimeData *list = rune_mime_create();
    if (list) on_gtk(read_clipboard, list);
    return list;
}
static void get_revision(void *out) {
    if (wayland) { *(int64_t *)out = rune_wayland_board_revision(wayland); return; }
    initialize();
    if (board) { refresh_owner(); *(int64_t *)out = revision; }
    else *(int64_t *)out = SDL_AtomicGet(&sdl_revision);
}
int64_t rune_clipboard_revision(void) {
    int64_t value = -1;
    on_gtk(get_revision, &value);
    return value;
}
struct Clear { int64_t expected; int cleared; };
static void clear_gtk(void *arg) {
    struct Clear *clear = arg;
    if (wayland) { clear->cleared = rune_wayland_board_clear(wayland, clear->expected); return; }
    initialize();
    if (!board) {
        clear->cleared = clear->expected < 0 && sdl_seat() && SDL_SetClipboardText("") == 0;
        return;
    }
    if (clear->expected < 0) {
        /* Clear foreign data by taking ownership. gtk_clipboard_clear alone
           only releases this process's previous selection. */
        gtk_clipboard_set_text(board, "", 0);
        gtk_clipboard_clear(board);
        clear->cleared = 1;
        return;
    }
    GdkDisplay *display = gtk_clipboard_get_display(board);
    gdk_x11_display_grab(display);
    refresh_owner();
    if (owned && last_window == owned_window && revision == clear->expected) {
        gtk_clipboard_clear(board);
        clear->cleared = 1;
        ++revision;
    }
    gdk_x11_display_ungrab(display);
    gdk_display_flush(display);
}
int rune_clipboard_clear(int64_t expected) {
    struct Clear clear = {expected, 0};
    on_gtk(clear_gtk, &clear);
    return clear.cleared;
}

int rune_desktop_open_url(const char *url) {
    return url && g_app_info_launch_default_for_uri(url, NULL, NULL);
}
struct PickerCall {
    RuneDesktopPicker *picker;
    int save, folders, multiple, result;
    const char *title, *directory, *filename;
};
static void show_picker(void *arg) {
    struct PickerCall *call = arg;
    initialize();
    if (!available) return;
    GtkFileChooserAction action = call->folders ? GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER :
        (call->save ? GTK_FILE_CHOOSER_ACTION_SAVE : GTK_FILE_CHOOSER_ACTION_OPEN);
    GtkFileChooserNative *dialog = gtk_file_chooser_native_new(
        *call->title ? call->title : NULL, NULL, action, NULL, NULL);
    GtkFileChooser *chooser = GTK_FILE_CHOOSER(dialog);
    gtk_file_chooser_set_select_multiple(chooser, call->multiple && !call->save && !call->folders);
    if (*call->directory) gtk_file_chooser_set_current_folder(chooser, call->directory);
    if (call->save) {
        gtk_file_chooser_set_do_overwrite_confirmation(chooser, TRUE);
        if (*call->filename) gtk_file_chooser_set_current_name(chooser, call->filename);
    }
    const RuneMimeData *filters = call->picker->filters;
    for (size_t i = 0; !call->folders && i < filters->count; ++i) {
        GtkFileFilter *filter = gtk_file_filter_new();
        gtk_file_filter_set_name(filter, filters->entries[i].type);
        char **patterns = g_strsplit((const char *)filters->entries[i].bytes, ";", -1);
        for (char **p = patterns; *p; ++p) gtk_file_filter_add_pattern(filter, *p);
        g_strfreev(patterns);
        gtk_file_chooser_add_filter(chooser, filter);
    }
    call->result = 0;
    if (gtk_native_dialog_run(GTK_NATIVE_DIALOG(dialog)) == GTK_RESPONSE_ACCEPT) {
        GSList *files = gtk_file_chooser_get_filenames(chooser);
        call->result = files ? 1 : -1;
        for (GSList *f = files; f; f = f->next) {
            if (!rune_picker_add_path(call->picker, (const char *)f->data)) call->result = -1;
        }
        g_slist_free_full(files, g_free);
    }
    g_object_unref(dialog);
}
int rune_picker_show(RuneDesktopPicker *picker, int save, int folders, int multiple,
                     const char *title, const char *directory, const char *filename) {
    struct PickerCall call = {picker, save, folders, multiple, -1, title, directory, filename};
    if (picker) on_gtk(show_picker, &call);
    return call.result;
}
#endif
