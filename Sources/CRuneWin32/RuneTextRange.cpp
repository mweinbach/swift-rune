#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include "RuneTextProvider.hpp"
#include <algorithm>
#include <atomic>
#include <cstdint>
#include <limits>
#include <mutex>
#include <new>

namespace {
struct Span {
    int start, end;
    int endpoint(TextPatternRangeEndpoint side) const {
        return side == TextPatternRangeEndpoint_Start ? start : end;
    }
    void setEndpoint(TextPatternRangeEndpoint side, int value) {
        if (side == TextPatternRangeEndpoint_Start) {
            start = value;
            end = std::max(end, value);
        } else {
            end = value;
            start = std::min(start, value);
        }
    }
};

bool validEndpoint(TextPatternRangeEndpoint side) {
    return side == TextPatternRangeEndpoint_Start || side == TextPatternRangeEndpoint_End;
}

bool validUnit(TextUnit unit) {
    return unit >= TextUnit_Character && unit <= TextUnit_Document;
}

// Snap retained offsets to available Rune insertion points after an edit.
int snap(const std::vector<int> &graphemes, int offset) {
    auto next = std::upper_bound(graphemes.begin(), graphemes.end(), offset);
    return next == graphemes.begin() ? 0 : *(next - 1);
}

void appendBoundary(std::vector<int> &bounds, int value) {
    if (bounds.back() != value) bounds.push_back(value);
}

bool lineBreak(wchar_t ch) {
    return ch == L'\r' || ch == L'\n' || ch == 0x0085 || ch == 0x2028 || ch == 0x2029;
}

std::vector<int> unitBoundaries(const RuneUiaTextContent &data, TextUnit unit) {
    const auto &graphemes = data.graphemes;
    const int length = static_cast<int>(data.text.size());
    std::vector<int> bounds{0};
    if (unit == TextUnit_Format || unit == TextUnit_Word) {
        // Rune fields have a single format. UIA promotes unsupported Format to Word.
        // UIA word units include trailing whitespace.
        std::vector<WORD> classes(length);
        if (length) GetStringTypeW(CT_CTYPE1, data.text.data(), length, classes.data());
        int previous = -1;
        for (size_t i = 0; i + 1 < graphemes.size(); ++i) {
            const int offset = graphemes[i];
            const WORD flags = classes[offset];
            const int kind = flags & C1_SPACE ? 0 : (flags & C1_PUNCT ? 1 : 2);
            if (kind != 0 && kind != previous) appendBoundary(bounds, offset);
            previous = kind;
        }
    } else if (unit == TextUnit_Line || unit == TextUnit_Paragraph) {
        for (size_t i = 0; i + 1 < graphemes.size(); ++i) {
            if (lineBreak(data.text[graphemes[i]])) appendBoundary(bounds, graphemes[i + 1]);
        }
        if (unit == TextUnit_Line) {
            // Cells within a visual line can arrive in right-to-left order. The
            // smallest logical offset on that line is its start in the document.
            int previousLine = -1, lineStart = 0;
            for (const auto &cell : data.cells) {
                if (cell.line != previousLine) {
                    if (previousLine > 0) bounds.push_back(lineStart);
                    previousLine = cell.line;
                    lineStart = cell.start;
                } else {
                    lineStart = std::min(lineStart, static_cast<int>(cell.start));
                }
            }
            if (previousLine > 0) bounds.push_back(lineStart);
            std::sort(bounds.begin(), bounds.end());
            bounds.erase(std::unique(bounds.begin(), bounds.end()), bounds.end());
        }
    }
    // Unpaginated fields promote Page to Document.
    appendBoundary(bounds, length);
    return bounds;
}

// Index of the unit containing an insertion point. The document end belongs to
// the last unit when expanding a range, but remains a valid caret destination.
int enclosingIndex(const std::vector<int> &bounds, int offset) {
    const int lastUnit = std::max(0, static_cast<int>(bounds.size()) - 2);
    const auto next = std::upper_bound(bounds.begin(), bounds.end(), offset);
    return std::min(lastUnit, std::max(0, static_cast<int>(next - bounds.begin()) - 1));
}

int shiftedIndex(int from, int count, int last) {
    const auto desired = static_cast<int64_t>(from) + count;
    return static_cast<int>(std::max<int64_t>(0, std::min<int64_t>(last, desired)));
}

int advanceEndpoint(const std::vector<int> &bounds, int offset, int count, int &moved) {
    if (count == 0 || bounds.empty()) return offset;
    // An endpoint inside a unit moves to its first boundary in the direction of
    // travel on the first step. Further steps advance one boundary at a time.
    const auto boundary = count > 0 ? std::upper_bound(bounds.begin(), bounds.end(), offset)
                                    : std::lower_bound(bounds.begin(), bounds.end(), offset);
    const int from = static_cast<int>(boundary - bounds.begin()) - (count > 0 ? 1 : 0);
    const int to = shiftedIndex(from, count, static_cast<int>(bounds.size()) - 1);
    moved = to - from;
    return bounds[to];
}

struct LineBox {
    int line;
    double x, y, right, bottom;
};

HRESULT boundingRectangles(const RuneUiaTextSnapshot &snapshot, Span range, SAFEARRAY **out) {
    std::vector<LineBox> boxes;
    if (range.start < range.end) {
        auto &clip = snapshot.viewport;
        for (const auto &cell : snapshot.content->cells) {
            if (cell.start >= range.end || cell.end <= range.start) continue;
            LineBox box{cell.line, std::max(cell.x, clip.left), std::max(cell.y, clip.top),
                        std::min(cell.x + cell.width, clip.left + clip.width),
                        std::min(cell.y + cell.height, clip.top + clip.height)};
            if (box.right > box.x && box.bottom > box.y) boxes.push_back(box);
        }
    }
    std::sort(boxes.begin(), boxes.end(), [](const LineBox &a, const LineBox &b) {
        return a.line == b.line ? a.x < b.x : a.line < b.line;
    });
    std::vector<LineBox> runs;
    for (auto box : boxes) {
        if (!runs.empty() && runs.back().line == box.line && box.x <= runs.back().right + 0.01) {
            auto &run = runs.back();
            run.right = std::max(run.right, box.right);
            run.bottom = std::max(run.bottom, box.bottom);
            run.y = std::min(run.y, box.y);
        } else {
            runs.push_back(box);
        }
    }
    if (runs.size() > std::numeric_limits<ULONG>::max() / 4) return E_OUTOFMEMORY;
    SAFEARRAY *result = SafeArrayCreateVector(VT_R8, 0, static_cast<ULONG>(runs.size() * 4));
    if (!result) return E_OUTOFMEMORY;
    if (!runs.empty()) {
        double *values = nullptr;
        HRESULT hr = SafeArrayAccessData(result, reinterpret_cast<void **>(&values));
        if (FAILED(hr)) { SafeArrayDestroy(result); return hr; }
        for (const auto &run : runs) {
            *values++ = run.x + snapshot.screenX;
            *values++ = run.y + snapshot.screenY;
            *values++ = run.right - run.x;
            *values++ = run.bottom - run.y;
        }
        SafeArrayUnaccessData(result);
    }
    *out = result;
    return S_OK;
}

// UIA passes range arguments back to their provider. Querying a private interface
// lets us validate ownership without casting a foreign COM implementation.
const IID runeRangeId = {0x4ce22525, 0xcd97, 0x4a44, {0xb3,0xfa,0x32,0xb9,0x73,0xa2,0x78,0x14}};
struct RuneRangeAccess : IUnknown {
    virtual HRESULT STDMETHODCALLTYPE boundsFor(const RuneUiaTextSource &source,
                                                const RuneUiaTextContent &content, Span &out) = 0;
};

class TextRange final : public ITextRangeProvider, public RuneRangeAccess {
    std::atomic<ULONG> refs{1};
    RuneUiaTextSource *source;
    std::mutex lock;
    Span endpoints;

