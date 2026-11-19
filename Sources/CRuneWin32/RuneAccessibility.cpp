#include "RuneAccessibility.h"
#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#include <commctrl.h>
#include <oleauto.h>
#include <uiautomation.h>
#include "RuneTextProvider.hpp"
#include "WindowRedraw.h"

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
    bool focusable = false, disabled = false, secure = false, readOnly = true, modal = false;
    bool pressable = false, settable = false, hasRange = false, scrollItem = false;
    int toggle = -1, live = 0, selected = -1, expanded = -1;
    int level = 0, position = 0, size = 0;
    double minimum = 0, maximum = 0, number = 0, step = 0;
    int selectionContainer = -1;
    std::vector<int> children;
    int anchor = 0, caret = 0;
    std::shared_ptr<RuneUiaTextContent> field;
    const std::wstring &valueText() const { return field ? field->text : value; }
    bool isDialog() const { return role == L"dialog" || role == L"alertdialog"; }
    bool isSelector() const {
        return role == L"combobox" || role == L"grid" || role == L"listbox" ||
               role == L"menu" || role == L"menubar" || role == L"radiogroup" ||
               role == L"tablist" || role == L"toolbar" || role == L"tree" || role == L"treegrid";
    }
    bool isRadio() const { return role == L"radio" || role == L"menu-item-radio"; }
    bool supportsSelectionItem() const {
        if (isRadio()) return toggle == ToggleState_Off || toggle == ToggleState_On;
        return role == L"gridcell" || (selected >= 0 &&
            (role == L"listitem" || role == L"option" || role == L"tab" || role == L"treeitem"));
    }
    bool isSelected() const { return isRadio() ? toggle == ToggleState_On : selected == 1; }
    // AccessKit's container traversal stops at item-like descendants. Cells and rows are transparent here.
    bool isItemLike() const {
        return isRadio() || role == L"listitem" || role == L"menuitem" || role == L"tab" ||
               role == L"menu-item-check-box" || role == L"treeitem" || role == L"option";
    }
    int headingLevel() const { return role == L"heading" ? HeadingLevel1 + std::min(level > 0 ? level : 2, 9) - 1 : 0; }
    const wchar_t *customLandmark() const {
        if (role == L"banner") return L"banner";
        if (role == L"complementary") return L"complementary";
        if (role == L"contentinfo") return L"content information";
        if (role == L"region" && !name.empty()) return L"region";
        return L"";
    }
    int landmarkType() const {
        if (role == L"main") return UIA_MainLandmarkTypeId;
        if (role == L"navigation") return UIA_NavigationLandmarkTypeId;
        if (role == L"search") return UIA_SearchLandmarkTypeId;
        if (role == L"form" && !name.empty()) return UIA_FormLandmarkTypeId;
        return *customLandmark() ? UIA_CustomLandmarkTypeId : 0;
    }
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
        {"scroll-view", UIA_PaneControlTypeId},
        {"text", UIA_TextControlTypeId}, {"heading", UIA_TextControlTypeId},
        {"button", UIA_ButtonControlTypeId}, {"checkbox", UIA_CheckBoxControlTypeId},
        {"switch", UIA_ButtonControlTypeId}, {"radio", UIA_RadioButtonControlTypeId},
        {"tab", UIA_TabItemControlTypeId}, {"tablist", UIA_TabControlTypeId},
        {"textbox", UIA_EditControlTypeId}, {"searchbox", UIA_EditControlTypeId}, {"password-input", UIA_EditControlTypeId},
        {"multiline-text-input", UIA_EditControlTypeId}, {"slider", UIA_SliderControlTypeId},
        {"spinbutton", UIA_SpinnerControlTypeId}, {"article", UIA_GroupControlTypeId},
        {"terminal", UIA_DocumentControlTypeId},
        {"progressbar", UIA_ProgressBarControlTypeId}, {"listitem", UIA_ListItemControlTypeId},
        {"option", UIA_ListItemControlTypeId}, {"list", UIA_ListControlTypeId},
        {"listbox", UIA_ListControlTypeId}, {"dialog", UIA_WindowControlTypeId},
        {"alertdialog", UIA_WindowControlTypeId}, {"alert", UIA_TextControlTypeId},
        {"menubar", UIA_MenuBarControlTypeId}, {"menu", UIA_MenuControlTypeId}, {"menuitem", UIA_MenuItemControlTypeId},
        {"menu-item-check-box", UIA_CheckBoxControlTypeId}, {"menu-item-radio", UIA_RadioButtonControlTypeId}, {"img", UIA_ImageControlTypeId},
        {"icon", UIA_ImageControlTypeId}, {"separator", UIA_SeparatorControlTypeId},
        {"combobox", UIA_ComboBoxControlTypeId}, {"tree", UIA_TreeControlTypeId},
        {"treeitem", UIA_TreeItemControlTypeId}, {"grid", UIA_DataGridControlTypeId},
        {"treegrid", UIA_DataGridControlTypeId},
        {"row", UIA_DataItemControlTypeId}, {"gridcell", UIA_DataItemControlTypeId},
        {"cell", UIA_DataItemControlTypeId}, {"rowheader", UIA_DataItemControlTypeId},
        {"columnheader", UIA_DataItemControlTypeId}, {"tooltip", UIA_ToolTipControlTypeId},
        {"link", UIA_HyperlinkControlTypeId}, {"toolbar", UIA_ToolBarControlTypeId},
        {"splitter", UIA_SeparatorControlTypeId}, {"status", UIA_StatusBarControlTypeId},
        {"table", UIA_TableControlTypeId}, {"mark", UIA_TextControlTypeId},
        {"code", UIA_TextControlTypeId}, {"blockquote", UIA_GroupControlTypeId}
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
    if (pattern == UIA_WindowPatternId) return n.isDialog();
    if (pattern == UIA_ScrollItemPatternId) return n.scrollItem;
    if (pattern == UIA_InvokePatternId) return n.pressable && n.toggle < 0 && n.selected < 0 && n.expanded < 0 &&
        n.control != UIA_EditControlTypeId && n.role != L"treeitem" && n.role != L"combobox";
    if (pattern == UIA_TogglePatternId) return n.toggle >= 0 && !n.supportsSelectionItem();
    if (pattern == UIA_ExpandCollapsePatternId) return n.expanded >= 0 && n.pressable;
    if (pattern == UIA_SelectionPatternId) return n.isSelector();
    if (pattern == UIA_SelectionItemPatternId) return n.supportsSelectionItem();
    if (pattern == UIA_TextPatternId || pattern == UIA_TextPattern2Id) return n.field && !n.secure;
    if (pattern == UIA_ValuePatternId) return n.control == UIA_EditControlTypeId;
    if (pattern == UIA_RangeValuePatternId) return n.hasRange;
    return false;
}

