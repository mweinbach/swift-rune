/* Real Rune windows and the ordinary desktop pump, on an unswitched test desktop. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <GL/gl.h>
#include <stdio.h>
#include "CRuneWin32.h"

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "line %d: %s (Win32 %lu)\n", __LINE__, #condition, GetLastError()); return 1; \
} } while (0)

typedef struct {
    RuneWinWindow *window;
    HWND hwnd;
    int frames, animate, saw_early_invalidation, failed_swap;
} View;

static double now_ms(void) {
    static LARGE_INTEGER frequency;
    LARGE_INTEGER ticks;
    if (!frequency.QuadPart) QueryPerformanceFrequency(&frequency);
    QueryPerformanceCounter(&ticks);
    return 1000.0 * (double)ticks.QuadPart / (double)frequency.QuadPart;
}

static void ask(View *view) {
    // Unlike mouse movement, wheel input does not arm an independent WM_MOUSELEAVE.
    SendMessageW(view->hwnd, WM_MOUSEWHEEL, MAKEWPARAM(0, WHEEL_DELTA), MAKELPARAM(12, 16));
}

static int32_t receive(void *context, const RuneWinEvent *event) {
    View *view = context;
    if (event->kind != RUNE_WIN_FRAME) return 0;
    if (++view->frames == 1) {
        glClearColor(.1f, .2f, .3f, 1);
        glClear(GL_COLOR_BUFFER_BIT);
        view->failed_swap = !rune_win_swap(view->window);
    }
    if (view->animate) {
        ask(view);
        if (GetUpdateRect(view->hwnd, NULL, FALSE)) ++view->saw_early_invalidation;
    }
    return -1;
}

static int open_view(View *view, const wchar_t *name, int x) {
    char error[256] = "";
    view->window = rune_win_create((const uint16_t *)name, 160, 100, 1, 1, 0, error, sizeof(error));
    if (!view->window) fprintf(stderr, "create: %s\n", error);
    CHECK(view->window);
    view->hwnd = rune_win_hwnd(view->window);
    CHECK(SetWindowPos(view->hwnd, HWND_TOP, x, 80, 0, 0, SWP_NOSIZE | SWP_NOACTIVATE));
    rune_win_enable_redraw_turns(view->window);
    rune_win_start(view->window, view, receive, 1, 1);
    CHECK(view->frames > 0 && !view->failed_swap);
    return 0;
}

static int drain_idle(void) {
    for (int i = 0; i < 2048; ++i) {
        int result = rune_win_pump_or_idle(1);
        if (result == RUNE_WIN_PUMP_IDLE) return 0;
        CHECK(result == 1);
    }
    fprintf(stderr, "message queue did not settle\n");
    return 1;
}

static int crowd(View *front, View *back) {
    front->animate = 1;
    const int front_start = front->frames;
    const int back_start = back->frames;
    ask(front);
    // Queued messages outrank WM_PAINT. Keep one ahead of every pump pass.
    for (int i = 0; i < 8; ++i) CHECK(PostMessageW(front->hwnd, WM_NULL, 0, 0));
    int turns = 0;
    double maximum_ms = 0;
    double minimum_ms = 500;
    for (int round = 0; round < 6; ++round) {
        const int before = back->frames;
        double first_ask = now_ms();
        ask(back);
        while (back->frames == before && now_ms() - first_ask < 500) {
            CHECK(PostMessageW(front->hwnd, WM_NULL, 0, 0));
            int32_t painted = 0;
            CHECK(rune_win_pump_turn(1, &painted) == 1 && !painted);
            ++turns;
            // Continuously arriving invalidations must retain the *oldest* request.
            ask(back);
            rune_win_end_redraw_turn(front->window, 1);
            rune_win_end_redraw_turn(back->window, 1);
        }
        double delay = now_ms() - first_ask;
        if (back->frames == before) fprintf(stderr, "rear window still starved at %.2f ms after %d turns\n", delay, turns);
        CHECK(back->frames == before + 1 && delay >= 16 && delay < 500);
        CHECK(!GetUpdateRect(back->hwnd, NULL, FALSE));
        MSG pending;
        CHECK(!PeekMessageW(&pending, back->hwnd, WM_PAINT, WM_PAINT, PM_NOREMOVE | PM_QS_PAINT));
        if (delay > maximum_ms) maximum_ms = delay;
        if (delay < minimum_ms) minimum_ms = delay;
    }
    front->animate = 0;
    CHECK(front->frames - front_start >= 3);
    CHECK(!front->saw_early_invalidation);
    rune_win_end_redraw_turn(front->window, 1);
    CHECK(back->frames == back_start + 6);
    printf("Six rear repaints across %d posted-message turns, %.2f to %.2f ms, %d front frames\n",
           turns, minimum_ms, maximum_ms, front->frames - front_start);
    CHECK(!drain_idle());
    return 0;
}

static int deferred_request(View *view) {
    const int before = view->frames;
    view->animate = 1;
    ask(view);
    CHECK(UpdateWindow(view->hwnd));
    CHECK(view->frames == before + 1 && !view->saw_early_invalidation);
    CHECK(!GetUpdateRect(view->hwnd, NULL, FALSE));
    view->animate = 0;
    rune_win_end_redraw_turn(view->window, 1);
    CHECK(GetUpdateRect(view->hwnd, NULL, FALSE));
    CHECK(!drain_idle());
    CHECK(view->frames == before + 2);

    // The last turn before GetMessage sleeps can itself force a paint. Any request
    // inside that paint must already be in User32's queue when the turn returns.
    view->animate = 1;
    ask(view);
    Sleep(35);
    rune_win_end_redraw_turn(view->window, 1);
    CHECK(view->frames == before + 3 && !view->saw_early_invalidation);
    CHECK(GetUpdateRect(view->hwnd, NULL, FALSE));
    view->animate = 0;
    CHECK(!drain_idle() && view->frames == before + 4);
    return 0;
}

static int visible_gates(View *view) {
    int before = view->frames;
    ask(view);
    Sleep(35);
    rune_win_end_redraw_turn(view->window, 0);
    CHECK(view->frames == before && GetUpdateRect(view->hwnd, NULL, FALSE));
    rune_win_end_redraw_turn(view->window, 1);
    CHECK(view->frames == before + 1 && !GetUpdateRect(view->hwnd, NULL, FALSE));

    rune_win_minimize(view->window);
    CHECK(IsIconic(view->hwnd));
    before = view->frames;
    ask(view);
    Sleep(35);
    rune_win_end_redraw_turn(view->window, 1);
    CHECK(view->frames == before);
    ShowWindow(view->hwnd, SW_RESTORE);
    CHECK(!IsIconic(view->hwnd));
    rune_win_show(view->window, 0);
    CHECK(!IsWindowVisible(view->hwnd));
    before = view->frames;
    ask(view);
    Sleep(35);
    rune_win_end_redraw_turn(view->window, 1);
    CHECK(view->frames == before);
    rune_win_show(view->window, 1);
    CHECK(IsWindowVisible(view->hwnd) && !drain_idle());
    CHECK(view->frames > before);
    return 0;
}

static DWORD WINAPI run(void *desktop) {
    CHECK(SetThreadDesktop(desktop));
    View back = {0}, front = {0};
    CHECK(!open_view(&back, L"Rune redraw rear", 50));
    CHECK(!open_view(&front, L"Rune redraw front", 250));
    CHECK(!drain_idle());
    CHECK(!crowd(&front, &back));
    CHECK(!deferred_request(&back));
    CHECK(!visible_gates(&back));
    rune_win_destroy(front.window);
    rune_win_destroy(back.window);
    puts("PASS Win32 turn-end redraw, fairness, visibility and single delivery");
    return 0;
}

int main(void) {
    wchar_t name[64];
    swprintf_s(name, ARRAYSIZE(name), L"RuneRedrawProbe-%lu", GetCurrentProcessId());
    HDESK desktop = CreateDesktopW(name, NULL, NULL, 0, GENERIC_ALL, NULL);
    CHECK(desktop);
    HANDLE worker = CreateThread(NULL, 0, run, desktop, 0, NULL);
    CHECK(worker && WaitForSingleObject(worker, 60000) == WAIT_OBJECT_0);
    DWORD code;
    CHECK(GetExitCodeThread(worker, &code));
    CloseHandle(worker);
    CHECK(CloseDesktop(desktop));
    return (int)code;
}
