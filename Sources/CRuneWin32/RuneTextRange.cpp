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

void appendBoundary(std::vector<int> &bounds, int value) {
    if (bounds.back() != value) bounds.push_back(value);
}

bool lineBreak(wchar_t ch) {
    return ch == L'\r' || ch == L'\n' || ch == 0x0085 || ch == 0x2028 || ch == 0x2029;
}

bool unicodeSpace(wchar_t ch) {
    return (ch >= 0x0009 && ch <= 0x000D) || ch == 0x0020 || ch == 0x0085 || ch == 0x00A0 ||
           ch == 0x1680 || (ch >= 0x2000 && ch <= 0x200A) || ch == 0x2028 || ch == 0x2029 ||
           ch == 0x202F || ch == 0x205F || ch == 0x3000;
}

std::vector<int> wordBoundaries(const RuneUiaTextContent &data) {
    const auto &text = data.text;
    std::vector<int> bounds{0};
    std::vector<uint8_t> flags;
    if (data.wordBreaks && !text.empty()) {
        flags.resize(text.size());
        data.wordBreaks(reinterpret_cast<const uint16_t *>(text.data()), static_cast<int32_t>(text.size()), flags.data());
    }
    size_t line = 0;
    for (size_t i = 1; i + 1 < data.characters.size(); ++i) {
        const int at = data.characters[i];
        if (flags.empty()) {
            if (unicodeSpace(text[at - 1]) && !unicodeSpace(text[at])) bounds.push_back(at);
            continue;
        }
        while (line + 1 < data.lineStarts.size() && data.lineStarts[line + 1] <= static_cast<int>(i)) ++line;
        const size_t inLine = i - data.lineStarts[line];
        // Rune's shaped runs store interior word breaks as u8 character indices.
        // A hard paragraph starts a word unit. Soft wraps alone do not split a word.
        if ((inLine == 0 && text[at - 1] == L'\n') ||
            (inLine > 0 && inLine < 256 && text[at] != L'\n' && flags[at])) {
            bounds.push_back(at);
        }
    }
    appendBoundary(bounds, static_cast<int>(text.size()));
    return bounds;
}

