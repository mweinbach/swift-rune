#ifndef RUNE_LINUX_GPU_SELECTION_H
#define RUNE_LINUX_GPU_SELECTION_H
#if defined(__linux__) && !defined(__ANDROID__)
#include <EGL/egl.h>
/* An initialized EGL_EXT_platform_device display, or EGL_NO_DISPLAY to use the normal WSI. */
EGLDisplay rune_gpu_offscreen_display(void);
/* A Wayland overlay must not export buffers from another GPU when feedback named its GPU. */
int rune_gpu_wayland_can_show(EGLDisplay display);
#endif
#endif
