#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdlib.h>
#include <string.h>
#include "RuneDesktopHotkeys.h"

typedef struct Binding {
    uint32_t id;
    int slot;
    UINT modifiers, key;
    struct Binding *next;
} Binding;

typedef struct {
    RuneHotkeySink sink;
    void *context;
    HANDLE worker, stop, work, done;
    HDESK desktop;
    DWORD thread_id;
    CRITICAL_SECTION callers;
    /* The worker exclusively owns bindings and assigns the limited Win32 IDs. */
    Binding *bindings;
    int last_slot, release_on_exit;
    /* Callers serialize this request and wait for its reply before reusing it. */
    uint32_t request_id;
    UINT request_key, request_modifiers;
    int reply;
} Hotkeys;

static UINT virtual_key(const char *name, HKL layout) {
    if (!name || !*name) return 0;
    if (!name[1]) {
        static const char *const rows[] = {"1234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm"};
        static const UINT first_scan[] = {0x02, 0x10, 0x1e, 0x2c};
        for (int i = 0; i < 4; ++i) {
            const char *match = strchr(rows[i], name[0]);
            if (match) return MapVirtualKeyExW(first_scan[i] + (UINT)(match - rows[i]), MAPVK_VSC_TO_VK_EX, layout);
        }
    }
    if (name[0] == 'f' && name[1] >= '1' && name[1] <= '9') {
        char *end;
        long number = strtol(name + 1, &end, 10);
        if (!*end && number <= 24) return VK_F1 + (UINT)number - 1;
    }
    static const struct { const char *name; UINT scan; } keys[] = {
        {"escape", 0x01}, {"backspace", 0x0e}, {"tab", 0x0f}, {"enter", 0x1c},
        {"space", 0x39}, {"insert", 0xe052}, {"delete", 0xe053}, {"home", 0xe047},
        {"end", 0xe04f}, {"pageup", 0xe049}, {"pagedown", 0xe051}, {"left", 0xe04b},
        {"right", 0xe04d}, {"up", 0xe048}, {"down", 0xe050}, {"minus", 0x0c},
        {"equal", 0x0d}, {"comma", 0x33}, {"period", 0x34}, {"slash", 0x35},
        {"semicolon", 0x27}, {"quote", 0x28}, {"bracketleft", 0x1a}, {"bracketright", 0x1b},
        {"backslash", 0x2b}, {"backquote", 0x29}
    };
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); ++i)
        if (strcmp(name, keys[i].name) == 0) return MapVirtualKeyExW(keys[i].scan, MAPVK_VSC_TO_VK_EX, layout);
    return 0;
}

static int native_error(DWORD error) {
    if (error == ERROR_HOTKEY_ALREADY_REGISTERED) return RUNE_HOTKEY_CONFLICT;
    if (error == ERROR_ACCESS_DENIED) return RUNE_HOTKEY_DENIED;
    return RUNE_HOTKEY_FAILED;
}

static int change_binding(Hotkeys *host, uint32_t id, UINT key, UINT mods) {
    Binding **entry = &host->bindings;
    while (*entry && (*entry)->id != id) entry = &(*entry)->next;
    if (!key) {
        Binding *binding = *entry;
        if (!binding) return RUNE_HOTKEY_UNKNOWN_ID;
        if (!UnregisterHotKey(NULL, binding->slot)) return native_error(GetLastError());
        *entry = binding->next;
        free(binding);
        return RUNE_HOTKEY_OK;
    }
    if (*entry) return RUNE_HOTKEY_CONFLICT;
    for (Binding *binding = host->bindings; binding; binding = binding->next)
        if (binding->modifiers == mods && binding->key == key) return RUNE_HOTKEY_CONFLICT;
    for (int attempt = 0; attempt < 0xbfff; ++attempt) {
        host->last_slot = host->last_slot % 0xbfff + 1;
        Binding *binding = host->bindings;
        while (binding && binding->slot != host->last_slot) binding = binding->next;
        if (binding) continue;
        binding = malloc(sizeof(*binding));
        if (!binding) return RUNE_HOTKEY_FAILED;
        if (!RegisterHotKey(NULL, host->last_slot, mods | MOD_NOREPEAT, key)) {
            int result = native_error(GetLastError());
            free(binding);
            return result;
        }
        *binding = (Binding){id, host->last_slot, mods, key, host->bindings};
        host->bindings = binding;
        return RUNE_HOTKEY_OK;
    }
    return RUNE_HOTKEY_FAILED;
}

static void release_host(Hotkeys *host) {
    if (host->worker) CloseHandle(host->worker);
    if (host->stop) CloseHandle(host->stop);
    if (host->work) CloseHandle(host->work);
    if (host->done) CloseHandle(host->done);
    DeleteCriticalSection(&host->callers);
    free(host);
}

