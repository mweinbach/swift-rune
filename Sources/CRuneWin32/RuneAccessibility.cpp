#include "RuneAccessibility.h"
#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#include <commctrl.h>
#include <oleauto.h>
#include <uiautomation.h>
#include "RuneTextProvider.hpp"

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {
struct Node {
    int id = 0, parent = -1, control = UIA_WindowControlTypeId;
    std::wstring key, role, name, help, value, shortcut;
    UiaRect rect{};
    bool focusable = false, disabled = false, secure = false, readOnly = true;
    bool pressable = false, settable = false, hasRange = false;
    int toggle = -1, live = 0, selected = -1, expanded = -1;
    int level = 0, position = 0, size = 0;
    double minimum = 0, maximum = 0, number = 0, step = 0;
    int nearestSelector = -1, selectionContainer = -1;
    std::vector<int> children, selectableItems;
    int anchor = 0, caret = 0;
    std::shared_ptr<RuneUiaTextContent> field;
    const std::wstring &valueText() const { return field ? field->text : value; }
};
struct Tree {
    std::unordered_map<int, Node> nodes;
    int focused = 0;
};
struct Action {
    int id, kind;
    std::wstring text;
    double number;
    int start = 0, end = 0;
    std::shared_ptr<const RuneUiaTextContent> selectionText;
};
struct Window {
    std::mutex lock;
    HWND hwnd;
    bool active = false, focusChanged = false;
    std::shared_ptr<const Tree> tree;
    std::deque<Action> actions;
    explicit Window(HWND h) : hwnd(h) {
        auto initial = std::make_shared<Tree>();
        initial->nodes.emplace(0, Node{});
        tree = initial;
    }
};

// Providers retained by an out-of-process client keep the snapshot alive, never the Swift runtime.
struct Snapshot {
    HWND hwnd;
    std::shared_ptr<const Tree> tree;
    const Node *node = nullptr;
    Snapshot(Window &window, int id) {
        std::lock_guard<std::mutex> lock(window.lock);
        hwnd = window.hwnd;
        tree = window.tree;
        const auto found = tree->nodes.find(id);
        if (hwnd && found != tree->nodes.end()) node = &found->second;
    }
};
std::wstring wide(const char *utf8) {
    if (!utf8 || !*utf8) return {};
    const int bytes = static_cast<int>(strlen(utf8));
    const int count = MultiByteToWideChar(CP_UTF8, 0, utf8, bytes, nullptr, 0);
    std::wstring result(count, L'\0');
    if (count) MultiByteToWideChar(CP_UTF8, 0, utf8, bytes, &result[0], count);
    return result;
}
int controlType(const std::string &role) {
    static const std::unordered_map<std::string, int> types = {
        {"text", UIA_TextControlTypeId}, {"heading", UIA_TextControlTypeId},
        {"button", UIA_ButtonControlTypeId}, {"checkbox", UIA_CheckBoxControlTypeId},
        {"switch", UIA_CheckBoxControlTypeId}, {"radio", UIA_RadioButtonControlTypeId},
        {"tab", UIA_TabItemControlTypeId}, {"tablist", UIA_TabControlTypeId},
        {"textbox", UIA_EditControlTypeId}, {"password-input", UIA_EditControlTypeId},
        {"multiline-text-input", UIA_EditControlTypeId}, {"slider", UIA_SliderControlTypeId},
        {"progressbar", UIA_ProgressBarControlTypeId}, {"listitem", UIA_ListItemControlTypeId},
        {"option", UIA_ListItemControlTypeId}, {"list", UIA_ListControlTypeId},
        {"listbox", UIA_ListControlTypeId}, {"dialog", UIA_WindowControlTypeId},
        {"menubar", UIA_MenuBarControlTypeId}, {"menu", UIA_MenuControlTypeId}, {"menuitem", UIA_MenuItemControlTypeId},
        {"menu-item-check-box", UIA_MenuItemControlTypeId}, {"menu-item-radio", UIA_MenuItemControlTypeId}, {"img", UIA_ImageControlTypeId},
        {"icon", UIA_ImageControlTypeId}, {"separator", UIA_SeparatorControlTypeId},
        {"combobox", UIA_ComboBoxControlTypeId}, {"tree", UIA_TreeControlTypeId},
        {"treeitem", UIA_TreeItemControlTypeId}, {"grid", UIA_DataGridControlTypeId},
        {"row", UIA_DataItemControlTypeId}, {"gridcell", UIA_DataItemControlTypeId},
        {"columnheader", UIA_HeaderItemControlTypeId}, {"tooltip", UIA_ToolTipControlTypeId},
        {"link", UIA_HyperlinkControlTypeId}, {"toolbar", UIA_ToolBarControlTypeId},
        {"splitter", UIA_ThumbControlTypeId}, {"status", UIA_StatusBarControlTypeId},
        {"table", UIA_TableControlTypeId}, {"mark", UIA_TextControlTypeId},
        {"code", UIA_TextControlTypeId}, {"blockquote", UIA_TextControlTypeId}
    };
    const auto found = types.find(role);
    return found == types.end() ? UIA_GroupControlTypeId : found->second;
}
// UIA requires screen coordinates in physical pixels, also on a query from a DPI-unaware client.
struct WindowDpi {
    DPI_AWARENESS_CONTEXT previous;
    explicit WindowDpi(HWND hwnd) : previous(SetThreadDpiAwarenessContext(GetWindowDpiAwarenessContext(hwnd))) {}
    ~WindowDpi() { if (previous) SetThreadDpiAwarenessContext(previous); }
};
bool contains(UiaRect r, double x, double y) {
    return x >= r.left && x < r.left + r.width && y >= r.top && y < r.top + r.height;
}
int hit(const Tree &tree, const Node &node, double x, double y) {
    // Paint order is back to front. Children may extend beyond an unclipped parent.
    for (auto it = node.children.rbegin(); it != node.children.rend(); ++it) {
        int child = hit(tree, tree.nodes.at(*it), x, y);
        if (child >= 0) return child;
    }
    return contains(node.rect, x, y) ? node.id : -1;
}
HRESULT stringProperty(VARIANT *out, const std::wstring &s) {
    out->bstrVal = SysAllocStringLen(s.data(), static_cast<UINT>(s.size()));
    if (!out->bstrVal) return E_OUTOFMEMORY;
    out->vt = VT_BSTR;
    return S_OK;
}
HRESULT boolProperty(VARIANT *out, bool value) {
    out->vt = VT_BOOL;
    out->boolVal = value ? VARIANT_TRUE : VARIANT_FALSE;
    return S_OK;
}
HRESULT intProperty(VARIANT *out, int value) {
    out->vt = VT_I4;
    out->lVal = value;
    return S_OK;
}
bool supports(const Node &n, PATTERNID pattern) {
    if (pattern == UIA_InvokePatternId) return n.pressable && n.toggle < 0 && n.selectionContainer < 0;
    if (pattern == UIA_TogglePatternId) return n.toggle >= 0 && n.selectionContainer < 0;
    if (pattern == UIA_ExpandCollapsePatternId) return n.expanded >= 0 && n.pressable;
    if (pattern == UIA_SelectionPatternId) return !n.selectableItems.empty();
    if (pattern == UIA_SelectionItemPatternId) return n.selectionContainer >= 0;
    if (pattern == UIA_TextPatternId || pattern == UIA_TextPattern2Id) return n.field && !n.secure;
    if (pattern == UIA_ValuePatternId) return n.control == UIA_EditControlTypeId;
    if (pattern == UIA_RangeValuePatternId) return n.hasRange;
    return false;
}

class Provider final : public IRawElementProviderSimple, public IRawElementProviderFragment,
    public IRawElementProviderFragmentRoot, public IInvokeProvider, public IToggleProvider,
    public IValueProvider, public IRangeValueProvider, public IExpandCollapseProvider,
    public ISelectionProvider, public ISelectionItemProvider, public RuneUiaTextSource {
    std::atomic<ULONG> refs{1};
    std::shared_ptr<Window> window;
    int id;
public:
    Provider(std::shared_ptr<Window> owner, int nodeId) : window(std::move(owner)), id(nodeId) {}
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
    ULONG STDMETHODCALLTYPE Release() override {
        const auto count = --refs;
        if (!count) delete this;
        return count;
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (iid == __uuidof(IUnknown) || iid == __uuidof(IRawElementProviderSimple))
            *out = static_cast<IRawElementProviderSimple *>(this);
        else if (iid == __uuidof(IRawElementProviderFragment)) *out = static_cast<IRawElementProviderFragment *>(this);
        else if (iid == __uuidof(IRawElementProviderFragmentRoot) && id == 0) *out = static_cast<IRawElementProviderFragmentRoot *>(this);
        else if (iid == __uuidof(IInvokeProvider)) *out = static_cast<IInvokeProvider *>(this);
        else if (iid == __uuidof(IToggleProvider)) *out = static_cast<IToggleProvider *>(this);
        else if (iid == __uuidof(IValueProvider)) *out = static_cast<IValueProvider *>(this);
        else if (iid == __uuidof(IRangeValueProvider)) *out = static_cast<IRangeValueProvider *>(this);
        else if (iid == __uuidof(IExpandCollapseProvider)) *out = static_cast<IExpandCollapseProvider *>(this);
        else if (iid == __uuidof(ISelectionProvider)) *out = static_cast<ISelectionProvider *>(this);
        else if (iid == __uuidof(ISelectionItemProvider)) *out = static_cast<ISelectionItemProvider *>(this);
        else return E_NOINTERFACE;
        AddRef();
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_ProviderOptions(ProviderOptions *out) override {
        if (!out) return E_POINTER;
        *out = ProviderOptions_ServerSideProvider;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetPatternProvider(PATTERNID pattern, IUnknown **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        Snapshot s(*window, id);
        if (!s.node) return UIA_E_ELEMENTNOTAVAILABLE;
        if (!supports(*s.node, pattern)) return S_OK;
        if (pattern == UIA_TextPatternId || pattern == UIA_TextPattern2Id) return runeCreateTextProvider(this, out);
        if (pattern == UIA_InvokePatternId) *out = static_cast<IInvokeProvider *>(this);
        if (pattern == UIA_TogglePatternId) *out = static_cast<IToggleProvider *>(this);
        if (pattern == UIA_ValuePatternId) *out = static_cast<IValueProvider *>(this);
        if (pattern == UIA_RangeValuePatternId) *out = static_cast<IRangeValueProvider *>(this);
        if (pattern == UIA_ExpandCollapsePatternId) *out = static_cast<IExpandCollapseProvider *>(this);
        if (pattern == UIA_SelectionPatternId) *out = static_cast<ISelectionProvider *>(this);
        if (pattern == UIA_SelectionItemPatternId) *out = static_cast<ISelectionItemProvider *>(this);
        AddRef();
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetPropertyValue(PROPERTYID property, VARIANT *out) override {
        if (!out) return E_POINTER;
        VariantInit(out);
        Snapshot s(*window, id);
        if (!s.node) return UIA_E_ELEMENTNOTAVAILABLE;
        const Node &n = *s.node;
        switch (property) {
        case UIA_ControlTypePropertyId: return intProperty(out, n.control);
        case UIA_NamePropertyId: return stringProperty(out, n.name);
        case UIA_AutomationIdPropertyId: return stringProperty(out, n.key);
        case UIA_HelpTextPropertyId: return stringProperty(out, n.help);
        case UIA_AriaRolePropertyId:
            if (n.role == L"menu-item-radio") return stringProperty(out, L"menuitemradio");
            if (n.role == L"menu-item-check-box") return stringProperty(out, L"menuitemcheckbox");
            if (n.role == L"password-input" || n.role == L"multiline-text-input") return stringProperty(out, L"textbox");
            if (n.role == L"icon") return stringProperty(out, L"img");
            if (n.role == L"splitter") return stringProperty(out, L"separator");
            return stringProperty(out, n.role);
        case UIA_AriaPropertiesPropertyId: {
            std::wstring props;
            if (n.selected >= 0) props += n.selected ? L"selected=true;" : L"selected=false;";
            if (n.expanded >= 0) props += n.expanded ? L"expanded=true;" : L"expanded=false;";
            if (n.toggle >= 0) props += n.toggle == 2 ? L"checked=mixed;" : (n.toggle ? L"checked=true;" : L"checked=false;");
            if (!props.empty()) props.pop_back();
            return stringProperty(out, props);
        }
        case UIA_LevelPropertyId: return n.level > 0 ? intProperty(out, n.level) : S_OK;
        case UIA_PositionInSetPropertyId: return n.position > 0 ? intProperty(out, n.position) : S_OK;
        case UIA_SizeOfSetPropertyId: return n.size > 0 ? intProperty(out, n.size) : S_OK;
        case UIA_AcceleratorKeyPropertyId: return stringProperty(out, n.shortcut);
        case UIA_FrameworkIdPropertyId: return stringProperty(out, L"Rune");
        case UIA_IsKeyboardFocusablePropertyId: return boolProperty(out, n.focusable);
        case UIA_HasKeyboardFocusPropertyId: return boolProperty(out, s.tree->focused == id && GetForegroundWindow() == s.hwnd);
        case UIA_IsEnabledPropertyId: return boolProperty(out, !n.disabled);
        case UIA_IsPasswordPropertyId: return boolProperty(out, n.secure);
        case UIA_IsOffscreenPropertyId: {
            if (!IsWindowVisible(s.hwnd) || IsIconic(s.hwnd)) return boolProperty(out, true);
            UiaRect bounds{};
            HRESULT hr = get_BoundingRectangle(&bounds);
            if (FAILED(hr)) return hr;
            WindowDpi dpi(s.hwnd);
            RECT screen = {static_cast<LONG>(bounds.left), static_cast<LONG>(bounds.top),
                           static_cast<LONG>(bounds.left + bounds.width), static_cast<LONG>(bounds.top + bounds.height)};
            return boolProperty(out, bounds.width <= 0 || bounds.height <= 0 ||
                                !MonitorFromRect(&screen, MONITOR_DEFAULTTONULL));
        }
        case UIA_IsContentElementPropertyId:
        case UIA_IsControlElementPropertyId: return boolProperty(out, true);
        case UIA_LiveSettingPropertyId: return intProperty(out, n.live);
        default: return S_OK;
        }
    }
    IRawElementProviderSimple *textOwner() override { return this; }
    const void *textWindow() const override { return window.get(); }
    int textId() const override { return id; }
    HRESULT readText(RuneUiaTextSnapshot &out) override {
        Snapshot s(*window, id);
        if (!s.node) return UIA_E_ELEMENTNOTAVAILABLE;
        if (s.node->secure) return E_ACCESSDENIED;
        if (!s.node->field) return UIA_E_NOTSUPPORTED;
        WindowDpi dpi(s.hwnd);
        POINT origin{};
        if (!ClientToScreen(s.hwnd, &origin)) return UIA_E_ELEMENTNOTAVAILABLE;
        out.content = s.node->field;
        out.anchor = s.node->anchor;
        out.focus = s.node->caret;
        out.focused = id == s.tree->focused && GetForegroundWindow() == s.hwnd;
        out.readOnly = s.node->readOnly || !s.node->settable;
        out.selectable = !s.node->disabled && s.node->settable;
        out.viewport = IsWindowVisible(s.hwnd) && !IsIconic(s.hwnd) ? s.node->rect : UiaRect{};
        out.screenX = origin.x; out.screenY = origin.y;
        return S_OK;
    }
    HRESULT selectText(int start, int end, const RuneUiaTextContent &expected) override {
        std::lock_guard<std::mutex> lock(window->lock);
        auto found = window->tree->nodes.find(id);
        if (!window->hwnd || found == window->tree->nodes.end()) return UIA_E_ELEMENTNOTAVAILABLE;
        const auto &n = found->second;
        if (n.secure) return E_ACCESSDENIED;
        if (n.disabled) return UIA_E_ELEMENTNOTENABLED;
        if (!n.field || !n.settable) return UIA_E_NOTSUPPORTED;
        if (n.field.get() != &expected && n.field->text != expected.text) return UIA_E_INVALIDOPERATION;
        Action request{id, 0, L"", 0, start, end, n.field};
        window->actions.push_back(std::move(request));
        if (!InvalidateRect(window->hwnd, nullptr, FALSE)) {
            window->actions.pop_back();
            return UIA_E_ELEMENTNOTAVAILABLE;
        }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_HostRawElementProvider(IRawElementProviderSimple **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        Snapshot s(*window, id);
        if (!s.node) return UIA_E_ELEMENTNOTAVAILABLE;
        return id == 0 ? UiaHostProviderFromHwnd(s.hwnd, out) : S_OK;
    }
    HRESULT STDMETHODCALLTYPE Navigate(NavigateDirection dir, IRawElementProviderFragment **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        Snapshot s(*window, id);
        if (!s.node) return UIA_E_ELEMENTNOTAVAILABLE;
        int target = -1;
        const Node &n = *s.node;
        if (dir == NavigateDirection_Parent) target = n.parent;
        if (dir == NavigateDirection_FirstChild && !n.children.empty()) target = n.children.front();
        if (dir == NavigateDirection_LastChild && !n.children.empty()) target = n.children.back();
        if ((dir == NavigateDirection_NextSibling || dir == NavigateDirection_PreviousSibling) && n.parent >= 0) {
            const auto &children = s.tree->nodes.at(n.parent).children;
            const auto it = std::find(children.begin(), children.end(), id);
            if (it != children.end()) {
                if (dir == NavigateDirection_NextSibling && it + 1 != children.end()) target = *(it + 1);
                if (dir == NavigateDirection_PreviousSibling && it != children.begin()) target = *(it - 1);
            }
        }
        if (target >= 0) *out = new Provider(window, target);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetRuntimeId(SAFEARRAY **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        Snapshot s(*window, id);
        if (!s.node) return UIA_E_ELEMENTNOTAVAILABLE;
        if (id == 0) return S_OK; // The window supplies the root identifier.
        SAFEARRAY *array = SafeArrayCreateVector(VT_I4, 0, 2);
        if (!array) return E_OUTOFMEMORY;
        LONG index = 0, value = UiaAppendRuntimeId;
        HRESULT hr = SafeArrayPutElement(array, &index, &value);
        index = 1; value = id;
        if (SUCCEEDED(hr)) hr = SafeArrayPutElement(array, &index, &value);
        if (FAILED(hr)) { SafeArrayDestroy(array); return hr; }
        *out = array;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_BoundingRectangle(UiaRect *out) override {
        if (!out) return E_POINTER;
        *out = {};
        Snapshot s(*window, id);
        if (!s.node) return UIA_E_ELEMENTNOTAVAILABLE;
        WindowDpi dpi(s.hwnd);
        POINT origin{};
        if (!ClientToScreen(s.hwnd, &origin)) return UIA_E_ELEMENTNOTAVAILABLE;
        *out = s.node->rect;
        if (id == 0) {
            RECT client{};
            if (!GetClientRect(s.hwnd, &client)) return UIA_E_ELEMENTNOTAVAILABLE;
            out->width = client.right; out->height = client.bottom;
        }
        out->left += origin.x;
        out->top += origin.y;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetEmbeddedFragmentRoots(SAFEARRAY **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_FragmentRoot(IRawElementProviderFragmentRoot **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        Snapshot s(*window, id);
        if (!s.node) return UIA_E_ELEMENTNOTAVAILABLE;
        *out = new Provider(window, 0);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE ElementProviderFromPoint(double x, double y, IRawElementProviderFragment **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        Snapshot s(*window, 0);
        if (!s.node) return UIA_E_ELEMENTNOTAVAILABLE;
        WindowDpi dpi(s.hwnd);
        POINT origin{};
        if (!ClientToScreen(s.hwnd, &origin)) return UIA_E_ELEMENTNOTAVAILABLE;
        RECT client{};
        if (!GetClientRect(s.hwnd, &client)) return UIA_E_ELEMENTNOTAVAILABLE;
        x -= origin.x; y -= origin.y;
        if (x < 0 || x >= client.right || y < 0 || y >= client.bottom) return S_OK;
        *out = new Provider(window, std::max(0, hit(*s.tree, *s.node, x, y)));
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetFocus(IRawElementProviderFragment **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        Snapshot s(*window, 0);
        if (!s.node) return UIA_E_ELEMENTNOTAVAILABLE;
        if (GetForegroundWindow() == s.hwnd) *out = new Provider(window, s.tree->focused);
        return S_OK;
    }
    HRESULT enqueue(int kind, PATTERNID pattern, const wchar_t *text = L"", double number = 0) {
        std::lock_guard<std::mutex> lock(window->lock);
        const auto found = window->tree->nodes.find(id);
        if (!window->hwnd || found == window->tree->nodes.end()) return UIA_E_ELEMENTNOTAVAILABLE;
        const Node &n = found->second;
        if (n.disabled) return UIA_E_ELEMENTNOTENABLED;
        if (pattern && !supports(n, pattern)) return UIA_E_NOTSUPPORTED;
        if (kind == RUNE_UIA_PRESS && !n.pressable) return UIA_E_NOTSUPPORTED;
        if (kind == RUNE_UIA_FOCUS && !n.focusable) return UIA_E_NOTSUPPORTED;
        if ((kind == RUNE_UIA_SET_TEXT || kind == RUNE_UIA_SET_NUMBER) && (!n.settable || n.readOnly)) return UIA_E_NOTSUPPORTED;
        window->actions.push_back({id, kind, text, number, 0, 0, nullptr});
        if (!InvalidateRect(window->hwnd, nullptr, FALSE)) {
            window->actions.pop_back();
            return UIA_E_ELEMENTNOTAVAILABLE;
        }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE SetFocus() override { return enqueue(RUNE_UIA_FOCUS, 0); }
    HRESULT STDMETHODCALLTYPE Invoke() override { return enqueue(RUNE_UIA_PRESS, UIA_InvokePatternId); }
    HRESULT STDMETHODCALLTYPE Toggle() override { return enqueue(RUNE_UIA_PRESS, UIA_TogglePatternId); }
    HRESULT expanded(bool desired) {
        Snapshot s(*window, id);
        if (!s.node) return UIA_E_ELEMENTNOTAVAILABLE;
        if (!supports(*s.node, UIA_ExpandCollapsePatternId)) return UIA_E_NOTSUPPORTED;
        if (s.node->disabled) return UIA_E_ELEMENTNOTENABLED;
        if (s.node->expanded == desired) return S_OK;
        return enqueue(desired ? RUNE_UIA_EXPAND : RUNE_UIA_COLLAPSE, UIA_ExpandCollapsePatternId);
    }
    HRESULT STDMETHODCALLTYPE Expand() override { return expanded(true); }
    HRESULT STDMETHODCALLTYPE Collapse() override { return expanded(false); }
    HRESULT STDMETHODCALLTYPE get_ExpandCollapseState(ExpandCollapseState *out) override {
        if (!out) return E_POINTER;
        Snapshot s(*window, id);
        if (!s.node) return UIA_E_ELEMENTNOTAVAILABLE;
        if (s.node->expanded < 0) return UIA_E_NOTSUPPORTED;
        *out = s.node->expanded ? ExpandCollapseState_Expanded : ExpandCollapseState_Collapsed;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetSelection(SAFEARRAY **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        Snapshot s(*window, id);
        if (!s.node) return UIA_E_ELEMENTNOTAVAILABLE;
        if (!supports(*s.node, UIA_SelectionPatternId)) return UIA_E_NOTSUPPORTED;
        std::vector<int> selected;
        for (int item : s.node->selectableItems) {
            if (s.tree->nodes.at(item).selected == 1) selected.push_back(item);
        }
        SAFEARRAY *items = SafeArrayCreateVector(VT_UNKNOWN, 0, static_cast<ULONG>(selected.size()));
        if (!items) return E_OUTOFMEMORY;
        for (LONG i = 0; i < static_cast<LONG>(selected.size()); ++i) {
            IRawElementProviderSimple *item = new Provider(window, selected[i]);
            HRESULT hr = SafeArrayPutElement(items, &i, item);
            item->Release();
            if (FAILED(hr)) { SafeArrayDestroy(items); return hr; }
        }
        *out = items;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_CanSelectMultiple(BOOL *out) override {
        if (!out) return E_POINTER;
        *out = FALSE;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_IsSelectionRequired(BOOL *out) override {
        if (!out) return E_POINTER;
        *out = TRUE;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_IsSelected(BOOL *out) override {
        if (!out) return E_POINTER;
        Snapshot s(*window, id);
        if (!s.node) return UIA_E_ELEMENTNOTAVAILABLE;
        *out = s.node->selected == 1;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_SelectionContainer(IRawElementProviderSimple **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        Snapshot s(*window, id);
        if (!s.node) return UIA_E_ELEMENTNOTAVAILABLE;
        if (s.node->selectionContainer >= 0) *out = new Provider(window, s.node->selectionContainer);
        return S_OK;
    }
    HRESULT select(bool adding) {
        Snapshot s(*window, id);
        if (!s.node) return UIA_E_ELEMENTNOTAVAILABLE;
        if (s.node->disabled) return UIA_E_ELEMENTNOTENABLED;
        if (s.node->selectionContainer < 0 || !s.node->pressable) return UIA_E_NOTSUPPORTED;
        if (s.node->selected == 1) return S_OK;
        if (adding) {
            for (int item : s.tree->nodes.at(s.node->selectionContainer).selectableItems) {
                if (s.tree->nodes.at(item).selected == 1) return UIA_E_INVALIDOPERATION;
            }
        }
        return enqueue(RUNE_UIA_SELECT, UIA_SelectionItemPatternId);
    }
    HRESULT STDMETHODCALLTYPE Select() override { return select(false); }
    HRESULT STDMETHODCALLTYPE AddToSelection() override { return select(true); }
    HRESULT STDMETHODCALLTYPE RemoveFromSelection() override {
        Snapshot s(*window, id);
        if (!s.node) return UIA_E_ELEMENTNOTAVAILABLE;
        if (s.node->disabled) return UIA_E_ELEMENTNOTENABLED;
        return s.node->selected == 1 ? UIA_E_INVALIDOPERATION : S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_ToggleState(ToggleState *out) override {
        if (!out) return E_POINTER;
        Snapshot s(*window, id); if (!s.node) return UIA_E_ELEMENTNOTAVAILABLE;
        if (s.node->toggle < 0) return UIA_E_NOTSUPPORTED;
        *out = static_cast<ToggleState>(s.node->toggle); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE SetValue(LPCWSTR value) override {
        return value ? enqueue(RUNE_UIA_SET_TEXT, UIA_ValuePatternId, value) : E_INVALIDARG;
    }
    HRESULT STDMETHODCALLTYPE SetValue(double value) override { return enqueue(RUNE_UIA_SET_NUMBER, UIA_RangeValuePatternId, L"", value); }
    HRESULT STDMETHODCALLTYPE get_Value(BSTR *out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        Snapshot s(*window, id); if (!s.node) return UIA_E_ELEMENTNOTAVAILABLE;
        if (!supports(*s.node, UIA_ValuePatternId)) return UIA_E_NOTSUPPORTED;
        if (s.node->secure) return E_ACCESSDENIED;
        *out = SysAllocStringLen(s.node->valueText().data(), static_cast<UINT>(s.node->valueText().size()));
        return *out ? S_OK : E_OUTOFMEMORY;
    }
    HRESULT STDMETHODCALLTYPE get_IsReadOnly(BOOL *out) override {
        if (!out) return E_POINTER;
        Snapshot s(*window, id); if (!s.node) return UIA_E_ELEMENTNOTAVAILABLE;
        *out = !s.node->settable || s.node->readOnly;
        return S_OK;
    }
    HRESULT range(double *out, double Node::*member) {
        if (!out) return E_POINTER;
        Snapshot s(*window, id); if (!s.node) return UIA_E_ELEMENTNOTAVAILABLE;
        if (!s.node->hasRange) return UIA_E_NOTSUPPORTED;
        *out = s.node->*member;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_Value(double *out) override { return range(out, &Node::number); }
    HRESULT STDMETHODCALLTYPE get_Minimum(double *out) override { return range(out, &Node::minimum); }
    HRESULT STDMETHODCALLTYPE get_Maximum(double *out) override { return range(out, &Node::maximum); }
    HRESULT STDMETHODCALLTYPE get_SmallChange(double *out) override { return range(out, &Node::step); }
    HRESULT STDMETHODCALLTYPE get_LargeChange(double *out) override { return range(out, &Node::step); }
};
} // namespace

struct RuneUiaHost {
    std::shared_ptr<Window> window;
    std::shared_ptr<Tree> staging;
    Provider *root;
    HWND attached; // Owned by the window thread until WM_NCDESTROY or explicit detach.
    bool initializedCOM;
    explicit RuneUiaHost(HWND hwnd) : window(std::make_shared<Window>(hwnd)), root(new Provider(window, 0)), attached(hwnd),
        initializedCOM(SUCCEEDED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) {}
    ~RuneUiaHost() {
        root->Release();
        if (initializedCOM) CoUninitialize();
    }
};

namespace {
const UINT_PTR subclassID = 0x52554158;
LRESULT CALLBACK accessibilityProc(HWND hwnd, UINT msg, WPARAM w, LPARAM l, UINT_PTR, DWORD_PTR data) {
    auto *host = reinterpret_cast<RuneUiaHost *>(data);
    if (msg == WM_GETOBJECT) {
        {
            std::lock_guard<std::mutex> lock(host->window->lock);
            if (!host->window->hwnd) return 0;
            if (!host->window->active) {
                host->window->active = true;
                InvalidateRect(hwnd, nullptr, FALSE);
            }
        }
        // UI Automation may send another WM_GETOBJECT during this call.
        return UiaReturnRawElementProvider(hwnd, w, l, host->root);
    }
    if (msg == WM_SETFOCUS || msg == WM_KILLFOCUS) {
        std::lock_guard<std::mutex> lock(host->window->lock);
        host->window->focusChanged = true;
        if (host->window->active) InvalidateRect(hwnd, nullptr, FALSE);
    }
    if (msg == WM_DESTROY) {
        bool active;
        {
            std::lock_guard<std::mutex> lock(host->window->lock);
            active = host->window->active;
            host->window->hwnd = nullptr;
        }
        // Release UIA's map of providers that raised events while this HWND was alive.
        if (active) UiaReturnRawElementProvider(hwnd, 0, 0, nullptr);
    }
    if (msg == WM_NCDESTROY) {
        host->attached = nullptr;
        RemoveWindowSubclass(hwnd, accessibilityProc, subclassID);
    }
    return DefSubclassProc(hwnd, msg, w, l);
}
void raiseProperty(Provider *provider, PROPERTYID id, VARIANT before, VARIANT after) {
    UiaRaiseAutomationPropertyChangedEvent(provider, id, before, after);
    VariantClear(&before);
    VariantClear(&after);
}
void raiseChanges(const std::shared_ptr<Window> &window, const Tree &before, const Tree &after, bool focusChanged) {
    bool structureChanged = before.nodes.size() != after.nodes.size();
    bool moved = false;
    for (const auto &pair : after.nodes) {
        const auto prior = before.nodes.find(pair.first);
        if (prior == before.nodes.end()) {
            structureChanged = true;
            continue;
        }
        const Node &old = prior->second, &node = pair.second;
        if (node.children != old.children || node.role != old.role ||
            node.selectionContainer != old.selectionContainer || node.pressable != old.pressable ||
            node.hasRange != old.hasRange || (node.expanded >= 0) != (old.expanded >= 0)) structureChanged = true;
        if (old.rect.left != node.rect.left || old.rect.top != node.rect.top ||
            old.rect.width != node.rect.width || old.rect.height != node.rect.height) moved = true;
        const bool changedName = old.name != node.name;
        const bool changedValue = !node.secure && node.valueText() != old.valueText();
        const bool changedTextSelection = node.field && (old.anchor != node.anchor || old.caret != node.caret);
        const bool changedProtection = old.secure != node.secure;
        const bool changedTextPattern = bool(old.field) != bool(node.field);
        const bool changedRange = node.hasRange && old.number != node.number;
        const bool changedToggle = node.toggle >= 0 && node.toggle != old.toggle;
        const bool changedSelection = node.selectionContainer >= 0 && old.selected != node.selected;
        const bool changedExpansion = node.expanded >= 0 && old.expanded != node.expanded;
        const bool changedEnabled = node.disabled != old.disabled;
        if (!(changedName || changedValue || changedRange || changedToggle || changedSelection || changedExpansion ||
              changedEnabled || changedTextSelection || changedProtection || changedTextPattern)) continue;
        Provider *p = new Provider(window, node.id);
        if (changedName) {
            VARIANT a{}, b{};
            stringProperty(&a, old.name); stringProperty(&b, node.name);
            raiseProperty(p, UIA_NamePropertyId, a, b);
        }
        if (changedValue && node.control == UIA_EditControlTypeId) {
            VARIANT a{}, b{};
            stringProperty(&a, old.valueText()); stringProperty(&b, node.valueText());
            raiseProperty(p, UIA_ValueValuePropertyId, a, b);
            if (node.field) UiaRaiseAutomationEvent(p, UIA_Text_TextChangedEventId);
        }
        if (changedTextSelection) UiaRaiseAutomationEvent(p, UIA_Text_TextSelectionChangedEventId);
        if (changedProtection) {
            VARIANT a{}, b{};
            boolProperty(&a, old.secure); boolProperty(&b, node.secure);
            raiseProperty(p, UIA_IsPasswordPropertyId, a, b);
        }
        if (changedTextPattern) {
            for (PROPERTYID property : {UIA_IsTextPatternAvailablePropertyId, UIA_IsTextPattern2AvailablePropertyId}) {
                VARIANT a{}, b{};
                boolProperty(&a, bool(old.field)); boolProperty(&b, bool(node.field));
                raiseProperty(p, property, a, b);
            }
        }
        if (changedRange) {
            VARIANT a{}, b{};
            a.vt = b.vt = VT_R8; a.dblVal = old.number; b.dblVal = node.number;
            raiseProperty(p, UIA_RangeValueValuePropertyId, a, b);
        }
        if (changedToggle) {
            VARIANT a{}, b{};
            intProperty(&a, old.toggle); intProperty(&b, node.toggle);
            raiseProperty(p, UIA_ToggleToggleStatePropertyId, a, b);
        }
        if (changedEnabled) {
            VARIANT a{}, b{};
            boolProperty(&a, !old.disabled); boolProperty(&b, !node.disabled);
            raiseProperty(p, UIA_IsEnabledPropertyId, a, b);
        }
        if (changedSelection) {
            VARIANT a{}, b{};
            boolProperty(&a, old.selected == 1); boolProperty(&b, node.selected == 1);
            raiseProperty(p, UIA_SelectionItemIsSelectedPropertyId, a, b);
            if (node.selected == 1) UiaRaiseAutomationEvent(p, UIA_SelectionItem_ElementSelectedEventId);
        }
        if (changedExpansion) {
            VARIANT a{}, b{};
            intProperty(&a, old.expanded ? ExpandCollapseState_Expanded : ExpandCollapseState_Collapsed);
            intProperty(&b, node.expanded ? ExpandCollapseState_Expanded : ExpandCollapseState_Collapsed);
            raiseProperty(p, UIA_ExpandCollapseExpandCollapseStatePropertyId, a, b);
        }
        if (node.live && (changedName || changedValue)) UiaRaiseAutomationEvent(p, UIA_LiveRegionChangedEventId);
        p->Release();
    }
    if (structureChanged) {
        Provider *p = new Provider(window, 0);
        UiaRaiseStructureChangedEvent(p, StructureChangeType_ChildrenInvalidated, nullptr, 0);
        p->Release();
    }
    if (moved) {
        Snapshot s(*window, 0);
        if (s.node) NotifyWinEvent(EVENT_OBJECT_LOCATIONCHANGE, s.hwnd, OBJID_CLIENT, CHILDID_SELF);
    }
    if (focusChanged || after.focused != before.focused) {
        Snapshot s(*window, after.focused);
        if (s.node) {
            Provider *p = new Provider(window, after.focused);
            if (GetForegroundWindow() == s.hwnd) {
                UiaRaiseAutomationEvent(p, UIA_AutomationFocusChangedEventId);
            } else if (focusChanged) {
                VARIANT a{}, b{};
                boolProperty(&a, true); boolProperty(&b, false);
                raiseProperty(p, UIA_HasKeyboardFocusPropertyId, a, b);
            }
            p->Release();
        }
    }
}
} // namespace

RuneUiaHost *rune_uia_attach(void *raw) {
    HWND hwnd = static_cast<HWND>(raw);
    if (!hwnd) return nullptr;
    std::unique_ptr<RuneUiaHost> host(new RuneUiaHost(hwnd));
    if (!SetWindowSubclass(hwnd, accessibilityProc, subclassID, reinterpret_cast<DWORD_PTR>(host.get()))) return nullptr;
    return host.release();
}
void rune_uia_detach(RuneUiaHost *host) {
    if (!host) return;
    HWND hwnd;
    bool active;
    {
        std::lock_guard<std::mutex> lock(host->window->lock);
        hwnd = host->window->hwnd;
        host->window->hwnd = nullptr;
        active = host->window->active;
    }
    if (host->attached) RemoveWindowSubclass(host->attached, accessibilityProc, subclassID);
    if (hwnd && active) UiaReturnRawElementProvider(hwnd, 0, 0, nullptr);
    if (active) UiaDisconnectProvider(host->root);
    delete host;
}
int rune_uia_active(const RuneUiaHost *host) {
    if (!host) return 0;
    std::lock_guard<std::mutex> lock(host->window->lock);
    return host->window->active;
}
void rune_uia_begin(RuneUiaHost *host, const char *title) {
    host->staging = std::make_shared<Tree>();
    Node root;
    root.name = wide(title);
    host->staging->nodes.emplace(0, std::move(root));
}
void rune_uia_add(RuneUiaHost *host, RuneUiaNode info, const char *key, const char *role,
                  const char *name, const char *help, const char *value, const char *shortcut) {
    auto &tree = *host->staging;
    if (info.id <= 0 || tree.nodes.count(info.id)) return;
    auto parent = tree.nodes.find(info.parent);
    if (parent == tree.nodes.end()) return;
    Node n;
    n.id = info.id; n.parent = info.parent; n.control = controlType(role);
    n.key = wide(key); n.role = wide(role); n.name = wide(name);
    n.help = wide(help); n.shortcut = wide(shortcut);
    n.secure = info.secure || n.role == L"password-input"; if (!n.secure) n.value = wide(value);
    n.focusable = info.focusable; n.disabled = info.disabled; n.readOnly = info.read_only;
    n.pressable = info.pressable; n.settable = info.settable; n.toggle = info.toggle; n.live = info.live;
    n.selected = info.selected; n.expanded = info.expanded;
    n.level = info.level; n.position = info.position; n.size = info.size_of_set;
    n.hasRange = info.has_range; n.minimum = info.minimum; n.maximum = info.maximum;
    n.step = info.step; n.number = info.number;
    n.rect = {info.x, info.y, info.width, info.height};
    if (info.focused) tree.focused = n.id;
    n.nearestSelector = parent->second.nearestSelector;
    if (n.role == L"tablist" || n.role == L"radiogroup") {
        n.nearestSelector = n.id;
    } else if (n.nearestSelector >= 0) {
        Node &selector = tree.nodes.at(n.nearestSelector);
        // Tab strips and radio groups have a well-defined single-selection contract.
        // Rune list/grid/tree controls can implement app-defined multi-selection.
        if ((selector.role == L"tablist" && n.role == L"tab") ||
            (selector.role == L"radiogroup" && n.role == L"radio")) {
            n.selectionContainer = selector.id;
            selector.selectableItems.push_back(n.id);
        }
    }
    parent->second.children.push_back(n.id);
    tree.nodes.emplace(n.id, std::move(n));
}
void rune_uia_text_model(RuneUiaHost *host, int32_t id, int32_t anchor, int32_t focus,
                         const uint16_t *text, int32_t length, const int32_t *graphemes, int32_t count) {
    if (!host || !host->staging || !graphemes || count < 1 || length < 0 || (length && !text)) return;
    auto found = host->staging->nodes.find(id);
    if (found == host->staging->nodes.end()) return;
    auto &n = found->second;
    if (n.secure || n.control != UIA_EditControlTypeId || n.field) return;
    if (graphemes[0] != 0 || graphemes[count - 1] != length) return;
    for (int i = 1; i < count; ++i) if (graphemes[i] <= graphemes[i - 1]) return;
    auto field = std::make_shared<RuneUiaTextContent>();
    n.value.clear();
    if (length) field->text.assign(text, text + length);
    field->graphemes.assign(graphemes, graphemes + count);
    n.anchor = std::max(0, std::min(anchor, length));
    n.caret = std::max(0, std::min(focus, length));
    n.field = std::move(field);
}
void rune_uia_text_geometry(RuneUiaHost *host, int32_t id, const RuneUiaTextCell *cells, int32_t count) {
    if (!host || !host->staging || !cells || count <= 0) return;
    auto found = host->staging->nodes.find(id);
    if (found == host->staging->nodes.end() || !found->second.field) return;
    found->second.field->cells.assign(cells, cells + count);
}
void rune_uia_commit(RuneUiaHost *host) {
    if (!host->staging) return;
    const auto window = host->window;
    std::shared_ptr<const Tree> before, after = std::move(host->staging);
    bool active, focusChanged;
    {
        std::lock_guard<std::mutex> lock(window->lock);
        before = std::move(window->tree);
        window->tree = after;
        active = window->active && window->hwnd;
        focusChanged = window->focusChanged;
        window->focusChanged = false;
    }
    if (active && UiaClientsAreListening()) raiseChanges(window, *before, *after, focusChanged);
}
int rune_uia_pop(RuneUiaHost *host, int32_t *id, int32_t *action, char **text, double *number) {
    Action next;
    {
        std::lock_guard<std::mutex> lock(host->window->lock);
        if (host->window->actions.empty() || host->window->actions.front().selectionText) return 0;
        next = std::move(host->window->actions.front());
        host->window->actions.pop_front();
    }
    *id = next.id; *action = next.kind; *number = next.number; *text = nullptr;
    if (next.kind == RUNE_UIA_FOCUS) {
        Snapshot s(*host->window, next.id);
        if (s.node) SetFocus(s.hwnd);
    }
    if (next.kind == RUNE_UIA_SET_TEXT) {
        const int bytes = WideCharToMultiByte(CP_UTF8, 0, next.text.c_str(), -1, nullptr, 0, nullptr, nullptr);
        *text = static_cast<char *>(malloc(bytes));
        if (*text) WideCharToMultiByte(CP_UTF8, 0, next.text.c_str(), -1, *text, bytes, nullptr, nullptr);
    }
    return 1;
}
int rune_uia_pop_text_selection(RuneUiaHost *host, int32_t *id, int32_t *start, int32_t *end, char **expected, int32_t *byteCount) {
    Action next;
    {
        std::lock_guard<std::mutex> lock(host->window->lock);
        if (host->window->actions.empty() || !host->window->actions.front().selectionText) return 0;
        next = std::move(host->window->actions.front());
        host->window->actions.pop_front();
    }
    *id = next.id; *start = next.start; *end = next.end;
    const auto &model = next.selectionText->text;
    const int length = static_cast<int>(model.size());
    *byteCount = length ? WideCharToMultiByte(CP_UTF8, 0, model.data(), length, nullptr, 0, nullptr, nullptr) : 0;
    *expected = static_cast<char *>(malloc(static_cast<size_t>(*byteCount) + 1));
    if (*expected) {
        if (*byteCount) WideCharToMultiByte(CP_UTF8, 0, model.data(), length, *expected, *byteCount, nullptr, nullptr);
        (*expected)[*byteCount] = 0;
    }
    return 1;
}
void rune_uia_free_text(char *text) { free(text); }
#endif
