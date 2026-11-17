#ifndef RUNE_EXIF_ORIENTATION_H
#define RUNE_EXIF_ORIENTATION_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

static inline uint16_t rune_tiff_u16(const uint8_t *p, int little) {
    return little ? (uint16_t)(p[0] | (p[1] << 8)) : (uint16_t)((p[0] << 8) | p[1]);
}

static inline uint32_t rune_tiff_u32(const uint8_t *p, int little) {
    uint32_t first = rune_tiff_u16(p, little), second = rune_tiff_u16(p + 2, little);
    return little ? first | (second << 16) : (first << 16) | second;
}

// A WebP EXIF chunk contains the TIFF directory, optionally prefixed by "Exif\0\0".
static inline int rune_exif_orientation(const uint8_t *p, size_t size) {
    if (size >= 6 && !memcmp(p, "Exif\0\0", 6)) { p += 6; size -= 6; }
    if (size < 8) return 1;
    int little = !memcmp(p, "II", 2);
    if ((!little && memcmp(p, "MM", 2)) || rune_tiff_u16(p + 2, little) != 42) return 1;
    size_t pos = rune_tiff_u32(p + 4, little);
    if (pos < 8 || pos > size - 2) return 1;
    unsigned count = rune_tiff_u16(p + pos, little);
    pos += 2;
    for (unsigned i = 0; i < count && size - pos >= 12; ++i, pos += 12) {
        if (rune_tiff_u16(p + pos, little) == 0x0112 && rune_tiff_u16(p + pos + 2, little) == 3 &&
            rune_tiff_u32(p + pos + 4, little) == 1) {
            unsigned orientation = rune_tiff_u16(p + pos + 8, little);
            return orientation >= 1 && orientation <= 8 ? (int)orientation : 1;
        }
    }
    return 1;
}

#endif
