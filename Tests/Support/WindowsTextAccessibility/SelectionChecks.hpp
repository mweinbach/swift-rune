// Out-of-process UI Automation checks for Rune's selection fixture.
// TextClient.cpp supplies field lookup, waitFor, require and HRESULT checking.
#pragma once
#include <algorithm>
#include <mutex>
#include <vector>
#include <wrl/implements.h>

namespace selectionTests {

using Element = ComPtr<IUIAutomationElement>;
using Item = ComPtr<IUIAutomationSelectionItemPattern>;
using Container = ComPtr<IUIAutomationSelectionPattern>;

template<typename Interface>
static ComPtr<Interface> pattern(IUIAutomationElement *element, PATTERNID id) {
    ComPtr<Interface> result;
    HRESULT hr = element->GetCurrentPatternAs(id, IID_PPV_ARGS(&result));
    if (hr != UIA_E_NOTSUPPORTED) check(hr, "GetCurrentPatternAs");
    return result;
}

static std::wstring authorId(IUIAutomationElement *element) {
    StringResult id;
    check(element->get_CurrentAutomationId(&id.value), "Reading element AutomationId");
    return id.str();
}

static Element lookup(IUIAutomation *uia, IUIAutomationElement *root, const wchar_t *id) {
    auto element = field(uia, root, id);
    if (!element) std::fprintf(stderr, "Missing AutomationId=%ls\n", id);
    require(element != nullptr, "Missing selection fixture element");
    return element;
}

static Container container(IUIAutomationElement *element) {
    auto result = pattern<IUIAutomationSelectionPattern>(element, UIA_SelectionPatternId);
    if (!result) std::fprintf(stderr, "Missing SelectionPattern on %ls\n", authorId(element).c_str());
    require(result != nullptr, "Missing SelectionPattern");
    BOOL multiple = TRUE, required = TRUE;
    check(result->get_CurrentCanSelectMultiple(&multiple), "CanSelectMultiple");
    check(result->get_CurrentIsSelectionRequired(&required), "IsSelectionRequired");
    require(!multiple && !required, "Unexpected selection container flags");
    return result;
}

static std::vector<std::wstring> selectedItems(IUIAutomationSelectionPattern *container) {
    ComPtr<IUIAutomationElementArray> selection;
    check(container->GetCurrentSelection(&selection), "GetCurrentSelection");
    require(selection != nullptr, "Selection container returned a null array");
    int count = 0;
    check(selection->get_Length(&count), "Selection length");
    std::vector<std::wstring> ids;
    for (int i = 0; i < count; ++i) {
        Element child;
        check(selection->GetElement(i, &child), "Reading selection item");
        ids.push_back(authorId(child.Get()));
    }
    return ids;
}

static Item item(IUIAutomationElement *element, bool expectedSelected, const wchar_t *parent) {
    auto result = pattern<IUIAutomationSelectionItemPattern>(element, UIA_SelectionItemPatternId);
    if (!result) std::fprintf(stderr, "Missing SelectionItem on %ls\n", authorId(element).c_str());
    require(result != nullptr, "Missing SelectionItem");
    BOOL selected = FALSE;
    check(result->get_CurrentIsSelected(&selected), "SelectionItem.IsSelected");
    if ((selected != FALSE) != expectedSelected)
        std::fprintf(stderr, "Unexpected selection state on %ls\n", authorId(element).c_str());
    require((selected != FALSE) == expectedSelected, "Incorrect selection state");
    Element actual;
    HRESULT hr = result->get_CurrentSelectionContainer(&actual);
    if (parent) {
        check(hr, "SelectionItem.SelectionContainer");
        require(actual && authorId(actual.Get()) == parent, "Incorrect SelectionContainer");
    } else {
        require(!actual && (SUCCEEDED(hr) || hr == E_FAIL), "Uncontained selection item reported a parent");
    }
    return result;
}

struct Observation {
    std::wstring sender;
    int event;
    int selected;
};

class Observer final : public Microsoft::WRL::RuntimeClass<
    Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
    IUIAutomationEventHandler, IUIAutomationPropertyChangedEventHandler> {
    std::mutex lock;
    std::vector<Observation> events;
    HRESULT record(IUIAutomationElement *sender, int event, int selected) noexcept {
        StringResult id;
        HRESULT hr = sender->get_CachedAutomationId(&id.value);
        if (FAILED(hr)) return hr;
        try {
            std::lock_guard<std::mutex> guard(lock);
            events.push_back({id.str(), event, selected});
            return S_OK;
        } catch (const std::bad_alloc &) {
            return E_OUTOFMEMORY;
        }
    }
public:
    HRESULT STDMETHODCALLTYPE HandleAutomationEvent(IUIAutomationElement *sender, EVENTID event) override {
        return record(sender, event, -1);
    }
    HRESULT STDMETHODCALLTYPE HandlePropertyChangedEvent(IUIAutomationElement *sender, PROPERTYID property,
                                                         VARIANT value) override {
        if (property != UIA_SelectionItemIsSelectedPropertyId || value.vt != VT_BOOL) return S_OK;
        return record(sender, property, value.boolVal != VARIANT_FALSE);
    }
    void await(const wchar_t *sender, int event, int selected = -1) {
        const auto deadline = GetTickCount64() + 15000;
        for (;;) {
            {
                std::lock_guard<std::mutex> guard(lock);
                auto found = std::find_if(events.begin(), events.end(), [&](const auto &observed) {
                    return observed.sender == sender && observed.event == event && observed.selected == selected;
                });
                if (found != events.end()) {
                    events.erase(found);
                    return;
                }
                if (GetTickCount64() >= deadline) {
                    std::fprintf(stderr, "Missing callback on %ls, event/property %d, value %d. Observed %zu pending callbacks:\n",
                                 sender, event, selected, events.size());
                    for (const auto &obs : events)
                        std::fprintf(stderr, "  %ls %d %d\n", obs.sender.c_str(), obs.event, obs.selected);
                    throw std::runtime_error("Missing selection callback");
                }
            }
            Sleep(50);
        }
    }
};

static void run(IUIAutomation *uia, IUIAutomationElement *window) {
    auto get = [&](const wchar_t *id) { return lookup(uia, window, id); };
    auto checkOrientation = [&](const wchar_t *id, OrientationType expected) {
        OrientationType orientation;
        check(get(id)->get_CurrentOrientation(&orientation), "Selection control orientation");
        require(orientation == expected, "Unexpected selection control orientation");
    };
    checkOrientation(L"tabs", OrientationType_Horizontal);
    checkOrientation(L"options", OrientationType_Vertical);
    checkOrientation(L"tree", OrientationType_None);
    auto checkType = [&](const wchar_t *id, CONTROLTYPEID expected) {
        auto element = get(id);
        CONTROLTYPEID actual = 0;
        check(element->get_CurrentControlType(&actual), "Reading UIA control type");
        if (actual != expected) std::fprintf(stderr, "Control %ls expected type %d, received %d\n", id, expected, actual);
        require(actual == expected, "Unexpected UIA control type");
        return element;
    };
    auto checkedSwitch = checkType(L"checked-switch", UIA_ButtonControlTypeId);
    checkType(L"alert", UIA_TextControlTypeId);
    checkType(L"quotation", UIA_GroupControlTypeId);
    auto splitter = checkType(L"splitter", UIA_SeparatorControlTypeId);
    auto switchToggle = pattern<IUIAutomationTogglePattern>(checkedSwitch.Get(), UIA_TogglePatternId);
    auto splitterInvoke = pattern<IUIAutomationInvokePattern>(splitter.Get(), UIA_InvokePatternId);
    require(switchToggle && splitterInvoke, "Missing switch toggle or splitter invoke");
    auto switchState = [&] {
        ToggleState state;
        check(switchToggle->get_CurrentToggleState(&state), "Reading switch state");
        return state;
    };
    require(switchState() == ToggleState_On, "Switch should start on");
    check(switchToggle->Toggle(), "Switch.Toggle");
    waitFor([&] { return switchState() == ToggleState_Off; }, "Switch did not turn off");
    check(splitterInvoke->Invoke(), "Splitter.Invoke");
    waitFor([&] { return switchState() == ToggleState_On; }, "Splitter action did not restore the switch");
    auto tabs = container(get(L"tabs").Get());
    auto options = container(get(L"options").Get());
    auto empty = container(get(L"empty-options").Get());
    require(selectedItems(empty.Get()).empty(), "Empty listbox has selected children");
    require(selectedItems(tabs.Get()) == std::vector<std::wstring>{L"tab-one"}, "Initial tab selection");
    require(selectedItems(options.Get()).empty(), "Initial option selection");
    auto first = item(get(L"tab-one").Get(), true, L"tabs");
    auto second = item(get(L"tab-two").Get(), false, L"tabs");
    item(get(L"list-item").Get(), true, nullptr);
    require(!pattern<IUIAutomationSelectionPattern>(get(L"list").Get(), UIA_SelectionPatternId),
            "An ordinary list offered SelectionPattern");
    item(get(L"tree-item").Get(), true, L"tree");
    require(selectedItems(container(get(L"tree").Get()).Get()) == std::vector<std::wstring>{L"tree-item"},
            "Tree selection did not enumerate its selected item");
    item(get(L"grid-cell").Get(), true, L"grid");
    require(selectedItems(container(get(L"grid").Get()).Get()).empty(), "Grid enumerated a non-item-like cell");
    auto treeGrid = get(L"tree-grid");
    CONTROLTYPEID treeGridType = 0;
    StringResult treeGridRole;
    check(treeGrid->get_CurrentControlType(&treeGridType), "Reading treegrid control type");
    check(treeGrid->get_CurrentAriaRole(&treeGridRole.value), "Reading treegrid ARIA role");
    require(treeGridType == UIA_DataGridControlTypeId && treeGridRole.str() == L"treegrid", "Treegrid roles");
    item(get(L"tree-grid-item").Get(), true, L"tree-grid");
    item(get(L"tree-grid-cell").Get(), true, L"tree-grid");
    require(selectedItems(container(treeGrid.Get()).Get()) == std::vector<std::wstring>{L"tree-grid-item"},
            "Treegrid did not enumerate selected items through its row");
    item(get(L"radio-on").Get(), true, L"radios");
    item(get(L"radio-off").Get(), false, L"radios");
    require(selectedItems(container(get(L"radios").Get()).Get()).empty(), "Radio checks leaked into raw selection");
    item(get(L"menu-radio").Get(), true, L"menu");
    require(selectedItems(container(get(L"menu").Get()).Get()).empty(), "Menu radio check leaked into raw selection");
    CONTROLTYPEID radioType = 0, checkboxType = 0;
    check(get(L"menu-radio")->get_CurrentControlType(&radioType), "Menu radio control type");
    auto menuCheck = get(L"menu-check");
    check(menuCheck->get_CurrentControlType(&checkboxType), "Menu checkbox control type");
    require(radioType == UIA_RadioButtonControlTypeId && checkboxType == UIA_CheckBoxControlTypeId,
            "Wrong menu item control types");
    auto toggle = pattern<IUIAutomationTogglePattern>(menuCheck.Get(), UIA_TogglePatternId);
    require(toggle != nullptr, "Checked menu item did not expose TogglePattern");
    ToggleState toggleState;
    check(toggle->get_CurrentToggleState(&toggleState), "Menu checkbox toggle state");
    require(toggleState == ToggleState_On, "Checked menu item reported false");
    auto unspecified = get(L"unspecified-check");
    require(!pattern<IUIAutomationSelectionItemPattern>(unspecified.Get(), UIA_SelectionItemPatternId) &&
            !pattern<IUIAutomationTogglePattern>(unspecified.Get(), UIA_TogglePatternId), "Unspecified checkbox state");
    auto mixed = get(L"mixed-radio");
    require(!pattern<IUIAutomationSelectionItemPattern>(mixed.Get(), UIA_SelectionItemPatternId) &&
            pattern<IUIAutomationTogglePattern>(mixed.Get(), UIA_TogglePatternId), "Mixed radio patterns");
    require(!pattern<IUIAutomationSelectionItemPattern>(get(L"unspecified-radio").Get(), UIA_SelectionItemPatternId),
            "A menu radio without checked state offered SelectionItem");
    require(!pattern<IUIAutomationSelectionItemPattern>(get(L"unmarked-option").Get(), UIA_SelectionItemPatternId),
            "An option without selected state offered SelectionItem");
    item(get(L"unmarked-cell").Get(), false, nullptr);
    require(!pattern<IUIAutomationSelectionItemPattern>(get(L"selected-button").Get(), UIA_SelectionItemPatternId),
            "A button offered SelectionItem because it was marked selected");
    auto disabled = item(get(L"disabled-option").Get(), false, L"options");
    require(disabled->RemoveFromSelection() == UIA_E_ELEMENTNOTENABLED, "Disabled no-op was accepted");
    auto readOnly = item(get(L"read-only-option").Get(), false, L"options");
    check(readOnly->Select(), "Click request on a nonpressable selectable item");
    auto one = item(get(L"option-one").Get(), false, L"options");
    auto two = item(get(L"option-two").Get(), false, L"options");

    auto listener = Microsoft::WRL::Make<Observer>();
    require(listener != nullptr, "Creating selection event handler");
    ComPtr<IUIAutomationCacheRequest> cache;
    check(uia->CreateCacheRequest(&cache), "Create event sender cache");
    check(cache->AddProperty(UIA_AutomationIdPropertyId), "Cache event sender AutomationId");
    const EVENTID eventIds[] = {UIA_SelectionItem_ElementSelectedEventId, UIA_SelectionItem_ElementRemovedFromSelectionEventId,
                                UIA_Selection_InvalidatedEventId};
    struct Subscription {
        IUIAutomation *uia;
        ~Subscription() { uia->RemoveAllEventHandlers(); }
    } subscription{uia};
    for (EVENTID event : eventIds)
        check(uia->AddAutomationEventHandler(event, window, TreeScope_Subtree, cache.Get(), listener.Get()),
                "Subscribe to selection events");
    PROPERTYID property = UIA_SelectionItemIsSelectedPropertyId;
    check(uia->AddPropertyChangedEventHandlerNativeArray(window, TreeScope_Subtree, cache.Get(),
                                                           listener.Get(), &property, 1), "Subscribe to IsSelected");

    check(second->AddToSelection(), "Select second tab through AddToSelection");
    listener->await(L"tab-two", UIA_SelectionItem_ElementSelectedEventId);
    listener->await(L"tab-two", property, true);
    listener->await(L"tab-one", property, false);
    require(selectedItems(tabs.Get()) == std::vector<std::wstring>{L"tab-two"}, "Previous tab remained selected");
    check(second->Select(), "Idempotent tab selection");
    check(first->RemoveFromSelection(), "Idempotent removal");

    check(item(get(L"radio-off").Get(), false, L"radios")->Select(), "Select second radio");
    listener->await(L"radio-off", UIA_SelectionItem_ElementSelectedEventId);
    listener->await(L"radio-off", property, true);
    listener->await(L"radio-on", UIA_SelectionItem_ElementRemovedFromSelectionEventId);
    listener->await(L"radio-on", property, false);
    item(get(L"radio-off").Get(), true, L"radios");
    item(get(L"radio-on").Get(), false, L"radios");
    check(item(get(L"menu-radio").Get(), true, L"menu")->RemoveFromSelection(), "Clear checked menu radio");
    listener->await(L"menu-radio", UIA_SelectionItem_ElementRemovedFromSelectionEventId);
    listener->await(L"menu-radio", property, false);
    item(get(L"menu-radio").Get(), false, L"menu");

    check(one->Select(), "Select first option");
    listener->await(L"option-one", UIA_SelectionItem_ElementSelectedEventId);
    listener->await(L"option-one", property, true);
    check(two->AddToSelection(), "Add second option");
    listener->await(L"option-two", UIA_SelectionItem_ElementSelectedEventId);
    listener->await(L"option-two", property, true);
    require(selectedItems(options.Get()) == std::vector<std::wstring>{L"option-one", L"option-two"},
            "Application-defined option selection was not published in tree order");
    check(one->RemoveFromSelection(), "Remove first option");
    listener->await(L"option-two", UIA_SelectionItem_ElementSelectedEventId);
    listener->await(L"option-one", property, false);
    check(two->RemoveFromSelection(), "Remove final option");
    listener->await(L"option-two", UIA_SelectionItem_ElementRemovedFromSelectionEventId);
    listener->await(L"option-two", property, false);
    require(selectedItems(options.Get()).empty(), "Final option was not removed");
    item(get(L"read-only-option").Get(), false, L"options");

    auto trigger = pattern<IUIAutomationInvokePattern>(get(L"select-batch").Get(), UIA_InvokePatternId);
    require(trigger != nullptr, "Missing bulk select action");
    check(trigger->Invoke(), "Select 21 items in one update");
    listener->await(L"batch-options", UIA_Selection_InvalidatedEventId);
    require(selectedItems(container(get(L"batch-options").Get()).Get()).size() == 21, "Bulk selection size");

    auto clippedOption = get(L"far-option");
    auto scroll = pattern<IUIAutomationScrollItemPattern>(clippedOption.Get(), UIA_ScrollItemPatternId);
    require(scroll != nullptr, "Offscreen option did not expose ScrollItem");
    require(!pattern<IUIAutomationScrollItemPattern>(get(L"outside").Get(), UIA_ScrollItemPatternId),
            "Outside item advertised scrolling without a scroll ancestor");
    BOOL offscreen = FALSE;
    check(clippedOption->get_CurrentIsOffscreen(&offscreen), "Initial option visibility");
    require(offscreen, "Expected clipped option");
    check(scroll->ScrollIntoView(), "Scroll option into view");
    waitFor([&] {
        check(clippedOption->get_CurrentIsOffscreen(&offscreen), "Scrolled option visibility");
        return offscreen == FALSE;
    }, "Scroll action did not reveal the option");
    RECT optionRect{}, viewport{};
    check(clippedOption->get_CurrentBoundingRectangle(&optionRect), "Scrolled option screen bounds");
    check(get(L"choice-scroll")->get_CurrentBoundingRectangle(&viewport), "Scroll container screen bounds");
    require(optionRect.right > optionRect.left && optionRect.bottom > optionRect.top &&
            optionRect.left >= viewport.left && optionRect.right <= viewport.right &&
            optionRect.top >= viewport.top && optionRect.bottom <= viewport.bottom, "Scrolled option bounds");
    std::puts("Rune UIA verified selection roles, containers, checked and mixed radios, idempotent and disabled actions, "
              "selection and property callbacks, 21-item selection invalidation and offscreen option scrolling.");
}

} // namespace selectionTests
