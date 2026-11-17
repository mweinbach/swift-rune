#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <stdio.h>
#include <wchar.h>
#include "StartupDriver.h"

static HWND window;
static int paint_depth;

static LRESULT CALLBACK observe(HWND hwnd, UINT message, WPARAM w, LPARAM l,
                                UINT_PTR id, DWORD_PTR data) {
    if (message == WM_PAINT) ++paint_depth;
    LRESULT result = DefSubclassProc(hwnd, message, w, l);
    if (message == WM_PAINT) --paint_depth;
    if (message == WM_NCDESTROY) {
        RemoveWindowSubclass(hwnd, observe, id);
        window = NULL;
    }
    return result;
}

int startup_observe_paint(void) {
    window = FindWindowW(L"RuneSwiftOpenGLWindow", L"Rune startup ordering fixture");
    return window && GetWindowThreadProcessId(window, NULL) == GetCurrentThreadId() &&
           SetWindowSubclass(window, observe, 1, 0);
}
int startup_is_painting(void) { return paint_depth != 0; }
int startup_post_key(void) {
    return window && PostMessageW(window, WM_KEYDOWN, VK_F6,
                                  1 | (MapVirtualKeyW(VK_F6, MAPVK_VK_TO_VSC) << 16));
}

// Run the public app with its own desktop. No foreground or global input state is changed.
int startup_launch_child(const wchar_t *mode) {
    wchar_t exe[MAX_PATH], command[2 * MAX_PATH], name[64];
    DWORD n = GetModuleFileNameW(NULL, exe, MAX_PATH);
    if (!n || n >= MAX_PATH) return 1;
    swprintf_s(command, ARRAYSIZE(command), L"\"%ls\" %ls", exe, mode);
    swprintf_s(name, ARRAYSIZE(name), L"RuneStartup-%lu", GetCurrentProcessId());
    HDESK desktop = CreateDesktopW(name, NULL, NULL, 0, GENERIC_ALL, NULL);
    if (!desktop) return 1;
    STARTUPINFOW startup = {.cb = sizeof(startup), .lpDesktop = name};
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    PROCESS_INFORMATION process = {0};
    DWORD code = 1;
    if (CreateProcessW(exe, command, NULL, NULL, TRUE, 0, NULL, NULL, &startup, &process)) {
        if (WaitForSingleObject(process.hProcess, 45000) == WAIT_OBJECT_0) {
            GetExitCodeProcess(process.hProcess, &code);
        } else {
            fprintf(stderr, "Startup app timed out in %ls\n", mode);
            TerminateProcess(process.hProcess, 1);
            WaitForSingleObject(process.hProcess, 3000);
        }
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
    }
    CloseDesktop(desktop);
    return (int)code;
}
