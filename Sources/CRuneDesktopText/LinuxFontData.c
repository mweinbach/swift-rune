#if defined(__linux__) && !defined(__ANDROID__)
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "RuneDesktopText.h"
#include <errno.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>

int32_t rune_desktop_register_font_bytes(const uint8_t *bytes, uint32_t length) {
    if (!bytes || !length) return 0;
    int fd = memfd_create("rune-font", MFD_CLOEXEC);
    if (fd < 0) return 0;
    size_t written = 0;
    while (written < length) {
        ssize_t n = write(fd, bytes + written, length - written);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) {
            close(fd);
            return 0;
        }
        written += (size_t)n;
    }
    char path[64];
    snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
    if (!rune_desktop_register_font_file(path)) {
        close(fd);
        return 0;
    }
    // Fontconfig reopens this filename when it needs a face. The descriptor
    // keeps it available until process exit without leaving any files on disk.
    return 1;
}
#endif
