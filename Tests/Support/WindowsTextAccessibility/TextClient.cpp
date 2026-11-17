// Out-of-process UI Automation client for the Swift RuneTextFixture.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <ole2.h>
#include <uiautomation.h>
#include <wrl/client.h>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <string>

using Microsoft::WRL::ComPtr;
using Range = ComPtr<IUIAutomationTextRange>;

static void require(bool ok, const char *message) {
    if (!ok) throw std::runtime_error(message);
}

static void check(HRESULT hr, const char *message) {
    if (FAILED(hr)) {
        std::fprintf(stderr, "%s (HRESULT 0x%08lx)\n", message, static_cast<unsigned long>(hr));
        throw std::runtime_error(message);
    }
}

struct StringResult {
    BSTR value = nullptr;
    ~StringResult() { SysFreeString(value); }
    std::wstring str() const { return value ? std::wstring(value, SysStringLen(value)) : L""; }
};

struct TargetWindow {
    DWORD pid;
    HWND hwnd = nullptr;
};

static BOOL CALLBACK findWindow(HWND hwnd, LPARAM data) {
    auto &target = *reinterpret_cast<TargetWindow *>(data);
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    wchar_t name[64] = {};
    if (pid != target.pid || !GetClassNameW(hwnd, name, 64) ||
        std::wstring(name) != L"RuneSwiftOpenGLWindow") return TRUE;
    target.hwnd = hwnd;
    return FALSE;
}

static ComPtr<IUIAutomationElement> field(IUIAutomation *uia, IUIAutomationElement *window, const wchar_t *id) {
    VARIANT value{};
    value.vt = VT_BSTR;
    value.bstrVal = SysAllocString(id);
    require(value.bstrVal != nullptr, "Allocating field id");
    ComPtr<IUIAutomationCondition> condition;
    HRESULT hr = uia->CreatePropertyCondition(UIA_AutomationIdPropertyId, value, &condition);
    VariantClear(&value);
    check(hr, "CreatePropertyCondition");
    ComPtr<IUIAutomationElement> result;
    check(window->FindFirst(TreeScope_Descendants, condition.Get(), &result), "Finding field");
    return result;
}

template<typename Predicate>
static void waitFor(Predicate predicate, const char *message, DWORD milliseconds = 15000) {
    auto deadline = GetTickCount64() + milliseconds;
    while (!predicate()) {
        require(GetTickCount64() < deadline, message);
        Sleep(50);
    }
}

static std::wstring read(IUIAutomationTextRange *range, int maximumLength = -1) {
    StringResult result;
    check(range->GetText(maximumLength, &result.value), "GetText");
    return result.str();
}

static int compare(IUIAutomationTextRange *left, TextPatternRangeEndpoint first,
                   IUIAutomationTextRange *right, TextPatternRangeEndpoint second) {
    int delta = 0;
    check(left->CompareEndpoints(first, right, second, &delta), "CompareEndpoints");
    return delta;
}

static void move(IUIAutomationTextRange *range, TextPatternRangeEndpoint endpoint, int count) {
    int moved = 0;
    check(range->MoveEndpointByUnit(endpoint, TextUnit_Character, count, &moved), "MoveEndpointByUnit");
    require(moved == count, "Unexpected count of characters moved");
}

static Range selection(IUIAutomationTextPattern *pattern) {
    ComPtr<IUIAutomationTextRangeArray> ranges;
    check(pattern->GetSelection(&ranges), "GetSelection");
    require(ranges.Get() != nullptr, "Missing selection array");
    int count = 0;
    check(ranges->get_Length(&count), "Selection count");
    require(count == 1, "Expected one editable selection");
    Range result;
    check(ranges->GetElement(0, &result), "Selection range");
    require(result.Get() != nullptr, "Missing editable selection");
    return result;
}

