#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include "WGLWorker.h"
#include "LazyGL.h"
#include "include/CRuneWin32.h"
#include <stdio.h>
#include <stdlib.h>

static void report_failure(const char *phase, DWORD error, HDC dc, int format) {
    wchar_t enabled[2];
    if (!(GetEnvironmentVariableW(L"RUNE_GPU_INFO", enabled, 2) == 1 && enabled[0] == L'1') &&
        !(GetEnvironmentVariableW(L"RUNE_BOOT_PROFILE", enabled, 2) == 1 && enabled[0] == L'1')) return;
    PIXELFORMATDESCRIPTOR pfd = {0};
    if (dc && !format) format = GetPixelFormat(dc);
    if (format && dc) DescribePixelFormat(dc, format, sizeof(pfd), &pfd);
    fprintf(stderr, "[rune.gpu] wgl_failed=%s win32_error=%lu pixel_format=%d flags=0x%lx color_bits=%u alpha_bits=%u\n",
            phase, error, format, pfd.dwFlags, (unsigned)pfd.cColorBits, (unsigned)pfd.cAlphaBits);
    fflush(stderr);
}

int rune_wgl_vsync(void) {
    typedef BOOL (WINAPI *SwapInterval)(int);
    SwapInterval interval = (SwapInterval)rune_win_gl_proc("wglSwapIntervalEXT");
    return interval && interval(1);
}

const char *rune_wgl_configure(HDC dc, HGLRC *out, int *vsync) {
    double start = rune_win_boot_clock();
    *out = NULL;
    // GDI selects from the installed OpenGL provider's pixel formats. Load it
    // on the GPU path before choosing a format on a previously GDI-only process.
    if (!rune_win_system_gl_export("wglCreateContext")) return "load opengl32!wglCreateContext";
    PIXELFORMATDESCRIPTOR format = {.nSize = sizeof(format), .nVersion = 1,
        .dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER,
        .iPixelType = PFD_TYPE_RGBA, .cColorBits = 32, .cAlphaBits = 8, .iLayerType = PFD_MAIN_PLANE};
    int pixel = dc ? ChoosePixelFormat(dc, &format) : 0;
    if (!pixel) return "ChoosePixelFormat";
    if (!SetPixelFormat(dc, pixel, &format)) return "SetPixelFormat";
    start = rune_win_boot_end("wgl_pixel_format", start);

    HGLRC legacy = rune_lazy_wglCreateContext(dc);
    if (!legacy) return "wglCreateContext";
    HGLRC previous = rune_lazy_wglGetCurrentContext();
    HDC previous_dc = rune_lazy_wglGetCurrentDC();
    const char *failed = "wglMakeCurrent (bootstrap)";
    HGLRC core = NULL;
    if (rune_lazy_wglMakeCurrent(dc, legacy)) {
        start = rune_win_boot_end("wgl_bootstrap_context", start);
        typedef HGLRC (WINAPI *CreateContext)(HDC, HGLRC, const int *);
        CreateContext create = (CreateContext)rune_win_gl_proc("wglCreateContextAttribsARB");
        // WGL_ARB_create_context and WGL_ARB_create_context_profile.
        const int attributes[] = {0x2091, 3, 0x2092, 3, 0x9126, 0x00000001, 0};
        if (create) core = create(dc, NULL, attributes);
        failed = core ? "wglMakeCurrent" : "OpenGL 3.3 core context (WGL_ARB_create_context)";
    }
    if (!core || !rune_lazy_wglMakeCurrent(dc, core)) {
        DWORD error = GetLastError();
        rune_lazy_wglMakeCurrent(previous_dc, previous);
        if (core) rune_lazy_wglDeleteContext(core);
        rune_lazy_wglDeleteContext(legacy);
        SetLastError(error);
        return failed;
    }
    rune_lazy_wglDeleteContext(legacy);
    *out = core;
    start = rune_win_boot_end("wgl_core_context", start);
    if (vsync) {
        *vsync = rune_wgl_vsync();
        rune_win_boot_end("wgl_swap_interval", start);
    }
    return NULL;
}

struct RuneWGLWorker {
    SRWLOCK lock;
    LONG references;
    HWND notify;
    DWORD owner_thread;
    UINT message;
    uint32_t token;
    POINT position;
    HANDLE thread, decision;
    int urgent, state, adopting;
    HGLRC prepared;
    int format;
    void *ctx;
    int32_t (*prepare)(void *);
    void (*release)(void *);
};

static LONG next_token;

