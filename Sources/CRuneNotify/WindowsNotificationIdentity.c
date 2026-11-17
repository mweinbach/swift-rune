#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shobjidl.h>
#include <wchar.h>
#include <stdlib.h>
#include "RuneNotifyIdentity.h"

static const wchar_t app_key_prefix[] = L"Software\\Classes\\AppUserModelId\\";
static const wchar_t scheme_key_prefix[] = L"Software\\Classes\\";

static HRESULT write_value(HKEY parent, const wchar_t *path, const wchar_t *name, const wchar_t *value) {
    HKEY key;
    LSTATUS status = RegCreateKeyExW(parent, path, 0, NULL, 0, KEY_SET_VALUE, NULL, &key, NULL);
    if (status != ERROR_SUCCESS) return HRESULT_FROM_WIN32(status);
    if (value) {
        status = RegSetValueExW(key, name, 0, REG_SZ, (const BYTE *)value,
                                (DWORD)((wcslen(value) + 1) * sizeof(*value)));
    } else {
        status = RegDeleteValueW(key, name);
        if (status == ERROR_FILE_NOT_FOUND) status = ERROR_SUCCESS;
    }
    RegCloseKey(key);
    return HRESULT_FROM_WIN32(status);
}

static int valid_id(const wchar_t *id) {
    return id && id[0] && wcslen(id) <= 128 && !wcschr(id, L'\\');
}

static int valid_scheme(const wchar_t *s) {
    if (!s || wcslen(s) < 2 || wcslen(s) > 255 || !((s[0] >= L'a' && s[0] <= L'z') ||
            (s[0] >= L'A' && s[0] <= L'Z'))) return 0;
    for (; *s; ++s) {
        if (!((*s >= L'a' && *s <= L'z') || (*s >= L'A' && *s <= L'Z') ||
              (*s >= L'0' && *s <= L'9') || *s == L'.' || *s == L'-' || *s == L'+')) return 0;
    }
    return 1;
}

static HRESULT register_scheme(const wchar_t *scheme, const wchar_t *display_name) {
    wchar_t path[320];
    swprintf_s(path, 320, L"%ls%ls", scheme_key_prefix, scheme);
    size_t name_capacity = wcslen(display_name) + 5;
    wchar_t *description = calloc(name_capacity, sizeof(wchar_t));
    if (!description) return E_OUTOFMEMORY;
    swprintf_s(description, name_capacity, L"URL:%ls", display_name);
    HRESULT status = write_value(HKEY_CURRENT_USER, path, NULL, description);
    free(description);
    if (SUCCEEDED(status)) status = write_value(HKEY_CURRENT_USER, path, L"URL Protocol", L"");
    if (FAILED(status)) return status;

    const DWORD capacity = 32768; /* Maximum NT path length, including NUL. */
    wchar_t *executable = calloc(capacity, sizeof(wchar_t));
    wchar_t *command = calloc(capacity + 12, sizeof(wchar_t));
    if (!executable || !command) {
        free(executable);
        free(command);
        return E_OUTOFMEMORY;
    }
    DWORD length = GetModuleFileNameW(NULL, executable, capacity);
    if (!length || length >= capacity) {
        status = HRESULT_FROM_WIN32(length ? ERROR_INSUFFICIENT_BUFFER : GetLastError());
    } else {
        swprintf_s(path, 320, L"%ls%ls\\DefaultIcon", scheme_key_prefix, scheme);
        swprintf_s(command, capacity + 12, L"\"%ls\",0", executable);
        status = write_value(HKEY_CURRENT_USER, path, NULL, command);
        if (SUCCEEDED(status)) {
            swprintf_s(path, 320, L"%ls%ls\\shell\\open\\command", scheme_key_prefix, scheme);
            swprintf_s(command, capacity + 12, L"\"%ls\" \"%%1\"", executable);
            status = write_value(HKEY_CURRENT_USER, path, NULL, command);
        }
    }
    free(executable);
    free(command);
    return status;
}

int32_t rune_notify_win_identity(const wchar_t *id, const wchar_t *name, const wchar_t *icon,
                                 const wchar_t *scheme, int write_registry) {
    if (!valid_id(id) || (scheme && *scheme && !valid_scheme(scheme))) return E_INVALIDARG;
    if (write_registry) {
        wchar_t app_key[192];
        swprintf_s(app_key, 192, L"%ls%ls", app_key_prefix, id);
        const wchar_t *display_name = name && *name ? name : id;
        HRESULT status = write_value(HKEY_CURRENT_USER, app_key, L"DisplayName", display_name);
        if (SUCCEEDED(status)) status = write_value(HKEY_CURRENT_USER, app_key, L"IconUri", icon && *icon ? icon : NULL);
        if (SUCCEEDED(status) && scheme && *scheme) status = register_scheme(scheme, display_name);
        if (FAILED(status)) return status;
    }

    wchar_t *current = NULL;
    if (SUCCEEDED(GetCurrentProcessExplicitAppUserModelID(&current))) {
        int already_set = current && wcscmp(current, id) == 0;
        CoTaskMemFree(current);
        if (already_set) return S_OK;
    }
    return SetCurrentProcessExplicitAppUserModelID(id);
}

int rune_notify_win_has_activator(const wchar_t *id) {
    if (!valid_id(id)) return 0;
    wchar_t path[192], value[64];
    swprintf_s(path, 192, L"%ls%ls", app_key_prefix, id);
    DWORD bytes = sizeof(value);
    CLSID clsid;
    return RegGetValueW(HKEY_CURRENT_USER, path, L"CustomActivator", RRF_RT_REG_SZ, NULL, value, &bytes) == ERROR_SUCCESS &&
           SUCCEEDED(CLSIDFromString(value, &clsid));
}

int rune_notify_win_focused(void) {
    HWND window = GetForegroundWindow();
    DWORD pid = 0;
    return window && GetWindowThreadProcessId(window, &pid) && pid == GetCurrentProcessId();
}

static BOOL CALLBACK find_app_window(HWND hwnd, LPARAM result) {
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid != GetCurrentProcessId() || !IsWindowVisible(hwnd) || GetWindow(hwnd, GW_OWNER) ||
        (GetWindowLongW(hwnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW)) return TRUE;
    *(HWND *)result = hwnd;
    return FALSE;
}

void rune_notify_win_front(void) {
    HWND window = NULL;
    EnumWindows(find_app_window, (LPARAM)&window);
    if (!window) return;
    ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW);
    if (SetForegroundWindow(window)) return;
    DWORD thread = GetCurrentThreadId();
    DWORD foreground = GetWindowThreadProcessId(GetForegroundWindow(), NULL);
    if (foreground && foreground != thread && AttachThreadInput(thread, foreground, TRUE)) {
        BringWindowToTop(window);
        SetForegroundWindow(window);
        AttachThreadInput(thread, foreground, FALSE);
    }
}
#endif
