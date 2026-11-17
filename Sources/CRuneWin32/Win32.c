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
#include <shlobj.h>
#include "LazyGL.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "CRuneWin32.h"
#include "Drop.h"
#include "WindowKeyboard.h"
#include "WindowLifecycle.h"
#include "WindowRedraw.h"
#include "CustomFrame.h"
#include "CpuDib.h"
#include "WGLWorker.h"
#include "WGLHandover.h"
#include "PresentDXGI.h"


static UINT taskbar_created;
static _Thread_local RuneWinWindow *painting_window;
static _Thread_local unsigned input_windows_awaiting_frame;
static _Thread_local int waiting_for_messages, dispatch_depth;

BOOL rune_win_idle_for_session(void) { return waiting_for_messages && !dispatch_depth; }
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
enum { gpu_ready_message = WM_APP + 0x7b8 };
enum { frame_timer = 1, rest_timer = 2, ready_timer = 3, overlay_timer = 0x52554f56, overlay_message = WM_APP + 0x7b4, wake_message = WM_APP + 0x103 };

// System-managed is used by embedders with their own message pump. Stock desktop
// windows finish every Rune turn through rune_win_end_redraw_turn.
enum RuneRedraw { redraw_system, redraw_idle, redraw_asked, redraw_painting, redraw_again, redraw_wants };

struct RuneWinWindow {
    HWND hwnd;
    HDC dc;
    HGLRC gl;
    HWND gl_child;
    RuneWinDib dib;
    RuneWGLWorker *worker;
    RuneWGLCover *cover;
    int cpu_first, handed, gpu_failed;
    void *context;
    RuneWinDispatch dispatch;
    int32_t min_width, min_height, max_width, max_height;
    RuneWinLifecycle lifecycle;
    enum RuneRedraw redraw;
    LARGE_INTEGER first_ask;
    LONGLONG starve_ticks;
    int defer_startup_hooks;
    uint64_t input_generation, painting_input_generation;
    BOOL input_frame_pending;
    RuneDXGIPresenter *dxgi;
    int checked_dxgi, vsync;
    int32_t refresh_hz;
    ULONGLONG refresh_expires;
    int maximize_on_show, fullscreen;
    DWORD windowed_style;
    WINDOWPLACEMENT windowed_placement;
    int in_size_move;
    int click_through, overlay;
    LONG_PTR added_input_styles;
    int context_failed, running, tracking_mouse, buttons, visible, composing, translated_key;
    int ime_enabled;
    HCURSOR cursor, custom_cursor;
};

static UINT redraw_flags(const RuneWinWindow *w) {
    // Internal paints carry the next frame without invalidating the retained DIB.
    // Genuine exposures still arrive in PAINTSTRUCT.rcPaint.
    return w->cpu_first && !w->handed ? RDW_INTERNALPAINT : RDW_INVALIDATE;
}

static void ask_redraw(RuneWinWindow *w) {
    if (!w->hwnd) return;
    switch (w->redraw) {
    case redraw_painting:
    case redraw_again:
        w->redraw = redraw_again;
        return;
    case redraw_idle:
    case redraw_wants:
        QueryPerformanceCounter(&w->first_ask);
        w->redraw = redraw_asked;
        break;
    case redraw_asked:
    case redraw_system:
        break;
    }
    if (w->cpu_first) RedrawWindow(w->hwnd, NULL, NULL, redraw_flags(w) | RDW_NOCHILDREN);
    else InvalidateRect(w->hwnd, NULL, FALSE);
}

void rune_win_enable_redraw_turns(RuneWinWindow *w) {
    if (w->redraw == redraw_system) {
        LARGE_INTEGER frequency;
        QueryPerformanceFrequency(&frequency);
        w->starve_ticks = (frequency.QuadPart * 16 + 999) / 1000;
        w->redraw = redraw_idle;
        SetPropW(w->hwnd, RUNE_REDRAW_PROPERTY, (HANDLE)1);
    }
}

static void clear_input_frame(RuneWinWindow *w) {
    if (w->input_frame_pending) {
        w->input_frame_pending = FALSE;
        --input_windows_awaiting_frame;
    }
}

int32_t rune_win_end_redraw_turn(RuneWinWindow *w, int32_t uncovered) {
    if (!uncovered || !w->running) clear_input_frame(w);
    if (!w->running) return 0;
    if (w->redraw == redraw_wants) {
        ask_redraw(w);
    } else if (w->redraw == redraw_asked && uncovered) {
        LARGE_INTEGER now;
        QueryPerformanceCounter(&now);
        if (now.QuadPart - w->first_ask.QuadPart >= w->starve_ticks && IsWindowVisible(w->hwnd) && !IsIconic(w->hwnd)) {
            // WM_PAINT normally loses to posted input and to a busy window ahead of us.
            // Service this window's real update region now; BeginPaint consumes it once.
            RedrawWindow(w->hwnd, NULL, NULL, redraw_flags(w) | RDW_UPDATENOW | RDW_NOCHILDREN);
            BOOL painted = w->redraw != redraw_asked;
            // This can be the last busy turn before the pump sleeps. A frame requested
            // in the forced paint must leave an actual update region for GetMessage.
            if (w->running && w->redraw == redraw_wants) ask_redraw(w);
            return painted;
        }
    }
    return 0;
}

static int emit(RuneWinWindow *w, RuneWinEvent event) {
    if (!w->dispatch) return 0;
    if (w->defer_startup_hooks && w->lifecycle.presented && w->visible && w->running) {
        switch (event.kind) {
        case RUNE_WIN_MOVE: case RUNE_WIN_DOWN: case RUNE_WIN_UP: case RUNE_WIN_WHEEL:
        case RUNE_WIN_KEY_DOWN: case RUNE_WIN_KEY_UP: case RUNE_WIN_CHAR:
        case RUNE_WIN_IME_PREEDIT: case RUNE_WIN_IME_COMMIT:
            ++w->input_generation;
            if (!w->input_frame_pending) {
                w->input_frame_pending = TRUE;
                ++input_windows_awaiting_frame;
            }
            break;
        default: break;
        }
    }
    ++dispatch_depth;
    int result = w->dispatch(w->context, &event);
    --dispatch_depth;
    return result;
}

static UINT dpi_for(HWND hwnd) {
    UINT dpi = GetDpiForWindow(hwnd);
    return dpi ? dpi : USER_DEFAULT_SCREEN_DPI;
}

