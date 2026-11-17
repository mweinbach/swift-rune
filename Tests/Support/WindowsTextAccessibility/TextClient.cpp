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

static std::wstring read(IUIAutomationTextRange *range) {
    StringResult result;
    check(range->GetText(-1, &result.value), "GetText");
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

static void run(DWORD pid) {
    ComPtr<IUIAutomation> uia;
    check(CoCreateInstance(CLSID_CUIAutomation8, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&uia)),
          "Create UI Automation client");
    TargetWindow target{pid};
    ComPtr<IUIAutomationElement> editor, password;
    waitFor([&] {
        if (!target.hwnd) EnumWindows(findWindow, reinterpret_cast<LPARAM>(&target));
        if (!target.hwnd) return false;
        ComPtr<IUIAutomationElement> window;
        check(uia->ElementFromHandle(target.hwnd, &window), "Resolving Rune window");
        editor = field(uia.Get(), window.Get(), L"editor");
        password = field(uia.Get(), window.Get(), L"password");
        return editor.Get() && password.Get();
    }, "The Swift fixture did not publish its text fields", 120000);
    checkEditor(editor.Get());
    checkPassword(password.Get());
    std::puts("Rune UIA verified Unicode document/value, grapheme movement, screen hit testing, backward/forward selection, caret and password redaction.");
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
