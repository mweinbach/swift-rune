#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <gl/GL.h>
#include <stdint.h>
#include <stdio.h>
#include <wchar.h>
#include "CPUProbeDriver.h"

// Observe WGL only after the host has loaded it. Linking opengl32 here would
// itself load the Windows GL runtime for the lifetime of a CPU-only process.
typedef struct {
    HGLRC (APIENTRY *context)(void);
    HDC (APIENTRY *dc)(void);
    PROC (APIENTRY *resolve)(LPCSTR);
    const GLubyte *(APIENTRY *string)(GLenum);
    void (APIENTRY *integer)(GLenum, GLint *);
    void (APIENTRY *store)(GLenum, GLint);
    void (APIENTRY *select)(GLenum);
    void (APIENTRY *read)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, GLvoid *);
} ProbeGL;
static ProbeGL gl;

int cpu_probe_gl_loaded(void) { return GetModuleHandleW(L"opengl32.dll") != NULL; }

static int observe_gl(void) {
    if (gl.context) return 1;
    HMODULE dll = GetModuleHandleW(L"opengl32.dll");
    if (!dll) return 0;
#define RESOLVE(member, name) api.member = (__typeof__(api.member))GetProcAddress(dll, name); if (!api.member) return 0
    ProbeGL api = {0};
    RESOLVE(context, "wglGetCurrentContext");
    RESOLVE(dc, "wglGetCurrentDC");
    RESOLVE(resolve, "wglGetProcAddress");
    RESOLVE(string, "glGetString");
    RESOLVE(integer, "glGetIntegerv");
    RESOLVE(store, "glPixelStorei");
    RESOLVE(select, "glReadBuffer");
    RESOLVE(read, "glReadPixels");
#undef RESOLVE
    gl = api;
    return 1;
}

static HWND window;
static int paint_depth;
static const UINT_PTR redraw_timer = 0x43505550;

static LRESULT CALLBACK observe(HWND hwnd, UINT msg, WPARAM w, LPARAM l, UINT_PTR id, DWORD_PTR data) {
    (void)data;
    if (msg == WM_TIMER && w == redraw_timer) {
        KillTimer(hwnd, redraw_timer);
        InvalidateRect(hwnd, NULL, FALSE);
        return 0;
    }
    if (msg == WM_LBUTTONDOWN || msg == WM_LBUTTONUP || (msg == WM_TIMER && w == redraw_timer)) {
        fprintf(stderr, "[cpu-probe] native input msg=%u hwnd=%p\n", msg, (void*)hwnd);
    }
    if (msg == WM_PAINT) ++paint_depth;
    LRESULT result = DefSubclassProc(hwnd, msg, w, l);
    if (msg == WM_PAINT) --paint_depth;
    if (msg == WM_NCDESTROY) {
        RemoveWindowSubclass(hwnd, observe, id);
        window = NULL;
    }
    return result;
}

static BOOL CALLBACK find_window(HWND hwnd, LPARAM param) {
    (void)param;
    wchar_t name[96];
    if (GetClassNameW(hwnd, name, ARRAYSIZE(name)) && wcscmp(name, L"RuneSwiftOpenGLWindow") == 0) {
        window = hwnd;
        return FALSE;
    }
    return TRUE;
}

int cpu_probe_attach(void) {
    EnumThreadWindows(GetCurrentThreadId(), find_window, 0);
    fprintf(stderr, "[cpu-probe] attached HWND=%p thread=%lu pid=%lu\n", (void*)window, GetCurrentThreadId(), GetCurrentProcessId());
    return window && SetWindowSubclass(window, observe, 1, 0);
}

int cpu_probe_in_paint(void) { return paint_depth > 0; }

static HWND current_wgl_window(void) {
    if (!window || !observe_gl() || !gl.context()) return NULL;
    HWND drawable = WindowFromDC(gl.dc());
    return drawable && (drawable == window || IsChild(window, drawable)) ? drawable : NULL;
}

int cpu_probe_has_current_wgl(void) { return current_wgl_window() != NULL; }

static int client_size(HWND hwnd, RECT *rect) {
    return hwnd && GetClientRect(hwnd, rect) && rect->right > 0 && rect->bottom > 0;
}

int cpu_probe_click(void) {
    RECT rect;
    if (!client_size(window, &rect)) return 0;
    LPARAM point = MAKELPARAM(rect.right / 2, rect.bottom / 2);
    return PostMessageW(window, WM_MOUSEMOVE, 0, point)
        && PostMessageW(window, WM_LBUTTONDOWN, MK_LBUTTON, point)
        && PostMessageW(window, WM_LBUTTONUP, 0, point);
}

int cpu_probe_request_paint(void) { return window && InvalidateRect(window, NULL, FALSE); }

int cpu_probe_arm_timer(unsigned milliseconds) {
    return window && SetTimer(window, redraw_timer, milliseconds, NULL) != 0;
}

