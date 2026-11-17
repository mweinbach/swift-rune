#include "RuneMicrophone.h"
#include <stdio.h>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdlib.h>

static wchar_t *wide_path(const char *utf8) {
    int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, NULL, 0);
    if (!size) return NULL;
    wchar_t *result = (wchar_t *)calloc((size_t)size, sizeof(*result));
    if (result && !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, result, size)) {
        free(result);
        return NULL;
    }
    return result;
}

int rune_mic_publish(const char *staging, const char *destination, char *error, size_t size) {
    wchar_t *from = wide_path(staging);
    wchar_t *to = wide_path(destination);
    int ok = from && to && MoveFileExW(from, to, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
    if (!ok && size) snprintf(error, size, "Could not save recording (Win32 error %lu)", GetLastError());
    free(from);
    free(to);
    return ok;
}
#elif defined(__linux__) && !defined(__ANDROID__)
#include <errno.h>
#include <string.h>
int rune_mic_publish(const char *staging, const char *destination, char *error, size_t size) {
    if (rename(staging, destination) == 0) return 1;
    if (size) snprintf(error, size, "Could not save recording: %s", strerror(errno));
    return 0;
}
#endif