    Span current(const RuneUiaTextContent &content) const {
        return {snap(content.graphemes, endpoints.start), snap(content.graphemes, endpoints.end)};
    }
    HRESULT read(RuneUiaTextSnapshot &snapshot, Span &range) {
        HRESULT hr = source->readText(snapshot);
        if (FAILED(hr)) return hr;
        std::lock_guard<std::mutex> guard(lock);
        range = current(*snapshot.content);
        return S_OK;
    }
    HRESULT targetSpan(ITextRangeProvider *target, const RuneUiaTextContent &content, Span &span) {
        if (!target) return E_INVALIDARG;
        RuneRangeAccess *access = nullptr;
        HRESULT hr = target->QueryInterface(runeRangeId, reinterpret_cast<void **>(&access));
        if (FAILED(hr)) return hr == E_NOINTERFACE ? E_INVALIDARG : hr;
        hr = access->boundsFor(*source, content, span);
        access->Release();
        return hr;
    }
    HRESULT unsupported(HRESULT reason) {
        RuneUiaTextSnapshot snapshot;
        HRESULT hr = source->readText(snapshot);
        return FAILED(hr) ? hr : reason;
    }

public:
    TextRange(RuneUiaTextSource *owner, Span span) : source(owner), endpoints(span) {
        source->textOwner()->AddRef();
    }
    ~TextRange() { source->textOwner()->Release(); }

    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
    ULONG STDMETHODCALLTYPE Release() override {
        ULONG remaining = --refs;
        if (!remaining) delete this;
        return remaining;
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (iid == __uuidof(IUnknown) || iid == __uuidof(ITextRangeProvider))
            *out = static_cast<ITextRangeProvider *>(this);
        else if (iid == runeRangeId)
            *out = static_cast<RuneRangeAccess *>(this);
        else return E_NOINTERFACE;
        AddRef();
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE boundsFor(const RuneUiaTextSource &owner,
                                        const RuneUiaTextContent &content, Span &out) override {
        if (!source->sameText(owner)) return E_INVALIDARG;
        std::lock_guard<std::mutex> guard(lock);
        out = current(content);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Clone(ITextRangeProvider **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        RuneUiaTextSnapshot snapshot;
        Span range;
        HRESULT hr = read(snapshot, range);
        return FAILED(hr) ? hr : runeCreateTextRange(source, range.start, range.end, out);
    }
    HRESULT STDMETHODCALLTYPE Compare(ITextRangeProvider *target, BOOL *out) override {
        if (!out) return E_POINTER;
        *out = FALSE;
        RuneUiaTextSnapshot snapshot;
        Span range, other;
        HRESULT hr = read(snapshot, range);
        if (FAILED(hr)) return hr;
        hr = targetSpan(target, *snapshot.content, other);
        if (FAILED(hr)) return hr;
        *out = range.start == other.start && range.end == other.end;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE CompareEndpoints(TextPatternRangeEndpoint side, ITextRangeProvider *target,
                                                 TextPatternRangeEndpoint targetSide, int *out) override {
        if (!out) return E_POINTER;
        *out = 0;
        if (!validEndpoint(side) || !validEndpoint(targetSide)) return E_INVALIDARG;
        RuneUiaTextSnapshot snapshot;
        Span range, other;
        HRESULT hr = read(snapshot, range);
        if (FAILED(hr)) return hr;
        hr = targetSpan(target, *snapshot.content, other);
        if (FAILED(hr)) return hr;
        *out = range.endpoint(side) - other.endpoint(targetSide);
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE ExpandToEnclosingUnit(TextUnit unit) override {
        if (!validUnit(unit)) return E_INVALIDARG;
        RuneUiaTextSnapshot snapshot;
        HRESULT hr = source->readText(snapshot);
        if (FAILED(hr)) return hr;
        const auto &data = *snapshot.content;
        std::vector<int> larger;
        if (unit != TextUnit_Character) larger = unitBoundaries(data, unit);
        const auto &bounds = unit == TextUnit_Character ? data.graphemes : larger;
        std::lock_guard<std::mutex> guard(lock);
        if (bounds.size() < 2) { endpoints = {0, 0}; return S_OK; }
        const int i = enclosingIndex(bounds, current(data).start);
        endpoints = {bounds[i], bounds[i + 1]};
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE FindAttribute(TEXTATTRIBUTEID id, VARIANT value, BOOL,
                                            ITextRangeProvider **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        RuneUiaTextSnapshot snapshot;
        Span range;
        HRESULT hr = read(snapshot, range);
        if (FAILED(hr)) return hr;
        if (id != UIA_IsReadOnlyAttributeId) return S_OK;
        if (value.vt != VT_BOOL) return E_INVALIDARG;
        if ((value.boolVal != VARIANT_FALSE) != snapshot.readOnly) return S_OK;
        return runeCreateTextRange(source, range.start, range.end, out);
    }
    HRESULT STDMETHODCALLTYPE FindText(BSTR text, BOOL backward, BOOL ignoreCase, ITextRangeProvider **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        const UINT needle = SysStringLen(text);
        if (!needle || needle > static_cast<UINT>(std::numeric_limits<int>::max())) return E_INVALIDARG;
        RuneUiaTextSnapshot snapshot;
        Span range;
        HRESULT hr = read(snapshot, range);
        if (FAILED(hr)) return hr;
        const int n = static_cast<int>(needle);
        if (n > range.end - range.start) return S_OK;
        const auto &data = *snapshot.content;
        // Compare ordinal UTF-16 at real insertion points. A match cannot leave a
        // client with half of an emoji, surrogate pair, or combining sequence.
        auto first = std::lower_bound(data.graphemes.begin(), data.graphemes.end(), range.start);
        auto last = std::upper_bound(first, data.graphemes.end(), range.end - n);
        while (first != last) {
            const int at = backward ? *--last : *first++;
            bool match = ignoreCase
                ? CompareStringOrdinal(data.text.data() + at, n, text, n, TRUE) == CSTR_EQUAL
                : data.text.compare(at, n, text, needle) == 0;
            if (match && std::binary_search(data.graphemes.begin(), data.graphemes.end(), at + n))
                return runeCreateTextRange(source, at, at + n, out);
        }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetAttributeValue(TEXTATTRIBUTEID id, VARIANT *out) override {
        if (!out) return E_POINTER;
        VariantInit(out);
        RuneUiaTextSnapshot snapshot;
        HRESULT hr = source->readText(snapshot);
        if (FAILED(hr)) return hr;
        if (id == UIA_IsReadOnlyAttributeId) {
            out->vt = VT_BOOL;
            out->boolVal = snapshot.readOnly ? VARIANT_TRUE : VARIANT_FALSE;
            return S_OK;
        }
        hr = UiaGetReservedNotSupportedValue(&out->punkVal);
        if (SUCCEEDED(hr)) out->vt = VT_UNKNOWN;
        return hr;
    }
    HRESULT STDMETHODCALLTYPE GetBoundingRectangles(SAFEARRAY **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        RuneUiaTextSnapshot snapshot;
        Span range;
        HRESULT hr = read(snapshot, range);
        return FAILED(hr) ? hr : boundingRectangles(snapshot, range, out);
    }
    HRESULT STDMETHODCALLTYPE GetEnclosingElement(IRawElementProviderSimple **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        RuneUiaTextSnapshot snapshot;
        HRESULT hr = source->readText(snapshot);
        if (FAILED(hr)) return hr;
        *out = source->textOwner();
        (*out)->AddRef();
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetText(int maxLength, BSTR *out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (maxLength < -1) return E_INVALIDARG;
        RuneUiaTextSnapshot snapshot;
        Span range;
        HRESULT hr = read(snapshot, range);
        if (FAILED(hr)) return hr;
        const auto &text = snapshot.content->text;
        int count = range.end - range.start;
        if (maxLength >= 0 && count > maxLength) {
            count = maxLength;
            if (count > 0 && IS_HIGH_SURROGATE(text[range.start + count - 1])) --count;
        }
        *out = SysAllocStringLen(text.data() + range.start, static_cast<UINT>(count));
        return *out ? S_OK : E_OUTOFMEMORY;
    }
    HRESULT STDMETHODCALLTYPE Move(TextUnit unit, int count, int *moved) override {
        if (!moved) return E_POINTER;
        *moved = 0;
        if (!validUnit(unit)) return E_INVALIDARG;
        RuneUiaTextSnapshot snapshot;
        HRESULT hr = source->readText(snapshot);
        if (FAILED(hr) || count == 0) return hr;
        const auto &data = *snapshot.content;
        std::vector<int> larger;
        if (unit != TextUnit_Character) larger = unitBoundaries(data, unit);
        const auto &bounds = unit == TextUnit_Character ? data.graphemes : larger;
        std::lock_guard<std::mutex> guard(lock);
        const Span range = current(data);
        if (bounds.size() < 2) return S_OK;
        if (range.start == range.end) {
            const int offset = advanceEndpoint(bounds, range.start, count, *moved);
            endpoints = {offset, offset};
        } else {
            const int from = enclosingIndex(bounds, range.start);
            const int to = shiftedIndex(from, count, static_cast<int>(bounds.size()) - 2);
            *moved = to - from;
            if (*moved) endpoints = {bounds[to], bounds[to + 1]};
        }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE MoveEndpointByUnit(TextPatternRangeEndpoint side, TextUnit unit,
                                                 int count, int *moved) override {
        if (!moved) return E_POINTER;
        *moved = 0;
        if (!validUnit(unit) || !validEndpoint(side)) return E_INVALIDARG;
        RuneUiaTextSnapshot snapshot;
        HRESULT hr = source->readText(snapshot);
        if (FAILED(hr) || count == 0) return hr;
        const auto &data = *snapshot.content;
        std::vector<int> larger;
        if (unit != TextUnit_Character) larger = unitBoundaries(data, unit);
        const auto &bounds = unit == TextUnit_Character ? data.graphemes : larger;
        std::lock_guard<std::mutex> guard(lock);
        endpoints = current(data);
        const int offset = advanceEndpoint(bounds, endpoints.endpoint(side), count, *moved);
        endpoints.setEndpoint(side, offset);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE MoveEndpointByRange(TextPatternRangeEndpoint side, ITextRangeProvider *target,
                                                  TextPatternRangeEndpoint targetSide) override {
        if (!validEndpoint(side) || !validEndpoint(targetSide)) return E_INVALIDARG;
        RuneUiaTextSnapshot snapshot;
        HRESULT hr = source->readText(snapshot);
        if (FAILED(hr)) return hr;
        Span other;
        hr = targetSpan(target, *snapshot.content, other);
        if (FAILED(hr)) return hr;
        std::lock_guard<std::mutex> guard(lock);
        endpoints = current(*snapshot.content);
        endpoints.setEndpoint(side, other.endpoint(targetSide));
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Select() override {
        RuneUiaTextSnapshot snapshot;
        Span range;
        HRESULT hr = read(snapshot, range);
        if (FAILED(hr)) return hr;
        if (!snapshot.selectable) return UIA_E_INVALIDOPERATION;
        return source->selectText(range.start, range.end, *snapshot.content);
    }
    HRESULT STDMETHODCALLTYPE AddToSelection() override { return unsupported(UIA_E_INVALIDOPERATION); }
    HRESULT STDMETHODCALLTYPE RemoveFromSelection() override { return unsupported(UIA_E_INVALIDOPERATION); }
    HRESULT STDMETHODCALLTYPE ScrollIntoView(BOOL) override { return unsupported(UIA_E_NOTSUPPORTED); }
    HRESULT STDMETHODCALLTYPE GetChildren(SAFEARRAY **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        RuneUiaTextSnapshot snapshot;
        HRESULT hr = source->readText(snapshot);
        if (FAILED(hr)) return hr;
        *out = SafeArrayCreateVector(VT_UNKNOWN, 0, 0);
        return *out ? S_OK : E_OUTOFMEMORY;
    }
};
} // namespace

HRESULT runeCreateTextRange(RuneUiaTextSource *source, int start, int end, ITextRangeProvider **out) {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (!source || start < 0 || end < start) return E_INVALIDARG;
    *out = new (std::nothrow) TextRange(source, {start, end});
    return *out ? S_OK : E_OUTOFMEMORY;
}
#endif
