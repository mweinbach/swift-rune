#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include <windows.h>
#include <windowsx.h>
#include <dwmapi.h>
#include <imm.h>
#include <shellapi.h>
#include <GL/gl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "CRuneWin32.h"
#include "Drop.h"
#include "WindowKeyboard.h"

static UINT taskbar_created;
static _Thread_local RuneWinWindow *painting_window;
static INIT_ONCE boot_once = INIT_ONCE_STATIC_INIT;
static LARGE_INTEGER boot_ticks, boot_frequency;
static double boot_offset_ms;

static BOOL CALLBACK init_boot_clock(PINIT_ONCE once, PVOID parameter, PVOID *context) {
    (void)once; (void)parameter; (void)context;
    wchar_t enabled[2];
    if (GetEnvironmentVariableW(L"RUNE_BOOT_PROFILE", enabled, 2) != 1 || enabled[0] != L'1') return TRUE;
    FILETIME creation, exit_time, kernel, user, wall;
    if (!GetProcessTimes(GetCurrentProcess(), &creation, &exit_time, &kernel, &user)) return TRUE;
    GetSystemTimePreciseAsFileTime(&wall);
    QueryPerformanceCounter(&boot_ticks);
    ULARGE_INTEGER start = {.LowPart = creation.dwLowDateTime, .HighPart = creation.dwHighDateTime};
    ULARGE_INTEGER now = {.LowPart = wall.dwLowDateTime, .HighPart = wall.dwHighDateTime};
    if (now.QuadPart >= start.QuadPart) boot_offset_ms = (double)(now.QuadPart - start.QuadPart) / 10000.0;
    QueryPerformanceFrequency(&boot_frequency);
    return TRUE;
}

double rune_win_boot_clock(void) {
    InitOnceExecuteOnce(&boot_once, init_boot_clock, NULL, NULL);
    if (!boot_frequency.QuadPart) return -1;
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    return boot_offset_ms + 1000.0 * (double)(now.QuadPart - boot_ticks.QuadPart) / (double)boot_frequency.QuadPart;
}

double rune_win_boot_end(const char *phase, double start_ms) {
    if (start_ms < 0) return -1;
    double now = rune_win_boot_clock();
    fprintf(stderr, "[rune.boot] phase=%s phase_ms=%.3f process_ms=%.3f\n", phase, now - start_ms, now);
    fflush(stderr);
    return now;
}

static const wchar_t class_name[] = L"RuneSwiftOpenGLWindow";
enum { frame_timer = 1, wake_message = WM_APP + 0x103 };

struct RuneWinWindow {
    HWND hwnd;
    HDC dc;
    HGLRC gl;
    void *context;
    RuneWinDispatch dispatch;
    int32_t min_width, min_height, max_width, max_height;
    int maximize_on_show, fullscreen;
    int click_through;
    LONG_PTR added_input_styles;
    int context_failed, running, tracking_mouse, buttons, visible, composing, translated_key;
    int ime_enabled;
    HCURSOR cursor, custom_cursor;
};

static int emit(RuneWinWindow *w, RuneWinEvent event) {
    return w->dispatch ? w->dispatch(w->context, &event) : 0;
}

static UINT dpi_for(HWND hwnd) {
    UINT dpi = GetDpiForWindow(hwnd);
    return dpi ? dpi : USER_DEFAULT_SCREEN_DPI;
}

static RECT client_to_window(HWND hwnd, int w, int h, UINT dpi) {
    RECT rect = {0, 0, MulDiv(w, dpi, 96), MulDiv(h, dpi, 96)};
    DWORD style = hwnd ? (DWORD)GetWindowLongPtrW(hwnd, GWL_STYLE) : WS_OVERLAPPEDWINDOW;
    DWORD ex_style = hwnd ? (DWORD)GetWindowLongPtrW(hwnd, GWL_EXSTYLE) : 0;
    AdjustWindowRectExForDpi(&rect, style, hwnd && GetMenu(hwnd), ex_style, dpi);
    return rect;
}

static void resize_event(RuneWinWindow *w) {
    DPI_AWARENESS_CONTEXT previous = SetThreadDpiAwarenessContext(GetWindowDpiAwarenessContext(w->hwnd));
    RECT rect;
    if (GetClientRect(w->hwnd, &rect) && rect.right > 0 && rect.bottom > 0) {
        emit(w, (RuneWinEvent){.kind = RUNE_WIN_SIZE, .dpi = dpi_for(w->hwnd),
                               .x = rect.right, .y = rect.bottom});
    }
    if (previous) SetThreadDpiAwarenessContext(previous);
}

int rune_win_drop_event(RuneWinWindow *w, RuneWinEventKind kind, void *files, int32_t x, int32_t y) {
    HDROP drop = (HDROP)files;
    UINT count = drop ? DragQueryFileW(drop, 0xffffffff, NULL, 0) : 0;
    if (drop && !count) return 0;
    for (UINT i = 0; i < count; ++i) {
        UINT length = DragQueryFileW(drop, i, NULL, 0);
        wchar_t *path = calloc((size_t)length + 1, sizeof(*path));
        if (path && DragQueryFileW(drop, i, path, length + 1)) {
            emit(w, (RuneWinEvent){.kind = RUNE_WIN_DROP_FILE, .text = (uint16_t *)path, .length = length});
        }
        free(path);
    }
    int accepted = emit(w, (RuneWinEvent){.kind = kind, .x = x, .y = y});
    InvalidateRect(w->hwnd, NULL, FALSE);
    return accepted != 0;
}

