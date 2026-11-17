#if defined(__linux__) && !defined(__ANDROID__)
#include "CRuneLinuxA11y.h"
#include "GLibWake.h"
#include <atk/atk.h>
#include <atk-bridge.h>
#include <pango/pango.h>
#include <math.h>
#include <string.h>

typedef struct {
    AtkObject parent;
    GPtrArray *children;
    RuneA11yWindow *window;
    char *target, *text, *shortcut;
    int text_length;
    PangoLogAttr *text_attrs;
    RuneA11yProperties properties;
    GArray *text_cells;
    guint64 states;
    guint generation;
} RuneAccessible;
typedef AtkObjectClass RuneAccessibleClass;

struct RuneA11yWindow {
    RuneAccessible *frame;
    GHashTable *nodes;
    GQueue requests;
    RuneGLibWatch *watch;
    RuneA11yWake action_wake;
    void *wake_context;
    int x, y;
    gboolean visible;
    guint generation;
};

typedef struct {
    char *target, *text;
    int kind, start, end;
    double number;
} ActionRequest;

static RuneAccessible *application;

static void component_iface(AtkComponentIface *);
static void action_iface(AtkActionIface *);
G_DEFINE_TYPE_WITH_CODE(RuneAccessible, rune_accessible, ATK_TYPE_OBJECT,
    G_IMPLEMENT_INTERFACE(ATK_TYPE_COMPONENT, component_iface)
    G_IMPLEMENT_INTERFACE(ATK_TYPE_ACTION, action_iface))

typedef RuneAccessible RuneWindowAccessible;
typedef RuneAccessibleClass RuneWindowAccessibleClass;
G_DEFINE_TYPE_WITH_CODE(RuneWindowAccessible, rune_window_accessible, rune_accessible_get_type(),
    G_IMPLEMENT_INTERFACE(ATK_TYPE_WINDOW, NULL))
static void rune_window_accessible_init(RuneWindowAccessible *node) { (void)node; }
static void rune_window_accessible_class_init(RuneWindowAccessibleClass *cls) { (void)cls; }

static void text_iface(AtkTextIface *);
static void edit_iface(AtkEditableTextIface *);
static void value_iface(AtkValueIface *);
typedef RuneAccessible RuneText;
typedef RuneAccessibleClass RuneTextClass;
G_DEFINE_TYPE_WITH_CODE(RuneText, rune_text, rune_accessible_get_type(),
    G_IMPLEMENT_INTERFACE(ATK_TYPE_TEXT, text_iface))
typedef RuneText RuneField;
typedef RuneTextClass RuneFieldClass;
G_DEFINE_TYPE_WITH_CODE(RuneField, rune_field, rune_text_get_type(),
    G_IMPLEMENT_INTERFACE(ATK_TYPE_EDITABLE_TEXT, edit_iface))
typedef RuneAccessible RuneRange;
typedef RuneAccessibleClass RuneRangeClass;
G_DEFINE_TYPE_WITH_CODE(RuneRange, rune_range, rune_accessible_get_type(),
    G_IMPLEMENT_INTERFACE(ATK_TYPE_VALUE, value_iface))
static void rune_text_init(RuneText *node) { (void)node; }
static void rune_text_class_init(RuneTextClass *cls) { (void)cls; }
static void rune_field_init(RuneField *node) { (void)node; }
static void rune_field_class_init(RuneFieldClass *cls) { (void)cls; }
static void rune_range_init(RuneRange *node) { (void)node; }
static void rune_range_class_init(RuneRangeClass *cls) { (void)cls; }

static gint child_count(AtkObject *obj) { return (gint)((RuneAccessible *)obj)->children->len; }
static AtkObject *ref_child(AtkObject *obj, gint index) {
    GPtrArray *children = ((RuneAccessible *)obj)->children;
    return index >= 0 && (guint)index < children->len ? g_object_ref(children->pdata[index]) : NULL;
}

static gint index_in_parent(AtkObject *obj) {
    AtkObject *parent = atk_object_get_parent(obj);
    guint index;
    if (!parent || !G_TYPE_CHECK_INSTANCE_TYPE(parent, rune_accessible_get_type())) return -1;
    return g_ptr_array_find(((RuneAccessible *)parent)->children, obj, &index) ? (gint)index : -1;
}

G_STATIC_ASSERT(ATK_STATE_LAST_DEFINED <= 64);
#define STATE_BIT(s) (G_GUINT64_CONSTANT(1) << (s))
static AtkStateSet *ref_states(AtkObject *obj) {
    RuneAccessible *node = (RuneAccessible *)obj;
    AtkStateSet *set = atk_state_set_new();
    guint64 states = node->states;
    if (node->window && !node->window->visible)
        states &= ~(STATE_BIT(ATK_STATE_SHOWING) | STATE_BIT(ATK_STATE_VISIBLE) | STATE_BIT(ATK_STATE_FOCUSED));
    for (int i = 1; i < ATK_STATE_LAST_DEFINED; ++i)
        if (states & STATE_BIT(i)) atk_state_set_add_state(set, i);
    return set;
}

static void set_states(RuneAccessible *node, guint64 states) {
    guint64 changed = node->states ^ states;
    node->states = states;
    for (int i = 1; changed && i < ATK_STATE_LAST_DEFINED; ++i) {
        if (changed & STATE_BIT(i)) {
            atk_object_notify_state_change(ATK_OBJECT(node), i, (states & STATE_BIT(i)) != 0);
            changed &= ~STATE_BIT(i);
        }
    }
}

