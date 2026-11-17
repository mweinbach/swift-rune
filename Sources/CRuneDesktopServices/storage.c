#include "services_internal.h"

RuneMimeData *rune_mime_create(void) { return calloc(1, sizeof(RuneMimeData)); }
void rune_mime_free(RuneMimeData *list) {
    if (!list) return;
    for (size_t i = 0; i < list->count; ++i) {
        free(list->entries[i].type);
        free(list->entries[i].bytes);
    }
    free(list->entries);
    free(list);
}

int rune_mime_add(RuneMimeData *list, const char *type, const uint8_t *bytes, size_t length) {
    if (!list || !type || !*type || (!bytes && length) || list->count >= RUNE_CLIPBOARD_TYPES ||
        length > RUNE_CLIPBOARD_LIMIT - list->total) return 0;
    size_t name_len = strlen(type);
    if (name_len > 1024) return 0;
    char *name = malloc(name_len + 1);
    uint8_t *value = malloc(length + 1);
    if (!name || !value) { free(name); free(value); return 0; }
    memcpy(name, type, name_len + 1);
    if (length) memcpy(value, bytes, length);
    value[length] = 0;
    struct RuneMimeEntry *entries = realloc(list->entries, (list->count + 1) * sizeof(*entries));
    if (!entries) { free(name); free(value); return 0; }
    list->entries = entries;
    entries[list->count++] = (struct RuneMimeEntry){name, value, length};
    list->total += length;
    return 1;
}
const struct RuneMimeEntry *rune_mime_find(const RuneMimeData *list, const char *type) {
    for (size_t i = 0; list && i < list->count; ++i)
        if (!strcmp(list->entries[i].type, type)) return &list->entries[i];
    return NULL;
}
size_t rune_mime_count(const RuneMimeData *list) { return list ? list->count : 0; }
const char *rune_mime_type(const RuneMimeData *list, size_t i) {
    return list && i < list->count ? list->entries[i].type : NULL;
}
const uint8_t *rune_mime_bytes(const RuneMimeData *list, size_t i, size_t *length) {
    if (!list || i >= list->count || !length) return NULL;
    *length = list->entries[i].length;
    return list->entries[i].bytes;
}
RuneDesktopPicker *rune_picker_create(void) {
    RuneDesktopPicker *picker = calloc(1, sizeof(*picker));
    if (picker && !(picker->filters = rune_mime_create())) { free(picker); return NULL; }
    return picker;
}
void rune_picker_free(RuneDesktopPicker *picker) {
    if (!picker) return;
    for (size_t i = 0; i < picker->count; ++i) free(picker->paths[i]);
    free(picker->paths);
    rune_mime_free(picker->filters);
    free(picker);
}
int rune_picker_filter(RuneDesktopPicker *picker, const char *name, const char *patterns) {
    return picker && patterns && rune_mime_add(picker->filters, name, (const uint8_t *)patterns, strlen(patterns));
}
int rune_picker_add_path(RuneDesktopPicker *picker, const char *path) {
    if (!picker || !path || picker->count >= 65536) return 0;
    char *copy = malloc(strlen(path) + 1);
    if (!copy) return 0;
    strcpy(copy, path);
    char **paths = realloc(picker->paths, (picker->count + 1) * sizeof(*paths));
    if (!paths) { free(copy); return 0; }
    picker->paths = paths;
    paths[picker->count++] = copy;
    return 1;
}
size_t rune_picker_count(const RuneDesktopPicker *picker) { return picker ? picker->count : 0; }
const char *rune_picker_path(const RuneDesktopPicker *picker, size_t i) {
    return picker && i < picker->count ? picker->paths[i] : NULL;
}