static LONG client_pixels(double points, UINT dpi, LONG borders) {
    double pixels = points * dpi / 96.0;
    double limit = (double)INT32_MAX - borders;
    if (!(pixels > 0)) return 0;
    return (LONG)(pixels + 0.5 < limit ? pixels + 0.5 : limit);
}

static RECT client_to_window(HWND hwnd, double w, double h, UINT dpi) {
    RECT rect = {0};
    DWORD style = hwnd ? (DWORD)GetWindowLongPtrW(hwnd, GWL_STYLE) : WS_OVERLAPPEDWINDOW;
    DWORD ex_style = hwnd ? (DWORD)GetWindowLongPtrW(hwnd, GWL_EXSTYLE) : 0;
    AdjustWindowRectExForDpi(&rect, style, hwnd && GetMenu(hwnd), ex_style, dpi);
    rune_custom_frame_adjust(hwnd, &rect, dpi);
    rect.right += client_pixels(w, dpi, rect.right - rect.left);
    rect.bottom += client_pixels(h, dpi, rect.bottom - rect.top);
    return rect;
}

static void position_event(RuneWinWindow *w) {
    if (w->overlay || IsIconic(w->hwnd)) return;
    DPI_AWARENESS_CONTEXT previous = SetThreadDpiAwarenessContext(GetWindowDpiAwarenessContext(w->hwnd));
    POINT origin = {0};
    if (ClientToScreen(w->hwnd, &origin))
        emit(w, (RuneWinEvent){.kind = RUNE_WIN_POSITION, .dpi = dpi_for(w->hwnd), .x = origin.x, .y = origin.y});
    if (previous) SetThreadDpiAwarenessContext(previous);
}