static guint64 states_for(RuneA11yProperties p, AtkRole role) {
    guint64 states = STATE_BIT(ATK_STATE_VISIBLE);
    if (!(p.state & RUNE_AX_OFFSCREEN)) states |= STATE_BIT(ATK_STATE_SHOWING);
    if (!(p.state & RUNE_AX_DISABLED)) states |= STATE_BIT(ATK_STATE_ENABLED) | STATE_BIT(ATK_STATE_SENSITIVE);
    static const struct { unsigned mask; AtkStateType state; } map[] = {
        {RUNE_AX_FOCUSABLE, ATK_STATE_FOCUSABLE}, {RUNE_AX_FOCUSED, ATK_STATE_FOCUSED},
        {RUNE_AX_CHECKABLE, ATK_STATE_CHECKABLE}, {RUNE_AX_CHECKED, ATK_STATE_CHECKED},
        {RUNE_AX_MIXED, ATK_STATE_INDETERMINATE}, {RUNE_AX_SELECTABLE, ATK_STATE_SELECTABLE},
        {RUNE_AX_SELECTED, ATK_STATE_SELECTED}, {RUNE_AX_EXPANDABLE, ATK_STATE_EXPANDABLE},
        {RUNE_AX_EXPANDED, ATK_STATE_EXPANDED}, {RUNE_AX_READ_ONLY, ATK_STATE_READ_ONLY},
        {RUNE_AX_BUSY, ATK_STATE_BUSY}, {RUNE_AX_INVALID, ATK_STATE_INVALID_ENTRY}, {RUNE_AX_MODAL, ATK_STATE_MODAL}
    };
    for (guint i = 0; i < G_N_ELEMENTS(map); ++i)
        if (p.state & map[i].mask) states |= STATE_BIT(map[i].state);
    if (p.actions & RUNE_AX_SET_TEXT) states |= STATE_BIT(ATK_STATE_EDITABLE);
    if (role == ATK_ROLE_TEXT) states |= STATE_BIT(ATK_STATE_MULTI_LINE);
    if (role == ATK_ROLE_ENTRY || role == ATK_ROLE_PASSWORD_TEXT) states |= STATE_BIT(ATK_STATE_SINGLE_LINE);
    return states;
}

static AtkRole at_role(const char *role) {
    static const struct { const char *name; AtkRole role; } map[] = {
        {"group", ATK_ROLE_GROUPING}, {"scroll-view", ATK_ROLE_PANEL}, {"text", ATK_ROLE_STATIC}, {"button", ATK_ROLE_PUSH_BUTTON},
        {"checkbox", ATK_ROLE_CHECK_BOX}, {"switch", ATK_ROLE_TOGGLE_BUTTON}, {"radio", ATK_ROLE_RADIO_BUTTON},
        {"tab", ATK_ROLE_PAGE_TAB}, {"textbox", ATK_ROLE_ENTRY}, {"slider", ATK_ROLE_SLIDER},
        {"progressbar", ATK_ROLE_PROGRESS_BAR}, {"listitem", ATK_ROLE_LIST_ITEM}, {"heading", ATK_ROLE_HEADING},
        {"dialog", ATK_ROLE_DIALOG}, {"alertdialog", ATK_ROLE_ALERT},
        {"menubar", ATK_ROLE_MENU_BAR}, {"menu", ATK_ROLE_MENU}, {"menuitem", ATK_ROLE_MENU_ITEM},
        {"img", ATK_ROLE_IMAGE}, {"figure", ATK_ROLE_PANEL}, {"icon", ATK_ROLE_ICON}, {"separator", ATK_ROLE_SEPARATOR},
        {"combobox", ATK_ROLE_COMBO_BOX}, {"listbox", ATK_ROLE_LIST_BOX}, {"option", ATK_ROLE_LIST_ITEM},
        {"tree", ATK_ROLE_TREE}, {"treeitem", ATK_ROLE_TREE_ITEM}, {"grid", ATK_ROLE_TABLE},
        {"row", ATK_ROLE_TABLE_ROW}, {"gridcell", ATK_ROLE_TABLE_CELL}, {"cell", ATK_ROLE_TABLE_CELL},
        {"columnheader", ATK_ROLE_COLUMN_HEADER}, {"rowheader", ATK_ROLE_ROW_HEADER},
        {"radiogroup", ATK_ROLE_GROUPING}, {"tablist", ATK_ROLE_PAGE_TAB_LIST}, {"tooltip", ATK_ROLE_TOOL_TIP},
        {"alert", ATK_ROLE_ALERT}, {"region", ATK_ROLE_LANDMARK}, {"main", ATK_ROLE_LANDMARK},
        {"navigation", ATK_ROLE_LANDMARK}, {"banner", ATK_ROLE_LANDMARK}, {"complementary", ATK_ROLE_LANDMARK},
        {"contentinfo", ATK_ROLE_LANDMARK}, {"form", ATK_ROLE_FORM}, {"search", ATK_ROLE_LANDMARK},
        {"link", ATK_ROLE_LINK}, {"toolbar", ATK_ROLE_TOOL_BAR}, {"splitter", ATK_ROLE_SPLIT_PANE},
        {"status", ATK_ROLE_STATUSBAR}, {"list", ATK_ROLE_LIST}, {"menu-item-check-box", ATK_ROLE_CHECK_MENU_ITEM},
        {"menu-item-radio", ATK_ROLE_RADIO_MENU_ITEM}, {"password-input", ATK_ROLE_PASSWORD_TEXT}, {"multiline-text-input", ATK_ROLE_TEXT},
        {"mark", ATK_ROLE_MARK}, {"code", ATK_ROLE_STATIC}, {"blockquote", ATK_ROLE_BLOCK_QUOTE},
        {"table", ATK_ROLE_TABLE}
    };
    for (guint i = 0; i < G_N_ELEMENTS(map); ++i)
        if (strcmp(map[i].name, role) == 0) return map[i].role;
    return ATK_ROLE_UNKNOWN;
}

