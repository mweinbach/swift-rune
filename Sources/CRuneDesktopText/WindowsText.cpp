#if defined(_WIN32)
#define NOMINMAX
#include <windows.h>
#include <dwrite_3.h>
#include <d2d1.h>
#include <wrl/client.h>
#include "RuneDesktopText.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cfloat>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <cwctype>
#include <cwchar>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <unordered_map>
#include <vector>

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

IDWriteFontCollection *systemFontCollection() {
    static const ComPtr<IDWriteFontCollection> collection = [] {
        ComPtr<IDWriteFontCollection> result;
        if (textFactory()) textFactory()->GetSystemFontCollection(result.GetAddressOf());
        return result;
    }();
    return collection.Get();
}

const WCHAR *userDefaultLocale() {
    static const std::wstring locale = [] {
        WCHAR buf[LOCALE_NAME_MAX_LENGTH] = {};
        return GetUserDefaultLocaleName(buf, LOCALE_NAME_MAX_LENGTH) ? std::wstring(buf) : std::wstring(L"en-US");
    }();
    return locale.c_str();
}

std::unique_ptr<WCHAR[]> toWide(const char *utf8, int length, int &units) {
    if (length == 0) {
        units = 0;
        std::unique_ptr<WCHAR[]> wide(new (std::nothrow) WCHAR[1]);
        if (wide) wide[0] = 0;
        return wide;
    }
    const size_t byteLen = length < 0 ? std::strlen(utf8) : size_t(length);
    if (byteLen > size_t(INT32_MAX - 1)) return nullptr;
    std::unique_ptr<WCHAR[]> wide(new (std::nothrow) WCHAR[byteLen + 1]);
    if (!wide) return nullptr;
    bool ascii = true;
    for (size_t i = 0; i < byteLen; ++i) {
        unsigned char b = static_cast<unsigned char>(utf8[i]);
        if (b >= 0x80) { ascii = false; break; }
        wide[i] = b;
    }
    if (ascii) {
        units = int(byteLen);
        wide[byteLen] = 0;
        return wide;
    }
    units = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, int(byteLen), wide.get(), int(byteLen));
    if (units == 0) return nullptr;
    wide[units] = 0;
    return wide;
}

// Decode one CSS family in place. Commas inside a quoted or escaped name
// belong to that family, including when the name is absent from the system.
WCHAR *nextFamily(WCHAR *&cursor) {
    while (std::iswspace(*cursor)) ++cursor;
    WCHAR *name = cursor, *out = name;
    WCHAR quote = 0;
    while (*cursor) {
        WCHAR c = *cursor++;
        if (c == L'\\' && *cursor) {
            *out++ = *cursor++;
        } else if (quote) {
            if (c == quote) quote = 0;
            else *out++ = c;
        } else if (out == name && (c == L'\'' || c == L'"')) {
            quote = c;
        } else if (c == L',') {
            break;
        } else {
            *out++ = c;
        }
    }
    while (out > name && std::iswspace(out[-1])) --out;
    *out = 0;
    while (std::iswspace(*name)) ++name;
    return name;
}

// Keep the process-private collection separate from the system collection.
// Existing layouts retain the immutable collection they were created with.
class AppFonts {
    std::mutex lock;
    ComPtr<IDWriteFactory5> factory;
    ComPtr<IDWriteInMemoryFontFileLoader> loader;
    ComPtr<IDWriteFontSet> set;
    ComPtr<IDWriteFontCollection1> collection;
    std::atomic<uint64_t> gen{0};

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
        gen.fetch_add(1, std::memory_order_release);
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
    uint64_t generation() const { return gen.load(std::memory_order_acquire); }
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
        if (gen.load(std::memory_order_acquire) == 0) return {};
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

struct FormatKey {
    std::string family;
    uint32_t sizeBits;
    int32_t weight;
    uint64_t appGen;
    bool mono;
    bool italic;
    bool rtl;

    bool operator==(const FormatKey &o) const {
        return sizeBits == o.sizeBits && weight == o.weight && appGen == o.appGen &&
               mono == o.mono && italic == o.italic && rtl == o.rtl && family == o.family;
    }
};

struct FormatKeyHash {
    size_t operator()(const FormatKey &k) const {
        size_t h = std::hash<std::string>{}(k.family);
        auto mix = [&](size_t v) { h ^= v + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2); };
        mix(k.sizeBits);
        mix(size_t(k.weight));
        mix(size_t(k.appGen));
        mix((k.mono ? 1u : 0u) | (k.italic ? 2u : 0u) | (k.rtl ? 4u : 0u));
        return h;
    }
};

ComPtr<IDWriteTextFormat> cachedTextFormat(const char *family, bool mono, float size_px, int32_t weight, bool italic, bool rtl) {
    const int32_t clampedWeight = std::max(1, std::min(999, int(weight)));
    uint32_t sizeBits = 0;
    std::memcpy(&sizeBits, &size_px, sizeof(sizeBits));
    const uint64_t appGen = appFonts().generation();
    FormatKey key{family && *family ? std::string(family) : std::string(), sizeBits, clampedWeight, appGen, mono, italic, rtl};

    struct Entry {
        ComPtr<IDWriteTextFormat> format;
        uint64_t lastUsed = 0;
    };
    static std::mutex lock;
    static std::unordered_map<FormatKey, Entry, FormatKeyHash> cache;
    static uint64_t clock = 0;
    static uint64_t cachedAppGen = 0;
    static constexpr size_t maxEntries = 128;

    {
        std::lock_guard<std::mutex> guard(lock);
        if (cachedAppGen != appGen) {
            cache.clear();
            cachedAppGen = appGen;
        } else {
            auto it = cache.find(key);
            if (it != cache.end()) {
                it->second.lastUsed = ++clock;
                return it->second.format;
            }
        }
    }

    const WCHAR *face = mono ? L"Consolas" : L"Segoe UI";
    std::unique_ptr<WCHAR[]> requested;
    ComPtr<IDWriteFontCollection> appCollection;
    if (!key.family.empty()) {
        int familyUnits = 0;
        requested = toWide(key.family.c_str(), int(key.family.size()), familyUnits);
        IDWriteFontCollection *fonts = systemFontCollection();
        for (WCHAR *cursor = requested.get(); cursor && *cursor;) {
            WCHAR *name = nextFamily(cursor);
            if (!*name) continue;
            appCollection = appFonts().find(name);
            UINT32 index = 0;
            BOOL exists = FALSE;
            if (appCollection || (fonts && SUCCEEDED(fonts->FindFamilyName(name, &index, &exists)) && exists)) {
                face = name;
                break;
            }
        }
    }
    ComPtr<IDWriteTextFormat> format;
    const auto fontWeight = static_cast<DWRITE_FONT_WEIGHT>(clampedWeight);
    if (FAILED(textFactory()->CreateTextFormat(face, appCollection.Get(), fontWeight,
        italic ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
        size_px, userDefaultLocale(), format.GetAddressOf()))) return {};
    if (FAILED(format->SetReadingDirection(rtl ? DWRITE_READING_DIRECTION_RIGHT_TO_LEFT : DWRITE_READING_DIRECTION_LEFT_TO_RIGHT)) ||
        FAILED(format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP))) return {};

    {
        std::lock_guard<std::mutex> guard(lock);
        if (cachedAppGen == appGen) {
            if (cache.size() >= maxEntries) {
                auto oldest = cache.begin();
                for (auto it = cache.begin(); it != cache.end(); ++it) {
                    if (it->second.lastUsed < oldest->second.lastUsed) oldest = it;
                }
                if (oldest != cache.end()) cache.erase(oldest);
            }
            cache.emplace(std::move(key), Entry{format, ++clock});
        }
    }
    return format;
}

ComPtr<IDWriteTextLayout> makeLayout(const WCHAR *text, UINT32 length, IDWriteTextFormat *format, bool rtl) {
    ComPtr<IDWriteTextLayout> layout;
    const FLOAT maxDim = rtl ? 1.0f : FLT_MAX;
    if (FAILED(textFactory()->CreateTextLayout(text, length, format, maxDim, maxDim, layout.GetAddressOf()))) return {};
    ComPtr<IDWriteTextLayout1> extended;
    if (length && SUCCEEDED(layout.As(&extended))) extended->SetPairKerning(TRUE, {0, length});
    return layout;
}

