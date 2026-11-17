#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <objbase.h>
#include <spellcheck.h>
#include <stdlib.h>
#include "RuneDesktopSpell.h"

/* The SDK declares these spellcheck.idl IDs but does not export them in uuid.lib. */
static const CLSID factory_class = {
    0x7AB36653, 0x1796, 0x484B, {0xBD, 0xFA, 0xE7, 0x4F, 0x1D, 0xB7, 0xC1, 0xDC}
};
static const IID factory_interface = {
    0x8E018A9D, 0x2415, 0x4677, {0xBF, 0x08, 0x79, 0x4E, 0xA6, 0x1F, 0x94, 0xBB}
};

/* The factory and its checkers are apartment-bound. Keep the entire operation
   in the caller's apartment, including release of the provider's objects. */
typedef struct {
    HRESULT apartment;
    ISpellCheckerFactory *factory;
    ISpellChecker *checker;
} SpellSession;

static wchar_t *to_wide(const char *utf8, int *count) {
    if (!utf8) return NULL;
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, NULL, 0);
    if (!n) return NULL;
    wchar_t *wide = calloc((size_t)n, sizeof(*wide));
    if (!wide) return NULL;
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, wide, n)) {
        free(wide);
        return NULL;
    }
    if (count) *count = n - 1;
    return wide;
}

static int start_session(SpellSession *session, const char *tag) {
    session->apartment = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    if (FAILED(session->apartment) && session->apartment != RPC_E_CHANGED_MODE) return 0;
    if (FAILED(CoCreateInstance(&factory_class, NULL, CLSCTX_INPROC_SERVER,
                                &factory_interface, (void **)&session->factory))) return 0;
    if (!tag) return 1;
    wchar_t *language = to_wide(tag, NULL);
    if (!language) return 0;
    HRESULT status = ISpellCheckerFactory_CreateSpellChecker(session->factory, language, &session->checker);
    free(language);
    return SUCCEEDED(status) && session->checker;
}

static void finish_session(SpellSession *session) {
    if (session->checker) ISpellChecker_Release(session->checker);
    if (session->factory) ISpellCheckerFactory_Release(session->factory);
    if (SUCCEEDED(session->apartment)) CoUninitialize();
}

static int emit_strings(IEnumString *list, void *context, RuneSpellString emit) {
    for (;;) {
        wchar_t *wide = NULL;
        ULONG fetched = 0;
        HRESULT status = IEnumString_Next(list, 1, &wide, &fetched);
        if (status != S_OK || !fetched || !wide) {
            CoTaskMemFree(wide);
            return SUCCEEDED(status);
        }
        int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, -1, NULL, 0, NULL, NULL);
        char *utf8 = size ? malloc((size_t)size) : NULL;
        int converted = utf8 && WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, -1, utf8, size, NULL, NULL);
        if (converted) emit(context, utf8);
        free(utf8);
        CoTaskMemFree(wide);
        if (!converted) return 0;
    }
}

int rune_spell_languages(void *context, RuneSpellString emit) {
    if (!emit) return 0;
    SpellSession session = {0};
    IEnumString *languages = NULL;
    int ok = start_session(&session, NULL)
        && SUCCEEDED(ISpellCheckerFactory_get_SupportedLanguages(session.factory, &languages)) && languages
        && emit_strings(languages, context, emit);
    if (languages) IEnumString_Release(languages);
    finish_session(&session);
    return ok;
}

/* Check() reports UTF-16 offsets. The second code unit of an astral scalar
   maps to that scalar's start, and the sentinel maps to the final UTF-8 byte. */
static size_t *utf8_offsets(const wchar_t *wide, int count) {
    size_t *offsets = calloc((size_t)count + 1, sizeof(*offsets));
    if (!offsets) return NULL;
    size_t byte = 0;
    for (int i = 0; i < count; ++i) {
        unsigned ch = wide[i];
        offsets[i] = byte;
        if (ch >= 0xD800 && ch <= 0xDBFF && i + 1 < count) {
            offsets[++i] = byte;
            byte += 4;
        } else {
            byte += ch < 0x80 ? 1 : ch < 0x800 ? 2 : 3;
        }
    }
    offsets[count] = byte;
    return offsets;
}

int rune_spell_check(const char *tag, const char *text, void *context, RuneSpellRange emit) {
    if (!tag || !emit) return 0;
    SpellSession session = {0};
    IEnumSpellingError *errors = NULL;
    int units = 0;
    wchar_t *wide = to_wide(text, &units);
    size_t *offsets = wide ? utf8_offsets(wide, units) : NULL;
    if (!offsets) { free(wide); return 0; }
    int ok = start_session(&session, tag)
        && SUCCEEDED(ISpellChecker_Check(session.checker, wide, &errors)) && errors;
    while (ok) {
        ISpellingError *error = NULL;
        HRESULT status = IEnumSpellingError_Next(errors, &error);
        if (status != S_OK || !error) {
            if (error) ISpellingError_Release(error);
            ok = SUCCEEDED(status);
            break;
        }
        CORRECTIVE_ACTION action = CORRECTIVE_ACTION_NONE;
        ULONG start = 0, length = 0;
        if (SUCCEEDED(ISpellingError_get_CorrectiveAction(error, &action))
            && (action == CORRECTIVE_ACTION_GET_SUGGESTIONS || action == CORRECTIVE_ACTION_REPLACE)
            && SUCCEEDED(ISpellingError_get_StartIndex(error, &start))
            && SUCCEEDED(ISpellingError_get_Length(error, &length))
            && start <= (ULONG)units && length <= (ULONG)units - start
            && offsets[start] < offsets[start + length]) {
            emit(context, offsets[start], offsets[start + length] - offsets[start]);
        }
        ISpellingError_Release(error);
    }
    if (errors) IEnumSpellingError_Release(errors);
    finish_session(&session);
    free(offsets);
    free(wide);
    return ok;
}

int rune_spell_suggest(const char *tag, const char *word, void *context, RuneSpellString emit) {
    if (!tag || !emit) return 0;
    wchar_t *wide = to_wide(word, NULL);
    if (!wide) return 0;
    SpellSession session = {0};
    IEnumString *suggestions = NULL;
    int ok = start_session(&session, tag)
        && SUCCEEDED(ISpellChecker_Suggest(session.checker, wide, &suggestions)) && suggestions
        && emit_strings(suggestions, context, emit);
    if (suggestions) IEnumString_Release(suggestions);
    finish_session(&session);
    free(wide);
    return ok;
}

int rune_spell_learn(const char *tag, const char *word) {
    if (!tag) return 0;
    wchar_t *wide = to_wide(word, NULL);
    if (!wide) return 0;
    SpellSession session = {0};
    int ok = start_session(&session, tag) && SUCCEEDED(ISpellChecker_Add(session.checker, wide));
    finish_session(&session);
    free(wide);
    return ok;
}
#endif