static void checkCaretPosition(IUIAutomationTextRange *range, CaretPosition expected) {
    VARIANT position{};
    check(range->GetAttributeValue(UIA_CaretPositionAttributeId, &position), "CaretPosition attribute");
    bool matches = position.vt == VT_I4 && position.lVal == expected;
    if (!matches) {
        std::fprintf(stderr, "Expected caret position %d, received variant type %u and position %ld\n",
                     expected, static_cast<unsigned>(position.vt), position.vt == VT_I4 ? position.lVal : -1L);
    }
    VariantClear(&position);
    require(matches, "Unexpected CaretPosition attribute");
}

static Range caretAt(IUIAutomationTextRange *document, int character) {
    Range caret;
    check(document->Clone(&caret), "Clone insertion point");
    check(caret->MoveEndpointByRange(TextPatternRangeEndpoint_End, caret.Get(), TextPatternRangeEndpoint_Start),
          "Collapse insertion point");
    move(caret.Get(), TextPatternRangeEndpoint_Start, character);
    return caret;
}

static void checkGeometry(IUIAutomationTextPattern *pattern, IUIAutomationTextRange *range) {
    SAFEARRAY *rects = nullptr;
    check(range->GetBoundingRectangles(&rects), "GetBoundingRectangles");
    require(rects != nullptr, "Missing glyph rectangles");
    struct ReleaseRects { SAFEARRAY *array; ~ReleaseRects() { SafeArrayDestroy(array); } } owner{rects};
    LONG lower, upper;
    check(SafeArrayGetLBound(rects, 1, &lower), "Rectangle lower bound");
    check(SafeArrayGetUBound(rects, 1, &upper), "Rectangle upper bound");
    require(upper - lower + 1 >= 4, "A rendered character has no bounding rectangle");
    double xywh[4] = {};
    for (LONG index = 0; index < 4; ++index) {
        LONG position = lower + index;
        check(SafeArrayGetElement(rects, &position, &xywh[index]), "Reading character rectangle");
    }
    require(xywh[2] > 0 && xywh[3] > 0, "Empty character rectangle");
    POINT point{static_cast<LONG>(xywh[0] + xywh[2] / 2), static_cast<LONG>(xywh[1] + xywh[3] / 2)};
    Range hit;
    check(pattern->RangeFromPoint(point, &hit), "RangeFromPoint");
    require(hit.Get() && read(hit.Get()).empty() &&
            compare(hit.Get(), TextPatternRangeEndpoint_Start, range, TextPatternRangeEndpoint_Start) >= 0 &&
            compare(hit.Get(), TextPatternRangeEndpoint_End, range, TextPatternRangeEndpoint_End) <= 0,
            "The character's screen point resolved outside its range");
}

