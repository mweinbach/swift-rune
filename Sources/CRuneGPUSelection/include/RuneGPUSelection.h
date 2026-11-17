#ifndef RUNE_GPU_SELECTION_H
#define RUNE_GPU_SELECTION_H
#include <stddef.h>
#include <stdint.h>
#include <string.h>

enum RuneGPUPowerClass { RuneGPUIntegrated, RuneGPUDiscrete, RuneGPUVirtual, RuneGPUOther, RuneGPUCPU };
struct RuneGPUAdapter {
    const char *name, *pci;
    unsigned vendor, device;
    enum RuneGPUPowerClass power;
    int usable, vulkan;
};
struct RuneGPUIDs { unsigned vendor, device; };

static inline unsigned rune_gpu_lower(unsigned c) { return c >= 'A' && c <= 'Z' ? c + ('a'-'A') : c; }

static inline int rune_gpu_prefix(const char *s, const char *prefix) {
    while (*prefix) if (rune_gpu_lower((unsigned char)*s++) != rune_gpu_lower((unsigned char)*prefix++)) return 0;
    return 1;
}

static inline int rune_gpu_by_name(const struct RuneGPUAdapter *a, int count, const char *wanted) {
    if (!wanted) return -1;
    for (int i = 0; i < count; i++) {
        if (!a[i].usable || !a[i].name) continue;
        const char *p = a[i].name;
        do { if (rune_gpu_prefix(p, wanted)) return i; } while (*p++);
    }
    return -1;
}

static inline int rune_gpu_shows(const char *compositor, const char *adapter) {
    return !compositor || (*compositor && adapter && strlen(compositor) == strlen(adapter) && rune_gpu_prefix(adapter, compositor));
}

static inline int rune_gpu_by_pci(const struct RuneGPUAdapter *a, int count, const char *pci) {
    int first = -1;
    if (!pci || !*pci) return -1;
    for (int i = 0; i < count; ++i) {
        if (!a[i].usable || !rune_gpu_shows(pci, a[i].pci)) continue;
        if (a[i].vulkan) return i;
        if (first < 0) first = i;
    }
    return first;
}

static inline int rune_gpu_by_display(const struct RuneGPUAdapter *a, int count, const struct RuneGPUIDs *ids, int displays) {
    for (int d = 0; d < displays; d++) for (int i = 0; i < count; i++)
        if (a[i].usable && a[i].power != RuneGPUCPU && a[i].vendor == ids[d].vendor && a[i].device == ids[d].device) return i;
    return -1;
}

static inline int rune_gpu_by_power(const struct RuneGPUAdapter *a, int count, int high) {
    int best = -1, bestRank = 5;
    for (int i = 0; i < count; i++) {
        int rank = a[i].power;
        if (high && rank <= RuneGPUDiscrete) rank = 1 - rank;
        if (a[i].usable && rank < bestRank) { best = i; bestRank = rank; }
    }
    return best;
}

static inline int rune_gpu_dev_numbers(const void *bytes, size_t size, uint32_t *major, uint32_t *minor) {
    uint64_t dev;
    if (size == sizeof(dev)) memcpy(&dev, bytes, size);
    else if (size == sizeof(uint32_t)) { uint32_t word; memcpy(&word, bytes, size); dev = word; }
    else return 0;
    *major = (uint32_t)(((dev >> 32) & 0xfffff000) | ((dev >> 8) & 0xfff));
    *minor = (uint32_t)(((dev >> 12) & 0xffffff00) | (dev & 0xff));
    return 1;
}

static inline int rune_gpu_hex(unsigned c) {
    c = rune_gpu_lower(c);
    if (c >= '0' && c <= '9') return (int)c - '0';
    if (c >= 'a' && c <= 'f') return (int)c - 'a' + 10;
    return -1;
}

static inline int rune_gpu_pci_link(const char *link, char out[13]) {
    const char *name = strrchr(link, '/');
    name = name ? name + 1 : link;
    if (strlen(name) != 12) return 0;
    for (int i = 0; i < 12; i++) {
        if (i == 4 || i == 7) { if (name[i] != ':') return 0; }
        else if (i == 10) { if (name[i] != '.') return 0; }
        else if (rune_gpu_hex((unsigned char)name[i]) < 0) return 0;
    }
    for (int i = 0; i <= 12; i++) out[i] = (char)rune_gpu_lower((unsigned char)name[i]);
    return 1;
}

static inline int rune_gpu_pci_ids(const char *hardwareID, struct RuneGPUIDs *ids) {
    if (!rune_gpu_prefix(hardwareID, "pci\\")) return 0;
    int flags = 0;
    const char *p = hardwareID + 4;
    while (*p) {
        const char *end = strchr(p, '&');
        if (!end) end = p + strlen(p);
        int flag = rune_gpu_prefix(p, "ven_") ? 1 : rune_gpu_prefix(p, "dev_") ? 2 : 0;
        if (flag && !(flags & flag) && end > p + 4 && end - (p + 4) <= 8) {
            unsigned value = 0;
            const char *digit = p + 4;
            while (digit != end) {
                int h = rune_gpu_hex((unsigned char)*digit);
                if (h < 0) break;
                value = (value << 4) | (unsigned)h; ++digit;
            }
            if (digit == end) { if (flag == 1) ids->vendor = value; else ids->device = value; flags |= flag; }
        }
        p = *end ? end + 1 : end;
    }
    return flags == 3;
}
#endif
