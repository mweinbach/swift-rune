/*
 * Run in a Visual Studio developer prompt with clang on PATH, from the package root.
 * clang -std=c11 -ISources/CRuneWin32/include Tests/Support/WindowsWindowHandle/HitTest.c Sources/CRuneWin32/Win32.c -o hit-test.exe -lopengl32 -lgdi32 -luser32 -lshell32 -ldwmapi -limm32
 * The test shows two inactive windows, queries one point in their client areas, and
 * closes them. A second GUI thread makes same-thread WM_NCHITTEST forwarding insufficient.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dwmapi.h>
#include <GL/gl.h>
#include <stdio.h>
#include "CRuneWin32.h"

static const int width = 100, height = 78;
static int x, y;
static HWND below;

static DWORD WINAPI background_window(void *ready) {
    SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    WNDCLASSW target = {.lpfnWndProc = DefWindowProcW, .hInstance = GetModuleHandleW(NULL),
                        .lpszClassName = L"RuneWindowHandleHitTest", .hbrBackground = GetStockObject(BLACK_BRUSH)};
    if (RegisterClassW(&target)) {
        below = CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, target.lpszClassName, L"Rune input target",
                                WS_POPUP, x, y, width, height, NULL, NULL, target.hInstance, NULL);
    }
    if (below) SetWindowPos(below, HWND_NOTOPMOST, x, y, width, height, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    SetEvent(ready);
    MSG message;
    while (below && GetMessageW(&message, NULL, 0, 0) > 0) DispatchMessageW(&message);
    if (below) DestroyWindow(below);
    return 0;
}

static int present_and_hit(RuneWinWindow *window, int color, POINT point, HWND expected) {
    if (!rune_win_make_current(window)) return 0;
    COLORREF target = RGB(color == 0 ? 255 : 0, color == 1 ? 255 : 0, color == 2 ? 255 : 0);
    int hit = 0, shown = 0;
    ULONGLONG deadline = GetTickCount64() + 2500;
    do {
        MSG message;
        while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) DispatchMessageW(&message);
        glClearColor(color == 0, color == 1, color == 2, 1);
        glClear(GL_COLOR_BUFFER_BIT);
        unsigned char pixel[4] = {0};
        glReadPixels(8, 8, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
        if (glGetError() || pixel[color] != 255 || !rune_win_swap(window)) return 0;
        DwmFlush();
        hit = WindowFromPoint(point) == expected;
        if (hit) {
            HDC screen = GetDC(NULL);
            shown = GetPixel(screen, point.x, point.y) == target;
            ReleaseDC(NULL, screen);
        }
        if (hit && shown) break;
        Sleep(16);
    } while (GetTickCount64() < deadline);
    printf("frame %d: target %s, composed pixel %s\n", color, hit ? "correct" : "wrong", shown ? "correct" : "wrong");
    return hit && shown;
}

int main(void) {
    SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    RECT workspace;
    if (!SystemParametersInfoW(SPI_GETWORKAREA, 0, &workspace, 0)) return 1;
    x = workspace.left + (workspace.right - workspace.left - width) * 3 / 4;
    y = workspace.top + (workspace.bottom - workspace.top - height) * 3 / 4;
    HANDLE ready = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!ready) return 1;
    DWORD thread_id;
    HANDLE thread = CreateThread(NULL, 0, background_window, ready, 0, &thread_id);
    if (!thread || WaitForSingleObject(ready, 5000) != WAIT_OBJECT_0 || !below) return 1;
    char error[256] = {0};
    RuneWinWindow *window = rune_win_create((const uint16_t *)L"Rune input overlay", width, height, 1, 1, 0,
                                            error, sizeof(error));
    int passed = 0;
    if (window) {
        RuneWinOptions options = {.borderless = 1};
        rune_win_configure(window, options);
        HWND overlay = rune_win_hwnd(window);
        SetWindowPos(overlay, HWND_TOPMOST, x, y, width, height, SWP_NOACTIVATE | SWP_SHOWWINDOW);
        SetWindowPos(below, overlay, 0, 0, 0, 0, SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE | SWP_ASYNCWINDOWPOS);
        POINT point = {x + 33, y + 33};
        passed = present_and_hit(window, 0, point, overlay)
              && rune_win_click_through(window, 1) && present_and_hit(window, 1, point, below)
              && rune_win_click_through(window, 0) && present_and_hit(window, 2, point, overlay);
        rune_win_destroy(window);
    } else {
        fprintf(stderr, "%s\n", error);
    }
    PostThreadMessageW(thread_id, WM_QUIT, 0, 0);
    WaitForSingleObject(thread, 5000);
    CloseHandle(thread);
    CloseHandle(ready);
    return passed ? 0 : 1;
}