static DWORD WINAPI run_hotkeys(void *opaque) {
    Hotkeys *host = opaque;
    /* Match the window's desktop, including apps hosted on a private desktop. */
    if (!SetThreadDesktop(host->desktop)) {
        host->reply = native_error(GetLastError());
        SetEvent(host->done);
        return 0;
    }
    host->reply = RUNE_HOTKEY_OK;
    SetEvent(host->done);
    HANDLE handles[] = {host->stop, host->work};
    for (;;) {
        DWORD event = MsgWaitForMultipleObjectsEx(2, handles, INFINITE, QS_HOTKEY | QS_POSTMESSAGE, MWMO_INPUTAVAILABLE);
        if (event == WAIT_OBJECT_0 + 1) {
            host->reply = change_binding(host, host->request_id, host->request_key, host->request_modifiers);
            SetEvent(host->done);
        } else if (event == WAIT_OBJECT_0 + 2) {
            MSG message;
            if (!PeekMessageW(&message, NULL, 0, 0, PM_REMOVE) || message.message != WM_HOTKEY) continue;
            for (Binding *binding = host->bindings; binding; binding = binding->next) {
                if (binding->slot == (int)message.wParam && binding->key == HIWORD(message.lParam)
                    && binding->modifiers == LOWORD(message.lParam)) {
                    host->sink(host->context, binding->id, NULL);
                    break;
                }
            }
        } else {
            break;
        }
    }
    while (host->bindings) {
        Binding *binding = host->bindings;
        host->bindings = binding->next;
        UnregisterHotKey(NULL, binding->slot);
        free(binding);
    }
    if (host->release_on_exit) release_host(host);
    return 0;
}

void *rune_win_hotkeys_open(RuneHotkeySink sink, void *context, int *status) {
    if (status) *status = RUNE_HOTKEY_FAILED;
    if (!sink) return NULL;
    Hotkeys *host = calloc(1, sizeof(*host));
    if (!host) return NULL;
    InitializeCriticalSection(&host->callers);
    host->context = context;
    host->sink = sink;
    host->desktop = GetThreadDesktop(GetCurrentThreadId());
    host->stop = CreateEventW(NULL, TRUE, FALSE, NULL);
    host->work = CreateEventW(NULL, FALSE, FALSE, NULL);
    host->done = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (host->desktop && host->stop && host->work && host->done)
        host->worker = CreateThread(NULL, 0, run_hotkeys, host, 0, &host->thread_id);
    if (!host->worker) {
        release_host(host);
        return NULL;
    }
    WaitForSingleObject(host->done, INFINITE);
    if (host->reply != RUNE_HOTKEY_OK) {
        if (status) *status = host->reply;
        WaitForSingleObject(host->worker, INFINITE);
        release_host(host);
        return NULL;
    }
    if (status) *status = RUNE_HOTKEY_OK;
    return host;
}

static int request(Hotkeys *host, uint32_t id, UINT key, UINT mods) {
    if (!host) return RUNE_HOTKEY_FAILED;
    if (GetCurrentThreadId() == host->thread_id) return change_binding(host, id, key, mods);
    EnterCriticalSection(&host->callers);
    host->request_id = id;
    host->request_key = key;
    host->request_modifiers = mods;
    HANDLE handles[] = {host->done, host->worker};
    int result = RUNE_HOTKEY_FAILED;
    if (SetEvent(host->work) && WaitForMultipleObjects(2, handles, FALSE, INFINITE) == WAIT_OBJECT_0)
        result = host->reply;
    LeaveCriticalSection(&host->callers);
    return result;
}

int rune_win_hotkeys_register(void *manager, uint32_t id, uint8_t mods, const char *name) {
    UINT key = virtual_key(name, GetKeyboardLayout(0));
    if (!key || (mods & ~15u)) return RUNE_HOTKEY_INVALID;
    UINT mask = 0;
    if (mods & 1) mask |= MOD_CONTROL;
    if (mods & 2) mask |= MOD_ALT;
    if (mods & 4) mask |= MOD_SHIFT;
    if (mods & 8) mask |= MOD_WIN;
    return request(manager, id, key, mask);
}

int rune_win_hotkeys_unregister(void *manager, uint32_t id) {
    return request(manager, id, 0, 0);
}

void rune_win_hotkeys_close(void *manager) {
    Hotkeys *host = manager;
    if (!host) return;
    if (GetCurrentThreadId() == host->thread_id) {
        host->release_on_exit = 1;
        SetEvent(host->stop);
        return;
    }
    SetEvent(host->stop);
    WaitForSingleObject(host->worker, INFINITE);
    release_host(host);
}
#endif
