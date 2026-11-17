#if defined(_WIN32)
#define NOMINMAX
#include <windows.h>
#include <dwrite_3.h>
#include <wrl/client.h>
#include "RuneDesktopText.h"

#include <algorithm>
#include <cfloat>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <cwctype>
#include <memory>
#include <mutex>
#include <new>

using Microsoft::WRL::ComPtr;

namespace {
IDWriteFactory2 *textFactory() {
    static const ComPtr<IDWriteFactory2> factory = [] {
        ComPtr<IDWriteFactory2> result;
        DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory2),
            reinterpret_cast<IUnknown **>(result.GetAddressOf()));
        return result;
    }();
    return factory.Get();
}

std::unique_ptr<WCHAR[]> toWide(const char *utf8, int length, int &units) {
    units = length == 0 ? 0 : MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, length, nullptr, 0);
    if (length != 0 && units == 0) return nullptr;
    std::unique_ptr<WCHAR[]> wide(new (std::nothrow) WCHAR[size_t(units) + 1]);
    if (!wide) return nullptr;
    if (length != 0 && !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, length, wide.get(), units))
        return nullptr;
    wide[units] = 0;
    return wide;
}

// Keep the process-private collection separate from the system collection.
// Existing layouts retain the immutable collection they were created with.
class AppFonts {
    std::mutex lock;
    ComPtr<IDWriteFactory5> factory;
    ComPtr<IDWriteInMemoryFontFileLoader> loader;
    ComPtr<IDWriteFontSet> set;
    ComPtr<IDWriteFontCollection1> collection;

    bool append(IDWriteFontFile *file) {
        ComPtr<IDWriteFontSetBuilder1> builder;
        ComPtr<IDWriteFontSet> nextSet;
        ComPtr<IDWriteFontCollection1> nextCollection;
        if (FAILED(factory->CreateFontSetBuilder(builder.GetAddressOf())) ||
            FAILED(builder->AddFontFile(file)) ||
            (set && FAILED(builder->AddFontSet(set.Get()))) ||
            FAILED(builder->CreateFontSet(nextSet.GetAddressOf())) ||
            FAILED(factory->CreateFontCollectionFromFontSet(nextSet.Get(), nextCollection.GetAddressOf())))
            return false;
        set = std::move(nextSet);
        collection = std::move(nextCollection);
        return true;
    }
public:
    AppFonts() {
        if (textFactory())
            textFactory()->QueryInterface(__uuidof(IDWriteFactory5), reinterpret_cast<void **>(factory.GetAddressOf()));
    }
    ~AppFonts() {
        collection.Reset();
        set.Reset();
        if (loader) factory->UnregisterFontFileLoader(loader.Get());
    }
    bool addFile(const WCHAR *path) {
        std::lock_guard<std::mutex> guard(lock);
        ComPtr<IDWriteFontFile> file;
        return factory && SUCCEEDED(factory->CreateFontFileReference(path, nullptr, file.GetAddressOf())) &&
            append(file.Get());
    }
    bool addBytes(const uint8_t *bytes, uint32_t length) {
        std::lock_guard<std::mutex> guard(lock);
        if (!factory) return false;
        if (!loader) {
            ComPtr<IDWriteInMemoryFontFileLoader> candidate;
            if (FAILED(factory->CreateInMemoryFontFileLoader(candidate.GetAddressOf())) ||
                FAILED(factory->RegisterFontFileLoader(candidate.Get()))) return false;
            loader = std::move(candidate);
        }
        ComPtr<IDWriteFontFile> file;
        return SUCCEEDED(loader->CreateInMemoryFontFileReference(factory.Get(), bytes, length, nullptr,
            file.GetAddressOf())) && append(file.Get());
    }
    ComPtr<IDWriteFontCollection> find(const WCHAR *family) {
        std::lock_guard<std::mutex> guard(lock);
        UINT32 index = 0;
        BOOL found = FALSE;
        if (collection && SUCCEEDED(collection->FindFamilyName(family, &index, &found)) && found)
            return ComPtr<IDWriteFontCollection>(collection.Get());
        return {};
    }
};

AppFonts &appFonts() {
    static AppFonts fonts;
    return fonts;
}

