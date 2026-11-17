#pragma once
#ifdef _WIN32
#include "RuneAccessibility.h"
#include <windows.h>
#include <uiautomation.h>
#include <memory>
#include <string>
#include <vector>

struct RuneUiaTextContent {
    std::wstring text;
    std::vector<int> graphemes;   // UTF-16 insertion offsets, including 0 and the end.
    std::vector<RuneUiaTextCell> cells;
};
struct RuneUiaTextSnapshot {
    std::shared_ptr<const RuneUiaTextContent> content;
    int anchor = 0, focus = 0;
    bool focused = false, readOnly = true, selectable = false;
    double screenX = 0, screenY = 0;
    UiaRect viewport{};          // Client-pixel coordinates, as are the cells.
};

// A text range retains textOwner() while it uses this interface. readText() returns
// UIA_E_ELEMENTNOTAVAILABLE for retired nodes and rejects secure fields.
struct RuneUiaTextSource {
    virtual IRawElementProviderSimple *textOwner() = 0;
    virtual const void *textWindow() const = 0;
    virtual int textId() const = 0;
    bool sameText(const RuneUiaTextSource &other) const {
        return textWindow() == other.textWindow() && textId() == other.textId();
    }
    virtual HRESULT readText(RuneUiaTextSnapshot &snapshot) = 0;
    virtual HRESULT selectText(int start, int end, const RuneUiaTextContent &expected) = 0;
};
HRESULT runeCreateTextRange(RuneUiaTextSource *source, int start, int end, ITextRangeProvider **out);
HRESULT runeCreateTextProvider(RuneUiaTextSource *source, IUnknown **out);
#endif
