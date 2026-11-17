/* From this directory in a Windows developer shell, `swift build`, then
   `clang probe.c -o .build/debug/overlay-test.exe -luser32`. Run overlay-test.exe
   with .build/debug as the working directory. The desktop is never switched to, and only the
   child's window receives messages. No system cursor movement or input injection. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <wchar.h>

struct Probe { DWORD pid; HWND overlay; };
static BOOL CALLBACK find_overlay(HWND hwnd, LPARAM arg) {
    struct Probe *test = (struct Probe *)arg;
    DWORD pid;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid != test->pid || !IsWindowVisible(hwnd)) return TRUE;
    wchar_t title[64] = {0};
    GetWindowTextW(hwnd, title, 64);
    if (wcscmp(title, L"Rune overlay test")) return TRUE;
    test->overlay = hwnd;
    return FALSE;
}

int main(void) {
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    HDESK original = GetThreadDesktop(GetCurrentThreadId());
    WCHAR name[80];
    swprintf_s(name, ARRAYSIZE(name), L"RuneOverlay-%lu", GetCurrentProcessId());
    HDESK desktop = CreateDesktopW(name, NULL, NULL, 0, GENERIC_ALL, NULL);
    if (!desktop || !SetThreadDesktop(desktop)) return 1;
    SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    STARTUPINFOW start = {.cb = sizeof(start), .lpDesktop = name};
    start.dwFlags = STARTF_USESTDHANDLES;
    start.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    start.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    start.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    PROCESS_INFORMATION proc = {0};
    wchar_t command[] = L"OverlayProbe.exe";
    int result = 1;
    if (!CreateProcessW(NULL, command, NULL, NULL, TRUE, 0, NULL, NULL, &start, &proc)) goto out;
    struct Probe test = {proc.dwProcessId, NULL};
    ULONGLONG end = GetTickCount64() + 70000;
    int reported = 0;
    while (GetTickCount64() < end && WaitForSingleObject(proc.hProcess, 20) == WAIT_TIMEOUT) {
        EnumDesktopWindows(desktop, find_overlay, (LPARAM)&test);
        if (!test.overlay) continue;
        HWND hwnd = test.overlay;
        RECT area;
        if (!GetClientRect(hwnd, &area)) continue;
        UINT dpi = GetDpiForWindow(hwnd);
        int inner = MulDiv(12, dpi, 96), outer = MulDiv(75, dpi, 96);
        POINT p = {inner, inner}, q = {outer, inner};
        ClientToScreen(hwnd, &p); ClientToScreen(hwnd, &q);
        DWORD_PTR in_hit, out_hit;
        if (!reported++) { fprintf(stderr, "overlay window found, client %ldx%ld dpi %u\n", area.right, area.bottom, dpi); }
        if (!SendMessageTimeoutW(hwnd, WM_NCHITTEST, 0, MAKELPARAM(p.x, p.y), SMTO_ABORTIFHUNG, 1000, &in_hit) ||
            !SendMessageTimeoutW(hwnd, WM_NCHITTEST, 0, MAKELPARAM(q.x, q.y), SMTO_ABORTIFHUNG, 1000, &out_hit) ||
            (LRESULT)in_hit != HTCLIENT || (LRESULT)out_hit != HTTRANSPARENT) continue;
        LONG_PTR ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        if (!(ex & WS_EX_TOOLWINDOW) || !(ex & WS_EX_LAYERED) || !(ex & WS_EX_NOACTIVATE) || !(ex & WS_EX_TOPMOST)) break;
        LPARAM point = MAKELPARAM(inner, inner);
        DWORD_PTR dispatched;
        if (!SendMessageTimeoutW(hwnd, WM_LBUTTONDOWN, MK_LBUTTON, point, SMTO_ABORTIFHUNG, 1000, &dispatched) ||
            !SendMessageTimeoutW(hwnd, WM_LBUTTONUP, 0, point, SMTO_ABORTIFHUNG, 1000, &dispatched)) break;
        printf("PASS nonactivating layered GPU window with selective hit testing at %u DPI, client=%ldx%ld\n", dpi, area.right, area.bottom);
        if (WaitForSingleObject(proc.hProcess, 10000) == WAIT_OBJECT_0) {
            DWORD status = 1;
            GetExitCodeProcess(proc.hProcess, &status);
            if (!status) result = 0;
        }
        break;
    }
    if (WaitForSingleObject(proc.hProcess, 0) != WAIT_OBJECT_0) {
        TerminateProcess(proc.hProcess, 2); WaitForSingleObject(proc.hProcess, 3000);
    }
    DWORD status = 1; GetExitCodeProcess(proc.hProcess, &status);
    fprintf(stderr, "OverlayProbe process returned 0x%lx\n", status);
    CloseHandle(proc.hProcess); CloseHandle(proc.hThread);
out:
    SetThreadDesktop(original);
    CloseDesktop(desktop);
    return result;
}