bool autoRTL(const WCHAR *text, int count) {
    int i = 0;
    for (; i < count; ++i) {
        const WCHAR c = text[i];
        if (c >= 0x80) break;
        if ((c >= L'A' && c <= L'Z') || (c >= L'a' && c <= L'z')) return false;
    }
    const int rem = count - i;
    if (rem <= 0) return false;
    WORD stackTypes[256];
    std::unique_ptr<WORD[]> heapTypes;
    WORD *types = stackTypes;
    if (rem > 256) {
        heapTypes.reset(new (std::nothrow) WORD[rem]);
        if (!heapTypes) return false;
        types = heapTypes.get();
    }
    if (GetStringTypeW(CT_CTYPE2, text + i, rem, types)) {
        for (int j = 0; j < rem; ++j) {
            if (types[j] == C2_LEFTTORIGHT || types[j] == C2_RIGHTTOLEFT)
                return types[j] == C2_RIGHTTOLEFT;
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
    DWRITE_TEXTURE_TYPE texture = DWRITE_TEXTURE_ALIASED_1x1;
    bool colored = false;
    BYTE rgba[4] = {};
    MaskRun *next = nullptr;
};

// The gasp table and maxp's maxSizeOfInstructions determine Skia's vertical
// smoothing choice for the selected face at this device-pixel size.
struct FontTable {
    IDWriteFontFace *face;
    const BYTE *bytes = nullptr;
    UINT32 size = 0;
    void *context = nullptr;
    FontTable(IDWriteFontFace *face, UINT32 tag) : face(face) {
        const void *data = nullptr;
        BOOL exists = FALSE;
        if (SUCCEEDED(face->TryGetFontTable(tag, &data, &size, &context, &exists)) && exists)
            bytes = static_cast<const BYTE *>(data);
    }
    ~FontTable() { if (bytes) face->ReleaseFontTable(context); }
    UINT16 u16(UINT32 at) const { return UINT16(UINT16(bytes[at]) << 8 | bytes[at + 1]); }
};

struct ChromiumFaceFacts {
    ComPtr<IDWriteFontFace> face;
    std::vector<std::pair<UINT16, bool>> gaspRanges;
    bool hasMaxpInstructions = false;
};

DWRITE_RENDERING_MODE chromiumRenderingMode(DWRITE_GLYPH_RUN &run) {
    const float gdi = std::max(1.F, std::round(run.fontEmSize * 64.F) / 64.F);
    static std::array<ChromiumFaceFacts, 32> cache;
    static size_t nextSlot = 0;
    static std::mutex lock;

    std::vector<std::pair<UINT16, bool>> gaspRanges;
    bool hasMaxpInstructions = false;
    bool found = false;
    {
        std::lock_guard<std::mutex> guard(lock);
        for (const auto &e : cache) {
            if (e.face.Get() == run.fontFace) {
                gaspRanges = e.gaspRanges;
                hasMaxpInstructions = e.hasMaxpInstructions;
                found = true;
                break;
            }
        }
        if (!found) {
            ComPtr<IDWriteFontFace5> comparable;
            run.fontFace->QueryInterface(__uuidof(IDWriteFontFace5), reinterpret_cast<void **>(comparable.GetAddressOf()));
            if (comparable) {
                for (const auto &e : cache) {
                    if (e.face && comparable->Equals(e.face.Get())) {
                        gaspRanges = e.gaspRanges;
                        hasMaxpInstructions = e.hasMaxpInstructions;
                        found = true;
                        break;
                    }
                }
            }
        }
        if (!found) {
            FontTable gasp(run.fontFace, DWRITE_MAKE_OPENTYPE_TAG('g', 'a', 's', 'p'));
            if (gasp.bytes && gasp.size >= 4 && gasp.u16(0) >= 1 && gasp.u16(2) <= (gasp.size - 4) / 4) {
                const UINT16 count = gasp.u16(2);
                gaspRanges.reserve(count);
                for (UINT32 i = 0; i < count; ++i) {
                    gaspRanges.emplace_back(gasp.u16(4 + i * 4), (gasp.u16(6 + i * 4) & 8) != 0);
                }
            }
            FontTable maxp(run.fontFace, DWRITE_MAKE_OPENTYPE_TAG('m', 'a', 'x', 'p'));
            if (maxp.bytes && maxp.size >= 32 && maxp.u16(0) == 1 && maxp.u16(2) == 0 && maxp.u16(26) > 0) {
                hasMaxpInstructions = true;
            }
            cache[nextSlot++ % cache.size()] = {run.fontFace, gaspRanges, hasMaxpInstructions};
        }
    }

    if (!gaspRanges.empty()) {
        const float roundedGdi = std::round(gdi);
        for (const auto &r : gaspRanges) {
            if (roundedGdi <= r.first)
                return r.second ? DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC : DWRITE_RENDERING_MODE_NATURAL;
        }
    }
    if (run.fontEmSize <= 20 && hasMaxpInstructions) {
        run.fontEmSize = gdi;
        return DWRITE_RENDERING_MODE_NATURAL;
    }
    return DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC;
}

struct ShapedRun;
struct ClusterSpan {
    ShapedRun *run;
    UINT32 first, count;
    FLOAT x;
    UINT32 ownerUnit;
    uint64_t paintOrder;
    ClusterSpan *next;
};

struct ShapedRun {
    ComPtr<IDWriteFontFace> face;
    DWRITE_GLYPH_RUN glyphs{};
    DWRITE_MEASURING_MODE mode;
    FLOAT y;
    std::unique_ptr<UINT16[]> ids;
    std::unique_ptr<FLOAT[]> advances;
    std::unique_ptr<DWRITE_GLYPH_OFFSET[]> offsets;
    std::unique_ptr<ClusterSpan[]> spans;
    ShapedRun *next = nullptr;
    mutable std::once_flag originPlacement, outlinePlacement;
    mutable std::unique_ptr<D2D1_POINT_2F[]> glyphPens;
    mutable uint64_t outlineFont = 0;
    mutable bool outlineCjk = false;

    const D2D1_POINT_2F *glyphOrigins() const {
        std::call_once(originPlacement, [&] {
            static const ComPtr<IDWriteFactory4> factory = [] {
                ComPtr<IDWriteFactory4> result;
                textFactory()->QueryInterface(IID_PPV_ARGS(result.GetAddressOf()));
                return result;
            }();
            std::unique_ptr<D2D1_POINT_2F[]> points(new (std::nothrow) D2D1_POINT_2F[glyphs.glyphCount]);
            if (factory && points && SUCCEEDED(factory->ComputeGlyphOrigins(&glyphs, mode, {spans[0].x, y}, nullptr, points.get())))
                glyphPens = std::move(points);
        });
        return glyphPens.get();
    }

    const D2D1_POINT_2F *pens() const {
        std::call_once(outlinePlacement, [&] {
            if (glyphs.isSideways || face->GetType() == DWRITE_FONT_FACE_TYPE_BITMAP ||
                face->GetSimulations() != DWRITE_FONT_SIMULATIONS_NONE) return;
            ComPtr<IDWriteFontFace2> colorFace;
            if (SUCCEEDED(face.As(&colorFace)) && colorFace->IsColorFont()) return;
            if (!glyphOrigins()) return;

            // A run holds its ID after eviction. Store IDs never name a different
            // face, size or direction, including after a private font is replaced.
            struct Face {
                ComPtr<IDWriteFontFace> font;
                float em = 0;
                DWRITE_MEASURING_MODE measure{};
                bool rtl = false;
                uint64_t id = 0;
                bool cjk = false;
            };
            static std::array<Face, 64> faces;
            static std::mutex lock;
            static uint64_t nextID = 1;
            std::lock_guard<std::mutex> guard(lock);
            ComPtr<IDWriteFontFace5> comparable;
            face.As(&comparable);
            const bool rtl = (glyphs.bidiLevel & 1) != 0;
            for (const auto &f : faces) {
                if (f.em == glyphs.fontEmSize && f.measure == mode && f.rtl == rtl &&
                    (f.font.Get() == face.Get() || (f.font && comparable && comparable->Equals(f.font.Get())))) {
                    outlineFont = f.id;
                    outlineCjk = f.cjk;
                    break;
                }
            }
            if (!outlineFont && nextID != UINT64_MAX) {
                outlineFont = nextID++;
                FontTable os2(face.Get(), DWRITE_MAKE_OPENTYPE_TAG('O', 'S', '/', '2'));
                if (os2.bytes && os2.size >= 50) {
                    const UINT32 range2 = (UINT32(os2.u16(46)) << 16) | os2.u16(48);
                    outlineCjk = (range2 & ((1u << 17) | (1u << 24) | (1u << 27))) != 0;
                }
                faces[(outlineFont - 1) % faces.size()] = {face, glyphs.fontEmSize, mode, rtl, outlineFont, outlineCjk};
            }
        });
        return outlineFont ? glyphPens.get() : nullptr;
    }
};

// DirectWrite's callback buffers expire at the end of DrawGlyphRun. Keep a
// private copy on the first ownership query, indexed by the logical UTF-16
// start of each cluster, including clusters with several positioned glyphs.
struct InkIndex {
    LONG refs = 1;
    ULONG AddRef() { return InterlockedIncrement(&refs); }
    ULONG Release() {
        const ULONG count = InterlockedDecrement(&refs);
        if (!count) delete this;
        return count;
    }

    const UINT32 length;
    std::unique_ptr<ClusterSpan *[]> owners;
    std::unique_ptr<UINT32[]> ownerUnits;
    ShapedRun *runs = nullptr;
    ShapedRun **tail = &runs;
    uint64_t nextPaintOrder = 0;

    explicit InkIndex(UINT32 length) : length(length), owners(new (std::nothrow) ClusterSpan *[length]{}),
                                      ownerUnits(new (std::nothrow) UINT32[length]) {
        if (ownerUnits) std::fill_n(ownerUnits.get(), length, UINT32_MAX);
    }
    ~InkIndex() {
        while (runs) {
            auto *next = runs->next;
            delete runs;
            runs = next;
        }
    }

    HRESULT capture(FLOAT x, FLOAT y, DWRITE_MEASURING_MODE mode, const DWRITE_GLYPH_RUN &glyphs,
        const DWRITE_GLYPH_RUN_DESCRIPTION *description) {
        const UINT32 count = glyphs.glyphCount;
        if (!count) return S_OK;
        if (!description || !description->stringLength ||
            description->textPosition > length || description->stringLength > length - description->textPosition)
            return E_UNEXPECTED;
        std::unique_ptr<ShapedRun> run(new (std::nothrow) ShapedRun);
        std::unique_ptr<UINT32[]> starts(new (std::nothrow) UINT32[count]);
        if (!run || !starts) return E_OUTOFMEMORY;
        run->ids.reset(new (std::nothrow) UINT16[count]);
        run->advances.reset(new (std::nothrow) FLOAT[count]);
        run->spans.reset(new (std::nothrow) ClusterSpan[count]);
        if (!run->ids || !run->advances || !run->spans) return E_OUTOFMEMORY;
        run->face = glyphs.fontFace;
        run->glyphs = glyphs;
        run->mode = mode;
        run->y = y;
        std::copy_n(glyphs.glyphIndices, count, run->ids.get());
        run->glyphs.glyphIndices = run->ids.get();
        if (glyphs.glyphAdvances) {
            std::copy_n(glyphs.glyphAdvances, count, run->advances.get());
            run->glyphs.glyphAdvances = run->advances.get();
        } else {
            // CreateTextLayout uses natural measuring. A null advances array
            // asks DirectWrite to use the unadjusted advances from the face.
            std::unique_ptr<DWRITE_GLYPH_METRICS[]> metrics(new (std::nothrow) DWRITE_GLYPH_METRICS[count]);
            if (!metrics) return E_OUTOFMEMORY;
            HRESULT hr = run->face->GetDesignGlyphMetrics(glyphs.glyphIndices, count, metrics.get(), glyphs.isSideways);
            if (FAILED(hr)) return hr;
            DWRITE_FONT_METRICS font{};
            run->face->GetMetrics(&font);
            if (!font.designUnitsPerEm) return E_UNEXPECTED;
            const FLOAT scale = glyphs.fontEmSize / font.designUnitsPerEm;
            for (UINT32 i = 0; i < count; ++i)
                run->advances[i] = scale * (glyphs.isSideways ? metrics[i].advanceHeight : metrics[i].advanceWidth);
        }
        if (glyphs.glyphOffsets) {
            run->offsets.reset(new (std::nothrow) DWRITE_GLYPH_OFFSET[count]);
            if (!run->offsets) return E_OUTOFMEMORY;
            std::copy_n(glyphs.glyphOffsets, count, run->offsets.get());
            run->glyphs.glyphOffsets = run->offsets.get();
        }
        std::fill_n(starts.get(), count, UINT32_MAX);
        for (UINT32 unit = 0; unit < description->stringLength; ++unit) {
            const UINT32 first = description->clusterMap ? description->clusterMap[unit] : (count == 1 ? 0 : unit);
            if (first >= count) return E_UNEXPECTED;
            const UINT32 position = description->textPosition + unit;
            starts[first] = std::min(starts[first], position);
            // clusterMap is in logical UTF-16 order even for a visually reversed run.
            ownerUnits[position] = std::min(ownerUnits[position], starts[first]);
        }
        if (starts[0] == UINT32_MAX) return E_UNEXPECTED;
        FLOAT pen = 0;
        for (UINT32 first = 0; first < count;) {
            const FLOAT origin = (glyphs.bidiLevel & 1) ? x - pen : x + pen;
            UINT32 end = first;
            do { pen += run->advances[end++]; } while (end < count && starts[end] == UINT32_MAX);
            auto &owner = owners[starts[first]];
            run->spans[first] = {run.get(), first, end - first, origin, starts[first], nextPaintOrder++, owner};
            owner = &run->spans[first];
            first = end;
        }
        *tail = run.release();
        tail = &(*tail)->next;
        return S_OK;
    }
};

// IDWriteTextLayout supplies the final shaped glyphs, including script-specific
// kerning, substitutions, positions and fallback font faces in visual order.
class RunCollector final : public IDWriteTextRenderer {
    LONG refs = 1;
    MaskRun **tail = &runs;
    bool chromiumMask;
public:
    explicit RunCollector(bool chromiumMask = false) : chromiumMask(chromiumMask) {}
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

    HRESULT STDMETHODCALLTYPE DrawGlyphRun(void *context, FLOAT x, FLOAT y, DWRITE_MEASURING_MODE mode,
        const DWRITE_GLYPH_RUN *glyphs, const DWRITE_GLYPH_RUN_DESCRIPTION *description, IUnknown *) noexcept override {
        if (context) return static_cast<InkIndex *>(context)->capture(x, y, mode, *glyphs, description);
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
        const bool lcd = chromiumMask && !color;
        DWRITE_GLYPH_RUN raster = *glyphs;
        const auto rendering = lcd ? chromiumRenderingMode(raster) : DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC;
        run->texture = lcd ? DWRITE_TEXTURE_CLEARTYPE_3x1 : DWRITE_TEXTURE_ALIASED_1x1;
        HRESULT hr = textFactory()->CreateGlyphRunAnalysis(&raster, nullptr, rendering,
            lcd ? DWRITE_MEASURING_MODE_NATURAL : mode, DWRITE_GRID_FIT_MODE_ENABLED,
            lcd ? DWRITE_TEXT_ANTIALIAS_MODE_CLEARTYPE : DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE,
            x, y, run->analysis.GetAddressOf());
        if (FAILED(hr)) return hr;
        hr = run->analysis->GetAlphaTextureBounds(run->texture, &run->bounds);
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

template<class Visit>
bool visitOwnedClusters(const InkIndex &index, UINT32 start, UINT32 end, Visit &&visit) {
    size_t count = 0;
    for (UINT32 unit = start; unit < end; ++unit)
        for (auto *span = index.owners[unit]; span; span = span->next) ++count;
    if (!count) return true;
    ClusterSpan *single;
    std::unique_ptr<ClusterSpan *[]> storage(count > 1 ? new (std::nothrow) ClusterSpan *[count] : nullptr);
    ClusterSpan **spans = count == 1 ? &single : storage.get();
    if (!spans) return false;
    size_t n = 0;
    for (UINT32 unit = start; unit < end; ++unit)
        for (auto *span = index.owners[unit]; span; span = span->next) spans[n++] = span;
    if (count > 1) std::sort(spans, spans + count, [](const auto *a, const auto *b) {
        return a->paintOrder < b->paintOrder;
    });
    for (size_t i = 0; i < count;) {
        const auto &span = *spans[i++];
        auto glyphs = span.run->glyphs;
        glyphs.glyphIndices += span.first;
        if (glyphs.glyphAdvances) glyphs.glyphAdvances += span.first;
        if (glyphs.glyphOffsets) glyphs.glyphOffsets += span.first;
        glyphs.glyphCount = span.count;
        while (i < count && spans[i]->run == span.run && spans[i]->first == span.first + glyphs.glyphCount)
            glyphs.glyphCount += spans[i++]->count;
        if (!visit(span, glyphs)) return false;
    }
    return true;
}

// GetGlyphRunOutline reports contours relative to the visual run's baseline. Keep
// DirectWrite's original pen and offsets, including right-to-left and mark placement.
class OutlineSink final : public IDWriteGeometrySink {
    LONG refs = 1;
    RuneOutlineEmit emit;
    void *context;
public:
    float x = 0, y = 0;
    bool drewSegments = false;
    OutlineSink(RuneOutlineEmit emit, void *context) : emit(emit), context(context) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) noexcept override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (iid != __uuidof(IUnknown) && iid != __uuidof(IDWriteGeometrySink)) return E_NOINTERFACE;
        *out = static_cast<IDWriteGeometrySink *>(this);
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() noexcept override { return InterlockedIncrement(&refs); }
    ULONG STDMETHODCALLTYPE Release() noexcept override {
        ULONG n = InterlockedDecrement(&refs);
        if (!n) delete this;
        return n;
    }
    void STDMETHODCALLTYPE SetFillMode(D2D1_FILL_MODE) noexcept override {}
    void STDMETHODCALLTYPE SetSegmentFlags(D2D1_PATH_SEGMENT) noexcept override {}
    void STDMETHODCALLTYPE BeginFigure(D2D1_POINT_2F p, D2D1_FIGURE_BEGIN) noexcept override {
        emit(context, 0, x + p.x, y + p.y, 0, 0, 0, 0);
    }
    void STDMETHODCALLTYPE AddLines(const D2D1_POINT_2F *points, UINT32 count) noexcept override {
        drewSegments |= count != 0;
        for (UINT32 i = 0; i < count; ++i) emit(context, 1, x + points[i].x, y + points[i].y, 0, 0, 0, 0);
    }
    void STDMETHODCALLTYPE AddBeziers(const D2D1_BEZIER_SEGMENT *segments, UINT32 count) noexcept override {
        drewSegments |= count != 0;
        for (UINT32 i = 0; i < count; ++i) {
            const auto &b = segments[i];
            emit(context, 3, x + b.point1.x, y + b.point1.y, x + b.point2.x, y + b.point2.y,
                x + b.point3.x, y + b.point3.y);
        }
    }
    void STDMETHODCALLTYPE EndFigure(D2D1_FIGURE_END end) noexcept override {
        if (end == D2D1_FIGURE_END_CLOSED) emit(context, 4, 0, 0, 0, 0, 0, 0);
    }
    HRESULT STDMETHODCALLTYPE Close() noexcept override { return S_OK; }
};

struct UnitEdges {
    float leading, trailing;
    UINT32 level;
};

// Lightweight stack-allocated renderer used during layout creation and InkIndex
// capture without triggering DirectWrite glyph-run raster analysis.
class MetricsCollector final : public IDWriteTextRenderer {
    IDWriteFontFace *lastFace = nullptr;
    float lastEm = 0;
public:
    float fontAscent = 0, fontDescent = 0, capHeight = 0;

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) noexcept override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (iid != __uuidof(IUnknown) && iid != __uuidof(IDWritePixelSnapping) && iid != __uuidof(IDWriteTextRenderer))
            return E_NOINTERFACE;
        *out = static_cast<IDWriteTextRenderer *>(this);
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() noexcept override { return 1; }
    ULONG STDMETHODCALLTYPE Release() noexcept override { return 1; }
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
    HRESULT STDMETHODCALLTYPE DrawGlyphRun(void *context, FLOAT x, FLOAT y, DWRITE_MEASURING_MODE mode,
        const DWRITE_GLYPH_RUN *glyphs, const DWRITE_GLYPH_RUN_DESCRIPTION *description, IUnknown *) noexcept override {
        if (context) return static_cast<InkIndex *>(context)->capture(x, y, mode, *glyphs, description);
        if (glyphs->fontFace == lastFace && glyphs->fontEmSize == lastEm) return S_OK;
        lastFace = glyphs->fontFace;
        lastEm = glyphs->fontEmSize;
        DWRITE_FONT_METRICS face{};
        glyphs->fontFace->GetMetrics(&face);
        if (face.designUnitsPerEm) {
            const float scale = glyphs->fontEmSize / face.designUnitsPerEm;
            fontAscent = std::max(fontAscent, face.ascent * scale);
            fontDescent = std::max(fontDescent, face.descent * scale);
            capHeight = std::max(capHeight, face.capHeight * scale);
        }
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

// DirectWrite exposes the visual origin and embedding level of each text range
// and the advance of each cluster. Cache per-unit boundaries for repeated caret
// and selection queries. Unusual layouts can still use native point hit testing.
std::unique_ptr<UnitEdges[]> buildHitCache(IDWriteTextLayout *layout, UINT32 length, float &visualWidth, bool &allUnitClusters, bool &allLTR) {
    allUnitClusters = false;
    allLTR = false;
    if (length < 2) return nullptr;
    DWRITE_CLUSTER_METRICS stackClusters[256];
    DWRITE_HIT_TEST_METRICS stackRanges[16];
    std::unique_ptr<DWRITE_CLUSTER_METRICS[]> heapClusters;
    std::unique_ptr<DWRITE_HIT_TEST_METRICS[]> heapRanges;
    DWRITE_CLUSTER_METRICS *clusters = stackClusters;
    DWRITE_HIT_TEST_METRICS *ranges = stackRanges;

    UINT32 clusterCount = 0;
    HRESULT hr = layout->GetClusterMetrics(stackClusters, 256, &clusterCount);
    if (hr == E_NOT_SUFFICIENT_BUFFER) {
        if (!clusterCount) return nullptr;
        heapClusters.reset(new (std::nothrow) DWRITE_CLUSTER_METRICS[clusterCount]);
        if (!heapClusters || FAILED(layout->GetClusterMetrics(heapClusters.get(), clusterCount, &clusterCount)))
            return nullptr;
        clusters = heapClusters.get();
    } else if (FAILED(hr) || !clusterCount) {
        return nullptr;
    }

    UINT32 rangeCount = 0;
    hr = layout->HitTestTextRange(0, length, 0, 0, stackRanges, 16, &rangeCount);
    if (hr == E_NOT_SUFFICIENT_BUFFER) {
        if (!rangeCount) return nullptr;
        heapRanges.reset(new (std::nothrow) DWRITE_HIT_TEST_METRICS[rangeCount]);
        if (!heapRanges || FAILED(layout->HitTestTextRange(0, length, 0, 0, heapRanges.get(), rangeCount, &rangeCount)))
            return nullptr;
        ranges = heapRanges.get();
    } else if (FAILED(hr) || !rangeCount) {
        return nullptr;
    }

    std::unique_ptr<UnitEdges[]> edges(new (std::nothrow) UnitEdges[length]);
    if (!edges) return nullptr;
    if (rangeCount > 1) {
        std::sort(ranges, ranges + rangeCount, [](const auto &a, const auto &b) {
            return a.textPosition < b.textPosition;
        });
    }
    UINT32 unit = 0, cluster = 0;
    float right = 0;
    for (UINT32 i = 0; i < rangeCount; ++i) {
        const auto &range = ranges[i];
        if (range.textPosition != unit || range.length > length - unit) return nullptr;
        const UINT32 end = unit + range.length;
        const bool rtl = (range.bidiLevel & 1) != 0;
        const float rangeRight = range.left + range.width;
        right = std::max(right, rangeRight);
        const float origin = rtl ? rangeRight : range.left;
        // DirectWrite sums cluster advances in FLOAT relative to the start of
        // each run, then adds or subtracts that offset from its visual origin.
        float pen = 0;
        while (unit < end) {
            if (cluster == clusterCount) return nullptr;
            const auto &c = clusters[cluster++];
            if (!c.length || c.length > end - unit) return nullptr;
            const float startX = rtl ? origin - pen : origin + pen;
            pen += c.width;
            const float endX = rtl ? origin - pen : origin + pen;
            float previous = startX;
            for (UINT32 j = 1; j <= c.length; ++j) {
                float next = endX;
                if (j < c.length) {
                    const float part = float(j) / c.length;
                    next = rtl ? endX + c.width * (1 - part) : startX + c.width * part;
                }
                edges[unit++] = {previous, next, range.bidiLevel};
                previous = next;
            }
        }
    }
    if (unit != length || cluster != clusterCount) return nullptr;
    allUnitClusters = (clusterCount == length);
    allLTR = (rangeCount == 1 && (ranges[0].bidiLevel & 1) == 0);
    // GetMetrics accumulates the whole paragraph in logical order. On very
    // long mixed-direction lines its width can differ from the actual right
    // edge by several pixels. Use the visual edge for Rune's width and caret.
    visualWidth = right;
    return edges;
}
} // namespace

struct RuneDesktopLine {
    bool chromiumMask = false;
    ComPtr<IDWriteTextLayout> layout;
    mutable ComPtr<RunCollector> collector;
    mutable std::atomic<bool> collectorReady{false};
    mutable int32_t ink_x = 0, ink_y = 0, ink_width = 0, ink_height = 0;
    std::unique_ptr<WCHAR[]> text;
    std::unique_ptr<UnitEdges[]> hits;
    mutable std::mutex inkLock;
    mutable ComPtr<InkIndex> inkIndex;
    mutable std::atomic<InkIndex *> inkIndexFast{nullptr};
    // Partial ink views share immutable shaped glyphs with their source; the
    // fast whole-line view delays indexing until an outline is actually read.
    ComPtr<IDWriteTextLayout> wholeInkLayout;
    UINT32 inkFirst = 0, inkEnd = 0;
    RuneDesktopLineMetrics metrics{};
    std::unique_ptr<UINT32[]> byteToUnit;
    int32_t byteCount = 0;
    bool rtl = false;
    bool ascii = false;
    bool allUnitClusters = false;
    bool allLTR = false;

    bool updateMetrics(IDWriteTextLayout *target) {
        DWRITE_TEXT_METRICS textMetrics{};
        if (FAILED(target->GetMetrics(&textMetrics))) return false;
        if (rtl) {
            if (FAILED(target->SetMaxWidth(textMetrics.widthIncludingTrailingWhitespace)) ||
                FAILED(target->SetMaxHeight(textMetrics.height))) return false;
        }
        DWRITE_LINE_METRICS row{};
        UINT32 rows = 0;
        if (FAILED(target->GetLineMetrics(&row, 1, &rows)) || rows != 1) return false;
        MetricsCollector mc;
        if (FAILED(target->Draw(nullptr, &mc, 0, 0))) return false;
        metrics = {textMetrics.widthIncludingTrailingWhitespace, row.baseline, row.height - row.baseline,
            0, 0, 0, 0,
            mc.fontAscent > 0 ? mc.fontAscent : row.baseline,
            mc.fontAscent > 0 ? mc.fontDescent : row.height - row.baseline,
            mc.capHeight};
        const UINT32 totalUnits = position(byteCount);
        bool unitClusters = false;
        bool ltrOnly = false;
        hits = buildHitCache(target, totalUnits, metrics.advance, unitClusters, ltrOnly);
        allUnitClusters = totalUnits <= 1 || unitClusters;
        allLTR = !rtl && ltrOnly;
        std::lock_guard<std::mutex> guard(inkLock);
        collector.Reset();
        ink_x = ink_y = ink_width = ink_height = 0;
        collectorReady.store(false, std::memory_order_release);
        inkIndexFast.store(nullptr, std::memory_order_release);
        inkIndex.Reset();
        return true;
    }

    bool ensureCollector() const {
        if (collectorReady.load(std::memory_order_acquire)) return collector != nullptr;
        std::lock_guard<std::mutex> guard(inkLock);
        if (collectorReady.load(std::memory_order_relaxed)) return collector != nullptr;
        if (!layout) {
            collectorReady.store(true, std::memory_order_release);
            return collector != nullptr;
        }
        ComPtr<RunCollector> updated;
        updated.Attach(new (std::nothrow) RunCollector(chromiumMask));
        if (!updated || FAILED(layout->Draw(nullptr, updated.Get(), 0, 0))) return false;
        const RECT &ink = updated->ink;
        int64_t width = int64_t(ink.right) - ink.left, height = int64_t(ink.bottom) - ink.top;
        if (width > INT32_MAX || height > INT32_MAX) return false;
        ink_x = ink.left;
        ink_y = ink.top;
        ink_width = int32_t(width);
        ink_height = int32_t(height);
        collector = std::move(updated);
        collectorReady.store(true, std::memory_order_release);
        return true;
    }

    ComPtr<InkIndex> shapedIndex(IDWriteTextLayout *source, UINT32 units) const {
        std::lock_guard<std::mutex> guard(inkLock);
        if (!inkIndex) {
            if (!source) return {};
            std::unique_ptr<InkIndex> index(new (std::nothrow) InkIndex(units));
            MetricsCollector mc;
            if (!index || !index->owners || !index->ownerUnits ||
                FAILED(source->Draw(index.get(), &mc, 0, 0))) return {};
            inkIndex.Attach(index.release());
            inkIndexFast.store(inkIndex.Get(), std::memory_order_release);
        }
        return inkIndex;
    }

    UINT32 position(int32_t byte) const {
        return byteToUnit ? byteToUnit[std::max<int32_t>(0, std::min(byteCount, byte))] : 0;
    }

    UINT32 firstUnitAtOrAfter(int32_t byte) const {
        byte = std::max<int32_t>(0, std::min(byteCount, byte));
        while (byte > 0 && byte < byteCount && byteToUnit[byte] == byteToUnit[byte - 1]) ++byte;
        return position(byte);
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
        // DirectWrite returns cluster edges for positions inside a ligature.
        // Interpolate carets within that cluster for selection and hit testing.
        const UINT32 boundary = unit + (trailing ? 1 : 0);
        if (boundary > hit.textPosition && boundary - hit.textPosition < hit.length) {
            const float t = float(boundary - hit.textPosition) / float(hit.length);
            return hit.left + hit.width * ((hit.bidiLevel & 1) ? 1 - t : t);
        }
        return x;
    }

    float caretAt(int32_t offset) const {
        if (!byteCount) return 0;
        const UINT32 index = position(offset);
        if (!index) return rtl ? metrics.advance : 0;
        if (offset >= byteCount) return rtl ? 0 : metrics.advance;
        UINT32 nextLevel = 0, previousLevel = 0;
        const float next = edge(index, false, &nextLevel);
        const float previous = edge(index - 1, true, &previousLevel);
        return previousLevel < nextLevel ? previous : next;
    }
};

extern "C" int32_t rune_desktop_line_cluster_owner(const RuneDesktopLine *line, int32_t byte) {
    if (!line || !line->layout || byte < 0 || byte >= line->byteCount) return byte;
    const auto bytes = line->byteToUnit.get();
    const UINT32 unit = bytes[byte];
    if (line->allUnitClusters && (!byte || bytes[byte - 1] != unit)) return byte;
    const InkIndex *idx = line->inkIndexFast.load(std::memory_order_acquire);
    ComPtr<InkIndex> held;
    if (!idx) {
        held = line->shapedIndex(line->layout.Get(), line->position(line->byteCount));
        idx = held.Get();
        if (!idx) return byte;
    }
    const UINT32 owner = idx->ownerUnits[unit];
    if (owner == UINT32_MAX || (owner == unit && (!byte || bytes[byte - 1] != unit))) return byte;
    return static_cast<int32_t>(std::lower_bound(bytes, bytes + byte + 1, owner) - bytes);
}

extern "C" int32_t rune_desktop_line_quality_glyphs(const RuneDesktopLine *line, void *context, RuneQualityGlyphFn emit) {
    if (!line || !line->layout || !emit) return 0;
    if (!line->byteCount) return 1;
    const auto index = line->shapedIndex(line->layout.Get(), line->position(line->byteCount));
    if (!index) return 0;
    const auto bytes = line->byteToUnit.get();
    for (const ShapedRun *run = index->runs; run; run = run->next) {
        const auto points = run->glyphOrigins();
        if (!points) return 0;
        for (UINT32 first = 0; first < run->glyphs.glyphCount;) {
            const auto &span = run->spans[first];
            const auto owner = std::lower_bound(bytes, bytes + line->byteCount, span.ownerUnit);
            const int32_t cluster = static_cast<int32_t>(owner - bytes);
            for (UINT32 i = first; i < first + span.count; ++i)
                emit(context, run->ids[i], cluster, points[i].x, points[i].y, run->advances[i]);
            first += span.count;
        }
    }
    return 1;
}

// Render each shaped glyph at its experimental pen without touching the line's
// production coverage, glyph advances, or fallback font collection.
extern "C" int32_t rune_desktop_line_quality_masks(const RuneDesktopLine *line, int32_t start, int32_t end,
        float origin_x, float baseline_y, int32_t hint, float embolden, void *context, RuneQualityMaskFn emit) {
    if (!line || !line->layout || !emit || start < 0 || end < start || end > line->byteCount ||
            !std::isfinite(origin_x) || !std::isfinite(baseline_y) || embolden != 0) return 0;
    const UINT32 first = line->firstUnitAtOrAfter(start), last = line->firstUnitAtOrAfter(end);
    if (first == last) return 1;
    const auto index = line->shapedIndex(line->layout.Get(), line->position(line->byteCount));
    if (!index) return 0;
    const auto grid = hint ? DWRITE_GRID_FIT_MODE_ENABLED : DWRITE_GRID_FIT_MODE_DISABLED;
    return visitOwnedClusters(*index.Get(), first, last, [&](const ClusterSpan &span, const DWRITE_GLYPH_RUN &glyphs) {
        const auto points = span.run->glyphOrigins();
        if (!points || glyphs.isSideways) return false;
        ComPtr<IDWriteFontFace4> face;
        if (FAILED(span.run->face.As(&face))) return false;
        const UINT32 ppem = UINT32(std::max(1.0f, std::min(65535.0f, std::round(glyphs.fontEmSize))));
        DWRITE_GLYPH_RUN glyph = glyphs;
        // ComputeGlyphOrigins already accounts for RTL advances and glyph offsets.
        glyph.bidiLevel = 0;
        glyph.glyphOffsets = nullptr;
        glyph.glyphAdvances = nullptr;
        glyph.glyphCount = 1;
        for (UINT32 i = 0; i < glyphs.glyphCount; ++i) {
            glyph.glyphIndices = glyphs.glyphIndices + i;
            // The Rust experiment asks Swash for Source::Outline, including on color fonts.
            DWRITE_GLYPH_IMAGE_FORMATS formats;
            if (FAILED(face->GetGlyphImageFormats(*glyph.glyphIndices, ppem, ppem, &formats))) return false;
            if (!(formats & (DWRITE_GLYPH_IMAGE_FORMATS_TRUETYPE | DWRITE_GLYPH_IMAGE_FORMATS_CFF))) continue;
            const auto p = points[span.first + i];
            const float pen = std::round((origin_x + p.x) * 4) / 4;
            // Swash's fract() uses the signed fraction, and its final bitmap uses floor().
            const float x = std::floor(pen) + std::fmod(pen, 1.0f);
            const float y = std::round(std::round(baseline_y) + (p.y - line->metrics.ascent));
            ComPtr<IDWriteGlyphRunAnalysis> analysis;
            if (FAILED(textFactory()->CreateGlyphRunAnalysis(&glyph, nullptr, DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC,
                    span.run->mode, grid, DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE, x, y, analysis.GetAddressOf()))) return false;
            RECT rect{};
            if (FAILED(analysis->GetAlphaTextureBounds(DWRITE_TEXTURE_ALIASED_1x1, &rect))) return false;
            const int64_t width = int64_t(rect.right) - rect.left, height = int64_t(rect.bottom) - rect.top;
            if (width <= 0 || height <= 0) continue;
            if (width > INT32_MAX || height > INT32_MAX || width * height > UINT32_MAX) return false;
            const UINT32 size = UINT32(width * height);
            std::unique_ptr<BYTE[]> data(new (std::nothrow) BYTE[size]);
            if (!data || FAILED(analysis->CreateAlphaTexture(DWRITE_TEXTURE_ALIASED_1x1, &rect, data.get(), size))) return false;
            emit(context, rect.left, rect.top, int32_t(width), int32_t(height), int32_t(width), data.get());
        }
        return true;
    });
}

extern "C" RuneDesktopLine *rune_desktop_line_extract_ink(const RuneDesktopLine *line, int32_t start, int32_t end) {
    if (!line || !line->layout) return nullptr;
    std::unique_ptr<RuneDesktopLine> owned(new (std::nothrow) RuneDesktopLine);
    if (!owned) return nullptr;
    owned->chromiumMask = line->chromiumMask;
    owned->metrics = line->metrics;
    if (start <= 0 && end >= line->byteCount) {
        if (!line->ensureCollector()) return nullptr;
        owned->collector = line->collector;
        owned->ink_x = line->ink_x;
        owned->ink_y = line->ink_y;
        owned->ink_width = line->ink_width;
        owned->ink_height = line->ink_height;
        owned->collectorReady.store(true, std::memory_order_relaxed);
        owned->wholeInkLayout = line->layout;
        owned->inkEnd = line->position(line->byteCount);
        return owned.release();
    }
    owned->collector.Attach(new (std::nothrow) RunCollector(line->chromiumMask));
    if (!owned->collector) return nullptr;
    const UINT32 first = line->firstUnitAtOrAfter(start), last = line->firstUnitAtOrAfter(end);
    if (first < last) {
        owned->inkIndex = line->shapedIndex(line->layout.Get(), line->position(line->byteCount));
        if (!owned->inkIndex) return nullptr;
        owned->inkIndexFast.store(owned->inkIndex.Get(), std::memory_order_relaxed);
        owned->inkFirst = first;
        owned->inkEnd = last;
        if (!visitOwnedClusters(*owned->inkIndex.Get(), first, last, [&](const ClusterSpan &span, const DWRITE_GLYPH_RUN &run) {
            return SUCCEEDED(owned->collector->DrawGlyphRun(nullptr, span.x, span.run->y, span.run->mode, &run, nullptr, nullptr));
        })) return nullptr;
    }
    const RECT &ink = owned->collector->ink;
    const int64_t width = int64_t(ink.right) - ink.left, height = int64_t(ink.bottom) - ink.top;
    if (width > INT32_MAX || height > INT32_MAX) return nullptr;
    owned->ink_x = ink.left;
    owned->ink_y = ink.top;
    owned->ink_width = int32_t(width);
    owned->ink_height = int32_t(height);
    owned->collectorReady.store(true, std::memory_order_relaxed);
    return owned.release();
}

extern "C" int32_t rune_desktop_line_outline(const RuneDesktopLine *ink, RuneOutlineEmit emit, void *context) {
    if (!ink || !emit || ink->layout || !ink->ensureCollector() || ink->collector->hasColor) return 0;
    if (ink->inkFirst == ink->inkEnd) return 1;
    auto index = ink->shapedIndex(ink->wholeInkLayout.Get(), ink->inkEnd);
    if (!index) return 0;
    ComPtr<OutlineSink> sink;
    sink.Attach(new (std::nothrow) OutlineSink(emit, context));
    if (!sink) return 0;
    const bool supported = visitOwnedClusters(*index.Get(), ink->inkFirst, ink->inkEnd, [&](const ClusterSpan &span, const DWRITE_GLYPH_RUN &run) {
        ComPtr<IDWriteFontFace2> colorFace;
        if (run.fontFace->GetType() == DWRITE_FONT_FACE_TYPE_BITMAP ||
            (SUCCEEDED(span.run->face.As(&colorFace)) && colorFace->IsColorFont())) return false;
        sink->x = span.x;
        sink->y = span.run->y;
        return SUCCEEDED(run.fontFace->GetGlyphRunOutline(run.fontEmSize, run.glyphIndices, run.glyphAdvances,
            run.glyphOffsets, run.glyphCount, run.isSideways, (run.bidiLevel & 1) != 0, sink.Get()));
    });
    return supported && (sink->drewSegments || !ink->collector->runs) ? 1 : 0;
}

extern "C" int32_t rune_desktop_line_outline_regions(const RuneDesktopLine *line, RuneOutlineRegion emit, void *context) {
    if (!line || !emit || !line->layout || !line->ensureCollector() || line->collector->hasColor) return 0;
    if (!line->byteCount) return 1;
    const UINT32 units = line->position(line->byteCount);
    auto index = line->shapedIndex(line->layout.Get(), units);
    std::unique_ptr<D2D1_RECT_F[]> bounds(new (std::nothrow) D2D1_RECT_F[units]{});
    if (!bounds || !index) return 0;
    // One geometry query and one placement query per font run. This index
    // locates candidate contours for each tile without rasterizing each cluster.
    for (const ShapedRun *run = index->runs; run; run = run->next) {
        const auto &glyphs = run->glyphs;
        const auto *pens = run->pens();
        std::unique_ptr<DWRITE_GLYPH_METRICS[]> metrics(new (std::nothrow) DWRITE_GLYPH_METRICS[glyphs.glyphCount]);
        DWRITE_FONT_METRICS face{};
        run->face->GetMetrics(&face);
        if (!metrics || !pens || !face.designUnitsPerEm ||
            FAILED(run->face->GetDesignGlyphMetrics(glyphs.glyphIndices, glyphs.glyphCount, metrics.get(), FALSE))) return 0;
        const float scale = glyphs.fontEmSize / face.designUnitsPerEm;
        for (UINT32 first = 0; first < glyphs.glyphCount;) {
            const ClusterSpan &span = run->spans[first];
            D2D1_RECT_F &box = bounds[span.ownerUnit];
            for (UINT32 i = first; i < first + span.count; ++i) {
                const auto &m = metrics[i];
                const float minX = float(m.leftSideBearing), maxX = float(m.advanceWidth) - float(m.rightSideBearing);
                const float minY = float(m.topSideBearing) - float(m.verticalOriginY);
                const float maxY = float(m.advanceHeight) - float(m.bottomSideBearing) - float(m.verticalOriginY);
                if (maxX <= minX || maxY <= minY) continue;
                // Include the rasterizer's filter footprint on all four sides.
                const D2D1_RECT_F ink{floorf(pens[i].x + minX * scale) - 2, floorf(pens[i].y + minY * scale) - 2,
                    ceilf(pens[i].x + maxX * scale) + 2, ceilf(pens[i].y + maxY * scale) + 2};
                if (box.right <= box.left) { box = ink; }
                else {
                    box.left = std::min(box.left, ink.left); box.top = std::min(box.top, ink.top);
                    box.right = std::max(box.right, ink.right); box.bottom = std::max(box.bottom, ink.bottom);
                }
            }
            first += span.count;
        }
    }
    for (int32_t byte = 0; byte < line->byteCount; ++byte) {
        const UINT32 unit = line->byteToUnit[byte];
        if (byte && line->byteToUnit[byte - 1] == unit) continue;
        const auto &box = bounds[unit];
        if (box.right > box.left) emit(context, byte, box.left, box.top, box.right, box.bottom);
    }
    return 1;
}

namespace {
const ClusterSpan *singleOutlineGlyph(const RuneDesktopLine *line, int32_t owner, ComPtr<InkIndex> &index) {
    if (!line || !line->layout || owner < 0 || owner >= line->byteCount) return nullptr;
    const UINT32 unit = line->byteToUnit[owner];
    if (owner && line->byteToUnit[owner - 1] == unit) return nullptr;
    index = line->shapedIndex(line->layout.Get(), line->position(line->byteCount));
    if (!index) return nullptr;
    const auto *span = index->owners[unit];
    if (!span || span->count != 1 || span->next || !span->run->pens() || !span->run->outlineFont) return nullptr;
    return span;
}
// Rune's CoreGraphics matching finds the anchors by PostScript glyph name.
// Subsets with post format 3 have no such anchors even if cmap maps o and X.
bool namedPostGlyph(const FontTable &post, UINT16 standard, BYTE name, UINT16 &glyph) {
    if (!post.bytes || post.size < 32 || post.u16(2) != 0) return false;
    if (post.u16(0) == 1) { glyph = standard; return true; }
    if (post.u16(0) != 2 || post.size < 34) return false;
    const UINT16 count = post.u16(32);
    UINT32 offset = 34 + UINT32(count) * 2;
    if (offset > post.size) return false;
    auto find = [&](UINT16 index) {
        for (UINT32 g = 0; g < count; ++g) {
            if (post.u16(34 + 2 * g) == index) { glyph = UINT16(g); return true; }
        }
        return false;
    };
    if (find(standard)) return true;
    for (UINT32 custom = 258; offset < post.size && custom <= UINT16_MAX; ++custom) {
        UINT32 length = post.bytes[offset++];
        if (length > post.size - offset) return false;
        if (length == 1 && post.bytes[offset] == name) return find(UINT16(custom));
        offset += length;
    }
    return false;
}

bool designOutlineTop(IDWriteFontFace *face, UINT16 glyph, FLOAT em, double &top) {
    if (glyph >= face->GetGlyphCount()) return false;
    struct PathTop { double lastY = 0, highest = -DBL_MAX; bool valid = true; } path;
    auto inspect = [](void *ctx, int32_t command, float, float y1, float, float y2, float, float y3) {
        auto &p = *static_cast<PathTop *>(ctx);
        if (command == 4) return;
        if (command == 3) {
            // DirectWrite represents each TrueType quadratic as a cubic in
            // its sink. Recover the original control point on the font grid.
            const double a = p.lastY + 1.5 * (y1 - p.lastY);
            const double b = y3 + 1.5 * (double(y2) - y3);
            if (std::abs(a - b) > 0.125) p.valid = false;
            p.highest = std::max(p.highest, -0.5 * (a + b));
            p.lastY = y3;
        } else { p.lastY = y1; }
        p.highest = std::max(p.highest, -p.lastY);
    };
    ComPtr<OutlineSink> sink;
    sink.Attach(new (std::nothrow) OutlineSink(inspect, &path));
    const FLOAT zero = 0;
    if (!sink || FAILED(face->GetGlyphRunOutline(em, &glyph, &zero, nullptr, 1, FALSE, FALSE, sink.Get())) ||
        !sink->drewSegments || !path.valid || path.highest == -DBL_MAX) return false;
    top = path.highest;
    return true;
}

std::array<double, 5> readAppleHintMetrics(IDWriteFontFace *face) {
    FontTable glyf(face, DWRITE_MAKE_OPENTYPE_TAG('g','l','y','f'));
    FontTable head(face, DWRITE_MAKE_OPENTYPE_TAG('h','e','a','d'));
    FontTable post(face, DWRITE_MAKE_OPENTYPE_TAG('p','o','s','t'));
    UINT16 idO, idX;
    if (!glyf.bytes || !head.bytes || head.size < 44 ||
        !namedPostGlyph(post, 82, 'o', idO) || !namedPostGlyph(post, 59, 'X', idX)) return {};
    DWRITE_FONT_METRICS fm{};
    face->GetMetrics(&fm);
    double o, x;
    if (!fm.designUnitsPerEm || !designOutlineTop(face, idO, fm.designUnitsPerEm, o) ||
        !designOutlineTop(face, idX, fm.designUnitsPerEm, x)) return {};

    double stem = 0;
    ComPtr<IDWriteFontFace3> described;
    ComPtr<IDWriteLocalizedStrings> names;
    BOOL exists = FALSE;
    if (SUCCEEDED(face->QueryInterface(IID_PPV_ARGS(described.GetAddressOf()))) &&
        SUCCEEDED(described->GetInformationalStrings(DWRITE_INFORMATIONAL_STRING_POSTSCRIPT_NAME, names.GetAddressOf(), &exists)) && exists && names) {
        UINT32 length = 0;
        if (SUCCEEDED(names->GetStringLength(0, &length)) && length < UINT32_MAX) {
            std::unique_ptr<WCHAR[]> name(new (std::nothrow) WCHAR[size_t(length) + 1]);
            if (name && SUCCEEDED(names->GetString(0, name.get(), length + 1))) {
                if (std::wcsncmp(name.get(), L".SFNS", 5) == 0) stem = 79;
                else if (std::wcscmp(name.get(), L"Helvetica") == 0) stem = 85;
            }
        }
    }
    const UINT16 bits = head.u16(42);
    const int maxY = bits < 0x8000 ? int(bits) : int(bits) - 0x10000;
    return {double(fm.designUnitsPerEm), o, x, double(maxY), stem};
}
} // namespace

extern "C" int32_t rune_desktop_line_outline_single(const RuneDesktopLine *line, int32_t owner,
    uint64_t *font_id, uint32_t *glyph, float *pen_x, float *pen_y) {
    if (!font_id || !glyph || !pen_x || !pen_y) return 0;
    ComPtr<InkIndex> index;
    const auto *span = singleOutlineGlyph(line, owner, index);
    if (!span) return 0;
    *font_id = span->run->outlineFont;
    *glyph = span->run->ids[span->first];
    *pen_x = span->run->glyphPens[span->first].x;
    *pen_y = span->run->glyphPens[span->first].y;
    return span->run->outlineCjk ? 3 : 1;
}

extern "C" int32_t rune_desktop_line_outline_unplaced(const RuneDesktopLine *line, int32_t owner,
    RuneOutlineEmit emit, void *context) {
    if (!emit) return 0;
    ComPtr<InkIndex> index;
    const auto *span = singleOutlineGlyph(line, owner, index);
    if (!span) return 0;
    ComPtr<OutlineSink> sink;
    sink.Attach(new (std::nothrow) OutlineSink(emit, context));
    if (!sink) return 0;
    // The shaped glyph ID includes any directional substitution. ComputeGlyphOrigins
    // supplies its placed pen separately, so this geometry has a zero horizontal pen.
    const FLOAT zero = 0;
    return SUCCEEDED(span->run->face->GetGlyphRunOutline(span->run->glyphs.fontEmSize,
        span->run->ids.get() + span->first, &zero, nullptr, 1, FALSE, FALSE, sink.Get())) && sink->drewSegments;
}

extern "C" int32_t rune_desktop_line_apple_hint_metrics(const RuneDesktopLine *line, int32_t owner, double metrics[5]) {
    if (!metrics) return 0;
    ComPtr<InkIndex> index;
    const auto *span = singleOutlineGlyph(line, owner, index);
    if (!span) return 0;
    struct Entry { ComPtr<IDWriteFontFace> font; std::array<double, 5> values{}; };
    static std::array<Entry, 64> cache;
    static size_t next = 0;
    static std::mutex lock;
    const auto &face = span->run->face;
    std::lock_guard<std::mutex> guard(lock);
    ComPtr<IDWriteFontFace5> comparable;
    face.As(&comparable);
    for (const auto &e : cache) {
        if (e.font.Get() == face.Get() || (e.font && comparable && comparable->Equals(e.font.Get()))) {
            if (!e.values[0]) return 0;
            std::copy(e.values.begin(), e.values.end(), metrics);
            return 1;
        }
    }
    auto &e = cache[next++ % cache.size()];
    e = {face, readAppleHintMetrics(face.Get())};
    if (!e.values[0]) return 0;
    std::copy(e.values.begin(), e.values.end(), metrics);
    return 1;
}

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
    return rune_windows_line_create(utf8, length, family, size_px, weight, italic, mono, direction, 0);
}

RuneDesktopLine *rune_windows_line_create(const char *utf8, int32_t length, const char *family,
    float size_px, int32_t weight, int32_t italic, int32_t mono, int32_t direction, int32_t chromium_mask) {
    return rune_windows_line_create_configured(utf8, length, family, size_px, weight, italic, mono,
        direction, chromium_mask, nullptr, nullptr, nullptr);
}

static bool configureLine(RuneDesktopLine &line, const WCHAR *text, UINT32 units, IDWriteTextFormat *format,
                          const char *language, const char *features, const char *variations);

RuneDesktopLine *rune_windows_line_create_configured(const char *utf8, int32_t length, const char *family,
    float size_px, int32_t weight, int32_t italic, int32_t mono, int32_t direction, int32_t chromium_mask,
    const char *language, const char *features, const char *variations) {
    if (length < 0 || (!utf8 && length) || !std::isfinite(size_px) || size_px <= 0 || !textFactory()) return nullptr;
    std::unique_ptr<RuneDesktopLine> line(new (std::nothrow) RuneDesktopLine);
    if (!line) return nullptr;
    line->chromiumMask = chromium_mask != 0;
    std::unique_ptr<WCHAR[]> text(new (std::nothrow) WCHAR[size_t(length) + 1]);
    line->byteToUnit.reset(new (std::nothrow) UINT32[size_t(length) + 1]);
    if (!text || !line->byteToUnit) return nullptr;
    line->byteCount = length;

    int units = 0;
    bool ascii = true;
    for (int32_t i = 0; i < length; ++i) {
        unsigned char b = static_cast<unsigned char>(utf8[i]);
        if (b >= 0x80) { ascii = false; break; }
        text[i] = b;
        line->byteToUnit[i] = UINT32(i);
    }
    if (ascii) {
        units = length;
        text[length] = 0;
        line->byteToUnit[length] = UINT32(length);
    } else {
        units = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, length, text.get(), length);
        if (units == 0) return nullptr;
        text[units] = 0;
        UINT32 native = 0;
        for (int32_t byte = 0; byte < length;) {
            unsigned char lead = static_cast<unsigned char>(utf8[byte]);
            int count = lead < 0x80 ? 1 : lead < 0xe0 ? 2 : lead < 0xf0 ? 3 : 4;
            for (int i = 0; i < count; ++i) line->byteToUnit[byte++] = native;
            native += count == 4 ? 2 : 1;
        }
        line->byteToUnit[length] = native;
    }

    line->ascii = ascii;
    line->rtl = direction == 2 || (direction == 0 && !ascii && autoRTL(text.get(), units));
    auto format = cachedTextFormat(family, mono != 0, size_px, weight, italic != 0, line->rtl);
    if (!format) return nullptr;
    // Tighten to the measured width before asking for glyph positions on RTL lines.
    // Collect native glyphs and hit-test geometry once, under the requested shaping settings.
    // Unavailable or invalid settings keep the ordinary unconfigured layout.
    if (!configureLine(*line, text.get(), units, format.Get(), language, features, variations)) {
        line->layout = makeLayout(text.get(), units, format.Get(), line->rtl);
        if (!line->layout || !line->updateMetrics(line->layout.Get())) return nullptr;
    }
    line->text = std::move(text);
    return line.release();
}

static bool configureLine(RuneDesktopLine &line, const WCHAR *text, UINT32 units, IDWriteTextFormat *format,
                          const char *language, const char *features, const char *variations) {
    if (!units || ((!language || !*language) && (!features || !*features) && (!variations || !*variations)))
        return false;
    DWRITE_TEXT_RANGE range{0, units};
    auto adjusted = makeLayout(text, units, format, line.rtl);
    if (!adjusted) return false;
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
    if (!changed || !line.updateMetrics(adjusted.Get())) return false;
    line.layout = std::move(adjusted);
    return true;
}

void rune_desktop_line_configure(RuneDesktopLine *line, const char *language, const char *features,
    const char *variations) {
    if (line) configureLine(*line, line->text.get(), line->position(line->byteCount), line->layout.Get(),
                            language, features, variations);
}

void rune_desktop_line_destroy(RuneDesktopLine *line) { delete line; }

RuneDesktopLineMetrics rune_desktop_line_metrics(const RuneDesktopLine *line) {
    if (!line) return RuneDesktopLineMetrics{};
    RuneDesktopLineMetrics out = line->metrics;
    if (line->ensureCollector()) {
        out.ink_x = line->ink_x;
        out.ink_y = line->ink_y;
        out.ink_width = line->ink_width;
        out.ink_height = line->ink_height;
    }
    return out;
}

RuneDesktopLineMetrics rune_windows_line_layout_metrics(const RuneDesktopLine *line) {
    return line ? line->metrics : RuneDesktopLineMetrics{};
}

int32_t rune_windows_line_is_unit_clusters(const RuneDesktopLine *line) {
    return line && line->allUnitClusters ? 1 : 0;
}

float rune_desktop_line_caret(const RuneDesktopLine *line, int32_t offset) {
    return line ? line->caretAt(offset) : 0;
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

void rune_windows_line_cells(const RuneDesktopLine *line, RuneWindowsCell *cells, int32_t count) {
    if (!line || !cells || count <= 0) return;
    if (line->hits && line->allLTR && line->ascii) {
        const UnitEdges *hits = line->hits.get();
        const int32_t len = line->byteCount;
        const float advance = line->metrics.advance;
        for (int32_t i = 0; i < count; ++i) {
            auto &c = cells[i];
            const int32_t s = c.start, e = c.end;
            if (s >= 0 && e > s && e <= len) {
                const float startX = hits[s].leading;
                const float endX = hits[e - 1].trailing;
                c.advance = std::abs(endX - startX);
                c.left = std::min(startX, endX);
                c.direction = 1;
                c.caret = s == 0 ? 0.0f : hits[s].leading;
                c.end_caret = e < len ? hits[e].leading : advance;
            } else {
                c.left = 0;
                c.advance = 0;
                c.direction = 0;
                c.caret = line->caretAt(s);
                c.end_caret = line->caretAt(e);
            }
        }
        return;
    }
    for (int32_t i = 0; i < count; ++i) {
        auto &c = cells[i];
        const UINT32 uStart = line->position(c.start);
        const UINT32 uEnd = line->position(c.end);
        if (uEnd <= uStart) {
            c.left = 0;
            c.advance = 0;
            c.direction = 0;
        } else {
            UINT32 level = 0;
            const float startX = line->edge(uStart, false, &level);
            const float endX = line->edge(uEnd - 1, true);
            c.advance = std::abs(endX - startX);
            c.left = std::min(startX, endX);
            c.direction = (level & 1) ? -1 : 1;
        }
        c.caret = line->caretAt(c.start);
        c.end_caret = line->caretAt(c.end);
    }
}

namespace {
int32_t drawTile(const RuneDesktopLine *line, int32_t x, int32_t y, int32_t width, int32_t height,
    uint8_t *pixels, bool color, bool lcd = false) {
    int channels = color ? 4 : lcd ? 3 : 1;
    if (!line || !pixels || width <= 0 || height <= 0 ||
        int64_t(width) * height > UINT32_MAX / channels ||
        int64_t(x) + width > INT32_MAX || int64_t(y) + height > INT32_MAX ||
        !line->ensureCollector()) return 0;
    size_t tilePixels = size_t(width) * height;
    std::memset(pixels, 0, tilePixels * channels);
    for (auto *run = line->collector->runs; run; run = run->next) {
        if (run->colored != color) continue;
        const RECT &b = run->bounds;
        RECT clip{ std::max<LONG>(x, b.left), std::max<LONG>(y, b.top),
            std::min<LONG>(x + width, b.right), std::min<LONG>(y + height, b.bottom) };
        if (clip.right <= clip.left || clip.bottom <= clip.top) continue;
        UINT32 w = clip.right - clip.left, h = clip.bottom - clip.top;
        const UINT32 samples = run->texture == DWRITE_TEXTURE_CLEARTYPE_3x1 ? 3 : 1;
        if (lcd && samples != 3) return 0;
        if (samples == UINT32(channels) && !color && run == line->collector->runs && !run->next && w == UINT32(width) && h == UINT32(height))
            return SUCCEEDED(run->analysis->CreateAlphaTexture(run->texture, &clip, pixels, w * h * samples));
        if (uint64_t(w) * h * samples > UINT32_MAX) return 0;
        std::unique_ptr<BYTE[]> mask(new (std::nothrow) BYTE[size_t(w) * h * samples]);
        if (!mask || FAILED(run->analysis->CreateAlphaTexture(run->texture, &clip, mask.get(), w * h * samples))) return 0;
        if (samples == 3 && !lcd) {
            for (size_t i = 0; i < size_t(w) * h; ++i)
                mask[i] = BYTE((int(mask[i * 3]) + mask[i * 3 + 1] + mask[i * 3 + 2]) / 3);
        }
        for (UINT32 row = 0; row < h; ++row) {
            auto *dst = pixels + (size_t(clip.top - y + row) * width + (clip.left - x)) * channels;
            const auto *src = mask.get() + size_t(row) * w * (lcd ? 3 : 1);
            if (!color) {
                for (UINT32 col = 0; col < w * UINT32(channels); ++col)
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

int32_t rune_windows_line_lcd(const RuneDesktopLine *line, int32_t x, int32_t y,
    int32_t width, int32_t height, uint8_t *rgb) {
    return line && line->chromiumMask && drawTile(line, x, y, width, height, rgb, false, true);
}

int32_t rune_desktop_line_has_color(const RuneDesktopLine *line) {
    return line && line->ensureCollector() && line->collector->hasColor;
}

int32_t rune_desktop_line_color(const RuneDesktopLine *line, int32_t x, int32_t y,
    int32_t width, int32_t height, uint8_t *pixels) {
    return drawTile(line, x, y, width, height, pixels, true);
}
#endif
