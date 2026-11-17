#if defined(__linux__) && !defined(__ANDROID__)
#define _POSIX_C_SOURCE 200809L
#include "RuneLinuxGPUSelection.h"
#include "RuneGPUSelection.h"
#include <EGL/eglext.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
#include <wayland-client.h>

/* Both tokens are used only after the runtime driver advertises their extension. */
#ifndef EGL_RENDERER_EXT
#define EGL_RENDERER_EXT 0x335F
#endif
#ifndef EGL_DRM_RENDER_NODE_FILE_EXT
#define EGL_DRM_RENDER_NODE_FILE_EXT 0x3377
#endif

/* wayland-scanner private-code for linux-dmabuf-v1, with process-local binding names. */
#define zwp_linux_dmabuf_v1_interface rune_pick_dmabuf
#define zwp_linux_buffer_params_v1_interface rune_pick_params
#define zwp_linux_dmabuf_feedback_v1_interface rune_pick_feedback
#include "LinuxDMABufProtocol.inc"

static int pci_for_dev(const void *bytes, size_t size, char pci[13]) {
    uint32_t major, minor;
    if (!rune_gpu_dev_numbers(bytes, size, &major, &minor)) return 0;
    char path[96], link[PATH_MAX];
    snprintf(path, sizeof path, "/sys/dev/char/%u:%u/device", major, minor);
    ssize_t length = readlink(path, link, sizeof link - 1);
    if (length <= 0) return 0;
    link[length] = 0;
    return rune_gpu_pci_link(link, pci);
}

struct Feedback { struct wl_proxy *manager; int done; char pci[13]; };
static void global(void *data, struct wl_registry *registry, uint32_t name, const char *type, uint32_t version) {
    struct Feedback *f = data;
    if (!f->manager && version >= 4 && !strcmp(type, "zwp_linux_dmabuf_v1"))
        f->manager = wl_registry_bind(registry, name, &rune_pick_dmabuf, version > 5 ? 5 : version);
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}
static const struct wl_registry_listener registry_events = { global, removed };
static int feedback_event(const void *implementation, void *target, uint32_t opcode,
                          const struct wl_message *message, union wl_argument *args) {
    (void)implementation; (void)message;
    struct Feedback *f = wl_proxy_get_user_data(target);
    switch (opcode) {
        case 0: f->done = 1; break;
        case 1: close(args[0].h); break; /* format_table transfers an FD, even when ignored */
        case 2: if (args[0].a) pci_for_dev(args[0].a->data, args[0].a->size, f->pci); break;
    }
    return 0;
}

static pthread_once_t compositor_once = PTHREAD_ONCE_INIT;
static char compositor_pci[13];
static void find_compositor(void) {
    if (!getenv("WAYLAND_DISPLAY")) return;
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) return;
    struct Feedback f = {0};
    struct wl_registry *registry = wl_display_get_registry(display);
    if (registry && wl_registry_add_listener(registry, &registry_events, &f) == 0 &&
        wl_display_roundtrip(display) >= 0 && f.manager) {
        struct wl_proxy *feedback = wl_proxy_marshal_constructor_versioned(
            f.manager, 2 /* get_default_feedback */, &rune_pick_feedback, wl_proxy_get_version(f.manager), NULL);
        if (feedback) {
            wl_proxy_add_dispatcher(feedback, feedback_event, NULL, &f);
            for (int i = 0; !f.done && i < 4; i++) if (wl_display_roundtrip(display) < 0) break;
            memcpy(compositor_pci, f.pci, sizeof f.pci);
            wl_proxy_destroy(feedback);
        }
    }
    if (f.manager) wl_proxy_destroy(f.manager);
    if (registry) wl_registry_destroy(registry);
    wl_display_disconnect(display);
}
static const char *compositor(void) {
    pthread_once(&compositor_once, find_compositor);
    return *compositor_pci ? compositor_pci : NULL;
}

static int extension(const char *list, const char *name) {
    if (!list) return 0;
    size_t len = strlen(name);
    for (const char *p = list; (p = strstr(p, name)); p += len)
        if ((p == list || p[-1] == ' ') && (!p[len] || p[len] == ' ')) return 1;
    return 0;
}

static void device_info(EGLDeviceEXT device, PFNEGLQUERYDEVICESTRINGEXTPROC query, struct RuneGPUAdapter *info, char pci[13]) {
    const char *extensions = query(device, EGL_EXTENSIONS);
    const char *path = NULL;
    if (extension(extensions, "EGL_EXT_device_drm_render_node")) path = query(device, EGL_DRM_RENDER_NODE_FILE_EXT);
    if (!path && extension(extensions, "EGL_EXT_device_drm")) path = query(device, EGL_DRM_DEVICE_FILE_EXT);
    struct stat st;
    if (path && !stat(path, &st)) pci_for_dev(&st.st_rdev, sizeof st.st_rdev, pci);
    *info = (struct RuneGPUAdapter){.pci = pci, .usable = 1, .power = RuneGPUOther};
    if (extension(extensions, "EGL_MESA_device_software")) info->power = RuneGPUCPU;
    if (extension(extensions, "EGL_EXT_device_query_name")) info->name = query(device, EGL_RENDERER_EXT);
}

/* Older Mesa exposes no EGL_RENDERER_EXT on EGLDevice. Only an explicit name
 * request pays for a temporary ES3 context. Restore the caller's API and
 * draw/read surfaces before returning. EGLDisplay is shared process-wide. */
