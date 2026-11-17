#ifndef RUNE_DESKTOP_SERVICES_INTERNAL_H
#define RUNE_DESKTOP_SERVICES_INTERNAL_H
#include "RuneDesktopServices.h"
#include <stdlib.h>
#include <string.h>

#define RUNE_CLIPBOARD_LIMIT (64u * 1024u * 1024u)
#define RUNE_CLIPBOARD_TYPES 256u
#define RUNE_PLAIN "text/plain;charset=utf-8"
#define RUNE_CONCEALED "org.nspasteboard.ConcealedType"
struct RuneMimeEntry { char *type; uint8_t *bytes; size_t length; };
struct RuneMimeData { struct RuneMimeEntry *entries; size_t count, total; };
struct RuneDesktopPicker {
    RuneMimeData *filters;
    char **paths;
    size_t count;
};
int rune_picker_add_path(RuneDesktopPicker *, const char *);
const struct RuneMimeEntry *rune_mime_find(const RuneMimeData *, const char *);
#endif