static void checkEditor(IUIAutomationElement *editor) {
    constexpr wchar_t text[] = L"A\U0001F680e\u0301Z";
    constexpr wchar_t selected[] = L"\U0001F680e\u0301";
    ComPtr<IUIAutomationValuePattern> valuePattern;
    check(editor->GetCurrentPatternAs(UIA_ValuePatternId, IID_PPV_ARGS(&valuePattern)), "ValuePattern");
    require(valuePattern.Get() != nullptr, "Editor is missing ValuePattern");
    StringResult value;
    check(valuePattern->get_CurrentValue(&value.value), "ValuePattern.CurrentValue");
    require(value.str() == text, "Editor value changed the Unicode text");

    ComPtr<IUIAutomationTextPattern> pattern;
    check(editor->GetCurrentPatternAs(UIA_TextPatternId, IID_PPV_ARGS(&pattern)), "TextPattern");
    require(pattern.Get() != nullptr, "Editor is missing TextPattern");
    ComPtr<IUIAutomationTextPattern2> pattern2;
    check(editor->GetCurrentPatternAs(UIA_TextPattern2Id, IID_PPV_ARGS(&pattern2)), "TextPattern2");
    require(pattern2.Get() != nullptr, "Editor is missing TextPattern2");
    SupportedTextSelection support;
    check(pattern->get_SupportedTextSelection(&support), "SupportedTextSelection");
    require(support == SupportedTextSelection_Single, "Expected single selection");
    Range document;
    check(pattern->get_DocumentRange(&document), "DocumentRange");
    require(document.Get() && read(document.Get()) == text, "Unexpected document text");
    Range format = caretAt(document.Get(), 2);
    check(format->ExpandToEnclosingUnit(TextUnit_Format), "Editor format range");
    require(read(format.Get()) == text, "Editor TextUnit_Format did not cover the uniform text");
    checkCaretPosition(document.Get(), CaretPosition_Unknown);
    checkCaretPosition(caretAt(document.Get(), 0).Get(), CaretPosition_BeginningOfLine);
    checkCaretPosition(caretAt(document.Get(), 2).Get(), CaretPosition_Unknown);
    checkCaretPosition(caretAt(document.Get(), 4).Get(), CaretPosition_EndOfLine);
    ComPtr<IUIAutomationTextRangeArray> visible;
    check(pattern->GetVisibleRanges(&visible), "GetVisibleRanges");
    require(visible.Get() != nullptr, "Missing visible ranges");
    int visibleCount = 0;
    check(visible->get_Length(&visibleCount), "Visible range count");
    std::wstring visibleText;
    for (int i = 0; i < visibleCount; ++i) {
        Range range;
        check(visible->GetElement(i, &range), "Visible range");
        require(range.Get() != nullptr, "Missing visible range");
        visibleText += read(range.Get());
    }
    require(visibleText == text, "Visible ranges do not cover the complete Unicode field");

    const auto start = TextPatternRangeEndpoint_Start, end = TextPatternRangeEndpoint_End;
    Range reversed = selection(pattern.Get()), initialCaret;
    require(read(reversed.Get()) == L"Z", "Rune's initial backward selection was lost");
    BOOL active = FALSE;
    check(pattern2->GetCaretRange(&active, &initialCaret), "GetCaretRange on backward selection");
    require(initialCaret.Get() && read(initialCaret.Get()).empty()
            && !compare(initialCaret.Get(), start, reversed.Get(), start),
            "The caret was reported at the anchor of a backward selection");
    Range section;
    check(document->Clone(&section), "Clone document");
    check(section->MoveEndpointByRange(end, section.Get(), start), "Collapse to document start");
    move(section.Get(), end, 1);
    checkGeometry(pattern.Get(), section.Get());
    move(section.Get(), start, 1);
    move(section.Get(), end, 1);
    require(read(section.Get()) == L"\U0001F680", "Character movement split the supplementary-plane emoji");
    move(section.Get(), end, 1);
    require(read(section.Get()) == selected, "Character movement split the combining sequence");
    check(section->Select(), "Select Unicode text");
    waitFor([&] {
        Range current = selection(pattern.Get());
        return read(current.Get()) == selected && !compare(current.Get(), start, section.Get(), start)
            && !compare(current.Get(), end, section.Get(), end);
    }, "Rune did not publish the selected Unicode range");

    check(section->MoveEndpointByRange(start, section.Get(), end), "Collapse to selection end");
    check(section->Select(), "Set insertion caret");
    waitFor([&] {
        BOOL active = FALSE;
        Range caret;
        check(pattern2->GetCaretRange(&active, &caret), "GetCaretRange");
        BOOL keyboardFocus = FALSE;
        check(editor->get_CurrentHasKeyboardFocus(&keyboardFocus), "Keyboard focus");
        Range current = selection(pattern.Get());
        return caret.Get() && active == keyboardFocus && read(caret.Get()).empty()
            && !compare(caret.Get(), start, section.Get(), start)
            && !compare(caret.Get(), end, section.Get(), end) && read(current.Get()).empty()
            && !compare(current.Get(), start, section.Get(), start);
    }, "Rune did not publish the insertion caret after the combining sequence");
}