class Provider final : public IRawElementProviderSimple, public IRawElementProviderFragment,
    public IRawElementProviderFragmentRoot, public IInvokeProvider, public IToggleProvider,
    public IValueProvider, public IRangeValueProvider, public IExpandCollapseProvider,
    public ISelectionProvider, public ISelectionItemProvider, public IScrollItemProvider,
    public IWindowProvider, public RuneUiaTextSource {
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
        else if (iid == __uuidof(IScrollItemProvider)) *out = static_cast<IScrollItemProvider *>(this);
        else if (iid == __uuidof(IWindowProvider)) *out = static_cast<IWindowProvider *>(this);
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
        if (pattern == UIA_ScrollItemPatternId) *out = static_cast<IScrollItemProvider *>(this);
        if (pattern == UIA_WindowPatternId) *out = static_cast<IWindowProvider *>(this);
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
        case UIA_IsDialogPropertyId: return boolProperty(out, n.isDialog());
        case UIA_WindowIsModalPropertyId: return n.isDialog() ? boolProperty(out, n.modal) : S_OK;
        case UIA_SelectionItemIsSelectedPropertyId: return n.supportsSelectionItem() ? boolProperty(out, n.isSelected()) : S_OK;
        case UIA_SelectionIsSelectionRequiredPropertyId:
        case UIA_SelectionCanSelectMultiplePropertyId: return n.isSelector() ? boolProperty(out, false) : S_OK;
        case UIA_OrientationPropertyId: return intProperty(out, n.role == L"tablist" ? OrientationType_Horizontal :
            n.role == L"listbox" ? OrientationType_Vertical : OrientationType_None);
        case UIA_NamePropertyId: return stringProperty(out, n.name);
        case UIA_AutomationIdPropertyId: return stringProperty(out, n.key);
        case UIA_HelpTextPropertyId: return stringProperty(out, n.help);
        case UIA_AriaRolePropertyId:
            if (n.role == L"scroll-view") return stringProperty(out, L"region");
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
        case UIA_HeadingLevelPropertyId: return n.headingLevel() ? intProperty(out, n.headingLevel()) : S_OK;
        case UIA_LandmarkTypePropertyId: return n.landmarkType() ? intProperty(out, n.landmarkType()) : S_OK;
        case UIA_LocalizedLandmarkTypePropertyId:
            return *n.customLandmark() ? stringProperty(out, n.customLandmark()) : S_OK;
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
        if (!rune_request_window_paint(window->hwnd, TRUE)) {
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
        // UIA also asks for the identity of an item in a removal event after the new tree is published.
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
        if (n.disabled && kind != RUNE_UIA_SCROLL_INTO_VIEW) return UIA_E_ELEMENTNOTENABLED;
        if (pattern && !supports(n, pattern)) return UIA_E_NOTSUPPORTED;
        if (kind == RUNE_UIA_SELECT && n.isSelected() == (number != 0)) return S_OK;
        if (kind == RUNE_UIA_PRESS && !n.pressable) return UIA_E_NOTSUPPORTED;
        if (kind == RUNE_UIA_FOCUS && !n.focusable) return UIA_E_NOTSUPPORTED;
        if ((kind == RUNE_UIA_SET_TEXT || kind == RUNE_UIA_SET_NUMBER) && (!n.settable || n.readOnly)) return UIA_E_NOTSUPPORTED;
        window->actions.push_back({id, kind, text, number, 0, 0, nullptr});
        if (!rune_request_window_paint(window->hwnd, TRUE)) {
            window->actions.pop_back();
            return UIA_E_ELEMENTNOTAVAILABLE;
        }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE SetFocus() override { return enqueue(RUNE_UIA_FOCUS, 0); }
    HRESULT STDMETHODCALLTYPE ScrollIntoView() override { return enqueue(RUNE_UIA_SCROLL_INTO_VIEW, UIA_ScrollItemPatternId); }
    HRESULT scrollTextIntoView() override { return enqueue(RUNE_UIA_SCROLL_INTO_VIEW, UIA_TextPatternId); }
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
        std::vector<int> pending(s.node->children.rbegin(), s.node->children.rend());
        while (!pending.empty()) {
            const Node &item = s.tree->nodes.at(pending.back());
            pending.pop_back();
            if (item.isItemLike()) {
                if (item.selected == 1) selected.push_back(item.id);
            } else {
                pending.insert(pending.end(), item.children.rbegin(), item.children.rend());
            }
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
        Snapshot s(*window, id);
        if (!s.node) return UIA_E_ELEMENTNOTAVAILABLE;
        *out = FALSE;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_IsSelectionRequired(BOOL *out) override {
        // Rune does not set either AccessKit container flag.
        return get_CanSelectMultiple(out);
    }
    HRESULT STDMETHODCALLTYPE get_IsSelected(BOOL *out) override {
        if (!out) return E_POINTER;
        Snapshot s(*window, id);
        if (!s.node) return UIA_E_ELEMENTNOTAVAILABLE;
        *out = s.node->isSelected();
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_SelectionContainer(IRawElementProviderSimple **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        Snapshot s(*window, id);
        if (!s.node) return UIA_E_ELEMENTNOTAVAILABLE;
        if (s.node->selectionContainer < 0) return E_FAIL;
        *out = new Provider(window, s.node->selectionContainer);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Select() override { return enqueue(RUNE_UIA_SELECT, UIA_SelectionItemPatternId, L"", 1); }
    HRESULT STDMETHODCALLTYPE AddToSelection() override { return Select(); }
    HRESULT STDMETHODCALLTYPE RemoveFromSelection() override { return enqueue(RUNE_UIA_SELECT, UIA_SelectionItemPatternId); }
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
    HRESULT STDMETHODCALLTYPE get_IsModal(BOOL *out) override {
        if (!out) return E_POINTER;
        Snapshot s(*window, id);
        if (!s.node) return UIA_E_ELEMENTNOTAVAILABLE;
        if (!s.node->isDialog()) return UIA_E_NOTSUPPORTED;
        *out = s.node->modal;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_WindowInteractionState(WindowInteractionState *out) override {
        if (!out) return E_POINTER;
        *out = WindowInteractionState_ReadyForUserInteraction;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE SetVisualState(WindowVisualState) override { return UIA_E_INVALIDOPERATION; }
    HRESULT STDMETHODCALLTYPE Close() override { return UIA_E_NOTSUPPORTED; }
    HRESULT STDMETHODCALLTYPE WaitForInputIdle(int, BOOL *) override { return UIA_E_NOTSUPPORTED; }
    HRESULT STDMETHODCALLTYPE get_CanMaximize(BOOL *) override { return UIA_E_NOTSUPPORTED; }
    HRESULT STDMETHODCALLTYPE get_CanMinimize(BOOL *) override { return UIA_E_NOTSUPPORTED; }
    HRESULT STDMETHODCALLTYPE get_IsTopmost(BOOL *) override { return UIA_E_NOTSUPPORTED; }
    HRESULT STDMETHODCALLTYPE get_WindowVisualState(WindowVisualState *) override { return UIA_E_NOTSUPPORTED; }
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
    std::shared_ptr<const Tree> beforeActivation;
    Provider *root;
    HWND attached; // Owned by the window thread until WM_NCDESTROY or explicit detach.
    bool initializedCOM;
    bool published = false;
    void *activationContext = nullptr;
    void (*activate)(void *) = nullptr;
    bool answeringDemand = false;
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
        // Senders may either sign-extend or zero-extend the 32-bit MSAA object ID.
        const int32_t object = static_cast<int32_t>(l);
        if (object < 0 && object != UiaRootObjectId && object != OBJID_CLIENT)
            return DefSubclassProc(hwnd, msg, w, l);
        bool first;
        {
            std::lock_guard<std::mutex> lock(host->window->lock);
            if (!host->window->hwnd) return 0;
            first = !host->window->active;
            host->window->active = true;
        }
        if (host->activate && (first || !host->published) && !host->answeringDemand) {
            host->answeringDemand = true;
            host->activate(host->activationContext);
            host->answeringDemand = false;
        }
        if (first) {
            // Complete deferred layout and deliver activation events after responding to UIA.
            rune_request_window_paint(hwnd, TRUE);
        }
        // UI Automation may send another WM_GETOBJECT during this call.
        return UiaReturnRawElementProvider(hwnd, w, l, host->root);
    }
    if (msg == WM_SETFOCUS || msg == WM_KILLFOCUS) {
        std::lock_guard<std::mutex> lock(host->window->lock);
        host->window->focusChanged = true;
        if (host->window->active) rune_request_window_paint(hwnd, TRUE);
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
struct SelectionChanges {
    std::vector<int> added, removed;
};
using SelectionChangesByContainer = std::unordered_map<int, SelectionChanges>;

void raiseSelectionChanges(const std::shared_ptr<Window> &window, const Tree &after,
                           const SelectionChangesByContainer &changes) {
    auto raiseItem = [&](int id, bool selected, EVENTID event) {
        Provider *item = new Provider(window, id);
        if (event) UiaRaiseAutomationEvent(item, event);
        VARIANT before{}, now{};
        boolProperty(&before, !selected); boolProperty(&now, selected);
        raiseProperty(item, UIA_SelectionItemIsSelectedPropertyId, before, now);
        item->Release();
    };
    for (const auto &group : changes) {
        const auto found = after.nodes.find(group.first);
        if (found == after.nodes.end()) continue;
        const Node &node = found->second;
        const auto &items = group.second;
        if (node.isSelector()) {
            // AccessKit coalesces by the raw selected state of direct, exposed children.
            // Checked radios have a SelectionItem state, but no raw selected state.
            int onlySelected = -1;
            for (const int child : node.children) {
                if (after.nodes.at(child).selected != 1) continue;
                if (onlySelected >= 0) { onlySelected = -1; break; }
                onlySelected = child;
            }
            if (onlySelected >= 0) {
                raiseItem(onlySelected, true, UIA_SelectionItem_ElementSelectedEventId);
                for (const int removed : items.removed) raiseItem(removed, false, 0);
                continue;
            }
            if (items.added.size() + items.removed.size() > 20) {
                Provider *container = new Provider(window, node.id);
                UiaRaiseAutomationEvent(container, UIA_Selection_InvalidatedEventId);
                container->Release();
                continue;
            }
        }
        // Rune does not set AccessKit's multiselectable flag on its containers.
        for (const int added : items.added) raiseItem(added, true, UIA_SelectionItem_ElementSelectedEventId);
        for (const int removed : items.removed) raiseItem(removed, false, UIA_SelectionItem_ElementRemovedFromSelectionEventId);
    }
}

void raiseChanges(const std::shared_ptr<Window> &window, const Tree &before, const Tree &after, bool focusChanged, bool uiaListening) {
    bool structureChanged = before.nodes.size() != after.nodes.size();
    bool moved = false;
    size_t addedNodes = 0;
    SelectionChangesByContainer selections;
    auto recordSelection = [&](const Node &item, bool selected) {
        auto &changes = selections[item.selectionContainer >= 0 ? item.selectionContainer : item.id];
        (selected ? changes.added : changes.removed).push_back(item.id);
    };
    for (const auto &pair : after.nodes) {
        const auto prior = before.nodes.find(pair.first);
        if (prior == before.nodes.end()) {
            structureChanged = true;
            ++addedNodes;
            if (uiaListening && pair.second.supportsSelectionItem() && pair.second.isSelected())
                recordSelection(pair.second, true);
            continue;
        }
        const Node &old = prior->second, &node = pair.second;
        const bool changedRole = node.role != old.role;
        if (node.children != old.children || changedRole ||
            node.selectionContainer != old.selectionContainer || node.pressable != old.pressable ||
            node.hasRange != old.hasRange || node.scrollItem != old.scrollItem ||
            (node.expanded >= 0) != (old.expanded >= 0)) structureChanged = true;
        if (old.rect.left != node.rect.left || old.rect.top != node.rect.top ||
            old.rect.width != node.rect.width || old.rect.height != node.rect.height) moved = true;
        if (!uiaListening) continue;
        const bool changedDialog = changedRole && old.isDialog() != node.isDialog();
        const bool changedModal = old.modal != node.modal && old.isDialog() && node.isDialog();
        const bool changedName = old.name != node.name;
        const bool changedHeading = (changedRole || old.level != node.level) && old.headingLevel() != node.headingLevel();
        const bool landmarkMayChange = changedRole || old.name.empty() != node.name.empty();
        const bool changedLandmark = landmarkMayChange && old.landmarkType() != node.landmarkType();
        const bool changedLandmarkName = landmarkMayChange && wcscmp(old.customLandmark(), node.customLandmark()) != 0;
        const bool changedValue = !node.secure && node.valueText() != old.valueText();
        const bool changedTextSelection = node.field && (old.anchor != node.anchor || old.caret != node.caret);
        const bool changedProtection = old.secure != node.secure;
        const bool changedTextPattern = bool(old.field) != bool(node.field);
        const bool changedRange = node.hasRange && old.number != node.number;
        const bool changedToggle = node.toggle != old.toggle && supports(old, UIA_TogglePatternId) && supports(node, UIA_TogglePatternId);
        if ((changedRole || old.selected != node.selected || old.toggle != node.toggle) &&
            node.supportsSelectionItem() && old.isSelected() != node.isSelected()) {
            recordSelection(node, node.isSelected());
        }
        const bool changedExpansion = node.expanded >= 0 && old.expanded != node.expanded;
        const bool changedEnabled = node.disabled != old.disabled;
        if (!(changedName || changedValue || changedRange || changedToggle || changedExpansion ||
              changedEnabled || changedTextSelection || changedProtection || changedTextPattern ||
              changedHeading || changedLandmark || changedLandmarkName || changedDialog || changedModal)) continue;
        Provider *p = new Provider(window, node.id);
        if (changedDialog) {
            VARIANT a{}, b{};
            boolProperty(&a, old.isDialog()); boolProperty(&b, node.isDialog());
            raiseProperty(p, UIA_IsDialogPropertyId, a, b);
            raiseProperty(p, UIA_IsWindowPatternAvailablePropertyId, a, b);
        }
        if (changedModal) {
            VARIANT a{}, b{};
            boolProperty(&a, old.modal); boolProperty(&b, node.modal);
            raiseProperty(p, UIA_WindowIsModalPropertyId, a, b);
        }
        if (changedHeading) {
            VARIANT a{}, b{};
            if (old.headingLevel()) intProperty(&a, old.headingLevel());
            if (node.headingLevel()) intProperty(&b, node.headingLevel());
            raiseProperty(p, UIA_HeadingLevelPropertyId, a, b);
        }
        if (changedLandmark) {
            VARIANT a{}, b{};
            if (old.landmarkType()) intProperty(&a, old.landmarkType());
            if (node.landmarkType()) intProperty(&b, node.landmarkType());
            raiseProperty(p, UIA_LandmarkTypePropertyId, a, b);
        }
        if (changedLandmarkName) {
            VARIANT a{}, b{};
            if (*old.customLandmark()) stringProperty(&a, old.customLandmark());
            if (*node.customLandmark()) stringProperty(&b, node.customLandmark());
            raiseProperty(p, UIA_LocalizedLandmarkTypePropertyId, a, b);
        }
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
        if (uiaListening) {
            Provider *p = new Provider(window, 0);
            UiaRaiseStructureChangedEvent(p, StructureChangeType_ChildrenInvalidated, nullptr, 0);
            p->Release();
        }
        Snapshot s(*window, 0);
        if (s.node) NotifyWinEvent(EVENT_OBJECT_REORDER, s.hwnd, OBJID_CLIENT, CHILDID_SELF);
    }
    if (moved) {
        Snapshot s(*window, 0);
        if (s.node) NotifyWinEvent(EVENT_OBJECT_LOCATIONCHANGE, s.hwnd, OBJID_CLIENT, CHILDID_SELF);
    }
    if (uiaListening && (focusChanged || after.focused != before.focused)) {
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
    if (uiaListening && after.nodes.size() - addedNodes < before.nodes.size()) {
        // Like AccessKit's node_removed callback, record every removed SelectionItem.
        for (const auto &entry : before.nodes) {
            if (after.nodes.count(entry.first) == 0 && entry.second.supportsSelectionItem())
                recordSelection(entry.second, false);
        }
    }
    if (!selections.empty()) raiseSelectionChanges(window, after, selections);
}
} // namespace

RuneUiaHost *rune_uia_attach(void *raw) {
    HWND hwnd = static_cast<HWND>(raw);
    if (!hwnd) return nullptr;
    std::unique_ptr<RuneUiaHost> host(new RuneUiaHost(hwnd));
    if (!SetWindowSubclass(hwnd, accessibilityProc, subclassID, reinterpret_cast<DWORD_PTR>(host.get()))) return nullptr;
    return host.release();
}
void rune_uia_on_demand(RuneUiaHost *host, void *context, void (*activate)(void *)) {
    if (!host) return;
    host->activationContext = context;
    host->activate = activate;
    // A reader that queried the HWND before the adapter attached should look again.
    if (host->attached) NotifyWinEvent(EVENT_OBJECT_REORDER, host->attached, OBJID_CLIENT, CHILDID_SELF);
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
    n.selected = info.selected; n.expanded = info.expanded; n.scrollItem = info.scroll_item;
    n.modal = info.modal;
    n.level = info.level; n.position = info.position; n.size = info.size_of_set;
    n.hasRange = info.has_range; n.minimum = info.minimum; n.maximum = info.maximum;
    n.step = info.step; n.number = info.number;
    n.rect = {info.x, info.y, info.width, info.height};
    if (info.focused) tree.focused = n.id;
    n.selectionContainer = parent->second.isSelector() ? parent->first : parent->second.selectionContainer;
    parent->second.children.push_back(n.id);
    tree.nodes.emplace(n.id, std::move(n));
}
void rune_uia_text_model(RuneUiaHost *host, int32_t id, int32_t anchor, int32_t focus,
                         const uint16_t *text, int32_t length, const int32_t *graphemes, int32_t count) {
    if (!host || !host->staging || count < 0 || (count && !graphemes) || length < 0 || (length && !text)) return;
    auto found = host->staging->nodes.find(id);
    if (found == host->staging->nodes.end()) return;
    auto &n = found->second;
    if (n.secure || n.control != UIA_EditControlTypeId || n.field) return;
    auto field = std::make_shared<RuneUiaTextContent>();
    if (count) {
        if (graphemes[0] != 0 || graphemes[count - 1] != length) return;
        for (int i = 1; i < count; ++i) if (graphemes[i] <= graphemes[i - 1]) return;
        field->characters.assign(graphemes, graphemes + count);
    } else {
        field->valueOnly = true;
        field->characters.reserve(static_cast<size_t>(length) + 1);
        uint64_t bytes = 0;
        for (int i = 0; i < length; ++i) {
            if (IS_LOW_SURROGATE(text[i])) continue;
            if (field->characters.size() % RuneUiaTextContent::scalarBlock == 0) field->byteBlocks.push_back(bytes);
            field->characters.push_back(i);
            bytes += RuneUiaTextContent::utf8Width(text[i]);
        }
        if (field->characters.size() % RuneUiaTextContent::scalarBlock == 0) field->byteBlocks.push_back(bytes);
        field->characters.push_back(length);
    }
    n.value.clear();
    if (length) field->text.assign(text, text + length);
    n.anchor = std::max(0, std::min(anchor, length));
    n.caret = std::max(0, std::min(focus, length));
    n.field = std::move(field);
}
void rune_uia_text_geometry(RuneUiaHost *host, int32_t id, const RuneUiaTextCell *cells, int32_t count,
                            RuneUiaWordBreaks wordBreaks) {
    if (!host || !host->staging || !cells || count <= 0) return;
    auto found = host->staging->nodes.find(id);
    if (found == host->staging->nodes.end() || !found->second.field) return;
    auto &field = *found->second.field;
    if (field.valueOnly) return;
    std::vector<int> lineStarts;
    for (int i = 0; i < count;) {
        const int line = cells[i].line;
        if (line != static_cast<int>(lineStarts.size())) return;
        int offset = cells[i].start;
        while (i < count && cells[i].line == line) {
            if (cells[i].start < 0 || cells[i].end < cells[i].start || cells[i].end > field.characters.back()) return;
            offset = std::min(offset, static_cast<int>(cells[i].start));
            ++i;
        }
        auto at = std::lower_bound(field.characters.begin(), field.characters.end(), offset);
        if (at == field.characters.end() || *at != offset) return;
        const int start = static_cast<int>(at - field.characters.begin());
        if (lineStarts.empty() ? start != 0 : start < lineStarts.back()) return;
        lineStarts.push_back(start);
    }
    field.lineStarts = std::move(lineStarts);
    field.wordBreaks = wordBreaks;
    field.cells.assign(cells, cells + count);
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
        if (!host->answeringDemand) window->focusChanged = false;
    }
    const bool first = !host->published;
    host->published = true;
    // The first caller receives the new tree directly. Raising UIA events from inside
    // WM_GETOBJECT can enter UIA again while it is resolving this window's provider.
    if (host->answeringDemand) {
        host->beforeActivation = std::move(before);
        return;
    }
    if (active && (first || host->beforeActivation) && GetForegroundWindow() == host->attached)
        focusChanged = true;
    if (host->beforeActivation) before = std::move(host->beforeActivation);
    if (first && !active && host->attached) {
        // A reader may have queried the HWND before the first semantic tree existed.
        NotifyWinEvent(EVENT_OBJECT_REORDER, host->attached, OBJID_CLIENT, CHILDID_SELF);
    }
    if (active) {
        const bool uia = UiaClientsAreListening() != FALSE;
        if (uia || IsWinEventHookInstalled(EVENT_OBJECT_REORDER) || IsWinEventHookInstalled(EVENT_OBJECT_LOCATIONCHANGE)) {
            raiseChanges(window, *before, *after, focusChanged, uia);
        }
    }
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