static GType type_for(AtkRole role, unsigned actions) {
    switch (role) {
    case ATK_ROLE_ENTRY: case ATK_ROLE_TEXT: case ATK_ROLE_PASSWORD_TEXT:
        return actions & RUNE_AX_SET_TEXT ? rune_field_get_type() : rune_text_get_type();
    case ATK_ROLE_STATIC: case ATK_ROLE_HEADING: return rune_text_get_type();
    case ATK_ROLE_SLIDER: case ATK_ROLE_PROGRESS_BAR: return rune_range_get_type();
    default: return rune_accessible_get_type();
    }
}

static void finalize(GObject *obj) {
    RuneAccessible *node = (RuneAccessible *)obj;
    g_ptr_array_unref(node->children);
    g_free(node->target);
    g_free(node->text);
    g_free(node->text_attrs);
    g_free(node->shortcut);
    g_clear_pointer(&node->text_cells, g_array_unref);
    G_OBJECT_CLASS(rune_accessible_parent_class)->finalize(obj);
}
static void rune_accessible_class_init(RuneAccessibleClass *cls) {
    G_OBJECT_CLASS(cls)->finalize = finalize;
    cls->get_n_children = child_count;
    cls->ref_child = ref_child;
    cls->get_index_in_parent = index_in_parent;
    cls->ref_state_set = ref_states;
}
static void rune_accessible_init(RuneAccessible *node) {
    node->children = g_ptr_array_new_with_free_func(g_object_unref);
    node->states = states_for((RuneA11yProperties){0}, ATK_ROLE_UNKNOWN);
}

static void orphan(RuneAccessible *child) {
    RuneAccessible *parent = (RuneAccessible *)atk_object_get_parent(ATK_OBJECT(child));
    gint index = index_in_parent(ATK_OBJECT(child));
    if (!parent || index < 0) return;
    /* The parent's ownership is released after the removal notification. */
    g_ptr_array_steal_index(parent->children, index);
    g_signal_emit_by_name(parent, "children-changed::remove", index, child);
    atk_object_set_parent(ATK_OBJECT(child), NULL);
    g_object_unref(child);
}

static void place_child(RuneAccessible *parent, RuneAccessible *child, int index) {
    if (atk_object_get_parent(ATK_OBJECT(child)) == ATK_OBJECT(parent) &&
        (guint)index < parent->children->len && parent->children->pdata[index] == child) return;
    orphan(child);
    index = CLAMP(index, 0, (gint)parent->children->len);
    g_ptr_array_insert(parent->children, index, g_object_ref(child));
    atk_object_set_parent(ATK_OBJECT(child), ATK_OBJECT(parent));
    g_signal_emit_by_name(parent, "children-changed::add", index, child);
}

static gboolean queue_request(RuneAccessible *node, int kind, const char *text, double number, int start, int end) {
    if (!node->window || !node->window->visible || !node->target || !(node->properties.actions & kind) ||
        ((node->properties.state & RUNE_AX_DISABLED) && kind != RUNE_AX_SCROLL_INTO_VIEW)) return FALSE;
    ActionRequest *request = g_new0(ActionRequest, 1);
    request->target = g_strdup(node->target);
    request->kind = kind;
    request->text = g_strdup(text);
    request->number = number;
    request->start = start; request->end = end;
    g_queue_push_tail(&node->window->requests, request);
    if (node->window->action_wake) node->window->action_wake(node->window->wake_context);
    return TRUE;
}
static gboolean queue_action(RuneAccessible *node, int kind, const char *text, double number) {
    return queue_request(node, kind, text, number, -1, -1);
}

static void free_request(ActionRequest *request) {
    g_free(request->target);
    g_free(request->text);
    g_free(request);
}

static void coordinate_origin(RuneAccessible *node, AtkCoordType coordinates, double *x, double *y) {
    *x = *y = 0;
    if (coordinates == ATK_XY_SCREEN && node->window) {
        *x = node->window->x;
        *y = node->window->y;
    } else if (coordinates == ATK_XY_PARENT && node->window && node != node->window->frame) {
        RuneAccessible *parent = (RuneAccessible *)atk_object_get_parent(ATK_OBJECT(node));
        if (parent) { *x = -(double)parent->properties.x; *y = -(double)parent->properties.y; }
    }
}
static gint coordinate_int(double value) { return (gint)CLAMP(value, (double)G_MININT, (double)G_MAXINT); }
static void extents(AtkComponent *comp, int *x, int *y, int *w, int *h, AtkCoordType coordinates) {
    RuneAccessible *node = (RuneAccessible *)comp;
    double dx, dy;
    coordinate_origin(node, coordinates, &dx, &dy);
    *x = coordinate_int(node->properties.x + dx); *y = coordinate_int(node->properties.y + dy);
    *w = node->properties.width; *h = node->properties.height;
}
static gboolean contains(AtkComponent *comp, gint x, gint y, AtkCoordType coords) {
    gint ax, ay, width, height;
    extents(comp, &ax, &ay, &width, &height, coords);
    return x >= ax && y >= ay && x < (gint64)ax + width && y < (gint64)ay + height;
}
static AtkObject *at_point(AtkComponent *comp, gint x, gint y, AtkCoordType coords) {
    RuneAccessible *node = (RuneAccessible *)comp;
    if (coords == ATK_XY_PARENT) {
        gint old_x, old_y, win_x, win_y, w, h;
        extents(comp, &old_x, &old_y, &w, &h, coords);
        extents(comp, &win_x, &win_y, &w, &h, ATK_XY_WINDOW);
        x += win_x - old_x; y += win_y - old_y; coords = ATK_XY_WINDOW;
    }
    for (guint i = node->children->len; i > 0; --i) {
        AtkComponent *child = ATK_COMPONENT(node->children->pdata[i - 1]);
        if (atk_component_contains(child, x, y, coords)) return ATK_OBJECT(g_object_ref(child));
    }
    return NULL;
}
static gboolean grab_focus(AtkComponent *comp) { return queue_action((RuneAccessible *)comp, RUNE_AX_FOCUS, NULL, 0); }
#if ATK_CHECK_VERSION(2, 30, 0)
static gboolean scroll_to(AtkComponent *comp, AtkScrollType type) {
    (void)type;
    return queue_action((RuneAccessible *)comp, RUNE_AX_SCROLL_INTO_VIEW, NULL, 0);
}
#endif
static void component_iface(AtkComponentIface *iface) {
    iface->get_extents = extents; iface->contains = contains;
    iface->ref_accessible_at_point = at_point; iface->grab_focus = grab_focus;
#if ATK_CHECK_VERSION(2, 30, 0)
    iface->scroll_to = scroll_to;
#endif
}

