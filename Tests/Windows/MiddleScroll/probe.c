/* Build with clang probe.c -o middle-scroll-test.exe -luser32 and run it beside
   MiddleScrollProbe.exe. Creates an isolated desktop without switching to it. */
#define _CRT_SECURE_NO_WARNINGS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <math.h>
#include <wchar.h>

struct Probe { DWORD pid; HWND window; };
static BOOL CALLBACK find_window(HWND hwnd, LPARAM argument) {
    struct Probe *probe = (struct Probe *)argument;
    DWORD pid;
    wchar_t title[128] = {0};
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid != probe->pid || !IsWindowVisible(hwnd)) return TRUE;
    GetWindowTextW(hwnd, title, 128);
    if (wcscmp(title, L"Rune middle scroll probe") != 0) return TRUE;
    probe->window = hwnd;
    return FALSE;
}
static int sample(float *offset, int *pan) {
    FILE *file = fopen("middle-scroll-state.txt", "r");
    if (!file) return 0;
    int ok = fscanf(file, "%f %d", offset, pan) == 2;
    fclose(file);
    return ok;
}
static int wait_sample(float minimum, int expected, float *offset) {
    int pan;
    ULONGLONG until = GetTickCount64() + 6000;
    do {
        if (sample(offset, &pan) && *offset >= minimum && pan == expected) return 1;
        Sleep(20);
    } while (GetTickCount64() < until);
    fprintf(stderr, "No scroll sample offset >= %.2f with pan cursor %d\n", minimum, expected);
    return 0;
}
static int send(HWND hwnd, UINT message, WPARAM key, LPARAM data) {
    DWORD_PTR result;
    return SendMessageTimeoutW(hwnd, message, key, data, SMTO_ABORTIFHUNG, 2000, &result) != 0;
}
static int stable(float offset) {
    float next;
    int pan;
    Sleep(180);
    return sample(&next, &pan) && pan == 0 && fabsf(next - offset) < 0.05f;
}
int main(void) {
    wchar_t name[80], child[] = L"MiddleScrollProbe.exe";
    swprintf(name, 80, L"RuneMiddleScroll-%lu", GetCurrentProcessId());
    HDESK desktop = CreateDesktopW(name, NULL, NULL, 0, GENERIC_ALL, NULL);
    if (!desktop) return 2;
    HDESK original = GetThreadDesktop(GetCurrentThreadId());
    if (!SetThreadDesktop(desktop)) { CloseDesktop(desktop); return 2; }
    STARTUPINFOW startup = {sizeof(startup)};
    startup.lpDesktop = name;
    PROCESS_INFORMATION childInfo = {0};
    DeleteFileW(L"middle-scroll-state.txt");
    int result = 1;
    if (!CreateProcessW(NULL, child, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &childInfo)) goto done;
    struct Probe probe = {childInfo.dwProcessId, NULL};
    for (int i = 0; i < 3000 && !probe.window; ++i) {
        EnumDesktopWindows(desktop, find_window, (LPARAM)&probe);
        if (WaitForSingleObject(childInfo.hProcess, 20) == WAIT_OBJECT_0) break;
    }
    float start, held, released, latched, cancelled;
    if (!probe.window || !wait_sample(0, 0, &start)) goto close;
    HWND hwnd = probe.window;
    RECT r;
    if (!GetClientRect(hwnd, &r) || r.right < 80 || r.bottom < 80) goto close;
    LPARAM origin = MAKELPARAM(r.right / 2, r.bottom / 4);
    LPARAM away = MAKELPARAM(r.right / 2, r.bottom * 3 / 4);
    if (!send(hwnd, WM_MOUSEMOVE, 0, origin) ||
        !send(hwnd, WM_MBUTTONDOWN, MK_MBUTTON, origin) || !wait_sample(start, 1, &held) ||
        !send(hwnd, WM_MOUSEMOVE, MK_MBUTTON, away) || !wait_sample(start + 5, 1, &held) ||
        !send(hwnd, WM_MBUTTONUP, 0, away) || !wait_sample(held, 0, &released) || !stable(released)) goto close;
    if (!send(hwnd, WM_MOUSEMOVE, 0, origin) || !send(hwnd, WM_MBUTTONDOWN, MK_MBUTTON, origin) ||
        !send(hwnd, WM_MBUTTONUP, 0, origin) || !send(hwnd, WM_MOUSEMOVE, 0, away) ||
        !wait_sample(released + 5, 1, &latched)) goto close;
    LPARAM key = (LPARAM)((MapVirtualKeyW(VK_ESCAPE, MAPVK_VK_TO_VSC) << 16) | 1);
    if (!send(hwnd, WM_KEYDOWN, VK_ESCAPE, key) || !send(hwnd, WM_KEYUP, VK_ESCAPE, key | 0xc0000000UL) ||
        !wait_sample(latched, 0, &cancelled) || !stable(cancelled)) goto close;
    printf("PASS Windows pan cursor, held scroll %.2f -> %.2f, latched scroll %.2f -> %.2f, stable after release and Escape\n",
           start, released, released, cancelled);
    result = 0;
close:
    if (probe.window) PostMessageW(probe.window, WM_CLOSE, 0, 0);
    if (WaitForSingleObject(childInfo.hProcess, 3000) != WAIT_OBJECT_0) {
        TerminateProcess(childInfo.hProcess, 2);
        WaitForSingleObject(childInfo.hProcess, 3000);
        result = 1;
    } else {
        DWORD exitCode;
        if (!GetExitCodeProcess(childInfo.hProcess, &exitCode) || exitCode != 0) result = 1;
    }
    CloseHandle(childInfo.hProcess);
    CloseHandle(childInfo.hThread);
done:
    SetThreadDesktop(original);
    CloseDesktop(desktop);
    return result;
}