static void checkPassword(IUIAutomationElement *password) {
    BOOL secure = FALSE;
    check(password->get_CurrentIsPassword(&secure), "Password flag");
    require(secure, "Password field is missing the secure flag");
    for (PATTERNID id : {UIA_TextPatternId, UIA_TextPattern2Id}) {
        ComPtr<IUnknown> pattern;
        auto hr = password->GetCurrentPattern(id, &pattern);
        if (hr != UIA_E_NOTSUPPORTED) check(hr, "Reading password pattern availability");
        require(!pattern.Get(), "Password exposed a text range");
    }
    ComPtr<IUIAutomationValuePattern> pattern;
    check(password->GetCurrentPatternAs(UIA_ValuePatternId, IID_PPV_ARGS(&pattern)), "Password ValuePattern");
    require(pattern.Get() != nullptr, "Password is missing ValuePattern");
    StringResult value;
    auto hr = pattern->get_CurrentValue(&value.value);
    require((hr == E_ACCESSDENIED || SUCCEEDED(hr)) && value.str().empty(), "Password exposed a readable value");
    VARIANT property{};
    hr = password->GetCurrentPropertyValue(UIA_ValueValuePropertyId, &property);
    bool redacted = (hr == E_ACCESSDENIED || SUCCEEDED(hr)) &&
                    (property.vt != VT_BSTR || SysStringLen(property.bstrVal) == 0);
    VariantClear(&property);
    require(redacted, "Password exposed its value as an element property");
    StringResult label;
    check(password->get_CurrentName(&label.value), "Password accessible name");
    require(label.str() == L"Password", "Unexpected password accessible name");
}

static bool offscreen(IUIAutomationElement *field) {
    BOOL result = FALSE;
    check(field->get_CurrentIsOffscreen(&result), "IsOffscreen");
    return result != FALSE;
}

static void checkLargeDocument(IUIAutomationElement *field, IUIAutomationElement *editor) {
    require(offscreen(field) && !offscreen(editor), "The document should start below the scroll viewport");
    ComPtr<IUIAutomationScrollItemPattern> scroll;
    check(field->GetCurrentPatternAs(UIA_ScrollItemPatternId, IID_PPV_ARGS(&scroll)), "ScrollItemPattern");
    require(scroll.Get() != nullptr, "The offscreen document is missing ScrollItemPattern");
    check(scroll->ScrollIntoView(), "ScrollItem.ScrollIntoView");
    waitFor([&] { return !offscreen(field) && offscreen(editor); }, "ScrollItem did not reveal the document");

    ComPtr<IUIAutomationTextPattern> pattern;
    check(field->GetCurrentPatternAs(UIA_TextPatternId, IID_PPV_ARGS(&pattern)), "Long document TextPattern");
    require(pattern.Get() != nullptr, "Missing long document TextPattern");
    Range document;
    check(pattern->get_DocumentRange(&document), "Long document range");
    std::wstring expected = L"\U0001F680e\u0301\n";
    for (int i = 0; i < 64; ++i) {
        for (int j = 0; j < 64; ++j) expected += L"0123456789abcdef";
        expected += L"\n";
    }
    expected += L"End";
    require(document.Get() && read(document.Get()) == expected, "Long document changed or was truncated");
    require(read(document.Get(), 1) == L"\U0001F680", "Long GetText(1) split the supplementary-plane character");
    Range accent = caretAt(document.Get(), 2);
    move(accent.Get(), TextPatternRangeEndpoint_End, 1);
    require(read(accent.Get()) == L"\u0301", "Long TextUnit_Character did not isolate the combining scalar");
    Range format = caretAt(document.Get(), 4);
    check(format->ExpandToEnclosingUnit(TextUnit_Format), "Long document format range");
    require(read(format.Get()) == expected, "Long TextUnit_Format did not cover the entire document");
    checkCaretPosition(document.Get(), CaretPosition_Unknown);
    checkCaretPosition(caretAt(document.Get(), 0).Get(), CaretPosition_BeginningOfLine);
    checkCaretPosition(caretAt(document.Get(), 1).Get(), CaretPosition_Unknown);
    checkCaretPosition(caretAt(document.Get(), 3).Get(), CaretPosition_EndOfLine);
    checkCaretPosition(caretAt(document.Get(), 4).Get(), CaretPosition_BeginningOfLine);

    RECT bounds{};
    check(field->get_CurrentBoundingRectangle(&bounds), "Long document bounds");
    require(bounds.right > bounds.left && bounds.bottom > bounds.top, "Long document has empty screen bounds");
    POINT point{bounds.right - 1, bounds.bottom - 1};
    Range hit, selected = selection(pattern.Get()), wanted = caretAt(document.Get(), 1);
    check(pattern->RangeFromPoint(point, &hit), "Long document RangeFromPoint");
    const auto start = TextPatternRangeEndpoint_Start;
    require(read(selected.Get()) == L"\U0001F680", "Missing long document's initial forward selection");
    require(hit.Get() && read(hit.Get()).empty() && !compare(hit.Get(), start, selected.Get(), TextPatternRangeEndpoint_End)
            && !compare(hit.Get(), start, wanted.Get(), start), "Long document point did not resolve to the selection focus");

    ComPtr<IUIAutomationTextPattern> editorPattern;
    check(editor->GetCurrentPatternAs(UIA_TextPatternId, IID_PPV_ARGS(&editorPattern)), "Editor TextPattern");
    Range editorRange = selection(editorPattern.Get());
    check(editorRange->ScrollIntoView(TRUE), "TextRange.ScrollIntoView(true)");
    waitFor([&] { return offscreen(field) && !offscreen(editor); }, "Text range did not restore the editor");
    check(document->ScrollIntoView(FALSE), "Long TextRange.ScrollIntoView(false)");
    waitFor([&] { return !offscreen(field) && offscreen(editor); }, "Long text range did not reveal its field");
}