static const char *const action_names[] = {"press", "focus", "increment", "decrement"};
static int action_count(AtkAction *action) {
    guint bits = ((RuneAccessible *)action)->properties.actions;
    int n = 0;
    for (guint i = 0; i < G_N_ELEMENTS(action_names); ++i) if (bits & (1u << i)) ++n;
    return n;
}
static int action_index(AtkAction *action, int lookup) {
    guint bits = ((RuneAccessible *)action)->properties.actions;
    for (guint i = 0; i < G_N_ELEMENTS(action_names); ++i)
        if ((bits & (1u << i)) && lookup-- == 0) return (int)i;
    return -1;
}
static const char *action_name(AtkAction *action, int requested) {
    int i = action_index(action, requested);
    return i >= 0 ? action_names[i] : NULL;
}
static const char *action_key(AtkAction *action, int requested) {
    return action_index(action, requested) == 0 ? ((RuneAccessible *)action)->shortcut : NULL;
}
static gboolean do_action(AtkAction *action, int requested) {
    int i = action_index(action, requested);
    return i >= 0 && queue_action((RuneAccessible *)action, 1 << i, NULL, 0);
}
static void action_iface(AtkActionIface *iface) {
    iface->do_action = do_action; iface->get_n_actions = action_count;
    iface->get_name = action_name; iface->get_localized_name = action_name; iface->get_keybinding = action_key;
}

static const char *visible_text(AtkText *obj) {
    RuneAccessible *node = (RuneAccessible *)obj;
    return node->text ? node->text : "";
}
static int character_count(AtkText *text) { return ((RuneAccessible *)text)->text_length; }
static char *get_text(AtkText *text, int start, int end) {
    const char *value = visible_text(text);
    int n = character_count(text);
    start = CLAMP(start, 0, n);
    return g_utf8_substring(value, start, end < 0 ? n : CLAMP(end, start, n));
}
static gunichar character_at(AtkText *text, int offset) {
    if (offset < 0 || offset >= character_count(text)) return 0;
    return g_utf8_get_char(g_utf8_offset_to_pointer(visible_text(text), offset));
}