static void release_worker(RuneWGLWorker *worker) {
    if (!InterlockedDecrement(&worker->references)) {
        if (worker->thread) CloseHandle(worker->thread);
        CloseHandle(worker->decision);
        free(worker);
    }
}

static HWND worker_window(POINT at) {
    static const wchar_t name[] = L"RuneSwiftWGLBootstrap";
    HINSTANCE instance = GetModuleHandleW(NULL);
    WNDCLASSW wc = {.style = CS_OWNDC, .lpfnWndProc = DefWindowProcW,
                    .hInstance = instance, .lpszClassName = name};
    if (!RegisterClassW(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return NULL;
    return CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, name, L"",
        WS_POPUP | WS_CLIPSIBLINGS | WS_CLIPCHILDREN, at.x, at.y, 1, 1,
        NULL, NULL, instance, NULL);
}

static void wait_for_decision(HANDLE decision) {
    // This thread owns an HWND. Keep servicing sent messages (including system
    // broadcasts) until the owner adopts the renderer or closes its window.
    for (;;) {
        DWORD wake = MsgWaitForMultipleObjectsEx(1, &decision, INFINITE, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        if (wake == WAIT_OBJECT_0) return;
        if (wake != WAIT_OBJECT_0 + 1) {
            WaitForSingleObject(decision, INFINITE);
            return;
        }
        MSG msg;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
            if (msg.message != WM_QUIT) { TranslateMessage(&msg); DispatchMessageW(&msg); }
            if (WaitForSingleObject(decision, 0) == WAIT_OBJECT_0) return;
        }
    }
}

static DWORD WINAPI build_renderer(void *arg) {
    RuneWGLWorker *worker = arg;
    AcquireSRWLockExclusive(&worker->lock);
    if (!worker->urgent) SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
    BOOL active = worker->notify != NULL;
    // New threads normally connect to the process's initial desktop. A host
    // can put its window thread on a different desktop before opening Rune.
    HDESK desktop = active ? GetThreadDesktop(worker->owner_thread) : NULL;
    BOOL connected = desktop && SetThreadDesktop(desktop);
    DWORD error = GetLastError();
    ReleaseSRWLockExclusive(&worker->lock);
    SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    HWND window = connected ? worker_window(worker->position) : NULL;
    if (connected && !window) error = GetLastError();
    HDC dc = window ? GetDC(window) : NULL;
    if (window && !dc) error = GetLastError();
    HGLRC gl = NULL;
    const char *failed = !connected ? "SetThreadDesktop" : !window ? "bootstrap window" : "bootstrap GetDC";
    if (dc) {
        failed = rune_wgl_configure(dc, &gl, NULL);
        error = GetLastError();
    }
    if (!failed) {
        AcquireSRWLockShared(&worker->lock);
        active = worker->notify != NULL;
        ReleaseSRWLockShared(&worker->lock);
        if (active && worker->prepare && !worker->prepare(worker->ctx)) {
            failed = "prepare renderer";
            error = GetLastError();
        }
    }
    int format = dc ? GetPixelFormat(dc) : 0;
    if (!failed && active && (!format || !rune_lazy_wglMakeCurrent(NULL, NULL))) {
        failed = format ? "release worker context" : "GetPixelFormat";
        error = GetLastError();
    }
    if (active && failed) report_failure(failed, error, dc, format);
    BOOL ready = active && !failed;
    AcquireSRWLockExclusive(&worker->lock);
    worker->state = ready ? 1 : -1;
    worker->prepared = ready ? gl : NULL;
    worker->format = format;
    active = worker->notify != NULL;
    if (active) PostMessageW(worker->notify, worker->message, worker->token, 0);
    ReleaseSRWLockExclusive(&worker->lock);

    if (ready) {
        if (active) wait_for_decision(worker->decision);
        AcquireSRWLockExclusive(&worker->lock);
        gl = worker->prepared; // Cleared by a successful adoption.
        worker->prepared = NULL;
        ReleaseSRWLockExclusive(&worker->lock);
        if (gl) rune_lazy_wglMakeCurrent(dc, gl);
    }
    // A cancelled candidate can still own allocated renderer resources. Release
    // the worker's Swift reference before tearing down its current context.
    if (worker->release) worker->release(worker->ctx);
    if (gl) {
        if (rune_lazy_wglGetCurrentContext() == gl) rune_lazy_wglMakeCurrent(NULL, NULL);
        rune_lazy_wglDeleteContext(gl);
    }
    if (dc) ReleaseDC(window, dc);
    if (window) DestroyWindow(window);
    release_worker(worker);
    return 0;
}

RuneWGLWorker *rune_wgl_worker_start(HWND notify, UINT message, int urgent, void *ctx,
                                    int32_t (*prepare)(void *), void (*release)(void *)) {
    RuneWGLWorker *worker = calloc(1, sizeof(*worker));
    if (notify && worker && (worker->decision = CreateEventW(NULL, TRUE, FALSE, NULL))) {
        worker->references = 2;
        worker->notify = notify;
        worker->owner_thread = GetWindowThreadProcessId(notify, NULL);
        worker->message = message;
        worker->token = (uint32_t)InterlockedIncrement(&next_token);
        worker->urgent = urgent;
        worker->ctx = ctx;
        worker->prepare = prepare;
        worker->release = release;
        // Make the private temporary drawable on the presenting monitor so WGL
        // can later rebind the context to a DC on the same device.
        DPI_AWARENESS_CONTEXT previous = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        MONITORINFO info = {.cbSize = sizeof(info)};
        if (GetMonitorInfoW(MonitorFromWindow(notify, MONITOR_DEFAULTTONEAREST), &info)) {
            worker->position.x = info.rcMonitor.left;
            worker->position.y = info.rcMonitor.top;
        }
        if (previous) SetThreadDpiAwarenessContext(previous);
        worker->thread = CreateThread(NULL, 0, build_renderer, worker, 0, NULL);
        if (worker->thread) return worker;
        CloseHandle(worker->decision);
    }
    if (release) release(ctx);
    free(worker);
    return NULL;
}

uint32_t rune_wgl_worker_token(RuneWGLWorker *worker) {
    return worker ? worker->token : 0;
}

int rune_wgl_worker_state(RuneWGLWorker *worker) {
    if (!worker) return -1;
    AcquireSRWLockShared(&worker->lock);
    int state = worker->state;
    ReleaseSRWLockShared(&worker->lock);
    return state;
}

void rune_wgl_worker_raise(RuneWGLWorker *worker) {
    if (!worker) return;
    AcquireSRWLockExclusive(&worker->lock);
    if (!worker->urgent) {
        worker->urgent = 1;
        SetThreadPriority(worker->thread, THREAD_PRIORITY_NORMAL);
    }
    ReleaseSRWLockExclusive(&worker->lock);
}

int rune_wgl_worker_adopt(RuneWGLWorker *worker, HDC drawable, HGLRC *out) {
    if (!worker || !out || !drawable) return 0;
    AcquireSRWLockExclusive(&worker->lock);
    HGLRC gl = worker->prepared;
    int format = worker->format;
    if (!worker->notify || worker->state != 1 || !gl || worker->adopting) {
        ReleaseSRWLockExclusive(&worker->lock);
        return 0;
    }
    worker->adopting = 1;
    InterlockedIncrement(&worker->references);
    ReleaseSRWLockExclusive(&worker->lock);

    HDC previous_dc = rune_lazy_wglGetCurrentDC();
    HGLRC previous = rune_lazy_wglGetCurrentContext();
    int selected = GetPixelFormat(drawable);
    PIXELFORMATDESCRIPTOR pfd;
    BOOL matches = selected ? selected == format :
        DescribePixelFormat(drawable, format, sizeof(pfd), &pfd) && SetPixelFormat(drawable, format, &pfd);
    BOOL current = matches && rune_lazy_wglMakeCurrent(drawable, gl);
    if (!current) report_failure(matches ? "adopt wglMakeCurrent" : "adopt pixel format",
                                 GetLastError(), drawable, selected ? selected : format);
    AcquireSRWLockExclusive(&worker->lock);
    BOOL adopted = current && worker->notify;
    void (*release)(void *) = NULL;
    if (adopted) {
        worker->prepared = NULL;
        // Finish the transfer of the Swift box on the adopting thread with
        // its context current. The worker no longer touches the box.
        release = worker->release;
        worker->release = NULL;
        *out = gl;
    } else {
        worker->state = -1;
    }
    ReleaseSRWLockExclusive(&worker->lock);
    if (!adopted && matches) rune_lazy_wglMakeCurrent(previous_dc, previous);
    if (release) release(worker->ctx);

    AcquireSRWLockExclusive(&worker->lock);
    worker->adopting = 0;
    SetEvent(worker->decision);
    ReleaseSRWLockExclusive(&worker->lock);
    release_worker(worker);
    return adopted;
}

void rune_wgl_worker_close(RuneWGLWorker *worker) {
    if (!worker) return;
    AcquireSRWLockExclusive(&worker->lock);
    worker->notify = NULL;
    if (!worker->adopting) SetEvent(worker->decision);
    ReleaseSRWLockExclusive(&worker->lock);
    release_worker(worker);
}
#endif
