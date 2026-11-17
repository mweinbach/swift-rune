/* Run from the repository root in a Visual Studio Developer PowerShell:
   cl /nologo /std:c11 /W4 /I Sources/CRuneDesktopServices/include Tests/Windows/GlobalShortcuts/probe.c user32.lib /Fo"$env:TEMP/RuneHotkeys.obj" /Fe"$env:TEMP/RuneHotkeys.exe"
   & "$env:TEMP/RuneHotkeys.exe"

   Include the implementation to address the private worker queue without sending
   keyboard input to the interactive desktop. All registrations use real User32. */
#include "../../../Sources/CRuneDesktopServices/WindowsHotkeys.c"
#include <stdio.h>
#define EXPECT(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL line=%d %s win32=%lu\n", __LINE__, #condition, GetLastError()); \
        return 1; \
    } \
} while (0)

typedef struct {
    HANDLE fired;
    LONG calls;
    uint32_t id;
} Sink;

static void receive(void *ctx, uint32_t id, const char *token) {
    Sink *sink = ctx;
    if (token) return;
    sink->id = id;
    InterlockedIncrement(&sink->calls);
    SetEvent(sink->fired);
}

int main(void) {
    wchar_t name[72], actual[72];
    DWORD length = 0;
    swprintf_s(name, 72, L"RuneHotkeyCheck_%lu_%llu", GetCurrentProcessId(), GetTickCount64());
    HDESK desktop = CreateDesktopW(name, NULL, NULL, 0, DESKTOP_CREATEWINDOW | DESKTOP_READOBJECTS | DESKTOP_WRITEOBJECTS, NULL);
    EXPECT(desktop && SetThreadDesktop(desktop));
    EXPECT(GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()), UOI_NAME, actual, sizeof(actual), &length) && !wcscmp(actual, name));
    Sink sink = {CreateEventW(NULL, FALSE, FALSE, NULL), 0, 0};
    EXPECT(sink.fired);
    int status = -1;
    Hotkeys *first = rune_win_hotkeys_open(receive, &sink, &status);
    EXPECT(first && status == RUNE_HOTKEY_OK);
    Hotkeys *other = rune_win_hotkeys_open(receive, &sink, &status);
    EXPECT(other && status == RUNE_HOTKEY_OK);
    const uint32_t id = 0xfeccbbaa;
    EXPECT(rune_win_hotkeys_register(first, id, 7, "f13") == RUNE_HOTKEY_OK);
    EXPECT(rune_win_hotkeys_register(first, id, 3, "f14") == RUNE_HOTKEY_CONFLICT);
    EXPECT(rune_win_hotkeys_register(other, 7, 7, "f13") == RUNE_HOTKEY_CONFLICT);
    EXPECT(!RegisterHotKey(NULL, 127, MOD_NOREPEAT | MOD_CONTROL | MOD_SHIFT | MOD_ALT, VK_F13));
    EXPECT(GetLastError() == ERROR_HOTKEY_ALREADY_REGISTERED);
    EXPECT(rune_win_hotkeys_register(other, 8, 7, "f25") == RUNE_HOTKEY_INVALID);
    EXPECT(rune_win_hotkeys_register(other, 8, 240, "f13") == RUNE_HOTKEY_INVALID);
    EXPECT(rune_win_hotkeys_unregister(other, 1234) == RUNE_HOTKEY_UNKNOWN_ID);
    /* The desktop is never made interactive. Deliver exactly the OS message
       to this fixture's queue without injecting keystrokes into any desktop. */
    EXPECT(PostThreadMessageW(first->thread_id, WM_HOTKEY, (WPARAM)first->last_slot,
                              MAKELPARAM(MOD_CONTROL | MOD_SHIFT | MOD_ALT, VK_F13)));
    EXPECT(WaitForSingleObject(sink.fired, 5000) == WAIT_OBJECT_0 && sink.calls == 1 && sink.id == id);
    EXPECT(rune_win_hotkeys_unregister(first, id) == RUNE_HOTKEY_OK);
    EXPECT(rune_win_hotkeys_register(other, 8, 7, "f13") == RUNE_HOTKEY_OK);
    EXPECT(rune_win_hotkeys_register(first, 9, 5, "slash") == RUNE_HOTKEY_OK);
    EXPECT(rune_win_hotkeys_register(first, 10, 5, "left") == RUNE_HOTKEY_OK);
    EXPECT(rune_win_hotkeys_register(first, 11, 5, "q") == RUNE_HOTKEY_OK);
    rune_win_hotkeys_close(other);
    EXPECT(RegisterHotKey(NULL, 127, MOD_NOREPEAT | MOD_CONTROL | MOD_SHIFT | MOD_ALT, VK_F13));
    EXPECT(UnregisterHotKey(NULL, 127));
    rune_win_hotkeys_close(first);
    CloseHandle(sink.fired);
    puts("PASS private desktop global registration, competing native/wrapper conflicts, full 32-bit delivery through queued WM_HOTKEY, physical punctuation/letters/navigation, unregistration and close releases the native chord");
    return 0;
}