static gint compare_cell_offsets(gconstpointer a, gconstpointer b) {
    const RuneA11yTextCell *left = a, *right = b;
    return (left->start > right->start) - (left->start < right->start);
}
static const RuneA11yTextCell *cell_for_offset(RuneAccessible *node, gint offset) {
    if (!node->text_cells || offset < 0) return NULL;
    const RuneA11yTextCell *cells = (const RuneA11yTextCell *)node->text_cells->data;
    guint low = 0, high = node->text_cells->len;
    while (low < high) {
        const guint middle = low + (high - low) / 2;
        if (offset < cells[middle].start) high = middle;
        else if (offset >= cells[middle].end) low = middle + 1;
        else return &cells[middle];
    }
    return NULL;
}
static AtkTextRectangle text_rect(RuneAccessible *node, AtkCoordType coords, double left, double top, double right, double bottom) {
    double dx, dy;
    coordinate_origin(node, coords, &dx, &dy);
    const double x = floor(left + dx), y = floor(top + dy);
    return (AtkTextRectangle){coordinate_int(x), coordinate_int(y),
        right > left ? coordinate_int(ceil(right + dx) - x) : 0, coordinate_int(ceil(bottom + dy) - y)};
}
static void character_extents(AtkText *text, gint offset, gint *x, gint *y, gint *width, gint *height, AtkCoordType coords) {
    RuneAccessible *node = (RuneAccessible *)text;
    const RuneA11yTextCell *cell = cell_for_offset(node, offset);
    AtkTextRectangle rect = {-1, -1, -1, -1};
    if (cell && node->window && node->window->visible && cell->height > 0)
        rect = text_rect(node, coords, cell->x, cell->y, cell->x + cell->width, cell->y + cell->height);
    if (x) *x = rect.x;
    if (y) *y = rect.y;
    if (width) *width = rect.width;
    if (height) *height = rect.height;
}
static void range_extents(AtkText *text, gint start, gint end, AtkCoordType coords, AtkTextRectangle *rect) {
    RuneAccessible *node = (RuneAccessible *)text;
    *rect = (AtkTextRectangle){-1, -1, -1, -1};
    if (!node->text_cells || !node->window || !node->window->visible || start < 0 || end <= start) return;
    double left = G_MAXDOUBLE, top = G_MAXDOUBLE, right = -G_MAXDOUBLE, bottom = -G_MAXDOUBLE;
    for (guint i = 0; i < node->text_cells->len; ++i) {
        const RuneA11yTextCell *cell = &g_array_index(node->text_cells, RuneA11yTextCell, i);
        if (cell->start >= end) break;
        if (cell->end <= start || cell->start == cell->end || cell->height <= 0) continue;
        left = MIN(left, cell->x); top = MIN(top, cell->y);
        right = MAX(right, cell->x + cell->width); bottom = MAX(bottom, cell->y + cell->height);
    }
    if (bottom > top) *rect = text_rect(node, coords, left, top, right, bottom);
}
static gint offset_at_point(AtkText *text, gint x, gint y, AtkCoordType coords) {
    RuneAccessible *node = (RuneAccessible *)text;
    if (!node->text_cells || !node->window || !node->window->visible) return -1;
    double dx, dy;
    coordinate_origin(node, coords, &dx, &dy);
    const double wx = x - dx, wy = y - dy;
    for (guint i = 0; i < node->text_cells->len; ++i) {
        const RuneA11yTextCell *cell = &g_array_index(node->text_cells, RuneA11yTextCell, i);
        if (wx >= cell->x && wx < cell->x + cell->width && wy >= cell->y && wy < cell->y + cell->height)
            return cell->start;
    }
    return -1;
}
static gboolean text_boundary(PangoLogAttr attr, AtkTextGranularity unit) {
    switch (unit) {
    case ATK_TEXT_GRANULARITY_CHAR: return attr.is_cursor_position;
    case ATK_TEXT_GRANULARITY_WORD: return attr.is_word_boundary;
    case ATK_TEXT_GRANULARITY_SENTENCE: return attr.is_sentence_start;
    case ATK_TEXT_GRANULARITY_LINE:
    case ATK_TEXT_GRANULARITY_PARAGRAPH: return attr.is_mandatory_break;
    default: return FALSE;
    }
}

static char *string_at_offset(AtkText *obj, int offset, AtkTextGranularity unit, int *start, int *end) {
    RuneAccessible *node = (RuneAccessible *)obj;
    int count = character_count(obj);
    *start = *end = -1;
    if (offset < 0 || offset >= count || unit > ATK_TEXT_GRANULARITY_PARAGRAPH) return NULL;
    if (unit == ATK_TEXT_GRANULARITY_LINE) {
        const RuneA11yTextCell *at = cell_for_offset(node, offset);
        if (at) {
            const RuneA11yTextCell *cells = (const RuneA11yTextCell *)node->text_cells->data;
            const RuneA11yTextCell *first = at, *last = at;
            while (first > cells && first[-1].line == at->line) --first;
            while (last + 1 < cells + node->text_cells->len && last[1].line == at->line) ++last;
            *start = first->start; *end = last->end;
            return get_text(obj, *start, *end);
        }
    }
    if (!node->text_attrs) {
        node->text_attrs = g_new0(PangoLogAttr, (gsize)count + 1);
        pango_get_log_attrs(visible_text(obj), -1, -1, pango_language_get_default(), node->text_attrs, count + 1);
    }
    *start = offset;
    *end = offset + 1;
    while (*start > 0 && !text_boundary(node->text_attrs[*start], unit)) --*start;
    while (*end < count && !text_boundary(node->text_attrs[*end], unit)) ++*end;
    return get_text(obj, *start, *end);
}

static int caret_offset(AtkText *obj) { return ((RuneAccessible *)obj)->properties.caret; }
static int selection_count(AtkText *obj) {
    RuneA11yProperties p = ((RuneAccessible *)obj)->properties;
    return p.anchor >= 0 && p.caret >= 0 && p.anchor != p.caret ? 1 : 0;
}
static char *get_selection(AtkText *obj, int index, int *start, int *end) {
    RuneA11yProperties p = ((RuneAccessible *)obj)->properties;
    *start = *end = -1;
    if (index != 0 || !selection_count(obj)) return NULL;
    *start = MIN(p.anchor, p.caret); *end = MAX(p.anchor, p.caret);
    return get_text(obj, *start, *end);
}
static gboolean select_text(AtkText *obj, int start, int end) {
    int count = character_count(obj);
    if (end == -1) end = count;
    if (start < 0 || start > end || end > count) return FALSE;
    return queue_request((RuneAccessible *)obj, RUNE_AX_SELECT_TEXT, NULL, 0, start, end);
}
static gboolean set_selection(AtkText *obj, int index, int start, int end) {
    return index == 0 && select_text(obj, start, end);
}
static gboolean set_caret(AtkText *obj, int offset) { return select_text(obj, offset, offset); }
static gboolean remove_selection(AtkText *obj, int index) {
    return index == 0 && selection_count(obj) && set_caret(obj, caret_offset(obj));
}
#if ATK_CHECK_VERSION(2, 32, 0)
static gboolean scroll_substring_to(AtkText *obj, int start, int end, AtkScrollType type) {
    int count = character_count(obj);
    if (end == -1) end = count;
    if (start < 0 || start > end || end > count) return FALSE;
    // Rune resolves a text run's scroll request to the element that owns the run.
    return scroll_to(ATK_COMPONENT(obj), type);
}
#endif
static void text_iface(AtkTextIface *iface) {
    iface->get_text = get_text; iface->get_character_count = character_count;
    iface->get_character_at_offset = character_at;
    iface->get_character_extents = character_extents;
    iface->get_range_extents = range_extents;
    iface->get_offset_at_point = offset_at_point;
#if ATK_CHECK_VERSION(2, 32, 0)
    iface->scroll_substring_to = scroll_substring_to;
#endif
    iface->get_string_at_offset = string_at_offset;
    iface->get_caret_offset = caret_offset; iface->set_caret_offset = set_caret;
    iface->get_n_selections = selection_count; iface->get_selection = get_selection;
    iface->add_selection = select_text; iface->set_selection = set_selection; iface->remove_selection = remove_selection;
}
static void set_text(AtkEditableText *text, const char *value) {
    queue_action((RuneAccessible *)text, RUNE_AX_SET_TEXT, value, 0);
}
static void insert_text(AtkEditableText *obj, const char *value, int length, int *position) {
    if (*position < 0 || *position > character_count(ATK_TEXT(obj)) || !value) return;
    char *insert = length < 0 ? g_strdup(value) : g_strndup(value, length);
    if (g_utf8_validate(insert, -1, NULL) && queue_request((RuneAccessible *)obj, RUNE_AX_REPLACE_TEXT, insert, 0, *position, *position))
        *position += (int)g_utf8_strlen(insert, -1);
    g_free(insert);
}
static void delete_text(AtkEditableText *obj, int start, int end) {
    int count = character_count(ATK_TEXT(obj));
    if (end == -1) end = count;
    if (start >= 0 && start < end && end <= count)
        queue_request((RuneAccessible *)obj, RUNE_AX_REPLACE_TEXT, "", 0, start, end);
}
static void edit_iface(AtkEditableTextIface *iface) {
    iface->set_text_contents = set_text; iface->insert_text = insert_text; iface->delete_text = delete_text;
}