static char *probe_renderer(EGLDisplay d) {
    EGLConfig config;
    EGLint configs = 0;
    const EGLint attrs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_NONE};
    if (d == EGL_NO_DISPLAY || !eglInitialize(d, NULL, NULL) ||
        !eglChooseConfig(d, attrs, &config, 1, &configs) || !configs) return NULL;
    EGLenum old_api = eglQueryAPI();
    EGLDisplay old_display = eglGetCurrentDisplay();
    EGLSurface draw = eglGetCurrentSurface(EGL_DRAW), read = eglGetCurrentSurface(EGL_READ);
    EGLContext old = eglGetCurrentContext();
    if (!eglBindAPI(EGL_OPENGL_ES_API)) return NULL;
    const EGLint version[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    const EGLint size[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    EGLSurface surface = eglCreatePbufferSurface(d, config, size);
    EGLContext context = eglCreateContext(d, config, EGL_NO_CONTEXT, version);
    char *name = NULL;
    if (context != EGL_NO_CONTEXT && surface != EGL_NO_SURFACE && eglMakeCurrent(d, surface, surface, context)) {
        typedef const unsigned char *(*GetString)(unsigned);
        GetString get = (GetString)eglGetProcAddress("glGetString");
        const char *renderer = get ? (const char *)get(0x1f01 /* GL_RENDERER */) : NULL;
        if (renderer) name = strdup(renderer);
        eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }
    if (context != EGL_NO_CONTEXT) eglDestroyContext(d, context);
    if (surface != EGL_NO_SURFACE) eglDestroySurface(d, surface);
    eglBindAPI(old_api);
    if (old != EGL_NO_CONTEXT) eglMakeCurrent(old_display, draw, read, old);
    return name;
}

EGLDisplay rune_gpu_offscreen_display(void) {
    const char *pci = compositor(), *name = getenv("WGPU_ADAPTER_NAME"), *power = getenv("WGPU_POWER_PREF");
    /* With no concrete selector, leave the native default (including DRI_PRIME) intact. */
    if (!pci && !name && !power) return EGL_NO_DISPLAY;
    const char *ext = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);
    if (!extension(ext, "EGL_EXT_platform_device") ||
        !(extension(ext, "EGL_EXT_device_enumeration") || extension(ext, "EGL_EXT_device_base"))) return EGL_NO_DISPLAY;
    PFNEGLQUERYDEVICESEXTPROC enumerate = (PFNEGLQUERYDEVICESEXTPROC)eglGetProcAddress("eglQueryDevicesEXT");
    PFNEGLQUERYDEVICESTRINGEXTPROC query = (PFNEGLQUERYDEVICESTRINGEXTPROC)eglGetProcAddress("eglQueryDeviceStringEXT");
    PFNEGLGETPLATFORMDISPLAYEXTPROC platform = (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    EGLint n = 0;
    if (!enumerate || !query || !platform || !enumerate(0, NULL, &n) || n <= 0) return EGL_NO_DISPLAY;
    EGLDeviceEXT *devices = calloc((size_t)n, sizeof *devices);
    struct RuneGPUAdapter *infos = calloc((size_t)n, sizeof *infos);
    char (*ids)[13] = calloc((size_t)n, sizeof *ids);
    char **probed = calloc((size_t)n, sizeof *probed);
    EGLDisplay result = EGL_NO_DISPLAY;
    if (devices && infos && ids && probed && enumerate(n, devices, &n)) {
        for (int i = 0; i < n; i++) {
            device_info(devices[i], query, &infos[i], ids[i]);
            if (name && !infos[i].name) {
                probed[i] = probe_renderer(platform(EGL_PLATFORM_DEVICE_EXT, devices[i], NULL));
                infos[i].name = probed[i];
                infos[i].usable = probed[i] != NULL;
            }
        }
        int index = rune_gpu_by_name(infos, n, name);
        /* EGL has no portable device power class. Let the WSI choose when two
         * unclassified physical devices would otherwise be guessed from enumeration order. */
        if (index < 0 && power && (!strcmp(power, "high") || !strcmp(power, "low") || !strcmp(power, "none"))) {
            int hardware = 0;
            for (int i = 0; i < n; i++) hardware += infos[i].power != RuneGPUCPU;
            if (hardware <= 1) index = rune_gpu_by_power(infos, n, !strcmp(power, "high"));
        } else if (index < 0) index = rune_gpu_by_pci(infos, n, pci);
        if (index >= 0) {
            EGLDisplay d = platform(EGL_PLATFORM_DEVICE_EXT, devices[index], NULL);
            EGLConfig config;
            EGLint configs = 0;
            const EGLint attrs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                                    EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
            if (d != EGL_NO_DISPLAY && eglInitialize(d, NULL, NULL) &&
                eglChooseConfig(d, attrs, &config, 1, &configs) && configs) result = d;
        }
    }
    if (probed) for (int i = 0; i < n; i++) free(probed[i]);
    free(probed); free(ids); free(infos); free(devices);
    return result;
}

int rune_gpu_wayland_can_show(EGLDisplay display) {
    const char *target = compositor();
    if (!target || display == EGL_NO_DISPLAY) return 1;
    PFNEGLQUERYDISPLAYATTRIBEXTPROC attr = (PFNEGLQUERYDISPLAYATTRIBEXTPROC)eglGetProcAddress("eglQueryDisplayAttribEXT");
    PFNEGLQUERYDEVICESTRINGEXTPROC query = (PFNEGLQUERYDEVICESTRINGEXTPROC)eglGetProcAddress("eglQueryDeviceStringEXT");
    EGLAttrib device = 0;
    if (!attr || !query || !attr(display, EGL_DEVICE_EXT, &device) || !device) return 1;
    struct RuneGPUAdapter info;
    char pci[13] = {0};
    device_info((EGLDeviceEXT)device, query, &info, pci);
    /* A driver without EGL device identity cannot be judged by this extension. */
    if (!*pci && info.power != RuneGPUCPU) return 1;
    return rune_gpu_shows(target, pci);
}
#endif