static void resize_event(RuneWinWindow *w) {
    DPI_AWARENESS_CONTEXT previous = SetThreadDpiAwarenessContext(GetWindowDpiAwarenessContext(w->hwnd));
    RECT rect;
    if (GetClientRect(w->hwnd, &rect) && rect.right > 0 && rect.bottom > 0) {
        if (w->handed && !w->dxgi && w->gl_child &&
            !SetWindowPos(w->gl_child, NULL, 0, 0, rect.right, rect.bottom,
                          SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE)) w->gpu_failed = 1;
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
    ask_redraw(w);
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
    case rune_request_paint:
        ask_redraw(w);
        return TRUE;
    case gpu_ready_message:
        if (w->worker && (uint32_t)wp == rune_wgl_worker_token(w->worker)) ask_redraw(w);
        return 0;
    case WM_WTSSESSION_CHANGE:
        if (wp == 7 && w->lifecycle.registered) emit(w, (RuneWinEvent){.kind = RUNE_WIN_SESSION_LOCK});
        break;
    case WM_NCDESTROY:
        clear_input_frame(w);
        if (w->worker) {
            rune_wgl_worker_close(w->worker);
            w->worker = NULL;
        }
        if (w->redraw != redraw_system) RemovePropW(hwnd, RUNE_REDRAW_PROPERTY);
        rune_lifecycle_destroy(hwnd, &w->lifecycle);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
        w->hwnd = NULL;
        return DefWindowProcW(hwnd, msg, wp, lp);
    case WM_MOUSEACTIVATE:
        if (w->overlay) return MA_NOACTIVATE;
        break;
    case WM_NCHITTEST:
        if (w->overlay) {
            POINT p = {GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
            ScreenToClient(hwnd, &p);
            return emit(w, (RuneWinEvent){.kind = RUNE_WIN_OVERLAY_HIT, .x = p.x, .y = p.y}) ? HTCLIENT : HTTRANSPARENT;
        }
        break;
    case WM_APP + 0x7b5:
        if (rune_dxgi_ready(w->dxgi, wp)) ask_redraw(w);
        return 0;
    case overlay_message:
        emit(w, (RuneWinEvent){.kind = RUNE_WIN_OVERLAY_POINTER});
        return 0;
    case WM_GETMINMAXINFO: {
        if (w->fullscreen) break;
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
    case WM_DISPLAYCHANGE:
        w->refresh_expires = 0;
        break;
    case WM_DPICHANGED: {
        w->refresh_expires = 0;
        const RECT *r = (const RECT *)lp;
        SetWindowPos(hwnd, NULL, r->left, r->top, r->right-r->left, r->bottom-r->top,
                     SWP_NOZORDER | SWP_NOACTIVATE);
        resize_event(w);
        position_event(w);
        ask_redraw(w);
        return 0;
    }
    case WM_MOVE:
        if (!w->overlay) {
            position_event(w);
            ask_redraw(w);
        }
        break;
    case WM_ENTERSIZEMOVE:
        w->in_size_move = 1;
        break;
    case WM_EXITSIZEMOVE:
        w->in_size_move = 0;
        break;
    case WM_SIZE:
        resize_event(w);
        visibility(w, hwnd);
        ask_redraw(w);
        // Paint inside the system's modal sizing loop so it can display the
        // new client area with its new pixels when this message returns.
        if (w->in_size_move && wp != SIZE_MINIMIZED && painting_window != w) UpdateWindow(hwnd);
        return 0;
    case WM_WINDOWPOSCHANGED: {
        w->refresh_expires = 0;
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
    case WM_PRINTCLIENT:
        if (w->cpu_first && !w->handed && rune_win_dib_paint(&w->dib, (HDC)wp, NULL)) return 0;
        break;
    case WM_PAINT: {
        PAINTSTRUCT paint;
        HDC paint_dc = BeginPaint(hwnd, &paint);
        if (w->cpu_first && !w->handed && !IsRectEmpty(&paint.rcPaint))
            rune_win_dib_paint(&w->dib, paint_dc, &paint.rcPaint);
        EndPaint(hwnd, &paint);
        if (w->redraw == redraw_painting || w->redraw == redraw_again) {
            w->redraw = redraw_again;
            return 0;
        }
        if (w->redraw != redraw_system) w->redraw = redraw_idle;
        if (w->defer_startup_hooks && (!IsWindowVisible(hwnd) || IsIconic(hwnd))) {
            if (!w->lifecycle.presented && w->running && KillTimer(hwnd, ready_timer))
                emit(w, (RuneWinEvent){.kind = RUNE_WIN_READY_WITHOUT_FRAME});
            return 0;
        }
        if (w->dispatch && w->running && !IsIconic(hwnd)) {
            KillTimer(hwnd, frame_timer);
            // Modal UI can synchronously repaint a sibling during a frame callback.
            RuneWinWindow *outer = painting_window;
            int restore_gl = outer && outer->gl;
            HDC previous_dc = restore_gl ? rune_lazy_wglGetCurrentDC() : NULL;
            HGLRC previous_gl = restore_gl ? rune_lazy_wglGetCurrentContext() : NULL;
            painting_window = w;
            if (w->redraw != redraw_system) w->redraw = redraw_painting;
            if ((!w->cpu_first || w->handed) && !rune_win_make_current(w)) {
                if (w->cpu_first) w->gpu_failed = 1;
                else w->context_failed = 1;
            }
            uint64_t outer_input = w->painting_input_generation;
            w->painting_input_generation = w->input_generation;
            int next = w->context_failed ? -2 : emit(w, (RuneWinEvent){.kind = RUNE_WIN_FRAME});
            w->painting_input_generation = outer_input;
            painting_window = outer;
            if (restore_gl && (rune_lazy_wglGetCurrentContext() != previous_gl || rune_lazy_wglGetCurrentDC() != previous_dc) &&
                !rune_lazy_wglMakeCurrent(previous_dc, previous_gl)) {
                rune_lazy_wglMakeCurrent(NULL, NULL);
                if (outer->cpu_first) outer->gpu_failed = 1;
                else outer->context_failed = 1;
            }
            if (w->context_failed || next == -2) {
                w->running = 0;
                PostMessageW(hwnd, WM_NULL, 0, 0);
            } else if (next == RUNE_WIN_CONTINUE_MOTION) {
                if (rune_win_present_paced(w)) ask_redraw(w);
                else SetTimer(hwnd, frame_timer, 16, NULL);
            } else if (next >= 0) {
                SetTimer(hwnd, frame_timer, (UINT)next, NULL);
            }
            if (w->redraw == redraw_again) w->redraw = redraw_wants;
            else if (w->redraw == redraw_painting) w->redraw = redraw_idle;
        }
        return 0;
    }
    case WM_TIMER:
        if (wp == ready_timer) {
            KillTimer(hwnd, ready_timer);
            if (w->running && !w->lifecycle.presented)
                emit(w, (RuneWinEvent){.kind = RUNE_WIN_READY_WITHOUT_FRAME});
            return 0;
        }
        if (wp == overlay_timer) {
            KillTimer(hwnd, overlay_timer);
            emit(w, (RuneWinEvent){.kind = RUNE_WIN_OVERLAY_DUE});
            return 0;
        }
        if (wp == rest_timer) {
            KillTimer(hwnd, rest_timer);
            emit(w, (RuneWinEvent){.kind = RUNE_WIN_REST_TIMER});
            return 0;
        }
        if (wp == rune_cloak_timer) {
            ULONGLONG now = GetTickCount64();
            if (w->lifecycle.cloaked && (now >= w->lifecycle.deadline ||
                !SetTimer(hwnd, rune_cloak_timer, (UINT)(w->lifecycle.deadline - now), NULL))) {
                rune_lifecycle_lift(hwnd, &w->lifecycle, TRUE);
            }
            return 0;
        }
        if (wp != frame_timer) break;
        KillTimer(hwnd, frame_timer);
        ask_redraw(w);
        return 0;
    case wake_message:
        emit(w, (RuneWinEvent){.kind = RUNE_WIN_WAKE});
        if (!IsIconic(hwnd) && IsWindowVisible(hwnd)) ask_redraw(w);
        return 0;
    case WM_CLOSE:
        if (!w->dispatch || emit(w, (RuneWinEvent){.kind = RUNE_WIN_CLOSE})) {
            w->running = 0;
            PostMessageW(hwnd, WM_NULL, 0, 0);
        } else {
            ask_redraw(w);
        }
        return 0;
    case WM_SETTINGCHANGE: case WM_SYSCOLORCHANGE: case WM_THEMECHANGED: case WM_DWMCOLORIZATIONCOLORCHANGED:
        emit(w, (RuneWinEvent){.kind = RUNE_WIN_SETTINGS});
        ask_redraw(w);
        break;
    case WM_SETFOCUS:
    case WM_KILLFOCUS:
        emit(w, (RuneWinEvent){.kind = RUNE_WIN_FOCUS, .value = msg == WM_SETFOCUS});
        ask_redraw(w);
        break;
    case WM_MOUSEMOVE: {
        if (!w->tracking_mouse) {
            TRACKMOUSEEVENT track = {sizeof(track), TME_LEAVE, hwnd, 0};
            w->tracking_mouse = TrackMouseEvent(&track);
        }
        int dirty = emit(w, (RuneWinEvent){.kind = RUNE_WIN_MOVE, .x = GET_X_LPARAM(lp), .y = GET_Y_LPARAM(lp), .mods = modifiers()});
        if (!w->overlay || dirty) ask_redraw(w);
        return 0;
    }
    case WM_MOUSELEAVE:
        w->tracking_mouse = 0;
        emit(w, (RuneWinEvent){.kind = RUNE_WIN_LEAVE});
        ask_redraw(w);
        return 0;
    case WM_LBUTTONDOWN: case WM_LBUTTONUP: case WM_LBUTTONDBLCLK:
    case WM_RBUTTONDOWN: case WM_RBUTTONUP: case WM_RBUTTONDBLCLK:
    case WM_MBUTTONDOWN: case WM_MBUTTONUP: case WM_MBUTTONDBLCLK:
    case WM_XBUTTONDOWN: case WM_XBUTTONUP: case WM_XBUTTONDBLCLK: {
        int down = msg != WM_LBUTTONUP && msg != WM_RBUTTONUP && msg != WM_MBUTTONUP && msg != WM_XBUTTONUP;
        int extra = msg >= WM_XBUTTONDOWN;
        uint32_t button;
        if (extra) button = GET_XBUTTON_WPARAM(wp) == XBUTTON1 ? 3 : 4;
        else if (msg >= WM_MBUTTONDOWN) button = 2;
        else if (msg >= WM_RBUTTONDOWN) button = 1;
        else button = 0;
        if (down) {
            if (!w->overlay) SetFocus(hwnd);
            SetCapture(hwnd);
            w->buttons |= 1 << button;
        }
        emit(w, (RuneWinEvent){.kind = down ? RUNE_WIN_DOWN : RUNE_WIN_UP, .value = button,
                               .x = GET_X_LPARAM(lp), .y = GET_Y_LPARAM(lp), .mods = modifiers()});
        if (!down) {
            w->buttons &= ~(1 << button);
            if (!w->buttons && GetCapture() == hwnd) ReleaseCapture();
        }
        ask_redraw(w);
        return extra ? TRUE : 0;
    }
    case WM_CAPTURECHANGED: case WM_CANCELMODE:
        if (w->buttons) {
            w->buttons = 0;
            emit(w, (RuneWinEvent){.kind = RUNE_WIN_CAPTURE_LOST});
            ask_redraw(w);
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
        ask_redraw(w);
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
        ask_redraw(w);
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
        ask_redraw(w);
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
        ask_redraw(w);
        if (taken) return 0;
        break;
    }
    case WM_IME_ENDCOMPOSITION:
        if (w->composing) {
            emit(w, (RuneWinEvent){.kind = RUNE_WIN_IME_PREEDIT});
            w->composing = 0;
            ask_redraw(w);
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
    if (!name) return NULL;
    PROC p = rune_lazy_wglGetProcAddress(name);
    if (!p || (uintptr_t)p <= 3 || (uintptr_t)p == UINTPTR_MAX)
        p = rune_win_system_gl_export(name);
    return (void *)p;
}

static RuneWinWindow *create_window(const uint16_t *title, int32_t width, int32_t height,
                                    int32_t min_width, int32_t min_height, int32_t dark,
                                    char *error, int32_t error_capacity, int cpu_first) {
    double start = rune_win_boot_clock();
    RuneWinWindow *w = calloc(1, sizeof(*w));
    const char *failed = "window allocation";
    DPI_AWARENESS_CONTEXT previous_dpi = NULL;
    if (!w) goto fail;
    w->cpu_first = cpu_first;
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
    if (cpu_first) failed = NULL;
    else {
        w->dc = GetDC(w->hwnd);
        failed = w->dc ? rune_wgl_configure(w->dc, &w->gl, &w->vsync) : "GetDC";
    }
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

RuneWinWindow *rune_win_create(const uint16_t *title, int32_t width, int32_t height,
                               int32_t min_width, int32_t min_height, int32_t dark,
                               char *error, int32_t error_capacity) {
    return create_window(title, width, height, min_width, min_height, dark, error, error_capacity, 0);
}

RuneWinWindow *rune_win_create_cpu(const uint16_t *title, int32_t width, int32_t height,
                                   int32_t min_width, int32_t min_height, int32_t dark,
                                   char *error, int32_t error_capacity) {
    return create_window(title, width, height, min_width, min_height, dark, error, error_capacity, 1);
}

void rune_win_gpu_start(RuneWinWindow *w, int32_t urgent, void *context,
                        RuneWinGPUPrepare prepare, RuneWinGPURelease release) {
    if (!w || !w->hwnd || !w->cpu_first || w->worker || w->gl || w->gpu_failed) {
        if (release) release(context);
        return;
    }
    w->worker = rune_wgl_worker_start(w->hwnd, gpu_ready_message, urgent, context, prepare, release);
    w->gpu_failed = !w->worker;
    if (w->gpu_failed) ask_redraw(w);
}

void rune_win_gpu_raise(RuneWinWindow *w) {
    if (w && w->worker) rune_wgl_worker_raise(w->worker);
}

int32_t rune_win_gpu_state(RuneWinWindow *w) {
    if (!w || w->gpu_failed) return -1;
    return w->gl ? 1 : w->worker ? rune_wgl_worker_state(w->worker) : 0;
}

static LRESULT CALLBACK visual_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_NCHITTEST) return HTTRANSPARENT;
    if (msg == WM_ERASEBKGND) return 1;
    if (msg == WM_PAINT) {
        PAINTSTRUCT paint;
        BeginPaint(hwnd, &paint);
        EndPaint(hwnd, &paint);
        if (!IsRectEmpty(&paint.rcPaint)) PostMessageW(GetParent(hwnd), rune_request_paint, 0, 0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static HWND make_gl_visual(HWND owner) {
    static const wchar_t name[] = L"RuneSwiftWGLVisual";
    WNDCLASSW cls = {.style = CS_OWNDC, .lpfnWndProc = visual_proc,
                     .hInstance = GetModuleHandleW(NULL), .lpszClassName = name};
    if (!RegisterClassW(&cls) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return NULL;
    return CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_NOPARENTNOTIFY, name, L"",
                           WS_CHILD | WS_DISABLED | WS_CLIPSIBLINGS, 0, 0, 1, 1,
                           owner, NULL, cls.hInstance, NULL);
}

int32_t rune_win_make_current(RuneWinWindow *w) {
    if (w->gl) return rune_lazy_wglGetCurrentContext() == w->gl || rune_lazy_wglMakeCurrent(w->dc, w->gl);
    if (!w->worker || rune_win_gpu_state(w) != 1) return 0;
    // The GDI parent's pixel format never changes. The worker's GL context moves
    // to a private DC on the same adapter and with the same pixel format.
    w->gl_child = make_gl_visual(w->hwnd);
    if (!w->gl_child || !(w->dc = GetDC(w->gl_child)) ||
        !rune_wgl_worker_adopt(w->worker, w->dc, &w->gl)) {
        w->gpu_failed = 1;
        return 0;
    }
    w->vsync = rune_wgl_vsync();
    rune_wgl_worker_close(w->worker);
    w->worker = NULL;
    return 1;
}

void rune_win_rest_timer(RuneWinWindow *w, int32_t delay_ms) {
    if (delay_ms < 0) KillTimer(w->hwnd, rest_timer);
    else SetTimer(w->hwnd, rest_timer, (UINT)delay_ms, NULL);
}

void rune_win_trim_gpu(RuneWinWindow *w, int32_t all) {
    if (w->cpu_first && !w->handed) return;
    HGLRC previous = rune_lazy_wglGetCurrentContext();
    HDC previous_dc = rune_lazy_wglGetCurrentDC();
    if (!rune_win_make_current(w)) {
        if (w->cpu_first) { w->gpu_failed = 1; ask_redraw(w); }
        else w->context_failed = 1;
        return;
    }
    emit(w, (RuneWinEvent){.kind = RUNE_WIN_TRIM_GPU, .value = (uint32_t)all});
    if (previous != w->gl && !rune_lazy_wglMakeCurrent(previous_dc, previous)) {
        rune_lazy_wglMakeCurrent(NULL, NULL);
        if (painting_window) {
            if (painting_window->cpu_first) painting_window->gpu_failed = 1;
            else painting_window->context_failed = 1;
        }
    }
}

int32_t rune_win_running(RuneWinWindow *w) { return w->context_failed ? -1 : w->running; }
uint32_t rune_win_thread(void) { return GetCurrentThreadId(); }
void rune_win_wake_thread(uint32_t thread) { PostThreadMessageW(thread, WM_NULL, 0, 0); }

void rune_win_toggle_fullscreen(RuneWinWindow *w) {
    HWND hwnd = w->hwnd;
    DPI_AWARENESS_CONTEXT previous = SetThreadDpiAwarenessContext(GetWindowDpiAwarenessContext(hwnd));
    DWORD style = (DWORD)GetWindowLongPtrW(hwnd, GWL_STYLE);
    UINT flags = SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED;
    if (w->fullscreen) {
        w->fullscreen = 0;
        SetWindowLongPtrW(hwnd, GWL_STYLE, w->windowed_style | (style & WS_VISIBLE));
        SetWindowPos(hwnd, NULL, 0, 0, 0, 0, flags | SWP_NOMOVE | SWP_NOSIZE);
        WINDOWPLACEMENT placement = w->windowed_placement;
        if (!(style & WS_VISIBLE)) placement.showCmd = SW_HIDE;
        else if (placement.showCmd == SW_HIDE) placement.showCmd = SW_SHOWNOACTIVATE;
        SetWindowPlacement(hwnd, &placement);
    } else {
        MONITORINFO monitor = {.cbSize = sizeof(monitor)};
        w->windowed_placement.length = sizeof(WINDOWPLACEMENT);
        if (GetWindowPlacement(hwnd, &w->windowed_placement) &&
            GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor)) {
            w->windowed_style = style & ~(WS_MAXIMIZE | WS_MINIMIZE | WS_VISIBLE);
            w->fullscreen = 1;
            SetWindowLongPtrW(hwnd, GWL_STYLE, (style & ~(WS_OVERLAPPEDWINDOW | WS_MAXIMIZE | WS_MINIMIZE)) | WS_POPUP);
            RECT *r = &monitor.rcMonitor;
            SetWindowPos(hwnd, NULL, r->left, r->top, r->right - r->left, r->bottom - r->top, flags);
        }
    }
    if (previous) SetThreadDpiAwarenessContext(previous);
}

void rune_win_configure(RuneWinWindow *w, RuneWinOptions options) {
    DPI_AWARENESS_CONTEXT previous = SetThreadDpiAwarenessContext(GetWindowDpiAwarenessContext(w->hwnd));
    if (w->fullscreen) rune_win_toggle_fullscreen(w);
    RECT client, outer;
    GetClientRect(w->hwnd, &client);
    GetWindowRect(w->hwnd, &outer);
    w->max_width = options.max_width;
    w->max_height = options.max_height;
    DWORD style = options.borderless ? WS_POPUP : WS_OVERLAPPEDWINDOW;
    style |= GetWindowLongPtrW(w->hwnd, GWL_STYLE) & WS_VISIBLE;
    if (!options.resizable) style &= ~(WS_THICKFRAME | WS_MAXIMIZEBOX);
    if (!options.minimizable) style &= ~WS_MINIMIZEBOX;
    SetWindowLongPtrW(w->hwnd, GWL_STYLE, style);
    if (!options.closable) EnableMenuItem(GetSystemMenu(w->hwnd, FALSE), SC_CLOSE, MF_GRAYED | MF_BYCOMMAND);
    // Preserve the requested client dimensions in the restored window placement.
    AdjustWindowRectExForDpi(&client, style, GetMenu(w->hwnd) != NULL,
                             (DWORD)GetWindowLongPtrW(w->hwnd, GWL_EXSTYLE), dpi_for(w->hwnd));
    rune_custom_frame_adjust(w->hwnd, &client, dpi_for(w->hwnd));
    outer.right = outer.left + client.right - client.left;
    outer.bottom = outer.top + client.bottom - client.top;
    SetWindowPos(w->hwnd, NULL, outer.left, outer.top, outer.right - outer.left, outer.bottom - outer.top,
                 SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    w->maximize_on_show = options.maximized && !options.fullscreen;
    if (options.fullscreen) rune_win_toggle_fullscreen(w);
    if (previous) SetThreadDpiAwarenessContext(previous);
}

void rune_win_start(RuneWinWindow *w, void *context, RuneWinDispatch dispatch, int32_t inactive, int32_t visible) {
    w->context = context;
    w->dispatch = dispatch;
    w->running = 1;
    // A hidden or minimized window may receive no paint. Its app can still start
    // live work after one second. Only a successful presentation marks its handle ready.
    if (w->defer_startup_hooks && !SetTimer(w->hwnd, ready_timer, 1000, NULL))
        PostMessageW(w->hwnd, WM_TIMER, ready_timer, 0);
    resize_event(w);
    if (visible) rune_lifecycle_hold(w->hwnd, &w->lifecycle, !inactive);
    position_event(w);
    BOOL show_inactive = inactive || w->lifecycle.cloaked;
    if (visible && w->maximize_on_show && show_inactive) {
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
        ShowWindow(w->hwnd, w->maximize_on_show ? SW_SHOWMAXIMIZED : show_inactive ? SW_SHOWNOACTIVATE : SW_SHOW);
    }
    emit(w, (RuneWinEvent){.kind = RUNE_WIN_FOCUS, .value = GetFocus() == w->hwnd});
    UpdateWindow(w->hwnd);
}

int32_t rune_win_screen_reader(void) {
    BOOL active = FALSE;
    return SystemParametersInfoW(SPI_GETSCREENREADER, 0, &active, 0) && active;
}

int32_t rune_win_input_waiting(void) {
    MSG msg;
    const UINT flags = PM_NOREMOVE | PM_QS_INPUT | PM_QS_POSTMESSAGE;
    return PeekMessageW(&msg, NULL, WM_KEYFIRST, WM_KEYLAST, flags) ||
           PeekMessageW(&msg, NULL, WM_MOUSEFIRST, WM_MOUSELAST, flags);
}

int32_t rune_win_startup_may_run(int32_t dispatched_paint) {
    // An internal GDI paint or a frame waiting for a GPU slot need not have
    // a WM_PAINT available to peek. Wait for the window that took the input.
    if (input_windows_awaiting_frame || rune_win_input_waiting()) return 0;
    MSG msg;
    // A turn-end paint can precede the pump. Input dispatched after that paint
    // still gets its next requested frame before startup work.
    return dispatched_paint ||
           !PeekMessageW(&msg, NULL, WM_PAINT, WM_PAINT, PM_NOREMOVE | PM_QS_PAINT | PM_QS_POSTMESSAGE);
}

static _Thread_local int32_t last_turn_timer;
int32_t rune_win_turn_timer(void) { return last_turn_timer; }

int32_t rune_win_pump_turn(int32_t idle_work_owed, int32_t *painted) {
    MSG msg;
    last_turn_timer = 0;
    if (painted) *painted = 0;
    if (idle_work_owed) {
        ++waiting_for_messages;
        BOOL received = PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE);
        --waiting_for_messages;
        if (!received) return RUNE_WIN_PUMP_IDLE;
        if (msg.message == WM_QUIT) return 0;
    } else {
        ++waiting_for_messages;
        int result = GetMessageW(&msg, NULL, 0, 0);
        --waiting_for_messages;
        if (result <= 0) return result;
    }
    last_turn_timer = msg.message == WM_TIMER;
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
    if (painted && msg.message == WM_PAINT) *painted = 1;
    return 1;
}

int32_t rune_win_pump_or_idle(int32_t idle_work_owed) { return rune_win_pump_turn(idle_work_owed, NULL); }

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
    if (on) {
        QUERY_USER_NOTIFICATION_STATE state;
        if (GetForegroundWindow() == w->hwnd || FAILED(SHQueryUserNotificationState(&state)) ||
            state != QUNS_ACCEPTS_NOTIFICATIONS) return;
    }
    FLASHWINFO info = {sizeof(info), w->hwnd, on ? FLASHW_TRAY : FLASHW_STOP, on ? 2 : 0, 0};
    FlashWindowEx(&info);
}
void *rune_win_hwnd(RuneWinWindow *w) { return w->hwnd; }
int32_t rune_win_refresh_hz(RuneWinWindow *w) {
    const ULONGLONG now = GetTickCount64();
    if (now < w->refresh_expires) return w->refresh_hz;
    MONITORINFOEXW info = {0};
    DEVMODEW mode = {0};
    info.cbSize = sizeof(info);
    mode.dmSize = sizeof(mode);
    HMONITOR monitor = MonitorFromWindow(w->hwnd, MONITOR_DEFAULTTONEAREST);
    w->refresh_hz = monitor && GetMonitorInfoW(monitor, (MONITORINFO *)&info) &&
        EnumDisplaySettingsW(info.szDevice, ENUM_CURRENT_SETTINGS, &mode) &&
        mode.dmDisplayFrequency > 1 ? (int32_t)mode.dmDisplayFrequency : 0;
    w->refresh_expires = now + 1000;
    return w->refresh_hz;
}
void rune_win_exit(RuneWinWindow *w) {
    w->running = 0;
    // Another window on this UI thread can be running User32's modal menu loop.
    EndMenu();
    PostMessageW(w->hwnd, WM_NULL, 0, 0);
}
int32_t rune_win_present_paced(RuneWinWindow *w) {
    return (!w->cpu_first || w->handed) && (w->dxgi != NULL || w->vsync);
}

static void first_presentation(RuneWinWindow *w) {
    if (w->painting_input_generation == w->input_generation) clear_input_frame(w);
    if (w->lifecycle.presented) return;
    if (w->defer_startup_hooks) KillTimer(w->hwnd, ready_timer);
    rune_lifecycle_presented(w->hwnd, &w->lifecycle);
    if (!w->defer_startup_hooks) rune_lifecycle_install_session_lock(w->hwnd, &w->lifecycle);
}

int32_t rune_win_cpu_present(RuneWinWindow *w, const uint8_t *pixels, int32_t width,
                             int32_t height, int32_t stride_bytes, const int32_t *rects,
                             int32_t count, int32_t full) {
    if (!w || !w->cpu_first || w->handed || !IsWindowVisible(w->hwnd) || IsIconic(w->hwnd)) return 0;
    if (!rune_win_dib_present(&w->dib, w->hwnd, pixels, width, height, stride_bytes, rects, count, full))
        return 0;
    first_presentation(w);
    return 1;
}

static int prepare_wgl_visual(RuneWinWindow *w) {
    RECT client, child;
    if (!GetClientRect(w->hwnd, &client) || !GetClientRect(w->gl_child, &child)) return -1;
    if (IsRectEmpty(&client)) return 0;
    if (!EqualRect(&client, &child) &&
        !SetWindowPos(w->gl_child, NULL, 0, 0, client.right, client.bottom,
                      SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE)) return -1;
    if (!(GetWindowLongPtrW(w->gl_child, GWL_STYLE) & WS_VISIBLE)) {
        if (w->dib.pixels) {
            // A hidden WGL default framebuffer doesn't own its pixels. The child must
            // already be visible to render. Cover it with the last DIB until its swap.
            if (client.right != w->dib.width || client.bottom != w->dib.height) {
                ask_redraw(w);
                return 0;
            }
            if (w->dib.capacity_width > INT32_MAX / 4) return -1;
            w->cover = rune_wgl_cover(w->gl_child, w->dib.pixels, w->dib.width,
                                      w->dib.height, w->dib.capacity_width * 4);
            if (!w->cover) return -1;
        }
        ShowWindow(w->gl_child, SW_SHOWNOACTIVATE);
        if (!IsWindowVisible(w->gl_child)) return -1;
    }
    return 1;
}

int32_t rune_win_take_frame_slot(RuneWinWindow *w) {
    int layered = (GetWindowLongPtrW(w->hwnd, GWL_EXSTYLE) & WS_EX_LAYERED) != 0;
    if (w->cpu_first && (!w->gl || w->gpu_failed)) return -1;
    if (w->dxgi && !w->cpu_first && (layered || w->overlay)) {
        // Click-through and overlay can be enabled after an ordinary window has presented.
        rune_dxgi_close(w->dxgi, 1);
        w->dxgi = NULL;
        w->checked_dxgi = 0;
    }
    if (!w->checked_dxgi && !w->overlay && !layered) {
        w->checked_dxgi = 1;
        w->dxgi = w->cpu_first ? rune_dxgi_open_cpu(w->hwnd, WM_APP + 0x7b5)
                               : rune_dxgi_open(w->hwnd, WM_APP + 0x7b5);
    }
    if (w->dxgi) {
        int ready = rune_dxgi_prepare(w->dxgi);
        if (ready >= 0) return ready;
        if (w->cpu_first) { w->gpu_failed = 1; return -1; }
        rune_dxgi_close(w->dxgi, 1);
        w->dxgi = NULL;
    }
    if (!w->cpu_first || w->handed) return 1;
    int ready = prepare_wgl_visual(w);
    if (ready < 0) w->gpu_failed = 1;
    return ready;
}

int32_t rune_win_swap_damage(RuneWinWindow *w, int width, int height, const int32_t *rects, int count) {
    if (w->cpu_first && (!w->gl || w->gpu_failed)) return 0;
    int presented = 0;
    if (w->dxgi) {
        presented = rune_dxgi_present(w->dxgi, width, height, rects, count);
        if (!presented) {
            if (w->cpu_first) { w->gpu_failed = 1; return 0; }
            rune_dxgi_close(w->dxgi, 1);
            w->dxgi = NULL;
        }
    }
    if (!presented) {
        if (!w->dc || (w->cpu_first && (!w->gl_child || !IsWindowVisible(w->gl_child)))) return 0;
        if (w->cover) rune_lazy_glFinish();
        if (!SwapBuffers(w->dc) || (w->cover && (FAILED(DwmFlush()) || !rune_wgl_uncover(w->cover)))) {
            if (w->cpu_first) {
                ShowWindow(w->gl_child, SW_HIDE);
                w->gpu_failed = 1;
            }
            return 0;
        }
        if (w->cover) {
            rune_wgl_cover_free(w->cover);
            w->cover = NULL;
        }
    }
    if (w->cpu_first && !w->handed) {
        w->handed = 1;
        rune_win_dib_dispose(&w->dib);
    }
    first_presentation(w);
    return 1;
}
void rune_win_defer_startup_hooks(RuneWinWindow *w) { w->defer_startup_hooks = 1; }

void rune_win_install_session_lock(RuneWinWindow *w) {
    rune_lifecycle_install_session_lock(w->hwnd, &w->lifecycle);
}

int32_t rune_win_swap(RuneWinWindow *w) { return rune_win_swap_damage(w, 0, 0, NULL, -1); }
void rune_win_wake(RuneWinWindow *w) { PostMessageW(w->hwnd, wake_message, 0, 0); }
int rune_win_overlay_pointer(int32_t *x, int32_t *y) {
    POINT p;
    if (!GetPhysicalCursorPos(&p)) return 0;
    *x = p.x; *y = p.y;
    return 1;
}

int rune_win_overlay_bind(RuneWinWindow *w, RuneOverlayGLBinding *previous) {
    previous->dc = rune_lazy_wglGetCurrentDC();
    previous->gl = rune_lazy_wglGetCurrentContext();
    return rune_win_make_current(w);
}

void rune_win_overlay_release_pointer(RuneWinWindow *w) {
    if (GetCapture() == w->hwnd) ReleaseCapture();
}

void rune_win_overlay_restore(RuneOverlayGLBinding previous) {
    if (rune_lazy_wglGetCurrentContext() == previous.gl && rune_lazy_wglGetCurrentDC() == previous.dc) return;
    if (!rune_lazy_wglMakeCurrent(previous.dc, previous.gl)) {
        rune_lazy_wglMakeCurrent(NULL, NULL);
        if (painting_window) {
            if (painting_window->cpu_first) painting_window->gpu_failed = 1;
            else painting_window->context_failed = 1;
        }
    }
}
void rune_win_overlay_place(RuneWinWindow *w, int32_t x, int32_t y, int32_t width, int32_t height) {
    DPI_AWARENESS_CONTEXT previous = SetThreadDpiAwarenessContext(GetWindowDpiAwarenessContext(w->hwnd));
    SetWindowPos(w->hwnd, NULL, x, y, width, height, SWP_NOZORDER | SWP_NOACTIVATE);
    if (previous) SetThreadDpiAwarenessContext(previous);
}
int rune_win_overlay_setup(RuneWinWindow *w) {
    HWND hwnd = w->hwnd;
    LONG_PTR style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
    SetLastError(0);
    if (!SetWindowLongPtrW(hwnd, GWL_EXSTYLE, (style & ~WS_EX_APPWINDOW) | WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE) && GetLastError()) return 0;
    if (!SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA)) return 0;
    // Give DWM the RGBA backbuffer, including the transparent pixels around the UI.
    HRGN region = CreateRectRgn(0, 0, -1, -1);
    if (!region) return 0;
    DWM_BLURBEHIND blur = {.dwFlags = DWM_BB_ENABLE | DWM_BB_BLURREGION, .fEnable = TRUE, .hRgnBlur = region};
    HRESULT result = DwmEnableBlurBehindWindow(hwnd, &blur);
    DeleteObject(region);
    if (FAILED(result)) return 0;
    w->overlay = 1;
    return 1;
}
int rune_win_overlay_work_area(int32_t x, int32_t y, int32_t *top, int32_t *bottom) {
    POINT p = {x,y};
    MONITORINFO info = {.cbSize = sizeof(info)};
    if (!GetMonitorInfoW(MonitorFromPoint(p, MONITOR_DEFAULTTONEAREST), &info)) return 0;
    *top = info.rcWork.top; *bottom = info.rcWork.bottom;
    return 1;
}
int rune_win_overlay_exclude(RuneWinWindow *w, int on) { return SetWindowDisplayAffinity(w->hwnd, on ? WDA_EXCLUDEFROMCAPTURE : WDA_NONE); }
void rune_win_overlay_alpha(RuneWinWindow *w, uint8_t alpha) { SetLayeredWindowAttributes(w->hwnd, 0, alpha, LWA_ALPHA); }
void rune_win_overlay_raise(RuneWinWindow *w) { SetWindowPos(w->hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE); }
void rune_win_overlay_due(RuneWinWindow *w, uint32_t after_ms) {
    KillTimer(w->hwnd, overlay_timer);
    if (after_ms) SetTimer(w->hwnd, overlay_timer, after_ms, NULL);
}
void rune_win_overlay_observed(RuneWinWindow *w) { PostMessageW(w->hwnd, overlay_message, 0, 0); }
void rune_win_dark_title(RuneWinWindow *w, int32_t dark) {
    BOOL dark_value = dark != 0;
    DwmSetWindowAttribute(w->hwnd, 20, &dark_value, sizeof(dark_value));
}
void rune_win_set_title(RuneWinWindow *w, const uint16_t *title) { SetWindowTextW(w->hwnd, (const wchar_t *)title); }
void rune_win_show(RuneWinWindow *w, int32_t show) {
    if (show && !w->overlay && !IsWindowVisible(w->hwnd)) rune_lifecycle_hold(w->hwnd, &w->lifecycle, FALSE);
    ShowWindow(w->hwnd, show ? SW_SHOWNOACTIVATE : SW_HIDE);
    if (!show) rune_lifecycle_lift(w->hwnd, &w->lifecycle, FALSE);
}
void rune_win_minimize(RuneWinWindow *w) {
    DWORD style = w->fullscreen ? w->windowed_style : (DWORD)GetWindowLongPtrW(w->hwnd, GWL_STYLE);
    if (IsWindowVisible(w->hwnd) && !IsIconic(w->hwnd) && !(style & WS_POPUP) && (style & WS_MINIMIZEBOX))
        ShowWindow(w->hwnd, SW_MINIMIZE);
}
void rune_win_focus(RuneWinWindow *w) { SetForegroundWindow(w->hwnd); SetFocus(w->hwnd); }

void rune_win_place_frame(RuneWinWindow *w, int32_t move, int32_t x, int32_t y,
                          int32_t resize, double width, double height) {
    DPI_AWARENESS_CONTEXT previous = SetThreadDpiAwarenessContext(GetWindowDpiAwarenessContext(w->hwnd));
    if (resize && rune_custom_frame_installed(w->hwnd) && IsZoomed(w->hwnd)) ShowWindow(w->hwnd, SW_RESTORE);
    UINT dpi = dpi_for(w->hwnd);
    RECT rect = client_to_window(w->hwnd, width, height, dpi);
    SetWindowPos(w->hwnd, NULL, x, y,
                 rect.right-rect.left, rect.bottom-rect.top, SWP_NOZORDER | SWP_NOACTIVATE |
                 (move ? 0 : SWP_NOMOVE) | (resize ? 0 : SWP_NOSIZE));
    if (previous) SetThreadDpiAwarenessContext(previous);
}

void rune_win_place(RuneWinWindow *w, int32_t move, int32_t x, int32_t y,
                    int32_t resize, int32_t width, int32_t height) {
    rune_win_place_frame(w, move, x, y, resize, width, height);
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
    rune_custom_frame_adjust(hwnd, &borders, dpi);
    LONG width = normal.right - normal.left - (borders.right - borders.left);
    LONG height = normal.bottom - normal.top - (borders.bottom - borders.top);
    out->restore_x = normal.left;
    out->restore_y = normal.top;
    out->restore_width = (uint32_t)(width > 0 ? width : 1);
    out->restore_height = (uint32_t)(height > 0 ? height : 1);
    out->has_restore = 1;
}

int rune_win_frame_geometry(RuneWinWindow *w, RuneWinPlacement *out,
                            uint32_t *outer_width, uint32_t *outer_height) {
    if (!w || !w->hwnd || !out) return 0;
    HWND hwnd = w->hwnd;
    DPI_AWARENESS_CONTEXT previous = SetThreadDpiAwarenessContext(GetWindowDpiAwarenessContext(hwnd));
    RECT outer, client;
    POINT origin = {0};
    int success = GetWindowRect(hwnd, &outer) && GetClientRect(hwnd, &client) && ClientToScreen(hwnd, &origin);
    if (success) {
        if (outer_width) *outer_width = (uint32_t)(outer.right - outer.left);
        if (outer_height) *outer_height = (uint32_t)(outer.bottom - outer.top);
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

int rune_win_placement(RuneWinWindow *w, RuneWinPlacement *out) {
    return rune_win_frame_geometry(w, out, NULL, NULL);
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
    ask_redraw(w);
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
        if (IsZoomed(w->hwnd) || (GetWindowLongPtrW(w->hwnd, GWL_STYLE) & WS_MAXIMIZEBOX))
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

static void release_gpu(RuneWinWindow *w) {
    rune_wgl_worker_close(w->worker);
    w->worker = NULL;
    if (w->hwnd && w->gl_child) ShowWindow(w->gl_child, SW_HIDE);
    rune_wgl_cover_free(w->cover);
    w->cover = NULL;
    if (w->dxgi) {
        HGLRC previous = rune_lazy_wglGetCurrentContext();
        HDC previous_dc = rune_lazy_wglGetCurrentDC();
        rune_dxgi_close(w->dxgi, rune_win_make_current(w));
        w->dxgi = NULL;
        if (previous != w->gl) rune_lazy_wglMakeCurrent(previous_dc, previous);
    }
    if (w->gl) {
        if (rune_lazy_wglGetCurrentContext() == w->gl) rune_lazy_wglMakeCurrent(NULL, NULL);
        rune_lazy_wglDeleteContext(w->gl);
        w->gl = NULL;
    }
    if (w->dc && w->hwnd) ReleaseDC(w->gl_child ? w->gl_child : w->hwnd, w->dc);
    w->dc = NULL;
    if (w->gl_child && w->hwnd) DestroyWindow(w->gl_child);
    w->gl_child = NULL;
    w->vsync = w->checked_dxgi = w->handed = w->gpu_failed = 0;
}

void rune_win_gpu_abandon(RuneWinWindow *w) {
    if (!w || !w->cpu_first) return;
    release_gpu(w);
    if (w->hwnd) {
        // An old child or composition visual may have covered the entire parent.
        InvalidateRect(w->hwnd, NULL, FALSE);
        ask_redraw(w);
    }
}

void rune_win_destroy(RuneWinWindow *w) {
    if (!w) return;
    clear_input_frame(w);
    w->dispatch = NULL;
    release_gpu(w);
    rune_win_dib_dispose(&w->dib);
    if (w->hwnd) DestroyWindow(w->hwnd);
    if (w->custom_cursor) DestroyCursor(w->custom_cursor);
    free(w);
}
#endif