static void value_and_text(AtkValue *obj, double *value, char **text) {
    RuneAccessible *node = (RuneAccessible *)obj;
    *value = node->properties.value;
    *text = g_strdup(node->text);
}
static AtkRange *get_range(AtkValue *obj) {
    RuneA11yProperties p = ((RuneAccessible *)obj)->properties;
    return atk_range_new(p.minimum, p.maximum, NULL);
}
static double get_increment(AtkValue *obj) { return ((RuneAccessible *)obj)->properties.step; }
static void set_number(AtkValue *obj, double value) { queue_action((RuneAccessible *)obj, RUNE_AX_SET_NUMBER, NULL, value); }
static void value_iface(AtkValueIface *iface) {
    iface->get_value_and_text = value_and_text; iface->get_range = get_range;
    iface->get_increment = get_increment; iface->set_value = set_number;
}

static AtkObject *get_root(void) { return ATK_OBJECT(application); }
static const char *get_toolkit(void) { return "Rune"; }
static const char *get_version(void) { return "1"; }

static RuneA11yWindow *open_window(const char *title, int visible, RuneA11yWake wake, void *context, gboolean overlay) {
    if (!wake || (!g_getenv("DBUS_SESSION_BUS_ADDRESS") && !g_getenv("AT_SPI_BUS_ADDRESS") && !g_getenv("DISPLAY"))) return NULL;
    if (!application) {
        AtkUtilClass *util = g_type_class_ref(ATK_TYPE_UTIL);
        /* Coexist with applications embedding Rune alongside a toolkit that owns ATK. */
        if (atk_get_root()) { g_type_class_unref(util); return NULL; }
        AtkObject *(*old_root)(void) = util->get_root;
        const char *(*old_name)(void) = util->get_toolkit_name;
        const char *(*old_version)(void) = util->get_toolkit_version;
        util->get_root = get_root; util->get_toolkit_name = get_toolkit; util->get_toolkit_version = get_version;
        application = g_object_new(rune_accessible_get_type(), NULL);
        atk_object_set_role(ATK_OBJECT(application), ATK_ROLE_APPLICATION);
        atk_object_set_name(ATK_OBJECT(application), title);
        if (atk_bridge_adaptor_init(NULL, NULL) != 0) {
            util->get_root = old_root; util->get_toolkit_name = old_name; util->get_toolkit_version = old_version;
            g_clear_object(&application);
            g_type_class_unref(util);
            return NULL;
        }
        g_type_class_unref(util);
    }
    RuneA11yWindow *window = g_new0(RuneA11yWindow, 1);
    if (overlay) {
        /* The GTK overlay already owns a host-loop descriptor watch. Wake its
         * Rune handle only when an AT-SPI request needs the runtime to act. */
        window->action_wake = wake;
        window->wake_context = context;
    } else {
        window->watch = rune_glib_watch_new(wake, context);
        if (!window->watch) { g_free(window); return NULL; }
    }
    window->nodes = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_object_unref);
    window->frame = g_object_new(rune_window_accessible_get_type(), NULL);
    window->frame->window = window;
    atk_object_set_role(ATK_OBJECT(window->frame), ATK_ROLE_FRAME);
    atk_object_set_name(ATK_OBJECT(window->frame), title);
    rune_ax_visible(window, visible);
    if (window->watch) rune_glib_watch_arm(window->watch);
    return window;
}

void rune_ax_toolkit_window(void *accessible, int visible) {
    if (!application || !ATK_IS_OBJECT(accessible) || !ATK_IS_COMPONENT(accessible)) return;
    AtkObject *window = ATK_OBJECT(accessible);
    guint index;
    gboolean attached = g_ptr_array_find(application->children, window, &index);
    if (visible && !attached) {
        index = application->children->len;
        g_ptr_array_add(application->children, g_object_ref(window));
        if (atk_object_get_parent(window) != ATK_OBJECT(application)) atk_object_set_parent(window, ATK_OBJECT(application));
        g_signal_emit_by_name(application, "children-changed::add", index, window);
    } else if (!visible && attached) {
        g_ptr_array_steal_index(application->children, index);
        g_signal_emit_by_name(application, "children-changed::remove", index, window);
        g_object_unref(window);
    }
}

