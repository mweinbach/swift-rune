#if defined(__linux__) && !defined(__ANDROID__)
#include "RuneDesktopSpell.h"
#include <dlfcn.h>
#include <pango/pango.h>
#include <string.h>
#include <sys/types.h>

/* Enchant is optional. UI-only installations can use Rune's built-in dictionary. */
typedef struct str_enchant_broker EnchantBroker;
typedef struct str_enchant_dict EnchantDict;
typedef void (*DescribeDict)(const char *, const char *, const char *, const char *, void *);

static struct {
    EnchantBroker *(*broker_init)(void);
    void (*broker_list_dicts)(EnchantBroker *, DescribeDict, void *);
    EnchantDict *(*broker_request_dict)(EnchantBroker *, const char *);
    int (*dict_check)(EnchantDict *, const char *, ssize_t);
    char **(*dict_suggest)(EnchantDict *, const char *, ssize_t, size_t *);
    void (*dict_free_string_list)(EnchantDict *, char **);
    void (*dict_add)(EnchantDict *, const char *, ssize_t);
    const char *(*dict_get_error)(EnchantDict *);
} enchant;

struct Dictionary {
    char *language, *enchant_tag;
    EnchantDict *handle;
};

static EnchantBroker *broker;
static GPtrArray *dictionaries;
static GMutex broker_lock;
static gsize initialized;

static void collect_language(const char *tag, const char *provider, const char *description,
                             const char *path, void *context) {
    (void)provider; (void)description; (void)path; (void)context;
    if (!tag || !tag[0]) return;
    char *language = g_strdelimit(g_strdup(tag), "_", '-');
    for (guint i = 0; i < dictionaries->len; ++i) {
        struct Dictionary *entry = g_ptr_array_index(dictionaries, i);
        if (g_ascii_strcasecmp(entry->language, language) == 0) {
            g_free(language);
            return;
        }
    }
    struct Dictionary *entry = g_new0(struct Dictionary, 1);
    entry->language = language;
    entry->enchant_tag = g_strdup(tag);
    g_ptr_array_add(dictionaries, entry);
}

static void open_broker(void) {
    void *library = dlopen("libenchant-2.so.2", RTLD_NOW | RTLD_LOCAL);
    if (!library) return;
#define LOAD(name) do { \
    enchant.name = dlsym(library, "enchant_" #name); \
    if (!enchant.name) { dlclose(library); return; } \
} while (0)
    LOAD(broker_init);
    LOAD(broker_list_dicts);
    LOAD(broker_request_dict);
    LOAD(dict_check);
    LOAD(dict_suggest);
    LOAD(dict_free_string_list);
    LOAD(dict_add);
    LOAD(dict_get_error);
#undef LOAD
    broker = enchant.broker_init();
    if (!broker) { dlclose(library); return; }
    dictionaries = g_ptr_array_new();
    enchant.broker_list_dicts(broker, collect_language, NULL);
}

static void ensure_initialized(void) {
    if (g_once_init_enter(&initialized)) {
        open_broker();
        g_once_init_leave(&initialized, 1);
    }
}

/* The inventory is immutable after initialization. A dictionary handle is created
   on first use and accessed only under broker_lock, including from worker threads. */
static EnchantDict *dictionary_locked(const char *tag) {
    if (!tag || !dictionaries) return NULL;
    for (guint i = 0; i < dictionaries->len; ++i) {
        struct Dictionary *entry = g_ptr_array_index(dictionaries, i);
        if (g_ascii_strcasecmp(tag, entry->language) == 0) {
            if (!entry->handle)
                entry->handle = enchant.broker_request_dict(broker, entry->enchant_tag);
            return entry->handle;
        }
    }
    return NULL;
}

int rune_spell_languages(void *context, RuneSpellString emit) {
    ensure_initialized();
    if (!dictionaries || !emit) return 0;
    for (guint i = 0; i < dictionaries->len; ++i) {
        struct Dictionary *entry = g_ptr_array_index(dictionaries, i);
        emit(context, entry->language);
    }
    return 1;
}

