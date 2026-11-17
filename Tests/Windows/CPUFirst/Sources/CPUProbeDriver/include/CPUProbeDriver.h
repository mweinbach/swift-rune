#ifndef RUNE_CPU_PROBE_DRIVER_H
#define RUNE_CPU_PROBE_DRIVER_H
#include <stddef.h>

typedef struct CPUProbePixels {
    // All colors are 0xRRGGBB, or -1 when the specific capture failed.
    int dc;            // top-level HWND GetPixel, after native presentation
    int print;         // PrintWindow for top-level client, including DWM where available
    int print_client;  // WM_PRINTCLIENT retained CPU DIB painted into a new bitmap
    int child_dc;      // GetPixel on WGL/DXGI display child if visible
    int front;         // native default WGL GL_FRONT after the frame was presented
    int back;          // diagnostic only: default WGL GL_BACK after presentation
    int gpu_child_visible;
} CPUProbePixels;

int cpu_probe_launch(const wchar_t *mode);
void cpu_probe_child_entered(void);
int cpu_probe_attach(void);
int cpu_probe_in_paint(void);
int cpu_probe_has_current_wgl(void);
int cpu_probe_gl_loaded(void);
int cpu_probe_click(void);
int cpu_probe_request_paint(void);
int cpu_probe_arm_timer(unsigned milliseconds);
CPUProbePixels cpu_probe_sample(void);

#endif