RuneA11yWindow *rune_ax_open(const char *title, int visible, RuneA11yWake wake, void *context) {
    return open_window(title, visible, wake, context, FALSE);
}
RuneA11yWindow *rune_ax_open_overlay(const char *title, int visible, RuneA11yWake wake, void *context) {
    return open_window(title, visible, wake, context, TRUE);
}
void rune_ax_visible(RuneA11yWindow *window, int visible) {
    if (!window || window->visible == (visible != 0)) return;
    window->visible = visible != 0;
    if (window->visible) {
        place_child(application, window->frame, (int)application->children->len);
        set_states(window->frame, states_for(window->frame->properties, ATK_ROLE_FRAME));
        g_signal_emit_by_name(window->frame, "create");
    } else {
        g_queue_clear_full(&window->requests, (GDestroyNotify)free_request);
        if (window->frame->states & STATE_BIT(ATK_STATE_ACTIVE)) g_signal_emit_by_name(window->frame, "deactivate");
        set_states(window->frame, 0);
        g_signal_emit_by_name(window->frame, "destroy");
        orphan(window->frame);
    }
}

void rune_ax_pump(RuneA11yWindow *window, RuneA11yAction consume, void *context) {
    if (!window) return;
    for (int i = 0; i < 32 && g_main_context_iteration(NULL, FALSE); ++i) {}
    rune_ax_take_requests(window, consume, context);
}
void rune_ax_take_requests(RuneA11yWindow *window, RuneA11yAction consume, void *context) {
    if (!window) return;
    ActionRequest *req;
    while ((req = g_queue_pop_head(&window->requests))) {
        consume(context, req->target, req->kind, req->text, req->number, req->start, req->end);
        free_request(req);
    }
    if (window->watch) rune_glib_watch_arm(window->watch);
}

void rune_ax_begin(RuneA11yWindow *w, const char *title, int x, int y, int width, int height, int focused) {
    if (!w) return;
    ++w->generation;
    gboolean moved = x != w->x || y != w->y || width != w->frame->properties.width || height != w->frame->properties.height;
    w->x = x; w->y = y;
    w->frame->properties.width = width;
    w->frame->properties.height = height;
    guint64 frame_states = states_for(w->frame->properties, ATK_ROLE_FRAME);
    gboolean was_active = (w->frame->states & STATE_BIT(ATK_STATE_ACTIVE)) != 0;
    if (!w->visible) { focused = 0; frame_states = 0; }
    set_states(w->frame, focused ? frame_states | STATE_BIT(ATK_STATE_ACTIVE) : frame_states);
    if (was_active != (focused != 0)) g_signal_emit_by_name(w->frame, focused ? "activate" : "deactivate");
    if (moved) {
        AtkRectangle rect = {x, y, width, height};
        g_signal_emit_by_name(w->frame, "bounds-changed", &rect);
    }
    if (g_strcmp0(atk_object_get_name(ATK_OBJECT(w->frame)), title))
        atk_object_set_name(ATK_OBJECT(w->frame), title);
}

static void change_text(RuneAccessible *node, const char *value) {
    if (!g_strcmp0(node->text, value)) return;
    gboolean text_node = ATK_IS_TEXT(node);
    if (text_node && node->text && *node->text)
        g_signal_emit_by_name(node, "text-changed::delete", 0, node->text_length);
    g_free(node->text);
    g_clear_pointer(&node->text_attrs, g_free);
    g_clear_pointer(&node->text_cells, g_array_unref);
    node->text = g_strdup(value);
    node->text_length = value ? (int)g_utf8_strlen(value, -1) : 0;
    if (text_node && value && *value)
        g_signal_emit_by_name(node, "text-changed::insert", 0, node->text_length);
}
static void retire_node(RuneAccessible *node) {
    orphan(node);
    node->window = NULL;
    g_clear_pointer(&node->text_cells, g_array_unref);
    set_states(node, STATE_BIT(ATK_STATE_DEFUNCT));
    while (node->children->len) orphan(node->children->pdata[node->children->len - 1]);
}

void rune_ax_remove(RuneA11yWindow *w, const char *key) {
    RuneAccessible *node = w && key ? g_hash_table_lookup(w->nodes, key) : NULL;
    if (!node) return;
    retire_node(node);
    g_hash_table_remove(w->nodes, key);
}

static void notify_bounds(RuneAccessible *node) {
    AtkRectangle rect;
    extents(ATK_COMPONENT(node), &rect.x, &rect.y, &rect.width, &rect.height, ATK_XY_SCREEN);
    g_signal_emit_by_name(node, "bounds-changed", &rect);
}

void rune_ax_geometry(RuneA11yWindow *w, const char *key, int x, int y, int width, int height, int offscreen) {
    RuneAccessible *node = w && key ? g_hash_table_lookup(w->nodes, key) : NULL;
    if (!node) return;
    node->generation = w->generation;
    RuneA11yProperties *p = &node->properties;
    gboolean moved = p->x != x || p->y != y || p->width != width || p->height != height;
    p->x = x; p->y = y; p->width = width; p->height = height;
    if (((p->state & RUNE_AX_OFFSCREEN) != 0) != (offscreen != 0)) {
        if (offscreen) p->state |= RUNE_AX_OFFSCREEN;
        else p->state &= ~RUNE_AX_OFFSCREEN;
        const guint64 showing = STATE_BIT(ATK_STATE_SHOWING);
        set_states(node, offscreen ? node->states & ~showing : node->states | showing);
    }
    if (moved) notify_bounds(node);
}