static void checkDocumentStructure(IUIAutomation *uia, IUIAutomationElement *window) {
    auto heading = field(uia, window, L"heading");
    auto main = field(uia, window, L"scroll");
    auto section = field(uia, window, L"section");
    require(heading.Get() && main.Get() && section.Get(), "Missing heading or landmark elements");
    ComPtr<IUIAutomationElement8> headingElement;
    check(heading.As(&headingElement), "Heading element");
    HEADINGLEVELID level = 0;
    check(headingElement->get_CurrentHeadingLevel(&level), "HeadingLevel");
    require(level == HeadingLevel3, "Unexpected UIA heading level");
    ComPtr<IUIAutomationElement5> mainElement, regionElement;
    check(main.As(&mainElement), "Main landmark");
    check(section.As(&regionElement), "Region landmark");
    LANDMARKTYPEID type = 0;
    check(mainElement->get_CurrentLandmarkType(&type), "Main LandmarkType");
    require(type == UIA_MainLandmarkTypeId, "Missing main landmark type");
    check(regionElement->get_CurrentLandmarkType(&type), "Region LandmarkType");
    require(type == UIA_CustomLandmarkTypeId, "Missing named region landmark type");
    StringResult localized;
    check(regionElement->get_CurrentLocalizedLandmarkType(&localized.value), "LocalizedLandmarkType");
    require(localized.str() == L"region", "Unexpected localized type for named region");
}