static int dc_sample(HWND hwnd) {
    RECT rect;
    if (!client_size(hwnd, &rect)) return -1;
    HDC dc = GetDC(hwnd);
    if (!dc) return -1;
    COLORREF rgb = GetPixel(dc, rect.right / 2, rect.bottom / 2);
    ReleaseDC(hwnd, dc);
    return rgb == CLR_INVALID ? -1 : RGB(GetBValue(rgb), GetGValue(rgb), GetRValue(rgb));
}

static int print_sample(HWND hwnd, int direct_client) {
    RECT rect;
    if (!client_size(hwnd, &rect) || rect.right > 2048 || rect.bottom > 2048) return -1;
    HDC memory = CreateCompatibleDC(NULL);
    if (!memory) return -1;
    BITMAPINFO info = {.bmiHeader = {.biSize = sizeof(BITMAPINFOHEADER), .biWidth = rect.right,
        .biHeight = -rect.bottom, .biPlanes = 1, .biBitCount = 32, .biCompression = BI_RGB}};
    DWORD *bits = NULL;
    HBITMAP bitmap = CreateDIBSection(memory, &info, DIB_RGB_COLORS, (void **)&bits, NULL, 0);
    int sample = -1;
    if (bitmap && bits) {
        HGDIOBJ old = SelectObject(memory, bitmap);
        if (old && old != HGDI_ERROR) {
            DWORD *center = &bits[(rect.bottom / 2) * rect.right + rect.right / 2];
            const DWORD sentinel = 0xfacead1b;
            *center = sentinel;
            BOOL captured = TRUE;
            if (direct_client) SendMessageW(hwnd, WM_PRINTCLIENT, (WPARAM)memory, PRF_CLIENT);
            else captured = PrintWindow(hwnd, memory, PW_CLIENTONLY | PW_RENDERFULLCONTENT);
            GdiFlush();
            if (captured && *center != sentinel) sample = *center & 0x00ffffff;
            SelectObject(memory, old);
        }
        DeleteObject(bitmap);
    }
    DeleteDC(memory);
    return sample;
}

typedef void (APIENTRY *BindObject)(GLenum, GLuint);

static BindObject bind_proc(const char *name) {
    PROC address = gl.resolve(name);
    uintptr_t value = (uintptr_t)address;
    return value > 3 && value != UINTPTR_MAX ? (BindObject)address : NULL;
}

static GLint gl_integer(GLenum what) {
    GLint result = 0;
    gl.integer(what, &result);
    return result;
}

static int gl_color(GLenum source, int x, int y) {
    GLubyte bytes[4] = {0xa5, 0x1d, 0x6a, 0xf2};
    gl.select(source);
    if (gl_integer(GL_READ_BUFFER) != (GLint)source) return -1;
    gl.read(x, y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, bytes);
    if (bytes[0] == 0xa5 && bytes[1] == 0x1d && bytes[2] == 0x6a && bytes[3] == 0xf2) return -1;
    return (bytes[0] << 16) | (bytes[1] << 8) | bytes[2];
}

static void gl_samples(HWND drawable, CPUProbePixels *samples) {
    RECT rect;
    if (!client_size(drawable, &rect)) return;
    BindObject framebuffer = bind_proc("glBindFramebuffer");
    BindObject buffer = bind_proc("glBindBuffer");
    if (!framebuffer || !buffer) return;
    const GLenum read_framebuffer = 0x8ca8, pixel_pack_buffer = 0x88eb;
    GLint old_framebuffer = gl_integer(0x8caa), old_pack_buffer = gl_integer(0x88ed);
    const GLenum pack[] = {GL_PACK_ALIGNMENT, GL_PACK_ROW_LENGTH, GL_PACK_SKIP_ROWS, GL_PACK_SKIP_PIXELS};
    GLint old_pack[ARRAYSIZE(pack)];
    framebuffer(read_framebuffer, 0);
    GLint old_read = gl_integer(GL_READ_BUFFER);
    buffer(pixel_pack_buffer, 0);
    for (unsigned i = 0; i < ARRAYSIZE(pack); ++i) {
        old_pack[i] = gl_integer(pack[i]);
        gl.store(pack[i], i == 0 ? 1 : 0);
    }
    if (gl_integer(0x8caa) == 0 && gl_integer(0x88ed) == 0) {
        int x = rect.right / 2, bottom_y = rect.bottom - 1 - rect.bottom / 2;
        samples->front = gl_color(GL_FRONT, x, bottom_y);
        samples->back = gl_color(GL_BACK, x, bottom_y);
    }
    gl.select((GLenum)old_read);
    for (unsigned i = 0; i < ARRAYSIZE(pack); ++i) gl.store(pack[i], old_pack[i]);
    buffer(pixel_pack_buffer, (GLuint)old_pack_buffer);
    framebuffer(read_framebuffer, (GLuint)old_framebuffer);
}