struct SpellingRange { size_t start, length; };

int rune_spell_check(const char *tag, const char *text, void *context, RuneSpellRange emit) {
    if (!text || !emit || strlen(text) >= G_MAXINT || !g_utf8_validate(text, -1, NULL)) return 0;
    ensure_initialized();
    g_mutex_lock(&broker_lock);
    EnchantDict *dict = dictionary_locked(tag);
    if (!dict) { g_mutex_unlock(&broker_lock); return 0; }

    /* Pango returns break positions per Unicode scalar. Keep UTF-8 pointers while
       walking them so composed/decomposed and non-BMP words retain their byte ranges. */
    int count = (int)g_utf8_strlen(text, -1);
    PangoLogAttr *attrs = g_new(PangoLogAttr, count + 1);
    pango_get_log_attrs(text, -1, -1, pango_language_from_string(tag), attrs, count + 1);
    GArray *ranges = g_array_new(FALSE, FALSE, sizeof(struct SpellingRange));
    const char *start = text, *p = text;
    gboolean has_letter = FALSE;
    int ok = 1;
    for (int i = 0; i <= count; ++i) {
        if (i == count || attrs[i].is_word_boundary) {
            if (has_letter) {
                char *word = g_utf8_normalize(start, p - start, G_NORMALIZE_NFC);
                int result = enchant.dict_check(dict, word, -1);
                g_free(word);
                if (result < 0) { ok = 0; break; }
                if (result > 0) {
                    struct SpellingRange range = { (size_t)(start - text), (size_t)(p - start) };
                    g_array_append_val(ranges, range);
                }
            }
            start = p;
            has_letter = FALSE;
        }
        if (i < count) {
            has_letter |= g_unichar_isalpha(g_utf8_get_char(p));
            p = g_utf8_next_char(p);
        }
    }
    g_mutex_unlock(&broker_lock);
    if (ok) {
        for (guint i = 0; i < ranges->len; ++i) {
            struct SpellingRange range = g_array_index(ranges, struct SpellingRange, i);
            emit(context, range.start, range.length);
        }
    }
    g_free(attrs);
    g_array_free(ranges, TRUE);
    return ok;
}

int rune_spell_suggest(const char *tag, const char *word, void *context, RuneSpellString emit) {
    if (!word || !word[0] || !emit || !g_utf8_validate(word, -1, NULL)) return 0;
    ensure_initialized();
    g_mutex_lock(&broker_lock);
    EnchantDict *dict = dictionary_locked(tag);
    if (!dict) { g_mutex_unlock(&broker_lock); return 0; }
    char *normalized = g_utf8_normalize(word, -1, G_NORMALIZE_NFC);
    size_t count = 0;
    char **list = enchant.dict_suggest(dict, normalized, -1, &count);
    int ok = !enchant.dict_get_error(dict);
    GPtrArray *suggestions = g_ptr_array_new_with_free_func(g_free);
    for (size_t i = 0; list && i < count && i < 5; ++i) {
        g_ptr_array_add(suggestions, g_strdup(list[i]));
    }
    if (list) enchant.dict_free_string_list(dict, list);
    g_free(normalized);
    g_mutex_unlock(&broker_lock);
    if (ok) {
        for (guint i = 0; i < suggestions->len; ++i)
            emit(context, g_ptr_array_index(suggestions, i));
    }
    g_ptr_array_unref(suggestions);
    return ok;
}

int rune_spell_learn(const char *tag, const char *word) {
    if (!word || !word[0] || !g_utf8_validate(word, -1, NULL)) return 0;
    ensure_initialized();
    g_mutex_lock(&broker_lock);
    EnchantDict *dict = dictionary_locked(tag);
    int ok = 0;
    if (dict) {
        char *normalized = g_utf8_normalize(word, -1, G_NORMALIZE_NFC);
        enchant.dict_add(dict, normalized, -1);
        ok = !enchant.dict_get_error(dict);
        g_free(normalized);
    }
    g_mutex_unlock(&broker_lock);
    return ok;
}
#endif
