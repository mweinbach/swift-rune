#ifndef RUNE_NOTIFY_ACTIVATION_H
#define RUNE_NOTIFY_ACTIVATION_H

#include <stddef.h>

/* Strings are UTF-16 on Windows and valid until the callback returns. */
typedef struct {
    const wchar_t *key;
    const wchar_t *value;
} RuneNotifyInput;

typedef void (*RuneNotifyActivation)(void *context, const wchar_t *arguments,
                                     const RuneNotifyInput *inputs, size_t count);

#endif
