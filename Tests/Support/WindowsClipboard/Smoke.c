/*
 * Run in a Visual Studio developer prompt from the package root.
 * cl /std:c11 /I Sources/CRuneDesktopServices/include Tests/Support/WindowsClipboard/Smoke.c Sources/CRuneDesktopServices/storage.c Sources/CRuneDesktopServices/windows.c /Fe:clipboard-smoke.exe /link user32.lib gdi32.lib shell32.lib ole32.lib uuid.lib
 * The probe creates a new window station and verifies the switch before it
 * opens the clipboard. A window station has its own clipboard on Windows.
 */
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include "RuneDesktopServices.h"

#define CHECK(test) do { if (!(test)) { fprintf(stderr, "Failed at line %d: %s\n", __LINE__, #test); return 1; } } while (0)

static int contains(RuneMimeData *list, const char *type, const void *expected, size_t length) {
    for (size_t i = 0; i < rune_mime_count(list); ++i) {
        size_t size;
        const uint8_t *bytes = rune_mime_bytes(list, i, &size);
        if (!strcmp(type, rune_mime_type(list, i)) && size == length && !memcmp(bytes, expected, size))
            return 1;
    }
    return 0;
}

int main(void) {
    wchar_t name[80];
    swprintf_s(name, 80, L"RuneClipboardTest_%lu_%llu", GetCurrentProcessId(), GetTickCount64());
    HWINSTA station = CreateWindowStationW(name, 0, WINSTA_ALL_ACCESS, NULL);
    CHECK(station && SetProcessWindowStation(station));
    HDESK desktop = CreateDesktopW(L"Desktop", NULL, NULL, 0, GENERIC_ALL, NULL);
    CHECK(desktop && SetThreadDesktop(desktop));
    wchar_t active[128];
    DWORD size;
    CHECK(GetUserObjectInformationW(GetProcessWindowStation(), UOI_NAME, active, sizeof(active), &size));
    CHECK(!wcscmp(name, active));

    const char text[] = "Rune \xf0\x9f\xa6\x8a";
    const char html[] = "<p>Rune</p>";
    const uint8_t binary[] = {0, 127, 0, 209};
    const char path[] = "C:\\Rune\\sample.txt";
    RuneMimeData *list = rune_mime_create();
    CHECK(rune_mime_add(list, "text/plain;charset=utf-8", (const uint8_t *)text, strlen(text)));
    CHECK(rune_mime_add(list, "text/html", (const uint8_t *)html, strlen(html)));
    CHECK(rune_mime_add(list, "application/x-rune-windows-file-paths", (const uint8_t *)path, sizeof(path)));
    CHECK(rune_mime_add(list, "application/x-rune-test", binary, sizeof(binary)));

    const uint8_t rgba[] = {1,0,0,0, 1,0,0,0, 127,64,16,37};
    CHECK(rune_mime_add(list, "application/x-rune-windows-rgba8", rgba, sizeof(rgba)));
    int64_t revision = rune_clipboard_write(list, 1);
    CHECK(revision >= 0 && revision == rune_clipboard_revision());
    RuneMimeData *read = rune_clipboard_read();
    CHECK(contains(read, "text/plain;charset=utf-8", text, strlen(text)));
    CHECK(contains(read, "text/html", html, strlen(html)));
    CHECK(contains(read, "application/x-rune-test", binary, sizeof(binary)));
    CHECK(IsClipboardFormatAvailable(CF_DIBV5));
    CHECK(contains(read, "application/x-rune-windows-rgba8", rgba, sizeof(rgba)));
    CHECK(contains(read, "application/x-rune-windows-file-paths", path, sizeof(path)));
    rune_mime_free(read);
    CHECK(IsClipboardFormatAvailable(RegisterClipboardFormatW(L"ExcludeClipboardContentFromMonitorProcessing")));

    /* A second producer publishes exactly the same Unicode text through Win32. */
    HWND other = CreateWindowExW(0, L"STATIC", NULL, 0, 0, 0, 0, 0, HWND_MESSAGE, NULL, NULL, NULL);
    CHECK(other && OpenClipboard(other) && EmptyClipboard());
    const wchar_t wide_text[] = L"Rune \xd83e\xdd8a";
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, sizeof(wide_text));
    void *destination = memory ? GlobalLock(memory) : NULL;
    CHECK(destination);
    memcpy(destination, wide_text, sizeof(wide_text));
    GlobalUnlock(memory);
    CHECK(SetClipboardData(CF_UNICODETEXT, memory) && CloseClipboard());
    CHECK(!rune_clipboard_clear(revision));
    read = rune_clipboard_read();
    CHECK(contains(read, "text/plain;charset=utf-8", text, strlen(text)));
    rune_mime_free(read);

    revision = rune_clipboard_write(list, 0);
    CHECK(revision >= 0 && rune_clipboard_clear(revision));
    CHECK(!IsClipboardFormatAvailable(CF_UNICODETEXT));
    rune_mime_free(list);
    DestroyWindow(other);
    puts("Private Windows clipboard tests passed.");
    return 0;
}