static void checkRetainedRange(IUIAutomationElement *editor) {
    ComPtr<IUIAutomationScrollItemPattern> scroll;
    check(editor->GetCurrentPatternAs(UIA_ScrollItemPatternId, IID_PPV_ARGS(&scroll)), "Revision scroll pattern");
    require(scroll.Get() != nullptr, "Revision editor has no scroll pattern");
    check(scroll->ScrollIntoView(), "Reveal the revision editor");
    waitFor([&] { return !offscreen(editor); }, "Revision editor stayed offscreen");
    ComPtr<IUIAutomationTextPattern> pattern;
    ComPtr<IUIAutomationValuePattern> value;
    check(editor->GetCurrentPatternAs(UIA_TextPatternId, IID_PPV_ARGS(&pattern)), "Revision text pattern");
    check(editor->GetCurrentPatternAs(UIA_ValuePatternId, IID_PPV_ARGS(&value)), "Revision value pattern");
    require(pattern.Get() && value.Get(), "Revision editor is missing text or value access");
    Range document, target;
    check(pattern->get_DocumentRange(&document), "Revision document");
    StringResult needle;
    needle.value = SysAllocString(L"target");
    require(needle.value != nullptr, "Allocating revision search text");
    check(document->FindText(needle.value, FALSE, FALSE, &target), "Find retained text");
    require(target.Get() && read(target.Get()) == L"target", "Could not retain text on the second line");
    auto replace = [&](const wchar_t *replacement) {
        StringResult input;
        input.value = SysAllocString(replacement);
        require(input.value != nullptr, "Allocating replacement text");
        check(value->SetValue(input.value), "Replace revision text");
        waitFor([&] {
            StringResult published;
            check(value->get_CurrentValue(&published.value), "Published revision text");
            return published.str() == replacement;
        }, "The edited document was not published");
    };
    replace(L"longer first line\nbefore target after");
    require(read(target.Get()) == L"target", "A retained second-line range moved into the edited first line");
    replace(L"short");
    StringResult removed;
    require(target->GetText(-1, &removed.value) == UIA_E_ELEMENTNOTAVAILABLE, "A removed line still exposed its range");
    check(target->ExpandToEnclosingUnit(TextUnit_Document), "Recover removed range as document");
    require(read(target.Get()) == L"short", "Expanding the removed range did not reacquire the current document");

    replace(L"can't 3.14!!");
    Range words;
    check(pattern->get_DocumentRange(&words), "Word segmentation document");
    auto word = caretAt(words.Get(), 2);
    check(word->ExpandToEnclosingUnit(TextUnit_Word), "Expand inside contraction");
    require(read(word.Get()) == L"can't", "Word navigation split an apostrophe inside a contraction");
    for (const wchar_t *expected : {L" ", L"3.14", L"!", L"!"}) {
        int moved = 0;
        check(word->Move(TextUnit_Word, 1, &moved), "Advance through shaped Unicode words");
        require(moved == 1 && read(word.Get()) == expected, "Wrong space, decimal or punctuation word boundary");
    }
}

static void checkDialog(IUIAutomationElement *element, const wchar_t *role, BOOL expectedModal) {
    require(element != nullptr, "Dialog missing");
    ComPtr<IUIAutomationElement9> info;
    check(element->QueryInterface(IID_PPV_ARGS(&info)), "Dialog information");
    BOOL isDialog = FALSE;
    check(info->get_CurrentIsDialog(&isDialog), "IsDialog");
    require(isDialog, "Dialog role missing from UI Automation");
    StringResult aria;
    check(element->get_CurrentAriaRole(&aria.value), "Dialog ARIA role");
    require(aria.str() == role, "Incorrect dialog ARIA role");
    CONTROLTYPEID control;
    check(element->get_CurrentControlType(&control), "Dialog control type");
    require(control == UIA_WindowControlTypeId, "Incorrect dialog control type");
    ComPtr<IUIAutomationWindowPattern> pattern;
    check(element->GetCurrentPatternAs(UIA_WindowPatternId, IID_PPV_ARGS(&pattern)), "Dialog WindowPattern");
    require(pattern.Get() != nullptr, "Missing dialog WindowPattern");
    BOOL modal = FALSE;
    check(pattern->get_CurrentIsModal(&modal), "WindowPattern.IsModal");
    require(modal == expectedModal, "Authored modality was lost");
    WindowInteractionState state;
    check(pattern->get_CurrentWindowInteractionState(&state), "WindowPattern.WindowInteractionState");
    require(state == WindowInteractionState_ReadyForUserInteraction, "Dialog is not ready");
    require(pattern->SetWindowVisualState(WindowVisualState_Maximized) == UIA_E_INVALIDOPERATION,
            "Dialog accepted a host window visual state change");
    require(pattern->Close() == UIA_E_NOTSUPPORTED, "Dialog accepted a host window close");
    BOOL idle = FALSE;
    require(pattern->WaitForInputIdle(0, &idle) == UIA_E_NOTSUPPORTED, "Dialog accepted WaitForInputIdle");
}