const std::vector<int> &unitBoundaries(const RuneUiaTextContent &data, TextUnit unit, std::vector<int> &bounds) {
    const auto &characters = data.characters;
    const int length = static_cast<int>(data.text.size());
    if (unit == TextUnit_Character) return characters;
    if (unit == TextUnit_Word) {
        std::call_once(data.wordsReady, [&] { data.words = wordBoundaries(data); });
        return data.words;
    }
    bounds.push_back(0);
    if (data.valueOnly) {
        // Rune's long_text adapter uses whitespace-delimited words and LF-delimited
        // lines. Format and Page expand to Document in the absence of text runs.
        if (unit == TextUnit_Line || unit == TextUnit_Paragraph) {
            for (size_t i = 1; i + 1 < characters.size(); ++i) {
                const int at = characters[i];
                if (data.text[at - 1] == L'\n') bounds.push_back(at);
            }
        }
        appendBoundary(bounds, length);
        return bounds;
    }
    if (unit == TextUnit_Line && !data.cells.empty()) {
        for (int line : data.lineStarts) appendBoundary(bounds, characters[line]);
    } else if (unit == TextUnit_Line || unit == TextUnit_Paragraph) {
        for (size_t i = 0; i + 1 < characters.size(); ++i) {
            if (lineBreak(data.text[characters[i]])) appendBoundary(bounds, characters[i + 1]);
        }
    }
    // Rune publishes one text format and no pages, so Format and Page cover the document.
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

// AccessKit retains an endpoint as (text run ID, character index). Rune emits one
// run per visual line. Its value-only fields instead retain a byte index in the value.
struct TextPosition {
    int line;
    uint64_t index;

    static TextPosition capture(const RuneUiaTextContent &data, int offset, bool preferPreviousLine) {
        auto after = std::upper_bound(data.characters.begin(), data.characters.end(), offset);
        const int character = static_cast<int>(after - data.characters.begin()) - 1;
        if (data.valueOnly) {
            const size_t block = static_cast<size_t>(character) / data.scalarBlock;
            uint64_t bytes = data.byteBlocks[block];
            for (size_t i = block * data.scalarBlock; i < static_cast<size_t>(character); ++i)
                bytes += data.utf8Width(data.text[data.characters[i]]);
            return {-1, bytes};
        }
        auto nextLine = preferPreviousLine && character > 0
            ? std::lower_bound(data.lineStarts.begin(), data.lineStarts.end(), character)
            : std::upper_bound(data.lineStarts.begin(), data.lineStarts.end(), character);
        const int line = std::max(0, static_cast<int>(nextLine - data.lineStarts.begin()) - 1);
        return {line, static_cast<uint64_t>(character - data.lineStarts[line])};
    }

    int resolve(const RuneUiaTextContent &data) {
        const int last = static_cast<int>(data.characters.size()) - 1;
        if ((line < 0) != data.valueOnly) return -1;
        if (data.valueOnly) {
            auto after = std::upper_bound(data.byteBlocks.begin(), data.byteBlocks.end(), index);
            const size_t block = static_cast<size_t>(after - data.byteBlocks.begin() - 1);
            int i = static_cast<int>(block * data.scalarBlock);
            uint64_t bytes = data.byteBlocks[block];
            while (i < last) {
                auto next = bytes + data.utf8Width(data.text[data.characters[i]]);
                if (next > index) break;
                bytes = next;
                ++i;
            }
            index = bytes; // A shorter or changed value clamps to a current scalar boundary.
            return data.characters[i];
        }
        if (line >= static_cast<int>(data.lineStarts.size())) return -1;
        const int first = data.lineStarts[line];
        const int end = line + 1 < static_cast<int>(data.lineStarts.size()) ? data.lineStarts[line + 1] : last;
        if (index > static_cast<uint64_t>(end - first)) return -1;
        return data.characters[first + static_cast<int>(index)];
    }
};

class TextRange final : public ITextRangeProvider, public RuneRangeAccess {
    std::atomic<ULONG> refs{1};
    RuneUiaTextSource *source;
    std::mutex lock;
    TextPosition start{}, end{};

    void set(const RuneUiaTextContent &content, Span range) {
        start = TextPosition::capture(content, range.start, false);
        end = range.start == range.end ? start : TextPosition::capture(content, range.end, true);
    }
    HRESULT current(const RuneUiaTextContent &content, Span &range) {
        range = {start.resolve(content), end.resolve(content)};
        return range.start >= 0 && range.end >= range.start ? S_OK : UIA_E_ELEMENTNOTAVAILABLE;
    }
    HRESULT read(RuneUiaTextSnapshot &snapshot, Span &range) {
        HRESULT hr = source->readText(snapshot);
        if (FAILED(hr)) return hr;
        std::lock_guard<std::mutex> guard(lock);
        return current(*snapshot.content, range);
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
    TextRange(RuneUiaTextSource *owner, const RuneUiaTextContent &content, Span range) : source(owner) {
        set(content, range);
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
        return current(content, out);
    }
    HRESULT STDMETHODCALLTYPE Clone(ITextRangeProvider **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        RuneUiaTextSnapshot snapshot;
        Span range;
        HRESULT hr = read(snapshot, range);
        return FAILED(hr) ? hr : runeCreateTextRange(source, *snapshot.content, range.start, range.end, out);
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
        const auto &bounds = unitBoundaries(data, unit, larger);
        std::lock_guard<std::mutex> guard(lock);
        // Narrator recovers a stale run by expanding it back to this field's document.
        if (unit == TextUnit_Document && !data.valueOnly && start.line >= 0) {
            set(data, {0, static_cast<int>(data.text.size())});
            return S_OK;
        }
        Span range;
        hr = current(data, range);
        if (FAILED(hr)) return hr;
        if (bounds.size() < 2) { set(data, {0, 0}); return S_OK; }
        if (range.start == static_cast<int>(data.text.size())) {
            if (unit == TextUnit_Character) return S_OK;
            if (data.valueOnly && (unit == TextUnit_Line || unit == TextUnit_Paragraph) && data.text.back() == L'\n') {
                set(data, {range.start, range.start});
                return S_OK;
            }
        }
        const int i = enclosingIndex(bounds, range.start);
        set(data, {bounds[i], bounds[i + 1]});
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
        return runeCreateTextRange(source, *snapshot.content, range.start, range.end, out);
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
        auto first = std::lower_bound(data.characters.begin(), data.characters.end(), range.start);
        auto last = std::upper_bound(first, data.characters.end(), range.end - n);
        while (first != last) {
            const int at = backward ? *--last : *first++;
            bool match = ignoreCase
                ? CompareStringOrdinal(data.text.data() + at, n, text, n, TRUE) == CSTR_EQUAL
                : data.text.compare(at, n, text, needle) == 0;
            if (match && std::binary_search(data.characters.begin(), data.characters.end(), at + n))
                return runeCreateTextRange(source, data, at, at + n, out);
        }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetAttributeValue(TEXTATTRIBUTEID id, VARIANT *out) override {
        if (!out) return E_POINTER;
        VariantInit(out);
        RuneUiaTextSnapshot snapshot;
        Span range;
        HRESULT hr = read(snapshot, range);
        if (FAILED(hr)) return hr;
        if (id == UIA_IsReadOnlyAttributeId) {
            out->vt = VT_BOOL;
            out->boolVal = snapshot.readOnly ? VARIANT_TRUE : VARIANT_FALSE;
            return S_OK;
        }
        if (id == UIA_CaretPositionAttributeId) {
            CaretPosition position = CaretPosition_Unknown;
            if (range.start == range.end) {
                const auto &data = *snapshot.content;
                const int offset = range.start, length = static_cast<int>(data.text.size());
                const auto newline = [&](wchar_t ch) { return data.valueOnly ? ch == L'\n' : lineBreak(ch); };
                if (offset == 0 || newline(data.text[offset - 1])) {
                    position = CaretPosition_BeginningOfLine;
                } else if (offset == length || newline(data.text[offset])) {
                    position = CaretPosition_EndOfLine;
                } else if (!data.valueOnly) {
                    auto at = std::lower_bound(data.characters.begin(), data.characters.end(), offset);
                    if (std::binary_search(data.lineStarts.begin(), data.lineStarts.end(), static_cast<int>(at - data.characters.begin()))) {
                        position = CaretPosition_BeginningOfLine;
                    }
                }
            }
            out->vt = VT_I4;
            out->lVal = position;
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
            if (snapshot.content->valueOnly) {
                const auto &characters = snapshot.content->characters;
                auto start = std::lower_bound(characters.begin(), characters.end(), range.start);
                auto end = std::lower_bound(start, characters.end(), range.end);
                if (end - start > maxLength) count = start[maxLength] - range.start;
            } else {
                count = maxLength;
                if (count > 0 && IS_HIGH_SURROGATE(text[range.start + count - 1])) --count;
            }
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
        const auto &bounds = unitBoundaries(data, unit, larger);
        std::lock_guard<std::mutex> guard(lock);
        Span range;
        hr = current(data, range);
        if (FAILED(hr)) return hr;
        if (bounds.size() < 2) return S_OK;
        if (range.start == range.end) {
            const int offset = advanceEndpoint(bounds, range.start, count, *moved);
            set(data, {offset, offset});
        } else {
            const int from = enclosingIndex(bounds, range.start);
            const int last = static_cast<int>(bounds.size()) - 1;
            const int to = shiftedIndex(from, count, last);
            *moved = to - from;
            if (*moved) set(data, {bounds[to], bounds[to == last ? to : to + 1]});
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
        const auto &bounds = unitBoundaries(data, unit, larger);
        std::lock_guard<std::mutex> guard(lock);
        Span range;
        hr = current(data, range);
        if (FAILED(hr)) return hr;
        const int offset = advanceEndpoint(bounds, range.endpoint(side), count, *moved);
        range.setEndpoint(side, offset);
        set(data, range);
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
        Span range;
        hr = current(*snapshot.content, range);
        if (FAILED(hr)) return hr;
        range.setEndpoint(side, other.endpoint(targetSide));
        set(*snapshot.content, range);
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
    HRESULT STDMETHODCALLTYPE ScrollIntoView(BOOL) override {
        RuneUiaTextSnapshot snapshot;
        Span range;
        HRESULT hr = read(snapshot, range);
        return FAILED(hr) ? hr : source->scrollTextIntoView();
    }
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

HRESULT runeCreateTextRange(RuneUiaTextSource *source, const RuneUiaTextContent &content, int start, int end, ITextRangeProvider **out) {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (!source || start < 0 || end < start) return E_INVALIDARG;
    *out = new (std::nothrow) TextRange(source, content, {start, end});
    return *out ? S_OK : E_OUTOFMEMORY;
}
#endif
