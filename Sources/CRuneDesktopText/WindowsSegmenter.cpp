#if defined(_WIN32)
#define NOMINMAX
#include <windows.h>
#include <icu.h>
#include <algorithm>
#include <memory>
#include <new>
#include "RuneDesktopText.h"

namespace {
using Open = void *(__cdecl *)(int32_t, const char *, const uint16_t *, int32_t, int32_t *);
using Next = int32_t (__cdecl *)(void *);
using Close = void (__cdecl *)(void *);
using Property = int32_t (__cdecl *)(UChar32, UProperty);
struct IteratorAPI { Open open; Next next; Close close; Property property; };
IteratorAPI api{};
INIT_ONCE started = INIT_ONCE_STATIC_INIT;
HANDLE presented;
volatile LONG ready;

// UBRK_WORD returns UTF-16 boundaries. There can be at most one end per unit.
int32_t wordEnds(const uint16_t *text, int32_t units, const char *locale, int32_t *ends) {
    int32_t status = 0, count = 0;
    void *iterator = api.open(1, locale, text, units, &status);
    if (!iterator) return -1;
    if (status <= 0) {
        for (int32_t end; (end = api.next(iterator)) != -1;) {
            if (end <= 0 || end > units || count >= units) { status = 1; break; }
            if (ends) ends[count] = end;
            ++count;
        }
    }
    api.close(iterator);
    return status > 0 ? -1 : count;
}

DWORD WINAPI warm(void *) {
    if (presented) WaitForSingleObject(presented, 1000);
    HMODULE module = LoadLibraryExW(L"icu.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!module) return 0;
    api = {reinterpret_cast<Open>(GetProcAddress(module, "ubrk_open")),
           reinterpret_cast<Next>(GetProcAddress(module, "ubrk_next")),
           reinterpret_cast<Close>(GetProcAddress(module, "ubrk_close")),
           reinterpret_cast<Property>(GetProcAddress(module, "u_getIntPropertyValue"))};
    if (!api.open || !api.next || !api.close) { FreeLibrary(module); return 0; }
    struct Sample { const char *locale; const char16_t *text; };
    const Sample samples[] = {{"th", u"ภาษาไทย"}, {"lo", u"ພາສາ"}, {"km", u"ភាសា"},
                              {"my", u"ဘာသာ"}, {"ja", u"日本語"}};
    for (const auto &sample : samples) {
        int32_t units = 0;
        while (sample.text[units]) ++units;
        wordEnds(reinterpret_cast<const uint16_t *>(sample.text), units, sample.locale, nullptr);
    }
    InterlockedExchange(&ready, 1);
    return 0;
}

enum class Language { other, thai, lao, khmer, myanmar, japanese };
Language language(int32_t script) {
    switch (script) {
    case USCRIPT_THAI: return Language::thai;
    case USCRIPT_LAO: return Language::lao;
    case USCRIPT_KHMER: return Language::khmer;
    case USCRIPT_MYANMAR: return Language::myanmar;
    case USCRIPT_HAN: case USCRIPT_HIRAGANA: case USCRIPT_KATAKANA: return Language::japanese;
    default: return Language::other;
    }
}

bool mark(UChar32 scalar) {
    return (U_MASK(api.property(scalar, UCHAR_GENERAL_CATEGORY)) & U_GC_M_MASK) != 0;
}

void refineRun(const uint16_t *text, int32_t units, Language lang, uint8_t *flags) {
    int32_t pos = 0;
    UChar32 scalar;
    U16_NEXT(text, pos, units, scalar);
    if (pos >= units) return;
    static const char *const locales[] = {"", "th", "lo", "km", "my", "ja"};
    std::unique_ptr<int32_t[]> ends(new (std::nothrow) int32_t[units]);
    if (!ends) return;
    const int32_t n = wordEnds(text, units, locales[int(lang)], ends.get());
    if (n < 0) return;
    std::fill(flags + 1, flags + units, BYTE(0));
    bool hasBase = !mark(scalar);
    int32_t end = 0;
    while (pos < units) {
        int32_t at = pos;
        U16_NEXT(text, pos, units, scalar);
        if (end < n && ends[end] == at) {
            const auto lb = api.property(scalar, UCHAR_LINE_BREAK);
            flags[at] = hasBase && lb != U_LB_NONSTARTER && lb != U_LB_COMBINING_MARK && lb != U_LB_ZWJ;
            ++end;
        }
        hasBase = hasBase || !mark(scalar);
    }
}

BOOL CALLBACK start(PINIT_ONCE, PVOID, PVOID *) {
    presented = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    QueueUserWorkItem(warm, nullptr, WT_EXECUTEDEFAULT);
    return TRUE;
}
}

void rune_windows_segmenter_start() {
    InitOnceExecuteOnce(&started, start, nullptr, nullptr);
}

void rune_windows_segmenter_presented() {
    rune_windows_segmenter_start();
    if (presented) SetEvent(presented);
}

int32_t rune_windows_word_ends(const uint16_t *text, int32_t units, int32_t *ends) {
    rune_windows_segmenter_start(); // Headless text use can precede the first window.
    if (!InterlockedCompareExchange(&ready, 0, 0) || units < 0 || (units && (!text || !ends))) return -1;
    return units ? wordEnds(text, units, "", ends) : 0;
}

int32_t rune_windows_visual_word_breaks(const uint16_t *text, int32_t units, uint8_t *flags) {
    rune_windows_segmenter_start();
    if (!InterlockedCompareExchange(&ready, 0, 0) || !api.property || units <= 0 || !text || !flags) return 0;
    int32_t start = 0, pos = 0;
    Language open = Language::other;
    while (pos < units) {
        const int32_t at = pos;
        UChar32 scalar;
        U16_NEXT(text, pos, units, scalar);
        const auto script = api.property(scalar, UCHAR_SCRIPT);
        const auto lang = language(script);
        if (open != Language::other) {
            if (lang == open || script == USCRIPT_INHERITED || mark(scalar) ||
                scalar == 0x200c || scalar == 0x200d || scalar == 0x30fc) continue;
            refineRun(text + start, at - start, open, flags + start);
        }
        start = at;
        open = lang;
    }
    if (open != Language::other) refineRun(text + start, units - start, open, flags + start);
    return 1;
}
#endif
