/* From the repository root:
   cc -ISources/CRuneLinuxA11y/include Tests/Support/LinuxAccessibility/SparseUpdates.c \
      Sources/CRuneLinuxA11y/Accessibility.c Sources/CRuneLinuxA11y/GLibWake.c \
      $(pkg-config --cflags --libs atk atk-bridge-2.0 pango) -o /tmp/rune-sparse-atk
   dbus-run-session -- /tmp/rune-sparse-atk */
#include "CRuneLinuxA11y.h"
#include <atk/atk.h>

static void wake(void *context) { (void)context; }
static int bounds_count, showing_count, remove_count;
static gboolean last_showing;
static AtkRectangle last_bounds;

static void bounds_changed(AtkComponent *component, AtkRectangle *rect, gpointer data) {
    (void)component; (void)data;
    last_bounds = *rect;
    ++bounds_count;
}

static void showing_changed(AtkObject *object, const char *name, gboolean showing, gpointer data) {
    (void)object; (void)name; (void)data;
    last_showing = showing;
    ++showing_count;
}

static void removed(AtkObject *parent, guint index, AtkObject *child, gpointer data) {
    (void)parent;
    g_assert_cmpuint(index, ==, 0);
    g_assert_true(child == data);
    ++remove_count;
}

static gboolean has_state(AtkObject *object, AtkStateType state) {
    AtkStateSet *states = atk_object_ref_state_set(object);
    gboolean present = atk_state_set_contains_state(states, state);
    g_object_unref(states);
    return present;
}

int main(void) {
    RuneA11yWindow *w = rune_ax_open_overlay("Sparse ATK", 1, wake, NULL);
    g_assert_nonnull(w);
    rune_ax_begin(w, "Sparse ATK", 100, 200, 300, 400, 1);
    RuneA11yProperties p = {.width = 20, .height = 30, .state = RUNE_AX_FOCUSABLE | RUNE_AX_FOCUSED};
    rune_ax_node(w, "field", NULL, 0, "field", "textbox", "Field", NULL, "hello", NULL, p);
    rune_ax_node(w, "stale", NULL, 1, "stale", "group", NULL, NULL, NULL, NULL, p);
    rune_ax_end(w);
    AtkObject *frame = atk_object_ref_accessible_child(atk_get_root(), 0);
    AtkObject *field = atk_object_ref_accessible_child(frame, 0);
    AtkObject *stale = atk_object_ref_accessible_child(frame, 1);
    g_signal_connect(field, "bounds-changed", G_CALLBACK(bounds_changed), NULL);
    g_signal_connect(field, "state-change::showing", G_CALLBACK(showing_changed), NULL);

    rune_ax_begin(w, "Sparse ATK", 100, 200, 300, 400, 1);
    rune_ax_geometry(w, "field", 4, 7, 24, 31, 1);
    rune_ax_geometry(w, "field", 4, 7, 24, 31, 1);
    g_assert_cmpint(bounds_count, ==, 1);
    g_assert_cmpint(last_bounds.x, ==, 104); g_assert_cmpint(last_bounds.y, ==, 207);
    g_assert_cmpint(last_bounds.width, ==, 24); g_assert_cmpint(last_bounds.height, ==, 31);
    g_assert_cmpint(showing_count, ==, 1); g_assert_false(last_showing);
    g_assert_false(has_state(field, ATK_STATE_SHOWING)); g_assert_true(has_state(field, ATK_STATE_FOCUSED));
    g_assert_cmpstr(atk_object_get_name(field), ==, "Field");
    g_autofree char *text = atk_text_get_text(ATK_TEXT(field), 0, -1);
    g_assert_cmpstr(text, ==, "hello");
    rune_ax_end(w);
    g_assert_true(has_state(stale, ATK_STATE_DEFUNCT));
    g_assert_cmpint(atk_object_get_n_accessible_children(frame), ==, 1);

    rune_ax_geometry(w, "field", 4, 7, 24, 31, 0);
    g_assert_cmpint(showing_count, ==, 2); g_assert_true(last_showing);
    g_assert_cmpint(bounds_count, ==, 1);
    g_signal_connect(frame, "children-changed::remove", G_CALLBACK(removed), field);
    rune_ax_remove(w, "field"); rune_ax_remove(w, "field");
    rune_ax_geometry(w, "field", 0, 0, 0, 0, 1);
    g_assert_cmpint(remove_count, ==, 1); g_assert_cmpint(bounds_count, ==, 1);
    g_assert_null(atk_object_get_parent(field)); g_assert_true(has_state(field, ATK_STATE_DEFUNCT));
    g_signal_handlers_disconnect_by_func(frame, G_CALLBACK(removed), field);

    rune_ax_node(w, "old", NULL, 0, "old", "group", NULL, NULL, NULL, NULL, p);
    AtkObject *old = atk_object_ref_accessible_child(frame, 0);
    rune_ax_begin(w, "Sparse ATK", 100, 200, 300, 400, 1);
    rune_ax_node(w, "new", NULL, 1, "new", "group", NULL, NULL, NULL, NULL, p);
    AtkObject *fresh = atk_object_ref_accessible_child(frame, 1);
    rune_ax_close(w);
    g_assert_true(has_state(old, ATK_STATE_DEFUNCT)); g_assert_true(has_state(fresh, ATK_STATE_DEFUNCT));
    g_assert_null(atk_object_get_parent(old)); g_assert_null(atk_object_get_parent(fresh));
    g_object_unref(old); g_object_unref(fresh); g_object_unref(stale); g_object_unref(field); g_object_unref(frame);
    g_print("PASS sparse ATK bounds, visibility, identity, removal, snapshot sweep, and close\n");
    return 0;
}