static int ime_text(RuneWinWindow *w, HIMC imc, DWORD flag) {
    LONG bytes = ImmGetCompositionStringW(imc, flag, NULL, 0);
    if (bytes < 0) return 0;
    uint16_t *text = bytes ? malloc((size_t)bytes) : NULL;
    if (bytes && (!text || ImmGetCompositionStringW(imc, flag, text, bytes) != bytes)) {
        free(text);
        return 0;
    }
    int is_preedit = flag == GCS_COMPSTR;
    LONG cursor = is_preedit ? ImmGetCompositionStringW(imc, GCS_CURSORPOS, NULL, 0) : 0;
    int handled = emit(w, (RuneWinEvent){.kind = is_preedit ? RUNE_WIN_IME_PREEDIT : RUNE_WIN_IME_COMMIT,
                       .text = text, .length = (uint32_t)bytes / 2, .x = cursor});
    w->composing = is_preedit && handled;
    free(text);
    return handled;
}

static void visibility(RuneWinWindow *w, HWND hwnd) {
    int visible = IsWindowVisible(hwnd) && !IsIconic(hwnd);
    if (w->visible != visible) {
        w->visible = visible;
        emit(w, (RuneWinEvent){.kind = RUNE_WIN_VISIBILITY, .value = (uint32_t)visible});
    }
}