ComPtr<IDWriteTextLayout> makeLayout(const WCHAR *text, UINT32 length, IDWriteTextFormat *format) {
    ComPtr<IDWriteTextLayout> layout;
    if (FAILED(textFactory()->CreateTextLayout(text, length, format, 1, 1, layout.GetAddressOf()))) return {};
    ComPtr<IDWriteTextLayout1> extended;
    if (length && SUCCEEDED(layout.As(&extended))) extended->SetPairKerning(TRUE, {0, length});
    return layout;
}

bool autoRTL(const WCHAR *text, int count) {
    std::unique_ptr<WORD[]> types(new (std::nothrow) WORD[count]);
    if (count && types && GetStringTypeW(CT_CTYPE2, text, count, types.get())) {
        for (int i = 0; i < count; ++i) {
            if (types[i] == C2_LEFTTORIGHT || types[i] == C2_RIGHTTOLEFT)
                return types[i] == C2_RIGHTTOLEFT;
        }
    }
    return false;
}

template<class Apply>
void readSettings(const char *settings, Apply apply) {
    for (const char *p = settings; p && *p;) {
        const char *end = std::strchr(p, ',');
        if (!end) end = p + std::strlen(p);
        if (end - p >= 6 && p[4] == '=') {
            char *parsed = nullptr;
            double value = std::strtod(p + 5, &parsed);
            if (parsed == end && std::isfinite(value))
                apply(DWRITE_MAKE_OPENTYPE_TAG(p[0], p[1], p[2], p[3]), value);
        }
        p = *end ? end + 1 : end;
    }
}

struct MaskRun {
    ComPtr<IDWriteGlyphRunAnalysis> analysis;
    RECT bounds{};
    bool colored = false;
    BYTE rgba[4] = {};
    MaskRun *next = nullptr;
};

// IDWriteTextLayout supplies the final shaped glyphs, including script-specific
// kerning, substitutions, positions and fallback font faces in visual order.
class RunCollector final : public IDWriteTextRenderer {
    LONG refs = 1;
    MaskRun **tail = &runs;
public:
    MaskRun *runs = nullptr;
    RECT ink{};
    bool hasColor = false;
    float fontAscent = 0, fontDescent = 0, capHeight = 0;