static void checkDialogPatterns(IUIAutomation *uia, IUIAutomationElement *window) {
    ComPtr<IUIAutomationElement9> root;
    check(window->QueryInterface(IID_PPV_ARGS(&root)), "Window information");
    BOOL isDialog = TRUE;
    check(root->get_CurrentIsDialog(&isDialog), "Window IsDialog");
    require(!isDialog, "Ordinary Rune window claimed to be a dialog");
    auto pane = field(uia, window, L"scroll-pane");
    require(pane.Get() != nullptr, "Plain scroll view missing");
    CONTROLTYPEID control;
    check(pane->get_CurrentControlType(&control), "Scroll view control type");
    require(control == UIA_PaneControlTypeId, "Plain scroll view must be a pane");
    StringResult aria;
    check(pane->get_CurrentAriaRole(&aria.value), "Scroll view ARIA role");
    require(aria.str() == L"region", "Plain scroll view must expose region ARIA semantics");
    checkDialog(field(uia, window, L"modeless-dialog").Get(), L"dialog", FALSE);
    checkDialog(field(uia, window, L"alert-dialog").Get(), L"alertdialog", FALSE);

    auto button = field(uia, window, L"open-modal");
    require(button.Get() != nullptr, "Confirmation button missing");
    ComPtr<IUIAutomationWindowPattern> ordinary;
    HRESULT hr = button->GetCurrentPatternAs(UIA_WindowPatternId, IID_PPV_ARGS(&ordinary));
    require((SUCCEEDED(hr) || hr == UIA_E_NOTSUPPORTED) && !ordinary.Get(), "Button advertised WindowPattern");
    ComPtr<IUIAutomationInvokePattern> invoke;
    check(button->GetCurrentPatternAs(UIA_InvokePatternId, IID_PPV_ARGS(&invoke)), "Open dialog pattern");
    require(invoke.Get() != nullptr, "Confirmation button cannot be invoked");
    check(invoke->Invoke(), "Open modal dialog");
    ComPtr<IUIAutomationElement> modal;
    waitFor([&] { modal = field(uia, window, L"modal-dialog"); return modal.Get() != nullptr; }, "Missing modal dialog");
    checkDialog(modal.Get(), L"dialog", TRUE);
}

static void run(DWORD pid) {
    ComPtr<IUIAutomation> uia;
    check(CoCreateInstance(CLSID_CUIAutomation8, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&uia)),
          "Create UI Automation client");
    TargetWindow target{pid};
    ComPtr<IUIAutomationElement> window, editor, password, document;
    waitFor([&] {
        if (!target.hwnd) EnumWindows(findWindow, reinterpret_cast<LPARAM>(&target));
        if (!target.hwnd) return false;
        HRESULT hr = uia->ElementFromHandle(target.hwnd, &window);
        if (hr == UIA_E_TIMEOUT || hr == HRESULT_FROM_WIN32(ERROR_TIMEOUT) || hr == UIA_E_ELEMENTNOTAVAILABLE)
            return false;
        check(hr, "Resolving Rune window");
        if (!window.Get()) return false;
        editor = field(uia.Get(), window.Get(), L"editor");
        password = field(uia.Get(), window.Get(), L"password");
        document = field(uia.Get(), window.Get(), L"document");
        return editor.Get() && password.Get() && document.Get();
    }, "The Swift fixture did not publish its text fields", 120000);
    checkEditor(editor.Get());
    checkPassword(password.Get());
    checkLargeDocument(document.Get(), editor.Get());
    checkDocumentStructure(uia.Get(), window.Get());
    auto revision = field(uia.Get(), window.Get(), L"revision");
    require(revision.Get() != nullptr, "Revision editor missing");
    checkRetainedRange(revision.Get());
    checkDialogPatterns(uia.Get(), window.Get());
    std::puts("Rune UIA verified Unicode text, visible ranges, graphemes, selection, caret attributes, "
              "password redaction, long-document hit testing, ScrollItem and TextRange scrolling, headings, "
              "landmarks, retained range recovery after editing and modeless, modal and alert dialogs.");
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    DWORD pid = static_cast<DWORD>(std::strtoul(argv[1], nullptr, 10));
    if (!pid) return 2;
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) return 1;
    int result = 0;
    try { run(pid); }
    catch (const std::exception &error) { std::fprintf(stderr, "%s\n", error.what()); result = 1; }
    CoUninitialize();
    return result;
}
