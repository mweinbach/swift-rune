#ifndef RUNE_DESKTOP_SPELL_H
#define RUNE_DESKTOP_SPELL_H
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*RuneSpellString)(void *context, const char *utf8);
typedef void (*RuneSpellRange)(void *context, size_t start_utf8, size_t length_utf8);

/* Operations are synchronous and may be called from any thread. Return 1
   when the dictionary answered, 0 when the service or dictionary is absent.
   A callback's data is borrowed until it returns. Tags are BCP 47. */
int rune_spell_languages(void *context, RuneSpellString emit);
int rune_spell_check(const char *tag, const char *text, void *context, RuneSpellRange emit);
int rune_spell_suggest(const char *tag, const char *word, void *context, RuneSpellString emit);
int rune_spell_learn(const char *tag, const char *word);

#ifdef __cplusplus
}
#endif
#endif