static LRESULT CALLBACK window_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    RuneWinWindow *w = (RuneWinWindow *)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (msg == WM_NCCREATE) {
        w = ((CREATESTRUCTW *)lp)->lpCreateParams;
        w->hwnd = hwnd;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)w);
    }
    if (!w) return DefWindowProcW(hwnd, msg, wp, lp);

    if (taskbar_created && msg == taskbar_created) {
        emit(w, (RuneWinEvent){.kind = RUNE_WIN_TASKBAR_CREATED});
        return 0;
    }
    switch (msg) {
    case WM_NCDESTROY:
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
        w->hwnd = NULL;
        return DefWindowProcW(hwnd, msg, wp, lp);
    case WM_GETMINMAXINFO: {
        RECT rect = client_to_window(hwnd, w->min_width, w->min_height, dpi_for(hwnd));
        MINMAXINFO *info = (MINMAXINFO *)lp;
        if (w->min_width > 0) info->ptMinTrackSize.x = rect.right - rect.left;
        if (w->min_height > 0) info->ptMinTrackSize.y = rect.bottom - rect.top;
        if (w->max_width > 0 || w->max_height > 0) {
            RECT maximum = client_to_window(hwnd, w->max_width, w->max_height, dpi_for(hwnd));
            if (w->max_width > 0) info->ptMaxTrackSize.x = maximum.right - maximum.left;
            if (w->max_height > 0) info->ptMaxTrackSize.y = maximum.bottom - maximum.top;
        }
        return 0;
    }
    case WM_DPICHANGED: {
        const RECT *r = (const RECT *)lp;
        SetWindowPos(hwnd, NULL, r->left, r->top, r->right-r->left, r->bottom-r->top,
                     SWP_NOZORDER | SWP_NOACTIVATE);
        resize_event(w);
        InvalidateRect(hwnd, NULL, FALSE);
        return 0;
    }
    case WM_SIZE:
        resize_event(w);
        visibility(w, hwnd);
        InvalidateRect(hwnd, NULL, FALSE);
        return 0;
    case WM_WINDOWPOSCHANGED: {
        LRESULT result = DefWindowProcW(hwnd, msg, wp, lp);
        visibility(w, hwnd);
        return result;
    }
    case WM_SETCURSOR:
        if (LOWORD(lp) == HTCLIENT) {
            SetCursor(w->cursor);
            return TRUE;
        }
        break;
    case WM_ERASEBKGND: return 1;
    case WM_PAINT: {
        PAINTSTRUCT paint;
        BeginPaint(hwnd, &paint);
        EndPaint(hwnd, &paint);
        if (w->dispatch && w->running && !IsIconic(hwnd)) {
            KillTimer(hwnd, frame_timer);
            // Modal UI can synchronously repaint a sibling during a frame callback.
            RuneWinWindow *outer = painting_window;
            HDC previous_dc = outer ? wglGetCurrentDC() : NULL;
            HGLRC previous_gl = outer ? wglGetCurrentContext() : NULL;
            painting_window = w;
            if (!rune_win_make_current(w)) w->context_failed = 1;
            int next = w->context_failed ? -2 : emit(w, (RuneWinEvent){.kind = RUNE_WIN_FRAME});
            painting_window = outer;
            if (outer && (wglGetCurrentContext() != previous_gl || wglGetCurrentDC() != previous_dc) &&
                !wglMakeCurrent(previous_dc, previous_gl)) {
                wglMakeCurrent(NULL, NULL);
                outer->context_failed = 1;
            }
            if (w->context_failed || next == -2) {
                w->running = 0;
                PostMessageW(hwnd, WM_NULL, 0, 0);
            } else if (next >= 0) {
                SetTimer(hwnd, frame_timer, (UINT)next, NULL);
            }
        }
        return 0;
    }
    case WM_TIMER:
        if (wp != frame_timer) break;
        KillTimer(hwnd, frame_timer);
        InvalidateRect(hwnd, NULL, FALSE);
        return 0;
    case wake_message:
        emit(w, (RuneWinEvent){.kind = RUNE_WIN_WAKE});
        if (!IsIconic(hwnd) && IsWindowVisible(hwnd)) InvalidateRect(hwnd, NULL, FALSE);
        return 0;
    case WM_CLOSE:
        if (!w->dispatch || emit(w, (RuneWinEvent){.kind = RUNE_WIN_CLOSE})) {
            w->running = 0;
            PostMessageW(hwnd, WM_NULL, 0, 0);
        } else {
            InvalidateRect(hwnd, NULL, FALSE);
        }
        return 0;
    case WM_SETTINGCHANGE: case WM_SYSCOLORCHANGE: case WM_THEMECHANGED: case WM_DWMCOLORIZATIONCOLORCHANGED:
        emit(w, (RuneWinEvent){.kind = RUNE_WIN_SETTINGS});
        InvalidateRect(hwnd, NULL, FALSE);
        break;
    case WM_SETFOCUS:
    case WM_KILLFOCUS:
        emit(w, (RuneWinEvent){.kind = RUNE_WIN_FOCUS, .value = msg == WM_SETFOCUS});
        InvalidateRect(hwnd, NULL, FALSE);
        break;
    case WM_MOUSEMOVE: {
        if (!w->tracking_mouse) {
            TRACKMOUSEEVENT track = {sizeof(track), TME_LEAVE, hwnd, 0};
            w->tracking_mouse = TrackMouseEvent(&track);
        }
        emit(w, (RuneWinEvent){.kind = RUNE_WIN_MOVE, .x = GET_X_LPARAM(lp), .y = GET_Y_LPARAM(lp), .mods = modifiers()});
        InvalidateRect(hwnd, NULL, FALSE);
        return 0;
    }
    case WM_MOUSELEAVE:
        w->tracking_mouse = 0;
        emit(w, (RuneWinEvent){.kind = RUNE_WIN_LEAVE});
        InvalidateRect(hwnd, NULL, FALSE);
        return 0;
    case WM_LBUTTONDOWN: case WM_LBUTTONUP: case WM_RBUTTONDOWN: case WM_RBUTTONUP:
    case WM_MBUTTONDOWN: case WM_MBUTTONUP: case WM_XBUTTONDOWN: case WM_XBUTTONUP: {
        int down = msg == WM_LBUTTONDOWN || msg == WM_RBUTTONDOWN || msg == WM_MBUTTONDOWN || msg == WM_XBUTTONDOWN;
        int extra = msg == WM_XBUTTONDOWN || msg == WM_XBUTTONUP;
        uint32_t button = extra ? (GET_XBUTTON_WPARAM(wp) == XBUTTON1 ? 3 : 4) :
                          msg == WM_MBUTTONDOWN || msg == WM_MBUTTONUP ? 2 :
                          msg == WM_RBUTTONDOWN || msg == WM_RBUTTONUP ? 1 : 0;
        if (down) {
            SetFocus(hwnd);
            SetCapture(hwnd);
            w->buttons |= 1 << button;
        }
        emit(w, (RuneWinEvent){.kind = down ? RUNE_WIN_DOWN : RUNE_WIN_UP, .value = button,
                               .x = GET_X_LPARAM(lp), .y = GET_Y_LPARAM(lp), .mods = modifiers()});
        if (!down) {
            w->buttons &= ~(1 << button);
            if (!w->buttons && GetCapture() == hwnd) ReleaseCapture();
        }
        InvalidateRect(hwnd, NULL, FALSE);
        return extra ? TRUE : 0;
    }
    case WM_CAPTURECHANGED: case WM_CANCELMODE:
        if (w->buttons) {
            w->buttons = 0;
            emit(w, (RuneWinEvent){.kind = RUNE_WIN_CAPTURE_LOST});
            InvalidateRect(hwnd, NULL, FALSE);
        }
        break;
    case WM_MOUSEWHEEL: case WM_MOUSEHWHEEL: {
        POINT p = {GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
        ScreenToClient(hwnd, &p);
        int horizontal = msg == WM_MOUSEHWHEEL;
        UINT count = horizontal ? 1 : 3;
        SystemParametersInfoW(horizontal ? SPI_GETWHEELSCROLLCHARS : SPI_GETWHEELSCROLLLINES, 0, &count, 0);
        float ticks = (float)GET_WHEEL_DELTA_WPARAM(wp) / WHEEL_DELTA;
        emit(w, (RuneWinEvent){.kind = RUNE_WIN_WHEEL, .x = p.x, .y = p.y, .horizontal = horizontal,
                               .ticks = horizontal ? -ticks : ticks, .count = count, .mods = modifiers()});
        InvalidateRect(hwnd, NULL, FALSE);
        return 0;
    }
    case WM_KEYDOWN: case WM_SYSKEYDOWN: case WM_KEYUP: case WM_SYSKEYUP: {
        int down = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN;
        UINT scan = (lp >> 16) & 0xff;
        UINT extended = (lp >> 24) & 1;
        UINT vk = (UINT)wp;
        if (vk == VK_SHIFT) vk = MapVirtualKeyW(scan, MAPVK_VSC_TO_VK_EX);
        if (vk == VK_CONTROL) vk = extended ? VK_RCONTROL : VK_LCONTROL;
        if (vk == VK_MENU) vk = extended ? VK_RMENU : VK_LMENU;
        HKL layout = GetKeyboardLayout(0);
        int taken = emit(w, (RuneWinEvent){.kind = down ? RUNE_WIN_KEY_DOWN : RUNE_WIN_KEY_UP,
                          .value = vk, .scan = scan | (extended << 8), .mods = modifiers(),
                          .layout_char = MapVirtualKeyExW(vk, MAPVK_VK_TO_CHAR, layout),
                          .shortcut_char = down ? shortcut_character(vk, scan, layout) : 0,
                          .repeated = down && (((uintptr_t)lp >> 30) & 1)});
        InvalidateRect(hwnd, NULL, FALSE);
        if (taken) {
            if (down) w->translated_key = 1;
            return 0;
        }
        break;
    }
    case WM_CHAR:
    case WM_SYSCHAR: {
        int taken = emit(w, (RuneWinEvent){.kind = RUNE_WIN_CHAR, .value = (uint16_t)wp,
                         .scan = ((uintptr_t)lp >> 16) & 0x1ff, .mods = modifiers(),
                         .repeated = (int)(((uintptr_t)lp >> 30) & 1)});
        InvalidateRect(hwnd, NULL, FALSE);
        if (taken || msg == WM_CHAR) return 0;
        break;
    }
    case WM_IME_COMPOSITION: {
        HIMC imc = ImmGetContext(hwnd);
        if (!imc) break;
        int taken = 0;
        if (lp & GCS_RESULTSTR) taken |= ime_text(w, imc, GCS_RESULTSTR);
        if (lp & GCS_COMPSTR) taken |= ime_text(w, imc, GCS_COMPSTR);
        ImmReleaseContext(hwnd, imc);
        InvalidateRect(hwnd, NULL, FALSE);
        if (taken) return 0;
        break;
    }
    case WM_IME_ENDCOMPOSITION:
        if (w->composing) {
            emit(w, (RuneWinEvent){.kind = RUNE_WIN_IME_PREEDIT});
            w->composing = 0;
            InvalidateRect(hwnd, NULL, FALSE);
        }
        break;
    case WM_DROPFILES: {
        POINT p = {0};
        HDROP drop = (HDROP)wp;
        DragQueryPoint(drop, &p);
        rune_win_drop_event(w, RUNE_WIN_DROP_END, drop, p.x, p.y);
        DragFinish(drop);
        return 0;
    }
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

void *rune_win_gl_proc(const char *name) {
    PROC p = wglGetProcAddress(name);
    if (!p || (uintptr_t)p <= 3 || (uintptr_t)p == UINTPTR_MAX)
        p = GetProcAddress(GetModuleHandleW(L"opengl32.dll"), name);
    return (void *)p;
}

static const char *configure_gl(RuneWinWindow *w) {
    double start = rune_win_boot_clock();
    PIXELFORMATDESCRIPTOR format = {.nSize = sizeof(format), .nVersion = 1,
        .dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER,
        .iPixelType = PFD_TYPE_RGBA, .cColorBits = 32, .cAlphaBits = 8, .iLayerType = PFD_MAIN_PLANE};
    w->dc = GetDC(w->hwnd);
    int pixel = ChoosePixelFormat(w->dc, &format);
    if (!pixel || !SetPixelFormat(w->dc, pixel, &format)) return "SetPixelFormat";
    start = rune_win_boot_end("wgl_pixel_format", start);
    HGLRC legacy = wglCreateContext(w->dc);
    if (!legacy) return "wglCreateContext";
    if (!wglMakeCurrent(w->dc, legacy)) {
        wglDeleteContext(legacy);
        return "wglMakeCurrent (bootstrap)";
    }
    start = rune_win_boot_end("wgl_bootstrap_context", start);
    typedef HGLRC (WINAPI *CreateContext)(HDC, HGLRC, const int *);
    CreateContext create = (CreateContext)rune_win_gl_proc("wglCreateContextAttribsARB");
    // WGL_ARB_create_context and WGL_ARB_create_context_profile attribute values.
    const int attributes[] = {0x2091, 3, 0x2092, 3, 0x9126, 0x00000001, 0};
    if (create) w->gl = create(w->dc, NULL, attributes);
    wglMakeCurrent(NULL, NULL);
    wglDeleteContext(legacy);
    if (!w->gl) return "OpenGL 3.3 core context (WGL_ARB_create_context)";
    if (!wglMakeCurrent(w->dc, w->gl)) return "wglMakeCurrent";
    start = rune_win_boot_end("wgl_core_context", start);
    typedef BOOL (WINAPI *SwapInterval)(int);
    SwapInterval interval = (SwapInterval)rune_win_gl_proc("wglSwapIntervalEXT");
    if (interval) interval(1);
    rune_win_boot_end("wgl_swap_interval", start);
    return NULL;
}

RuneWinWindow *rune_win_create(const uint16_t *title, int32_t width, int32_t height,
                               int32_t min_width, int32_t min_height, int32_t dark,
                               char *error, int32_t error_capacity) {
    double start = rune_win_boot_clock();
    RuneWinWindow *w = calloc(1, sizeof(*w));
    const char *failed = "window allocation";
    DPI_AWARENESS_CONTEXT previous_dpi = NULL;
    if (!w) goto fail;
    if (!taskbar_created) taskbar_created = RegisterWindowMessageW(L"TaskbarButtonCreated");
    w->min_width = min_width;
    w->min_height = min_height;
    previous_dpi = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    // The WGL context holds its GetDC handle until teardown. A common DC also
    // permits WS_EX_LAYERED when this window later needs to pass pointer input through.
    WNDCLASSEXW cls = {.cbSize = sizeof(cls), .style = CS_HREDRAW | CS_VREDRAW,
        .lpfnWndProc = window_proc, .hInstance = GetModuleHandleW(NULL),
        .hCursor = LoadCursorW(NULL, IDC_ARROW), .lpszClassName = class_name};
    if (!RegisterClassExW(&cls) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        failed = "RegisterClassExW";
        goto fail;
    }
    UINT dpi = GetDpiForSystem();
    RECT rect = client_to_window(w->hwnd, width, height, dpi);
    if (!CreateWindowExW(0, class_name, (const wchar_t *)title, WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT, CW_USEDEFAULT, rect.right-rect.left, rect.bottom-rect.top,
            NULL, NULL, cls.hInstance, w)) {
        failed = "CreateWindowExW";
        goto fail;
    }
    if (dpi_for(w->hwnd) != dpi) {
        rect = client_to_window(w->hwnd, width, height, dpi_for(w->hwnd));
        SetWindowPos(w->hwnd, NULL, 0, 0, rect.right-rect.left, rect.bottom-rect.top,
                     SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    }
    w->cursor = LoadCursorW(NULL, IDC_ARROW);
    w->ime_enabled = 1;
    rune_win_dark_title(w, dark);
    DragAcceptFiles(w->hwnd, TRUE);
    rune_win_boot_end("native_window", start);
    failed = configure_gl(w);
    if (!failed) {
        if (previous_dpi) SetThreadDpiAwarenessContext(previous_dpi);
        return w;
    }
fail:
    if (error && error_capacity > 0)
        snprintf(error, (size_t)error_capacity, "%s failed (Win32 error %lu)", failed, (unsigned long)GetLastError());
    rune_win_destroy(w);
    if (previous_dpi) SetThreadDpiAwarenessContext(previous_dpi);
    return NULL;
}

int32_t rune_win_make_current(RuneWinWindow *w) {
    return wglGetCurrentContext() == w->gl || wglMakeCurrent(w->dc, w->gl);
}

int32_t rune_win_running(RuneWinWindow *w) { return w->context_failed ? -1 : w->running; }
uint32_t rune_win_thread(void) { return GetCurrentThreadId(); }
void rune_win_wake_thread(uint32_t thread) { PostThreadMessageW(thread, WM_NULL, 0, 0); }

void rune_win_configure(RuneWinWindow *w, RuneWinOptions options) {
    DPI_AWARENESS_CONTEXT previous = SetThreadDpiAwarenessContext(GetWindowDpiAwarenessContext(w->hwnd));
    RECT client, outer;
    GetClientRect(w->hwnd, &client);
    GetWindowRect(w->hwnd, &outer);
    w->max_width = options.max_width;
    w->max_height = options.max_height;
    w->fullscreen = options.fullscreen;
    DWORD style = options.borderless || options.fullscreen ? WS_POPUP : WS_OVERLAPPEDWINDOW;
    if (!options.resizable) style &= ~(WS_THICKFRAME | WS_MAXIMIZEBOX);
    if (!options.minimizable) style &= ~WS_MINIMIZEBOX;
    SetWindowLongPtrW(w->hwnd, GWL_STYLE, style);
    if (!options.closable) EnableMenuItem(GetSystemMenu(w->hwnd, FALSE), SC_CLOSE, MF_GRAYED | MF_BYCOMMAND);
    if (options.fullscreen) {
        MONITORINFO monitor = {.cbSize = sizeof(monitor)};
        if (GetMonitorInfoW(MonitorFromWindow(w->hwnd, MONITOR_DEFAULTTONEAREST), &monitor)) outer = monitor.rcMonitor;
    } else {
        // Preserve the requested physical client area when frame decorations change.
        AdjustWindowRectExForDpi(&client, style, GetMenu(w->hwnd) != NULL,
                                 (DWORD)GetWindowLongPtrW(w->hwnd, GWL_EXSTYLE), dpi_for(w->hwnd));
        outer.right = outer.left + client.right - client.left;
        outer.bottom = outer.top + client.bottom - client.top;
    }
    SetWindowPos(w->hwnd, NULL, outer.left, outer.top, outer.right - outer.left, outer.bottom - outer.top,
                 SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    w->maximize_on_show = options.maximized && !options.fullscreen;
    if (previous) SetThreadDpiAwarenessContext(previous);
}

void rune_win_start(RuneWinWindow *w, void *context, RuneWinDispatch dispatch, int32_t inactive, int32_t visible) {
    w->context = context;
    w->dispatch = dispatch;
    w->running = 1;
    resize_event(w);
    if (visible && w->maximize_on_show && inactive) {
        WINDOWPLACEMENT p = {.length = sizeof(p)};
        if (GetWindowPlacement(w->hwnd, &p)) {
            p.flags = WPF_ASYNCWINDOWPLACEMENT;
            p.showCmd = SW_SHOWMAXIMIZED;
            // Preserve open-inactive process launches even when the app asks to maximize.
            LONG_PTR ext = GetWindowLongPtrW(w->hwnd, GWL_EXSTYLE);
            SetWindowLongPtrW(w->hwnd, GWL_EXSTYLE, ext | WS_EX_NOACTIVATE);
            SetWindowPlacement(w->hwnd, &p);
            SetWindowLongPtrW(w->hwnd, GWL_EXSTYLE, ext);
        }
    } else if (visible) {
        ShowWindow(w->hwnd, w->maximize_on_show ? SW_SHOWMAXIMIZED : inactive ? SW_SHOWNOACTIVATE : SW_SHOW);
    }
    emit(w, (RuneWinEvent){.kind = RUNE_WIN_FOCUS, .value = GetFocus() == w->hwnd});
    UpdateWindow(w->hwnd);
}

int32_t rune_win_pump_or_idle(int32_t idle_work_owed) {
    MSG msg;
    if (idle_work_owed) {
        if (!PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) return RUNE_WIN_PUMP_IDLE;
        if (msg.message == WM_QUIT) return 0;
    } else {
        int result = GetMessageW(&msg, NULL, 0, 0);
        if (result <= 0) return result;
    }
    if (msg.hwnd && (msg.message == WM_KEYDOWN || msg.message == WM_SYSKEYDOWN) &&
        GetClassLongPtrW(msg.hwnd, GCLP_WNDPROC) == (ULONG_PTR)window_proc) {
        RuneWinWindow *w = (RuneWinWindow *)GetWindowLongPtrW(msg.hwnd, GWLP_USERDATA);
        if (w) {
            w->translated_key = 0;
            DispatchMessageW(&msg);
            if (!w->translated_key) TranslateMessage(&msg);
            return 1;
        }
    }
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
    return 1;
}

int32_t rune_win_pump(void) { return rune_win_pump_or_idle(0); }

int32_t rune_win_run(RuneWinWindow *w, void *context, RuneWinDispatch dispatch, int32_t inactive) {
    rune_win_start(w, context, dispatch, inactive, 1);
    int result = 1;
    while (w->running && result > 0) result = rune_win_pump();
    w->dispatch = NULL;
    return result < 0 || w->context_failed ? -1 : 0;
}

void rune_win_request_close(RuneWinWindow *w) { PostMessageW(w->hwnd, WM_CLOSE, 0, 0); }
void rune_win_topmost(RuneWinWindow *w, int32_t on) {
    SetWindowPos(w->hwnd, on ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}
void rune_win_center(RuneWinWindow *w) {
    DPI_AWARENESS_CONTEXT previous = SetThreadDpiAwarenessContext(GetWindowDpiAwarenessContext(w->hwnd));
    RECT r;
    MONITORINFO monitor = {.cbSize = sizeof(monitor)};
    if (GetWindowRect(w->hwnd, &r) &&
        GetMonitorInfoW(MonitorFromWindow(w->hwnd, MONITOR_DEFAULTTONEAREST), &monitor))
        SetWindowPos(w->hwnd, NULL, (monitor.rcWork.left + monitor.rcWork.right - (r.right-r.left))/2,
                     (monitor.rcWork.top + monitor.rcWork.bottom - (r.bottom-r.top))/2,
                     0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    if (previous) SetThreadDpiAwarenessContext(previous);
}
void rune_win_flash(RuneWinWindow *w, int32_t on) {
    FLASHWINFO info = {sizeof(info), w->hwnd, on ? FLASHW_TRAY | FLASHW_TIMERNOFG : FLASHW_STOP, 0, 0};
    FlashWindowEx(&info);
}
void *rune_win_hwnd(RuneWinWindow *w) { return w->hwnd; }
void rune_win_exit(RuneWinWindow *w) {
    w->running = 0;
    // Another window on this UI thread can be running User32's modal menu loop.
    EndMenu();
    PostMessageW(w->hwnd, WM_NULL, 0, 0);
}
int32_t rune_win_swap(RuneWinWindow *w) { return SwapBuffers(w->dc); }
void rune_win_wake(RuneWinWindow *w) { PostMessageW(w->hwnd, wake_message, 0, 0); }
void rune_win_dark_title(RuneWinWindow *w, int32_t dark) {
    BOOL dark_value = dark != 0;
    DwmSetWindowAttribute(w->hwnd, 20, &dark_value, sizeof(dark_value));
}
void rune_win_set_title(RuneWinWindow *w, const uint16_t *title) { SetWindowTextW(w->hwnd, (const wchar_t *)title); }
void rune_win_show(RuneWinWindow *w, int32_t show) { ShowWindow(w->hwnd, show ? SW_SHOWNOACTIVATE : SW_HIDE); }
void rune_win_minimize(RuneWinWindow *w) { ShowWindow(w->hwnd, SW_MINIMIZE); }
void rune_win_focus(RuneWinWindow *w) { SetForegroundWindow(w->hwnd); SetFocus(w->hwnd); }

void rune_win_place(RuneWinWindow *w, int32_t move, int32_t x, int32_t y,
                    int32_t resize, int32_t width, int32_t height) {
    DPI_AWARENESS_CONTEXT previous = SetThreadDpiAwarenessContext(GetWindowDpiAwarenessContext(w->hwnd));
    UINT dpi = dpi_for(w->hwnd);
    RECT rect = client_to_window(w->hwnd, width, height, dpi);
    SetWindowPos(w->hwnd, NULL, x, y,
                 rect.right-rect.left, rect.bottom-rect.top, SWP_NOZORDER | SWP_NOACTIVATE |
                 (move ? 0 : SWP_NOMOVE) | (resize ? 0 : SWP_NOSIZE));
    if (previous) SetThreadDpiAwarenessContext(previous);
}

static void read_restore_frame(HWND hwnd, UINT dpi, RuneWinPlacement *out) {
    WINDOWPLACEMENT placement = {.length = sizeof(placement)};
    if (!GetWindowPlacement(hwnd, &placement)) return;
    RECT normal = placement.rcNormalPosition;
    LONG_PTR ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
    if (!(ex & WS_EX_TOOLWINDOW)) {
        // GetWindowPlacement uses workspace coordinates for ordinary top-level windows.
        MONITORINFO monitor = {.cbSize = sizeof(monitor)};
        if (!GetMonitorInfoW(MonitorFromRect(&normal, MONITOR_DEFAULTTONEAREST), &monitor)) return;
        OffsetRect(&normal, monitor.rcWork.left - monitor.rcMonitor.left, monitor.rcWork.top - monitor.rcMonitor.top);
    }
    RECT borders = {0};
    DWORD style = (DWORD)GetWindowLongPtrW(hwnd, GWL_STYLE) & ~(WS_MAXIMIZE | WS_MINIMIZE);
    if (!AdjustWindowRectExForDpi(&borders, style, GetMenu(hwnd) != NULL, (DWORD)ex, dpi)) return;
    LONG width = normal.right - normal.left - (borders.right - borders.left);
    LONG height = normal.bottom - normal.top - (borders.bottom - borders.top);
    out->restore_x = normal.left;
    out->restore_y = normal.top;
    out->restore_width = (uint32_t)(width > 0 ? width : 1);
    out->restore_height = (uint32_t)(height > 0 ? height : 1);
    out->has_restore = 1;
}

int rune_win_placement(RuneWinWindow *w, RuneWinPlacement *out) {
    if (!w || !w->hwnd || !out) return 0;
    HWND hwnd = w->hwnd;
    DPI_AWARENESS_CONTEXT previous = SetThreadDpiAwarenessContext(GetWindowDpiAwarenessContext(hwnd));
    RECT outer, client;
    POINT origin = {0};
    int success = GetWindowRect(hwnd, &outer) && GetClientRect(hwnd, &client) && ClientToScreen(hwnd, &origin);
    if (success) {
        UINT dpi = dpi_for(hwnd);
        *out = (RuneWinPlacement){
            .x = outer.left, .y = outer.top, .content_x = origin.x, .content_y = origin.y,
            .width = (uint32_t)(client.right - client.left), .height = (uint32_t)(client.bottom - client.top),
            .scale = dpi / 96.0, .visible = IsWindowVisible(hwnd) && !IsIconic(hwnd),
            .maximized = IsZoomed(hwnd) != 0, .minimized = IsIconic(hwnd) != 0, .fullscreen = w->fullscreen
        };
        HMONITOR display = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        MONITORINFO info = {.cbSize = sizeof(info)};
        if (display && GetMonitorInfoW(display, &info)) {
            out->display = (uint64_t)(uintptr_t)display;
            out->display_x = info.rcMonitor.left;
            out->display_y = info.rcMonitor.top;
            out->display_width = (uint32_t)(info.rcMonitor.right - info.rcMonitor.left);
            out->display_height = (uint32_t)(info.rcMonitor.bottom - info.rcMonitor.top);
        }
        if (!out->fullscreen && (out->maximized || out->minimized)) read_restore_frame(hwnd, dpi, out);
    }
    if (previous) SetThreadDpiAwarenessContext(previous);
    return success;
}

int rune_win_click_through(RuneWinWindow *w, int on) {
    if (!w || !w->hwnd) return 0;
    on = on != 0;
    if (w->click_through == on) return 1;
    const LONG_PTR input_styles = WS_EX_TRANSPARENT | WS_EX_LAYERED;
    HWND hwnd = w->hwnd;
    SetLastError(ERROR_SUCCESS);
    LONG_PTR old = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
    if (!old && GetLastError() != ERROR_SUCCESS) return 0;
    LONG_PTR style = on ? old | input_styles : old & ~w->added_input_styles;
    SetLastError(ERROR_SUCCESS);
    if (!SetWindowLongPtrW(hwnd, GWL_EXSTYLE, style) && GetLastError() != ERROR_SUCCESS) return 0;
    if (on && !(old & WS_EX_LAYERED) && !SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA)) {
        SetWindowLongPtrW(hwnd, GWL_EXSTYLE, old);
        return 0;
    }
    if (on && GetCapture() == hwnd) ReleaseCapture();
    w->added_input_styles = on ? input_styles & ~old : 0;
    w->click_through = on;
    InvalidateRect(hwnd, NULL, FALSE);
    return 1;
}

static void replace_cursor(RuneWinWindow *w, HCURSOR next, int owned) {
    HCURSOR old = w->custom_cursor;
    w->custom_cursor = owned ? next : NULL;
    w->cursor = next;
    POINT p;
    RECT client;
    if (GetCursorPos(&p) && WindowFromPoint(p) == w->hwnd && ScreenToClient(w->hwnd, &p) &&
        GetClientRect(w->hwnd, &client) && PtInRect(&client, p)) SetCursor(next);
    if (old) DestroyCursor(old);
}

void rune_win_cursor(RuneWinWindow *w, RuneWinCursor kind) {
    LPCWSTR id = IDC_ARROW;
    switch (kind) {
    case RUNE_CURSOR_ARROW: break;
    case RUNE_CURSOR_HAND: id = IDC_HAND; break;
    case RUNE_CURSOR_TEXT: id = IDC_IBEAM; break;
    case RUNE_CURSOR_MOVE: id = IDC_SIZEALL; break;
    case RUNE_CURSOR_DENIED: id = IDC_NO; break;
    case RUNE_CURSOR_COLUMN: id = IDC_SIZEWE; break;
    case RUNE_CURSOR_ROW: id = IDC_SIZENS; break;
    case RUNE_CURSOR_CROSS: id = IDC_CROSS; break;
    case RUNE_CURSOR_HIDDEN: id = NULL; break;
    }
    replace_cursor(w, id ? LoadCursorW(NULL, id) : NULL, 0);
}

int rune_win_cursor_image(RuneWinWindow *w, const uint8_t *rgba, int32_t width, int32_t height,
                          int32_t tw, int32_t th, int32_t x_hot, int32_t y_hot, int32_t crisp) {
    if (!rgba || width < 1 || height < 1 || width > 256 || height > 256 ||
        tw < 1 || th < 1 || tw > 1024 || th > 1024) return 0;
    BITMAPINFO info = {0};
    info.bmiHeader = (BITMAPINFOHEADER){.biSize=sizeof(BITMAPINFOHEADER), .biWidth=width,
        .biHeight=-height, .biPlanes=1, .biBitCount=32, .biCompression=BI_RGB};
    uint8_t *bits = NULL;
    HBITMAP source = CreateDIBSection(NULL, &info, DIB_RGB_COLORS, (void **)&bits, NULL, 0);
    if (!source) return 0;
    for (int i = 0; i < width * height; ++i) {
        const uint8_t *px = rgba + i*4;
        bits[i*4+0] = (uint8_t)((px[2] * px[3] + 127)/255);
        bits[i*4+1] = (uint8_t)((px[1] * px[3] + 127)/255);
        bits[i*4+2] = (uint8_t)((px[0] * px[3] + 127)/255);
        bits[i*4+3] = px[3];
    }
    // A DIB section retains the alpha channel. StretchBlt's HALFTONE conversion can
    // clear that byte, so resample all four premultiplied channels together.
    info.bmiHeader.biWidth = tw;
    info.bmiHeader.biHeight = -th;
    uint8_t *scaled = NULL;
    HBITMAP color = CreateDIBSection(NULL, &info, DIB_RGB_COLORS, (void **)&scaled, NULL, 0);
    HBITMAP mask = CreateBitmap(tw, th, 1, 1, NULL);
    HCURSOR cursor = NULL;
    if (color && mask) {
        for (int y = 0; y < th; ++y) for (int x = 0; x < tw; ++x) {
            float sx = ((float)x + 0.5f) * width / tw - 0.5f;
            float sy = ((float)y + 0.5f) * height / th - 0.5f;
            sx = sx < 0 ? 0 : sx > width-1 ? (float)(width-1) : sx;
            sy = sy < 0 ? 0 : sy > height-1 ? (float)(height-1) : sy;
            uint8_t *dst = scaled + (y*tw+x)*4;
            if (crisp) {
                memcpy(dst, bits+((int)(sy+0.5f)*width+(int)(sx+0.5f))*4, 4);
            } else {
                int x0=(int)sx, y0=(int)sy, x1=x0+1 < width ? x0+1 : x0, y1=y0+1 < height ? y0+1 : y0;
                float fx=sx-x0, fy=sy-y0;
                for (int k=0; k<4; ++k) {
                    float a=bits[(y0*width+x0)*4+k]*(1-fx)+bits[(y0*width+x1)*4+k]*fx;
                    float b=bits[(y1*width+x0)*4+k]*(1-fx)+bits[(y1*width+x1)*4+k]*fx;
                    dst[k]=(uint8_t)(a*(1-fy)+b*fy+0.5f);
                }
            }
        }
        ICONINFO icon = {.fIcon=FALSE, .xHotspot=(DWORD)x_hot, .yHotspot=(DWORD)y_hot,
                         .hbmMask=mask, .hbmColor=color};
        cursor = CreateIconIndirect(&icon);
    }
    if (mask) DeleteObject(mask);
    if (color) DeleteObject(color);
    DeleteObject(source);
    if (!cursor) return 0;
    replace_cursor(w, cursor, 1);
    return 1;
}

void rune_win_titlebar(RuneWinWindow *w, int32_t double_click) {
    if (double_click) {
        if (GetWindowLongPtrW(w->hwnd, GWL_STYLE) & WS_MAXIMIZEBOX)
            ShowWindow(w->hwnd, IsZoomed(w->hwnd) ? SW_RESTORE : SW_MAXIMIZE);
    } else {
        if (GetCapture() == w->hwnd) ReleaseCapture();
        PostMessageW(w->hwnd, WM_NCLBUTTONDOWN, HTCAPTION, GetMessagePos());
    }
}

void rune_win_ime_state(RuneWinWindow *w, int32_t enabled, int32_t reset) {
    if (w->ime_enabled && (reset || !enabled)) {
        HIMC imc = ImmGetContext(w->hwnd);
        if (imc) {
            ImmNotifyIME(imc, NI_COMPOSITIONSTR, CPS_CANCEL, 0);
            ImmReleaseContext(w->hwnd, imc);
        }
        w->composing = 0;
    }
    if (w->ime_enabled != enabled && ImmAssociateContextEx(w->hwnd, NULL, enabled ? IACE_DEFAULT : 0))
        w->ime_enabled = enabled;
}

void rune_win_ime_caret(RuneWinWindow *w, int32_t x, int32_t y) {
    HIMC imc = ImmGetContext(w->hwnd);
    if (!imc) return;
    CANDIDATEFORM form = {.dwStyle = CFS_CANDIDATEPOS, .ptCurrentPos = {x,y}};
    ImmSetCandidateWindow(imc, &form);
    ImmReleaseContext(w->hwnd, imc);
}

void rune_win_destroy(RuneWinWindow *w) {
    if (!w) return;
    w->dispatch = NULL;
    if (w->gl) {
        if (wglGetCurrentContext() == w->gl) wglMakeCurrent(NULL, NULL);
        wglDeleteContext(w->gl);
    }
    if (w->dc && w->hwnd) ReleaseDC(w->hwnd, w->dc);
    if (w->hwnd) DestroyWindow(w->hwnd);
    if (w->custom_cursor) DestroyCursor(w->custom_cursor);
    free(w);
}
#endif