CPUProbePixels cpu_probe_sample(void) {
    CPUProbePixels samples = {.dc = -1, .print = -1, .print_client = -1, .child_dc = -1, .front = -1, .back = -1};
    if (!window) return samples;
    HWND drawable = current_wgl_window();
    if (drawable) {
        static int logged_wgl;
        if (!logged_wgl++) fprintf(stderr, "[cpu-probe] WGL vendor=%s renderer=%s version=%s\n",
            gl.string(GL_VENDOR), gl.string(GL_RENDERER), gl.string(GL_VERSION));
        gl_samples(drawable, &samples);
    }
    HWND visual = FindWindowExW(window, NULL, L"RuneSwiftDXGIVisual", NULL);
    if (!visual || !IsWindowVisible(visual))
        visual = FindWindowExW(window, NULL, L"RuneSwiftWGLVisual", NULL);
    if (visual && IsWindowVisible(visual)) {
        samples.gpu_child_visible = 1;
        samples.child_dc = dc_sample(visual);
    }
    samples.dc = dc_sample(window);
    samples.print_client = print_sample(window, 1);
    // PrintWindow's DWM capture can block a hidden desktop. A GDI or retained
    // DIB read and a current WGL front buffer can be sampled synchronously.
    if (samples.dc < 0 && samples.print_client < 0 && samples.front < 0 && samples.child_dc < 0)
        samples.print = print_sample(window, 0);
    return samples;
}

void cpu_probe_child_entered(void) {
    wchar_t name[96];
    if (!GetEnvironmentVariableW(L"RUNE_CPU_FIXTURE_ENTERED", name, ARRAYSIZE(name))) return;
    HANDLE event = OpenEventW(EVENT_MODIFY_STATE, FALSE, name);
    if (event) { SetEvent(event); CloseHandle(event); }
}

int cpu_probe_launch(const wchar_t *mode) {
    setvbuf(stderr, NULL, _IONBF, 0);
    fprintf(stderr, "[cpu-probe] launcher pid=%lu mode=%ls\n", GetCurrentProcessId(), mode);
    WCHAR exe[32768], command[32768], name[96];
    DWORD length = GetModuleFileNameW(NULL, exe, ARRAYSIZE(exe));
    if (!length || length >= ARRAYSIZE(exe) || !mode) return 1;
    wchar_t *basename = wcsrchr(exe, L'\\');
    if (!basename || wcscpy_s(basename + 1, ARRAYSIZE(exe) - (size_t)(basename + 1 - exe), L"CPUProbe.exe")) return 1;
    if (swprintf_s(command, ARRAYSIZE(command), L"\"%ls\" --child %ls", exe, mode) < 0) return 1;
    swprintf_s(name, ARRAYSIZE(name), L"RuneCPUFirst-%lu-%llu", GetCurrentProcessId(), GetTickCount64());
    HDESK desktop = CreateDesktopW(name, NULL, NULL, 0, GENERIC_ALL, NULL);
    if (!desktop) return 1;
    wchar_t event_name[96];
    swprintf_s(event_name, ARRAYSIZE(event_name), L"Local\\RuneCPUStart-%lu-%llu", GetCurrentProcessId(), GetTickCount64());
    HANDLE entered = CreateEventW(NULL, TRUE, FALSE, event_name);
    if (!entered || !SetEnvironmentVariableW(L"RUNE_CPU_FIXTURE_ENTERED", event_name)) {
        if (entered) CloseHandle(entered);
        CloseDesktop(desktop); return 1;
    }
    STARTUPINFOW startup = {.cb = sizeof(startup), .lpDesktop = name, .dwFlags = STARTF_USESTDHANDLES,
        .hStdInput = GetStdHandle(STD_INPUT_HANDLE), .hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE),
        .hStdError = GetStdHandle(STD_ERROR_HANDLE)};
    PROCESS_INFORMATION process = {0};
    DWORD code = 1;
    // Run only the fixture on its own unswitched desktop. Its queues receive the click messages directly.
    if (CreateProcessW(exe, command, NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &startup, &process)) {
        fprintf(stderr, "[cpu-probe] desktop=%ls child=%lu parent=%lu\n", name, process.dwProcessId, GetCurrentProcessId());
        DWORD scenario_ms = wcscmp(mode, L"failure") == 0 ? 210000 : 120000;
        HANDLE handles[2] = {process.hProcess, entered};
        DWORD result = WaitForMultipleObjects(2, handles, FALSE, 150000);
        if (result == WAIT_OBJECT_0 + 1) {
            fprintf(stderr, "[cpu-probe] child Swift entry observed mode=%ls\n", mode);
            result = WaitForSingleObject(process.hProcess, scenario_ms);
        }
        if (result == WAIT_OBJECT_0) GetExitCodeProcess(process.hProcess, &code);
        else {
            fprintf(stderr, "Timed out waiting for CPU-first fixture mode=%ls entered=%d\n", mode, WaitForSingleObject(entered, 0) == WAIT_OBJECT_0);
            TerminateProcess(process.hProcess, 1);
            WaitForSingleObject(process.hProcess, 3000);
        }
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
    } else fprintf(stderr, "Could not launch CPU-first fixture: %lu\n", GetLastError());
    SetEnvironmentVariableW(L"RUNE_CPU_FIXTURE_ENTERED", NULL);
    CloseHandle(entered);
    CloseDesktop(desktop);
    return (int)code;
}