    ~RunCollector() {
        while (runs) {
            auto *next = runs->next;
            delete runs;
            runs = next;
        }
    }

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) noexcept override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (iid != __uuidof(IUnknown) && iid != __uuidof(IDWritePixelSnapping) && iid != __uuidof(IDWriteTextRenderer))
            return E_NOINTERFACE;
        *out = static_cast<IDWriteTextRenderer *>(this);
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() noexcept override { return InterlockedIncrement(&refs); }
    ULONG STDMETHODCALLTYPE Release() noexcept override {
        ULONG n = InterlockedDecrement(&refs);
        if (!n) delete this;
        return n;
    }
    HRESULT STDMETHODCALLTYPE IsPixelSnappingDisabled(void *, BOOL *disabled) noexcept override {
        *disabled = TRUE;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetCurrentTransform(void *, DWRITE_MATRIX *matrix) noexcept override {
        *matrix = {1, 0, 0, 1, 0, 0};
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetPixelsPerDip(void *, FLOAT *scale) noexcept override {
        *scale = 1;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE DrawGlyphRun(void *, FLOAT x, FLOAT y, DWRITE_MEASURING_MODE mode,
        const DWRITE_GLYPH_RUN *glyphs, const DWRITE_GLYPH_RUN_DESCRIPTION *description, IUnknown *) noexcept override {
        DWRITE_FONT_METRICS face{};
        glyphs->fontFace->GetMetrics(&face);
        if (face.designUnitsPerEm) {
            const float scale = glyphs->fontEmSize / face.designUnitsPerEm;
            fontAscent = std::max(fontAscent, face.ascent * scale);
            fontDescent = std::max(fontDescent, face.descent * scale);
            capHeight = std::max(capHeight, face.capHeight * scale);
        }
        ComPtr<IDWriteFontFace2> colorFace;
        if (FAILED(glyphs->fontFace->QueryInterface(__uuidof(IDWriteFontFace2),
                reinterpret_cast<void **>(colorFace.GetAddressOf()))) || !colorFace->IsColorFont())
            return appendMask(x, y, mode, glyphs, nullptr);
        ComPtr<IDWriteColorGlyphRunEnumerator> layers;
        HRESULT hr = textFactory()->TranslateColorGlyphRun(x, y, glyphs, description, mode, nullptr, 0, layers.GetAddressOf());
        if (hr == DWRITE_E_NOCOLOR) return appendMask(x, y, mode, glyphs, nullptr);
        if (FAILED(hr)) return hr;
        BOOL more = FALSE;
        while (SUCCEEDED(hr = layers->MoveNext(&more)) && more) {
            const DWRITE_COLOR_GLYPH_RUN *layer = nullptr;
            hr = layers->GetCurrentRun(&layer);
            if (FAILED(hr)) return hr;
            const auto *color = layer->paletteIndex == 0xffff ? nullptr : &layer->runColor;
            hr = appendMask(layer->baselineOriginX, layer->baselineOriginY, mode, &layer->glyphRun, color);
            if (FAILED(hr)) return hr;
        }
        return hr;
    }
    HRESULT appendMask(FLOAT x, FLOAT y, DWRITE_MEASURING_MODE mode,
        const DWRITE_GLYPH_RUN *glyphs, const DWRITE_COLOR_F *color) {
        std::unique_ptr<MaskRun> run(new (std::nothrow) MaskRun);
        if (!run) return E_OUTOFMEMORY;
        HRESULT hr = textFactory()->CreateGlyphRunAnalysis(glyphs, nullptr,
            DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, mode, DWRITE_GRID_FIT_MODE_ENABLED,
            DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE, x, y, run->analysis.GetAddressOf());
        if (FAILED(hr)) return hr;
        // DirectWrite uses the one-channel texture format for grayscale coverage.
        hr = run->analysis->GetAlphaTextureBounds(DWRITE_TEXTURE_ALIASED_1x1, &run->bounds);
        if (FAILED(hr)) return hr;
        const RECT &b = run->bounds;
        if (b.right <= b.left || b.bottom <= b.top) return S_OK;
        if (color) {
            auto channel = [](float c) { return BYTE(std::max(0.F, std::min(1.F, c)) * 255 + 0.5F); };
            run->rgba[0] = channel(color->r);
            run->rgba[1] = channel(color->g);
            run->rgba[2] = channel(color->b);
            run->rgba[3] = channel(color->a);
            if (!run->rgba[3]) return S_OK;
            run->colored = true;
            hasColor = true;
        }
        if (!runs) {
            ink = b;
        } else {
            ink.left = std::min(ink.left, b.left);
            ink.top = std::min(ink.top, b.top);
            ink.right = std::max(ink.right, b.right);
            ink.bottom = std::max(ink.bottom, b.bottom);
        }
        *tail = run.release();
        tail = &(*tail)->next;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DrawUnderline(void *, FLOAT, FLOAT, const DWRITE_UNDERLINE *, IUnknown *) noexcept override {
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DrawStrikethrough(void *, FLOAT, FLOAT, const DWRITE_STRIKETHROUGH *, IUnknown *) noexcept override {
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DrawInlineObject(void *, FLOAT, FLOAT, IDWriteInlineObject *, BOOL, BOOL, IUnknown *) noexcept override {
        return E_NOTIMPL;
    }
};
struct UnitEdges {
    float leading = 0, trailing = 0;
    UINT32 level = UINT32_MAX;
};

// DirectWrite exposes the visual origin and embedding level of each text range
// and the advance of each cluster. Cache per-unit boundaries for repeated caret
// and selection queries. Unusual layouts can still use native point hit testing.
std::unique_ptr<UnitEdges[]> buildHitCache(IDWriteTextLayout *layout, UINT32 length) {
    if (length < 2) return nullptr;
    UINT32 clusterCount = 0, rangeCount = 0;
    layout->GetClusterMetrics(nullptr, 0, &clusterCount);
    layout->HitTestTextRange(0, length, 0, 0, nullptr, 0, &rangeCount);
    if (!clusterCount || !rangeCount) return nullptr;
    std::unique_ptr<DWRITE_CLUSTER_METRICS[]> clusters(new (std::nothrow) DWRITE_CLUSTER_METRICS[clusterCount]);
    std::unique_ptr<DWRITE_HIT_TEST_METRICS[]> ranges(new (std::nothrow) DWRITE_HIT_TEST_METRICS[rangeCount]);
    std::unique_ptr<UnitEdges[]> edges(new (std::nothrow) UnitEdges[length]);
    if (!clusters || !ranges || !edges ||
        FAILED(layout->GetClusterMetrics(clusters.get(), clusterCount, &clusterCount)) ||
        FAILED(layout->HitTestTextRange(0, length, 0, 0, ranges.get(), rangeCount, &rangeCount))) return nullptr;
    // Store advances temporarily in trailing until the ranges provide positions.
    UINT32 unit = 0;
    for (UINT32 i = 0; i < clusterCount; ++i) {
        const auto &c = clusters[i];
        if (!c.length || c.length > length - unit) return nullptr;
        for (UINT32 j = 0; j < c.length; ++j)
            edges[unit++].trailing = c.width / c.length;
    }
    if (unit != length) return nullptr;
    for (UINT32 i = 0; i < rangeCount; ++i) {
        const auto &range = ranges[i];
        if (range.textPosition > length || range.length > length - range.textPosition) return nullptr;
        bool rtl = (range.bidiLevel & 1) != 0;
        double cursor = rtl ? double(range.left) + range.width : range.left;
        for (UINT32 j = 0; j < range.length; ++j) {
            auto &cell = edges[range.textPosition + j];
            if (cell.level != UINT32_MAX) return nullptr;
            float advance = cell.trailing;
            cell.leading = float(cursor);
            cursor += rtl ? -advance : advance;
            cell.trailing = float(cursor);
            cell.level = range.bidiLevel;
        }
    }
    for (UINT32 i = 0; i < length; ++i)
        if (edges[i].level == UINT32_MAX) return nullptr;
    return edges;
}
} // namespace

struct RuneDesktopLine {
    ComPtr<IDWriteTextLayout> layout;
    ComPtr<RunCollector> collector;
    std::unique_ptr<WCHAR[]> text;
    std::unique_ptr<UnitEdges[]> hits;
    RuneDesktopLineMetrics metrics{};
    std::unique_ptr<UINT32[]> byteToUnit;
    int32_t byteCount = 0;
    bool rtl = false;

    bool updateMetrics(IDWriteTextLayout *target) {
        DWRITE_TEXT_METRICS textMetrics{};
        if (FAILED(target->GetMetrics(&textMetrics)) ||
            FAILED(target->SetMaxWidth(textMetrics.widthIncludingTrailingWhitespace)) ||
            FAILED(target->SetMaxHeight(textMetrics.height))) return false;
        DWRITE_LINE_METRICS row{};
        UINT32 rows = 0;
        if (FAILED(target->GetLineMetrics(&row, 1, &rows)) || rows != 1) return false;
        ComPtr<RunCollector> updated;
        updated.Attach(new (std::nothrow) RunCollector);
        if (!updated || FAILED(target->Draw(nullptr, updated.Get(), 0, 0))) return false;
        const RECT &ink = updated->ink;
        int64_t width = int64_t(ink.right) - ink.left, height = int64_t(ink.bottom) - ink.top;
        if (width > INT32_MAX || height > INT32_MAX) return false;
        metrics = {textMetrics.widthIncludingTrailingWhitespace, row.baseline, row.height - row.baseline,
            ink.left, ink.top, int32_t(width), int32_t(height),
            updated->fontAscent > 0 ? updated->fontAscent : row.baseline,
            updated->fontAscent > 0 ? updated->fontDescent : row.height - row.baseline,
            updated->capHeight};
        hits = buildHitCache(target, position(byteCount));
        collector = std::move(updated);
        return true;
    }

    UINT32 position(int32_t byte) const {
        return byteToUnit[std::max<int32_t>(0, std::min(byteCount, byte))];
    }

    float edge(UINT32 unit, bool trailing, UINT32 *level = nullptr) const {
        if (hits) {
            if (level) *level = hits[unit].level;
            return trailing ? hits[unit].trailing : hits[unit].leading;
        }
        DWRITE_HIT_TEST_METRICS hit{};
        float x = 0, y = 0;
        if (FAILED(layout->HitTestTextPosition(unit, trailing, &x, &y, &hit))) return 0;
        if (level) *level = hit.bidiLevel;
        // DirectWrite returns cluster edges for positions inside a ligature. Give
        // adjacent graphemes disjoint cells so atlas slices reconstruct the run.
        const UINT32 boundary = unit + (trailing ? 1 : 0);
        if (boundary > hit.textPosition && boundary - hit.textPosition < hit.length) {
            const float t = float(boundary - hit.textPosition) / float(hit.length);
            return hit.left + hit.width * ((hit.bidiLevel & 1) ? 1 - t : t);
        }
        return x;
    }
};

int32_t rune_desktop_register_font_file(const char *utf8_path) {
    if (!utf8_path || !*utf8_path) return 0;
    // Foundation file URLs can spell a drive root as /C:/.
    if (utf8_path[0] == '/' && utf8_path[1] && utf8_path[2] == ':') ++utf8_path;
    int units = 0;
    auto path = toWide(utf8_path, -1, units);
    if (!path) return 0;
    DWORD count = GetFullPathNameW(path.get(), 0, nullptr, nullptr);
    if (!count) return 0;
    std::unique_ptr<WCHAR[]> absolute(new (std::nothrow) WCHAR[count]);
    if (!absolute) return 0;
    DWORD copied = GetFullPathNameW(path.get(), count, absolute.get(), nullptr);
    return copied && copied < count && appFonts().addFile(absolute.get());
}

int32_t rune_desktop_register_font_bytes(const uint8_t *bytes, uint32_t length) {
    return bytes && length && appFonts().addBytes(bytes, length);
}

RuneDesktopLine *rune_desktop_line_create(const char *utf8, int32_t length, const char *family,
    float size_px, int32_t weight, int32_t italic, int32_t mono, int32_t direction) {
    if (length < 0 || (!utf8 && length) || !std::isfinite(size_px) || size_px <= 0 || !textFactory()) return nullptr;
    std::unique_ptr<RuneDesktopLine> line(new (std::nothrow) RuneDesktopLine);
    if (!line) return nullptr;
    int units = 0;
    auto text = toWide(utf8, length, units);
    if (!text) return nullptr;
    line->byteCount = length;
    line->byteToUnit.reset(new (std::nothrow) UINT32[size_t(length) + 1]);
    if (!line->byteToUnit) return nullptr;
    UINT32 native = 0;
    for (int32_t byte = 0; byte < length;) {
        unsigned char lead = static_cast<unsigned char>(utf8[byte]);
        int count = lead < 0x80 ? 1 : lead < 0xe0 ? 2 : lead < 0xf0 ? 3 : 4;
        for (int i = 0; i < count; ++i) line->byteToUnit[byte++] = native;
        native += count == 4 ? 2 : 1;
    }
    line->byteToUnit[length] = native;

    const WCHAR *face = mono ? L"Consolas" : L"Segoe UI";
    std::unique_ptr<WCHAR[]> requested;
    ComPtr<IDWriteFontCollection> appCollection;
    if (family && *family) {
        int familyUnits = 0;
        requested = toWide(family, -1, familyUnits);
        ComPtr<IDWriteFontCollection> fonts;
        textFactory()->GetSystemFontCollection(fonts.GetAddressOf());
        for (WCHAR *name = requested.get(); name && *name;) {
            WCHAR *next = std::wcschr(name, L',');
            if (next) *next++ = 0;
            while (std::iswspace(*name)) ++name;
            WCHAR *end = name + std::wcslen(name);
            while (end > name && std::iswspace(end[-1])) --end;
            if (end-name >= 2 && (*name == L'\'' || *name == L'"') && end[-1] == *name) {
                ++name;
                --end;
            }
            *end = 0;
            appCollection = appFonts().find(name);
            UINT32 index = 0;
            BOOL exists = FALSE;
            if (appCollection || (fonts && SUCCEEDED(fonts->FindFamilyName(name, &index, &exists)) && exists)) {
                face = name;
                break;
            }
            name = next;
        }
    }
    WCHAR locale[LOCALE_NAME_MAX_LENGTH] = {};
    const WCHAR *localeName = GetUserDefaultLocaleName(locale, LOCALE_NAME_MAX_LENGTH) ? locale : L"en-US";
    ComPtr<IDWriteTextFormat> format;
    const auto fontWeight = static_cast<DWRITE_FONT_WEIGHT>(std::max(1, std::min(999, int(weight))));
    if (FAILED(textFactory()->CreateTextFormat(face, appCollection.Get(), fontWeight,
        italic ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
        size_px, localeName, format.GetAddressOf()))) return nullptr;
    line->rtl = direction == 2 || (direction == 0 && autoRTL(text.get(), units));
    if (FAILED(format->SetReadingDirection(line->rtl ? DWRITE_READING_DIRECTION_RIGHT_TO_LEFT : DWRITE_READING_DIRECTION_LEFT_TO_RIGHT)) ||
        FAILED(format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP))) return nullptr;
    // Tighten to the measured width before asking for glyph positions. In a
    // right-to-left line DirectWrite aligns the leading edge to the right.
    line->layout = makeLayout(text.get(), units, format.Get());
    if (!line->layout || !line->updateMetrics(line->layout.Get())) return nullptr;
    line->text = std::move(text);
    return line.release();
}

void rune_desktop_line_configure(RuneDesktopLine *line, const char *language, const char *features,
    const char *variations) {
    if (!line) return;
    DWRITE_TEXT_RANGE range{0, line->position(line->byteCount)};
    if (!range.length) return;
    auto adjusted = makeLayout(line->text.get(), range.length, line->layout.Get());
    if (!adjusted) return;
    bool changed = false;
    if (language && *language) {
        int units = 0;
        auto locale = toWide(language, -1, units);
        if (locale && SUCCEEDED(adjusted->SetLocaleName(locale.get(), range))) changed = true;
    }
    if (features && *features) {
        ComPtr<IDWriteTypography> settings;
        if (SUCCEEDED(textFactory()->CreateTypography(settings.GetAddressOf()))) {
            readSettings(features, [&](UINT32 tag, double value) {
                if (value >= 0 && value <= UINT32_MAX && std::floor(value) == value) {
                    settings->AddFontFeature({static_cast<DWRITE_FONT_FEATURE_TAG>(tag), UINT32(value)});
                    if (tag == DWRITE_FONT_FEATURE_TAG_KERNING) {
                        ComPtr<IDWriteTextLayout1> extended;
                        if (SUCCEEDED(adjusted.As(&extended))) extended->SetPairKerning(value != 0, range);
                    }
                }
            });
            if (settings->GetFontFeatureCount() && SUCCEEDED(adjusted->SetTypography(settings.Get(), range)))
                changed = true;
        }
    }
    if (variations && *variations) {
        ComPtr<IDWriteTextLayout4> variable;
        if (SUCCEEDED(adjusted.As(&variable))) {
            size_t capacity = 1 + std::count(variations, variations + std::strlen(variations), ',');
            std::unique_ptr<DWRITE_FONT_AXIS_VALUE[]> axes(new (std::nothrow) DWRITE_FONT_AXIS_VALUE[capacity]);
            UINT32 count = 0;
            if (axes) readSettings(variations, [&](UINT32 tag, double value) {
                if (std::abs(value) <= FLT_MAX && count < UINT32_MAX)
                    axes[count++] = {static_cast<DWRITE_FONT_AXIS_TAG>(tag), float(value)};
            });
            if (count && SUCCEEDED(variable->SetFontAxisValues(axes.get(), count, range))) changed = true;
        }
    }
    if (changed && line->updateMetrics(adjusted.Get())) line->layout = std::move(adjusted);
}

void rune_desktop_line_destroy(RuneDesktopLine *line) { delete line; }

RuneDesktopLineMetrics rune_desktop_line_metrics(const RuneDesktopLine *line) {
    return line ? line->metrics : RuneDesktopLineMetrics{};
}

float rune_desktop_line_caret(const RuneDesktopLine *line, int32_t offset) {
    if (!line || !line->byteCount) return 0;
    const UINT32 index = line->position(offset);
    if (!index) return line->rtl ? line->metrics.advance : 0;
    if (offset >= line->byteCount) return line->rtl ? 0 : line->metrics.advance;
    // At a bidi boundary the strong caret follows the shallower embedding.
    UINT32 nextLevel = 0, previousLevel = 0;
    const float next = line->edge(index, false, &nextLevel);
    const float previous = line->edge(index - 1, true, &previousLevel);
    return previousLevel < nextLevel ? previous : next;
}

int32_t rune_desktop_line_cell(const RuneDesktopLine *line, int32_t start, int32_t end, float *left, float *advance) {
    if (!left || !advance) return 0;
    *left = 0;
    *advance = 0;
    if (!line || line->position(end) <= line->position(start)) return 0;
    // Use the trailing edge within the grapheme, since the next grapheme
    // can start in a different run with the opposite writing direction.
    UINT32 level = 0;
    *left = line->edge(line->position(start), false, &level);
    float endX = line->edge(line->position(end) - 1, true);
    *advance = std::abs(endX - *left);
    *left = std::min(*left, endX);
    return (level & 1) ? -1 : 1;
}

namespace {
int32_t drawTile(const RuneDesktopLine *line, int32_t x, int32_t y, int32_t width, int32_t height,
    uint8_t *pixels, bool color) {
    int channels = color ? 4 : 1;
    if (!line || !pixels || width <= 0 || height <= 0 ||
        int64_t(width) * height > UINT32_MAX / channels ||
        int64_t(x) + width > INT32_MAX || int64_t(y) + height > INT32_MAX) return 0;
    size_t tilePixels = size_t(width) * height;
    std::memset(pixels, 0, tilePixels * channels);
    for (auto *run = line->collector->runs; run; run = run->next) {
        if (run->colored != color) continue;
        const RECT &b = run->bounds;
        RECT clip{ std::max<LONG>(x, b.left), std::max<LONG>(y, b.top),
            std::min<LONG>(x + width, b.right), std::min<LONG>(y + height, b.bottom) };
        if (clip.right <= clip.left || clip.bottom <= clip.top) continue;
        UINT32 w = clip.right - clip.left, h = clip.bottom - clip.top;
        if (!color && run == line->collector->runs && !run->next && w == UINT32(width) && h == UINT32(height))
            return SUCCEEDED(run->analysis->CreateAlphaTexture(DWRITE_TEXTURE_ALIASED_1x1, &clip, pixels, w * h));
        std::unique_ptr<BYTE[]> mask(new (std::nothrow) BYTE[size_t(w) * h]);
        if (!mask || FAILED(run->analysis->CreateAlphaTexture(DWRITE_TEXTURE_ALIASED_1x1, &clip, mask.get(), w * h))) return 0;
        for (UINT32 row = 0; row < h; ++row) {
            auto *dst = pixels + (size_t(clip.top - y + row) * width + (clip.left - x)) * channels;
            const auto *src = mask.get() + size_t(row) * w;
            if (!color) {
                for (UINT32 col = 0; col < w; ++col)
                    dst[col] = uint8_t(src[col] + (dst[col] * (255 - src[col]) + 127) / 255);
            } else {
                for (UINT32 col = 0; col < w; ++col, dst += 4) {
                    unsigned alpha = (src[col] * run->rgba[3] + 127) / 255;
                    for (int c = 0; c < 3; ++c)
                        dst[c] = BYTE((run->rgba[c] * alpha + dst[c] * (255 - alpha) + 127) / 255);
                    dst[3] = BYTE(alpha + (dst[3] * (255 - alpha) + 127) / 255);
                }
            }
        }
    }
    if (color) {
        for (size_t i = 0; i < tilePixels; ++i) {
            auto *pixel = pixels + 4 * i;
            if (pixel[3] > 0 && pixel[3] < 255) {
                for (int c = 0; c < 3; ++c)
                    pixel[c] = BYTE(std::min(255, (255 * pixel[c] + pixel[3] / 2) / pixel[3]));
            }
        }
    }
    return 1;
}
} // namespace

int32_t rune_desktop_line_mask(const RuneDesktopLine *line, int32_t x, int32_t y,
    int32_t width, int32_t height, uint8_t *pixels) {
    return drawTile(line, x, y, width, height, pixels, false);
}

int32_t rune_desktop_line_has_color(const RuneDesktopLine *line) {
    return line && line->collector->hasColor;
}

int32_t rune_desktop_line_color(const RuneDesktopLine *line, int32_t x, int32_t y,
    int32_t width, int32_t height, uint8_t *pixels) {
    return drawTile(line, x, y, width, height, pixels, true);
}
#endif