void rune_ax_node(RuneA11yWindow *w, const char *key, const char *parent_key, int index,
                  const char *target, const char *role_name, const char *name, const char *help,
                  const char *text, const char *shortcut, RuneA11yProperties properties) {
    if (!w) return;
    RuneAccessible *parent = parent_key ? g_hash_table_lookup(w->nodes, parent_key) : w->frame;
    if (!parent) return;
    AtkRole role = at_role(role_name);
    GType type = type_for(role, properties.actions);
    RuneAccessible *node = g_hash_table_lookup(w->nodes, key);
    if (node && G_OBJECT_TYPE(node) != type) {
        retire_node(node); g_hash_table_remove(w->nodes, key); node = NULL;
    }
    if (!node) {
        node = g_object_new(type, NULL);
        node->window = w;
        node->target = g_strdup(target);
        atk_object_set_accessible_id(ATK_OBJECT(node), target);
        g_hash_table_insert(w->nodes, g_strdup(key), node);
    }
    node->generation = w->generation;
    AtkObject *obj = ATK_OBJECT(node);
    if (atk_object_get_role(obj) != role) atk_object_set_role(obj, role);
    if (g_strcmp0(atk_object_get_name(obj), name)) atk_object_set_name(obj, name);
    if (g_strcmp0(atk_object_get_description(obj), help)) atk_object_set_description(obj, help);
    if (g_strcmp0(node->shortcut, shortcut)) { g_free(node->shortcut); node->shortcut = g_strdup(shortcut); }
    /* Password content is excluded independently at both ends of the ABI. */
    change_text(node, role == ATK_ROLE_PASSWORD_TEXT ? NULL : text);
    RuneA11yProperties old = node->properties;
    node->properties = properties;
    set_states(node, states_for(properties, role));
    if (old.x != properties.x || old.y != properties.y || old.width != properties.width || old.height != properties.height)
        notify_bounds(node);
    if (ATK_IS_TEXT(node) && (old.anchor != properties.anchor || old.caret != properties.caret)) {
        if (old.caret != properties.caret && properties.caret >= 0) g_signal_emit_by_name(node, "text-caret-moved", properties.caret);
        if (old.anchor != old.caret || properties.anchor != properties.caret) g_signal_emit_by_name(node, "text-selection-changed");
    }
    if (ATK_IS_VALUE(node) && old.value != properties.value)
        g_signal_emit_by_name(node, "value-changed", properties.value, node->text);
    place_child(parent, node, index);
}

void rune_ax_text_geometry(RuneA11yWindow *w, const char *key, const RuneA11yTextCell *cells, int count) {
    RuneAccessible *node = w && key ? g_hash_table_lookup(w->nodes, key) : NULL;
    if (!node || !ATK_IS_TEXT(node)) return;
    g_clear_pointer(&node->text_cells, g_array_unref);
    if (!cells || count <= 0 || atk_object_get_role(ATK_OBJECT(node)) == ATK_ROLE_PASSWORD_TEXT) return;
    const int length = character_count(ATK_TEXT(node));
    for (int i = 0; i < count; ++i) {
        const RuneA11yTextCell *cell = &cells[i];
        if (cell->start < 0 || cell->end < cell->start || cell->end > length || cell->line < 0 ||
            !isfinite(cell->x) || !isfinite(cell->y) || !isfinite(cell->width) || !isfinite(cell->height) ||
            cell->width < 0 || cell->height < 0) return;
    }
    node->text_cells = g_array_sized_new(FALSE, FALSE, sizeof(*cells), (guint)count);
    g_array_append_vals(node->text_cells, cells, (guint)count);
    /* The shaper emits bidi cells in visual order. ATK indices address logical scalar ranges. */
    g_array_sort(node->text_cells, compare_cell_offsets);
}

static void retire_nodes(RuneA11yWindow *w, gboolean all) {
    GHashTableIter it;
    gpointer value;
    g_hash_table_iter_init(&it, w->nodes);
    while (g_hash_table_iter_next(&it, NULL, &value)) {
        RuneAccessible *node = value;
        if (all || node->generation != w->generation) { retire_node(node); g_hash_table_iter_remove(&it); }
    }
}
void rune_ax_end(RuneA11yWindow *w) {
    if (w) retire_nodes(w, FALSE);
}
void rune_ax_announce(RuneA11yWindow *w, const char *text, int assertive) {
    if (!w || !text || !*text) return;
#if ATK_CHECK_VERSION(2, 50, 0)
    g_signal_emit_by_name(w->frame, "notification", text, assertive ? ATK_LIVE_ASSERTIVE : ATK_LIVE_POLITE);
#else
    if (g_signal_lookup("announcement", ATK_TYPE_OBJECT)) g_signal_emit_by_name(w->frame, "announcement", text);
    (void)assertive;
#endif
}

void rune_ax_close(RuneA11yWindow *w) {
    if (!w) return;
    if (w->watch) rune_glib_watch_free(w->watch);
    retire_nodes(w, TRUE);
    rune_ax_visible(w, FALSE);
    retire_node(w->frame);
    g_object_unref(w->frame);
    g_hash_table_unref(w->nodes);
    g_queue_clear_full(&w->requests, (GDestroyNotify)free_request);
    g_free(w);
    /* ATK adaptor state is process-wide. A new Rune window can attach to the same root. */
}
#endif
