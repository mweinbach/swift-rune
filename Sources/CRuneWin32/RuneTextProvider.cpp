#ifdef _WIN32
#define NOMINMAX
#include "RuneTextProvider.hpp"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <limits>
#include <new>

namespace {
using Span = std::pair<int, int>;

HRESULT rangesArray(RuneUiaTextSource *source, const RuneUiaTextContent &content, const std::vector<Span> &spans, SAFEARRAY **out) {
    *out = nullptr;
    SAFEARRAY *array = SafeArrayCreateVector(VT_UNKNOWN, 0, static_cast<ULONG>(spans.size()));
    if (!array) return E_OUTOFMEMORY;
    for (LONG i = 0; i < static_cast<LONG>(spans.size()); ++i) {
        ITextRangeProvider *range = nullptr;
        HRESULT hr = runeCreateTextRange(source, content, spans[i].first, spans[i].second, &range);
        if (SUCCEEDED(hr)) {
            hr = SafeArrayPutElement(array, &i, range);
            range->Release();
        }
        if (FAILED(hr)) { SafeArrayDestroy(array); return hr; }
    }
    *out = array;
    return S_OK;
}

class TextProvider final : public ITextProvider2 {
    std::atomic<ULONG> refs{1};
    RuneUiaTextSource *source;
public:
    explicit TextProvider(RuneUiaTextSource *s) : source(s) { source->textOwner()->AddRef(); }
    ~TextProvider() { source->textOwner()->Release(); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (iid != __uuidof(IUnknown) && iid != __uuidof(ITextProvider) && iid != __uuidof(ITextProvider2)) return E_NOINTERFACE;
        *out = static_cast<ITextProvider2 *>(this);
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
    ULONG STDMETHODCALLTYPE Release() override {
        ULONG count = --refs;
        if (!count) delete this;
        return count;
    }
    HRESULT STDMETHODCALLTYPE get_DocumentRange(ITextRangeProvider **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        RuneUiaTextSnapshot s;
        HRESULT hr = source->readText(s);
        if (FAILED(hr)) return hr;
        return runeCreateTextRange(source, *s.content, 0, static_cast<int>(s.content->text.size()), out);
    }
    HRESULT STDMETHODCALLTYPE GetSelection(SAFEARRAY **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        RuneUiaTextSnapshot s;
        HRESULT hr = source->readText(s);
        if (FAILED(hr)) return hr;
        // Every published field model carries its selection, even when the editor
        // withholds write access. Select() checks permission separately.
        return rangesArray(source, *s.content, {{std::min(s.anchor, s.focus), std::max(s.anchor, s.focus)}}, out);
    }
    HRESULT STDMETHODCALLTYPE get_SupportedTextSelection(SupportedTextSelection *out) override {
        if (!out) return E_POINTER;
        RuneUiaTextSnapshot s;
        HRESULT hr = source->readText(s);
        if (FAILED(hr)) return hr;
        *out = SupportedTextSelection_Single;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetCaretRange(BOOL *active, ITextRangeProvider **out) override {
        if (!active || !out) return E_POINTER;
        *out = nullptr;
        *active = FALSE;
        RuneUiaTextSnapshot s;
        HRESULT hr = source->readText(s);
        if (FAILED(hr)) return hr;
        *active = s.focused && s.selectable;
        return runeCreateTextRange(source, *s.content, s.focus, s.focus, out);
    }
    HRESULT STDMETHODCALLTYPE GetVisibleRanges(SAFEARRAY **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        RuneUiaTextSnapshot s;
        HRESULT hr = source->readText(s);
        if (FAILED(hr)) return hr;
        if (s.viewport.width <= 0 || s.viewport.height <= 0) return rangesArray(source, *s.content, {}, out);
        std::vector<Span> visible;
        for (const auto &cell : s.content->cells) {
            if (cell.height > 0 && cell.end >= cell.start) visible.emplace_back(cell.start, cell.end);
        }
        // Physical cell order can differ from document order for bidirectional text.
        std::sort(visible.begin(), visible.end());
        std::vector<Span> ranges;
        for (const auto &span : visible) {
            if (!ranges.empty() && span.first <= ranges.back().second) {
                ranges.back().second = std::max(ranges.back().second, span.second);
            } else {
                ranges.push_back(span);
            }
        }
        return rangesArray(source, *s.content, ranges, out);
    }
    HRESULT STDMETHODCALLTYPE RangeFromPoint(UiaPoint point, ITextRangeProvider **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        RuneUiaTextSnapshot s;
        HRESULT hr = source->readText(s);
        if (FAILED(hr)) return hr;
        // Rune publishes only the value and selection for long, elided or incompletely
        // shaped fields. Fully clipped shaped fields still have logical cells.
        if (s.content->valueOnly) return runeCreateTextRange(source, *s.content, s.focus, s.focus, out);
        if (s.viewport.width <= 0 || s.viewport.height <= 0) return UIA_E_NOTSUPPORTED;
        if (s.content->text.empty()) return runeCreateTextRange(source, *s.content, 0, 0, out);
        const double x = point.x - s.screenX, y = point.y - s.screenY;
        double closestLine = std::numeric_limits<double>::infinity();
        double closestCell = std::numeric_limits<double>::infinity();
        int insertion = -1;
        for (const auto &cell : s.content->cells) {
            if (cell.height <= 0) continue;
            const double dy = std::max({cell.y - y, y - cell.y - cell.height, 0.0});
            const double dx = std::max({cell.x - x, x - cell.x - cell.width, 0.0});
            // Beyond a short line's trailing edge, stay on the line under the pointer.
            if (dy > closestLine || (dy == closestLine && dx >= closestCell)) continue;
            closestLine = dy;
            closestCell = dx;
            const double midpoint = cell.has_hit_midpoint ? cell.hit_midpoint : cell.x + cell.width * 0.5;
            const bool trailing = x >= midpoint;
            insertion = trailing != bool(cell.rtl) ? cell.end : cell.start;
        }
        if (insertion < 0) return UIA_E_NOTSUPPORTED;
        return runeCreateTextRange(source, *s.content, insertion, insertion, out);
    }
    HRESULT STDMETHODCALLTYPE RangeFromChild(IRawElementProviderSimple *, ITextRangeProvider **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        return E_INVALIDARG; // Rune fields do not expose embedded UIA children.
    }
    HRESULT STDMETHODCALLTYPE RangeFromAnnotation(IRawElementProviderSimple *, ITextRangeProvider **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        return E_INVALIDARG;
    }
};
}

HRESULT runeCreateTextProvider(RuneUiaTextSource *source, IUnknown **out) {
    if (!out) return E_POINTER;
    *out = new (std::nothrow) TextProvider(source);
    return *out ? S_OK : E_OUTOFMEMORY;
}
#endif
