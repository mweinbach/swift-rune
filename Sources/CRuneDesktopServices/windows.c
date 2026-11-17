#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include "services_internal.h"

#define RUNE_RGBA "application/x-rune-windows-rgba8"
#define RUNE_PATHS "application/x-rune-windows-file-paths"
static wchar_t *wide(const char *source) {
    if (!source) return NULL;
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, source, -1, NULL, 0);
    wchar_t *result = count ? malloc((size_t)count * sizeof(*result)) : NULL;
    if (result && !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, source, -1, result, count)) {
        free(result); return NULL;
    }
    return result;
}
static char *utf8(const wchar_t *source, int chars, int *count) {
    *count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, source, chars, NULL, 0, NULL, NULL);
    if (!*count && chars) return NULL;
    char *result = calloc((size_t)*count + 1, 1);
    if (result && *count && !WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, source, chars,
                                                  result, *count, NULL, NULL)) { free(result); return NULL; }
    return result;
}
static UINT clipboard_format(const char *type) {
    if (!strcmp(type, RUNE_PLAIN)) return CF_UNICODETEXT;
    if (!strcmp(type, RUNE_PATHS)) return CF_HDROP;
    if (!strcmp(type, RUNE_RGBA)) return CF_DIBV5;
    if (!strcmp(type, "text/html")) return RegisterClipboardFormatW(L"HTML Format");
    if (!strcmp(type, "text/rtf")) return RegisterClipboardFormatW(L"Rich Text Format");
    if (!strcmp(type, "image/png")) return RegisterClipboardFormatW(L"PNG");
    wchar_t *name = wide(type);
    UINT result = name ? RegisterClipboardFormatW(name) : 0;
    free(name);
    return result;
}
static int open_board(HWND owner) {
    for (int attempt = 0; attempt < 4; ++attempt) {
        if (OpenClipboard(owner)) return 1;
        if (attempt < 3) Sleep(2);
    }
    return 0;
}
static HGLOBAL block(const void *bytes, size_t length, size_t terminator) {
    HGLOBAL handle = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, length + terminator ? length + terminator : 1);
    void *out = handle ? GlobalLock(handle) : NULL;
    if (!out) { if (handle) GlobalFree(handle); return NULL; }
    if (length) memcpy(out, bytes, length);
    GlobalUnlock(handle);
    return handle;
}
/* Input is a list of NUL-delimited UTF-8 file paths; DROPFILES takes a
   double-NUL-terminated UTF-16 list. */
static HGLOBAL files_block(const struct RuneMimeEntry *entry) {
    if (!entry->length || entry->bytes[entry->length - 1] != 0) return NULL;
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, (const char *)entry->bytes,
                                     (int)entry->length, NULL, 0);
    if (!count) return NULL;
    size_t bytes = sizeof(DROPFILES) + ((size_t)count + 1) * sizeof(wchar_t);
    HGLOBAL handle = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, bytes);
    DROPFILES *drop = handle ? GlobalLock(handle) : NULL;
    if (!drop) { if (handle) GlobalFree(handle); return NULL; }
    drop->pFiles = sizeof(*drop);
    drop->fWide = TRUE;
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, (const char *)entry->bytes,
                        (int)entry->length, (wchar_t *)(drop + 1), count);
    GlobalUnlock(handle);
    return handle;
}
/* Internal RGBA entry holds two little-endian UInt32 dimensions followed
   by straight-alpha pixels. CF_DIBV5 is DWORD-aligned BGRA with explicit
   channel masks and a negative height for top-down rows. */
static HGLOBAL dib_block(const struct RuneMimeEntry *entry) {
    if (entry->length < 8) return NULL;
    uint32_t dimensions[2];
    memcpy(dimensions, entry->bytes, sizeof(dimensions));
    const uint64_t pixels = (uint64_t)dimensions[0] * dimensions[1];
    if (!pixels || pixels > (RUNE_CLIPBOARD_LIMIT - 8) / 4 || pixels * 4 != entry->length - 8) return NULL;
    size_t length = (size_t)pixels * 4;
    HGLOBAL handle = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, sizeof(BITMAPV5HEADER) + length);
    BITMAPV5HEADER *header = handle ? GlobalLock(handle) : NULL;
    if (!header) { if (handle) GlobalFree(handle); return NULL; }
    header->bV5Size = sizeof(*header); header->bV5Width = dimensions[0]; header->bV5Height = -(LONG)dimensions[1];
    header->bV5Planes = 1; header->bV5BitCount = 32; header->bV5SizeImage = (DWORD)length;
    header->bV5Compression = BI_BITFIELDS;
    header->bV5RedMask = 0x00ff0000; header->bV5GreenMask = 0x0000ff00;
    header->bV5BlueMask = 0x000000ff; header->bV5AlphaMask = 0xff000000;
    header->bV5CSType = LCS_sRGB; header->bV5Intent = LCS_GM_IMAGES;
    const uint8_t *rgba = entry->bytes + 8;
    uint8_t *bgra = (uint8_t *)(header + 1);
    for (size_t i = 0; i < length; i += 4) {
        bgra[i] = rgba[i+2]; bgra[i+1] = rgba[i+1]; bgra[i+2] = rgba[i]; bgra[i+3] = rgba[i+3];
    }
    GlobalUnlock(handle);
    return handle;
}
/* Most Win32 drawing tools publish DIBV5 directly. Keep its alpha channel
   and native row orientation before using GDI for older bitmap formats. */
static int copy_dibv5(RuneMimeData *list) {
    HGLOBAL memory = GetClipboardData(CF_DIBV5);
    size_t capacity = memory ? GlobalSize(memory) : 0;
    const BITMAPV5HEADER *h = capacity >= sizeof(*h) ? GlobalLock(memory) : NULL;
    if (!h) return 0;
    int copied = 0;
    if (h->bV5Size != sizeof(*h) || h->bV5Planes != 1 || h->bV5BitCount != 32 ||
        h->bV5Compression != BI_BITFIELDS || h->bV5ClrUsed || h->bV5ProfileSize ||
        h->bV5Width <= 0 || !h->bV5Height || h->bV5RedMask != 0x00ff0000 ||
        h->bV5GreenMask != 0x0000ff00 || h->bV5BlueMask != 0x000000ff ||
        (h->bV5AlphaMask && h->bV5AlphaMask != 0xff000000)) goto done;
    uint32_t width = (uint32_t)h->bV5Width;
    uint32_t height = (uint32_t)(h->bV5Height < 0 ? -(int64_t)h->bV5Height : h->bV5Height);
    uint64_t pixels = (uint64_t)width * height;
    if (pixels > (RUNE_CLIPBOARD_LIMIT - 8) / 4 || pixels * 4 > capacity - sizeof(*h)) goto done;
    size_t stride = (size_t)width * 4, length = (size_t)pixels * 4;
    uint8_t *buffer = malloc(8 + length);
    if (!buffer) goto done;
    memcpy(buffer, &width, 4); memcpy(buffer + 4, &height, 4);
    for (uint32_t y = 0; y < height; ++y) {
        const uint8_t *src = (const uint8_t *)(h + 1) + (h->bV5Height < 0 ? y : height - 1 - y) * stride;
        uint8_t *dst = buffer + 8 + y * stride;
        for (size_t i = 0; i < stride; i += 4) {
            dst[i] = src[i+2]; dst[i+1] = src[i+1]; dst[i+2] = src[i];
            dst[i+3] = h->bV5AlphaMask ? src[i+3] : 255;
        }
    }
    copied = rune_mime_add(list, RUNE_RGBA, buffer, 8 + length);
    free(buffer);
done:
    GlobalUnlock(memory);
    return copied;
}
static void copy_bitmap(RuneMimeData *list) {
    HBITMAP bitmap = GetClipboardData(CF_BITMAP);
    BITMAP desc;
    if (!bitmap || !GetObjectW(bitmap, sizeof(desc), &desc) || desc.bmWidth <= 0 || desc.bmHeight <= 0) return;
    uint32_t width = (uint32_t)desc.bmWidth, height = (uint32_t)desc.bmHeight;
    uint64_t pixels = (uint64_t)width * height;
    if (pixels > (RUNE_CLIPBOARD_LIMIT - 8) / 4) return;
    size_t length = (size_t)pixels * 4;
    uint8_t *buffer = malloc(8 + length);
    if (!buffer) return;
    memcpy(buffer, &width, 4); memcpy(buffer + 4, &height, 4);
    BITMAPINFO info = {0};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = (LONG)width; info.bmiHeader.biHeight = -(LONG)height;
    info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32; info.bmiHeader.biCompression = BI_RGB;
    HDC dc = GetDC(NULL);
    int rows = dc ? GetDIBits(dc, bitmap, 0, height, buffer + 8, &info, DIB_RGB_COLORS) : 0;
    if (dc) ReleaseDC(NULL, dc);
    if (rows == (int)height) {
        for (size_t i = 8; i < 8 + length; i += 4) {
            uint8_t b = buffer[i]; buffer[i] = buffer[i+2]; buffer[i+2] = b;
            /* GDI's BI_RGB fourth channel is reserved. */
            buffer[i+3] = 255;
        }
        rune_mime_add(list, RUNE_RGBA, buffer, length + 8);
    }
    free(buffer);
}
struct Slot { UINT format; HGLOBAL memory; };
struct SizeTag { uint32_t format, length; };
static UINT token_format(void) { return RegisterClipboardFormatW(L"Rune clipboard write identity"); }
static UINT lengths_format(void) { return RegisterClipboardFormatW(L"Rune MIME byte lengths"); }
/* Win32 may round up GlobalAlloc's size; keep exact lengths without wrapping
   the public representation that external applications consume. */
int64_t rune_clipboard_write(const RuneMimeData *list, int concealed) {
    if (!list || !list->count) return -1;
    struct Slot slots[RUNE_CLIPBOARD_TYPES + 5] = {{0}};
    struct SizeTag lengths[RUNE_CLIPBOARD_TYPES] = {{0}};
    GUID token;
    if (FAILED(CoCreateGuid(&token))) return -1;
    size_t n = 0;
    int64_t result = -1;
    HWND temporary = NULL;
    for (size_t i = 0; i < list->count; ++i) {
        const struct RuneMimeEntry *entry = &list->entries[i];
        UINT format = clipboard_format(entry->type);
        HGLOBAL memory = NULL;
        if (format == CF_UNICODETEXT) {
            wchar_t *value = wide((const char *)entry->bytes);
            if (value) { memory = block(value, wcslen(value) * sizeof(*value), sizeof(*value)); free(value); }
        } else if (format == CF_HDROP) {
            memory = files_block(entry);
        } else if (format == CF_DIBV5) {
            memory = dib_block(entry);
        } else if (format) {
            memory = block(entry->bytes, entry->length, 1);
        }
        if (!memory) goto cleanup;
        slots[n] = (struct Slot){format, memory};
        lengths[n++] = (struct SizeTag){format, (uint32_t)entry->length};
    }
    size_t entries = n;
    slots[n++] = (struct Slot){token_format(), block(&token, sizeof(token), 0)};
    slots[n++] = (struct Slot){lengths_format(), block(lengths, entries * sizeof(*lengths), 0)};
    if (concealed) {
        DWORD zero = 0;
        slots[n++] = (struct Slot){RegisterClipboardFormatW(L"CanIncludeInClipboardHistory"), block(&zero, sizeof(zero), 0)};
        slots[n++] = (struct Slot){RegisterClipboardFormatW(L"CanUploadToCloudClipboard"), block(&zero, sizeof(zero), 0)};
        slots[n++] = (struct Slot){RegisterClipboardFormatW(L"ExcludeClipboardContentFromMonitorProcessing"), block(NULL, 0, 1)};
    }
    for (size_t i = 0; i < n; ++i) if (!slots[i].format || !slots[i].memory) goto cleanup;
    HWND owner = GetActiveWindow();
    if (!owner) { temporary = CreateWindowExW(0, L"STATIC", NULL, 0, 0, 0, 0, 0, HWND_MESSAGE, NULL, NULL, NULL); owner = temporary; }
    if (!owner || !open_board(owner)) goto cleanup;
    if (EmptyClipboard()) {
        for (size_t i = 0; i < n; ++i) {
            if (!SetClipboardData(slots[i].format, slots[i].memory)) { EmptyClipboard(); goto close; }
            slots[i].memory = NULL;
        }
        result = GetClipboardSequenceNumber();
    }
close:
    CloseClipboard();
cleanup:
    if (temporary) DestroyWindow(temporary);
    if (result >= 0) {
        /* CloseClipboard may add synthesized formats and advance the Win32
           sequence. Reopen, verify this exact write survived, and take the
           sequence while other writers are excluded. */
        result = -1;
        if (open_board(NULL)) {
            HGLOBAL memory = GetClipboardData(token_format());
            const GUID *stored = memory && GlobalSize(memory) >= sizeof(token) ? GlobalLock(memory) : NULL;
            if (stored) {
                int matches = !memcmp(stored, &token, sizeof(token));
                GlobalUnlock(memory);
                if (matches) {
                    DWORD sequence = GetClipboardSequenceNumber();
                    if (sequence) result = sequence;
                    else if (concealed) EmptyClipboard();
                }
            }
            CloseClipboard();
        }
    }
    for (size_t i = 0; i < n; ++i) if (slots[i].memory) GlobalFree(slots[i].memory);
    return result;
}
static void copy_paths(RuneMimeData *list, HDROP drop) {
    UINT count = DragQueryFileW(drop, 0xffffffff, NULL, 0);
    if (!count || count > 65536) return;
    char *paths = NULL;
    size_t size = 0;
    for (UINT i = 0; i < count; ++i) {
        UINT chars = DragQueryFileW(drop, i, NULL, 0);
        if (!chars || chars > 32767) goto done;
        wchar_t *name = calloc((size_t)chars + 1, sizeof(*name));
        if (!name) goto done;
        UINT read = DragQueryFileW(drop, i, name, chars + 1);
        int bytes = 0;
        char *path = read ? utf8(name, (int)read, &bytes) : NULL;
        free(name);
        if (!path || (size_t)bytes + 1 > RUNE_CLIPBOARD_LIMIT - size) { free(path); goto done; }
        char *next = realloc(paths, size + (size_t)bytes + 1);
        if (!next) { free(path); goto done; }
        paths = next;
        memcpy(paths + size, path, (size_t)bytes + 1);
        size += (size_t)bytes + 1;
        free(path);
    }
    rune_mime_add(list, RUNE_PATHS, (const uint8_t *)paths, size);
done:
    free(paths);
}
RuneMimeData *rune_clipboard_read(void) {
    RuneMimeData *list = rune_mime_create();
    if (!list || !open_board(NULL)) return list;
    UINT size_fmt = lengths_format();
    HGLOBAL sizes_handle = GetClipboardData(size_fmt);
    const struct SizeTag *sizes = sizes_handle ? GlobalLock(sizes_handle) : NULL;
    size_t nsizes = sizes ? GlobalSize(sizes_handle) / sizeof(*sizes) : 0;
    if (nsizes > RUNE_CLIPBOARD_TYPES) nsizes = 0;
    /* CF_UNICODETEXT may be synthesized from an ANSI source. Request it even
       when it was not one of the originally advertised formats. */
    HGLOBAL text = GetClipboardData(CF_UNICODETEXT);
    const wchar_t *wtext = text ? GlobalLock(text) : NULL;
    if (wtext) {
        size_t capacity = GlobalSize(text) / sizeof(*wtext);
        if (capacity <= RUNE_CLIPBOARD_LIMIT / sizeof(*wtext)) {
            size_t chars = 0;
            while (chars < capacity && wtext[chars]) ++chars;
            int count = 0;
            char *value = utf8(wtext, (int)chars, &count);
            if (value) { rune_mime_add(list, RUNE_PLAIN, (uint8_t *)value, count); free(value); }
        }
        GlobalUnlock(text);
    }
    HDROP drop = GetClipboardData(CF_HDROP);
    if (drop) copy_paths(list, drop);
    UINT format = 0;
    while ((format = EnumClipboardFormats(format)) && list->count < RUNE_CLIPBOARD_TYPES) {
        if (format < 0xc000 || format == size_fmt) continue;
        wchar_t name[256];
        int length = GetClipboardFormatNameW(format, name, 256);
        if (!length) continue;
        int bytes = 0;
        char *type = utf8(name, length, &bytes);
        if (!type) continue;
        const char *mime = type;
        if (!strcmp(type, "HTML Format")) mime = "text/html";
        else if (!strcmp(type, "Rich Text Format")) mime = "text/rtf";
        else if (!strcmp(type, "PNG")) mime = "image/png";
        else if (!strcmp(type, "ExcludeClipboardContentFromMonitorProcessing")) mime = RUNE_CONCEALED;
        else if (!strchr(type, '/') && strcmp(type, RUNE_CONCEALED)) { free(type); continue; }
        HGLOBAL memory = GetClipboardData(format);
        size_t size = memory ? GlobalSize(memory) : 0;
        if (size <= RUNE_CLIPBOARD_LIMIT && memory && !rune_mime_find(list, mime)) {
            const uint8_t *data = GlobalLock(memory);
            if (data) {
                for (size_t j = 0; j < nsizes; ++j)
                    if (sizes[j].format == format && sizes[j].length <= size) { size = sizes[j].length; break; }
                if (!strncmp(mime, "text/", 5)) {
                    const uint8_t *end = memchr(data, 0, size);
                    if (end) size = (size_t)(end - data);
                }
                rune_mime_add(list, mime, data, size);
                GlobalUnlock(memory);
            }
        }
        free(type);
    }
    if (!rune_mime_find(list, "image/png") && !copy_dibv5(list)) copy_bitmap(list);
    if (sizes) GlobalUnlock(sizes_handle);
    CloseClipboard();
    return list;
}
int64_t rune_clipboard_revision(void) {
    DWORD sequence = GetClipboardSequenceNumber();
    return sequence ? (int64_t)sequence : -1;
}
int rune_clipboard_clear(int64_t expected) {
    if (expected == 0) return 0;
    if (!open_board(NULL)) return 0;
    int cleared = (expected < 0 || (int64_t)GetClipboardSequenceNumber() == expected) && EmptyClipboard();
    CloseClipboard();
    return cleared;
}
int rune_desktop_open_url(const char *url) {
    wchar_t *link = wide(url);
    if (!link) return 0;
    INT_PTR result = (INT_PTR)ShellExecuteW(GetActiveWindow(), L"open", link, NULL, NULL, SW_SHOWNORMAL);
    free(link);
    return result > 32;
}
static HRESULT add_item(RuneDesktopPicker *picker, IShellItem *item) {
    wchar_t *path = NULL;
    HRESULT hr = IShellItem_GetDisplayName(item, SIGDN_FILESYSPATH, &path);
    if (SUCCEEDED(hr)) {
        int count;
        char *name = utf8(path, -1, &count);
        if (!name || !rune_picker_add_path(picker, name)) hr = E_OUTOFMEMORY;
        free(name);
        CoTaskMemFree(path);
    }
    return hr;
}
int rune_picker_show(RuneDesktopPicker *picker, int save, int folders, int multiple,
                     const char *title, const char *directory, const char *filename) {
    if (!picker) return -1;
    HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    if (FAILED(hr)) return -1;
    IFileDialog *dialog = NULL;
    IShellItem *item = NULL;
    IFileOpenDialog *open = NULL;
    IShellItemArray *items = NULL;
    const size_t count = folders ? 0 : picker->filters->count;
    COMDLG_FILTERSPEC *filters = count ? calloc(count, sizeof(*filters)) : NULL;
    wchar_t *wide_title = wide(title), *wide_dir = wide(directory), *wide_name = wide(filename);
    hr = CoCreateInstance(save ? &CLSID_FileSaveDialog : &CLSID_FileOpenDialog, NULL,
                          CLSCTX_INPROC_SERVER, &IID_IFileDialog, (void **)&dialog);
    if (FAILED(hr)) goto done;
    FILEOPENDIALOGOPTIONS flags;
    hr = IFileDialog_GetOptions(dialog, &flags);
    if (FAILED(hr)) goto done;
    flags |= FOS_FORCEFILESYSTEM | FOS_NOCHANGEDIR;
    if (folders) flags |= FOS_PICKFOLDERS;
    if (multiple && !save && !folders) flags |= FOS_ALLOWMULTISELECT;
    hr = IFileDialog_SetOptions(dialog, flags);
    if (FAILED(hr)) goto done;
    if (wide_title && *wide_title) IFileDialog_SetTitle(dialog, wide_title);
    if (wide_name && *wide_name && save) IFileDialog_SetFileName(dialog, wide_name);
    if (wide_dir && *wide_dir) {
        IShellItem *folder = NULL;
        if (SUCCEEDED(SHCreateItemFromParsingName(wide_dir, NULL, &IID_IShellItem, (void **)&folder))) {
            IFileDialog_SetFolder(dialog, folder);
            IShellItem_Release(folder);
        }
    }
    if (count) {
        if (!filters) { hr = E_OUTOFMEMORY; goto done; }
        for (size_t i = 0; i < count; ++i) {
            filters[i].pszName = wide(picker->filters->entries[i].type);
            filters[i].pszSpec = wide((const char *)picker->filters->entries[i].bytes);
            if (!filters[i].pszName || !filters[i].pszSpec) { hr = E_OUTOFMEMORY; goto done; }
        }
        hr = IFileDialog_SetFileTypes(dialog, (UINT)count, filters);
        if (FAILED(hr)) goto done;
    }
    hr = IFileDialog_Show(dialog, GetActiveWindow());
    if (FAILED(hr)) goto done;
    if (multiple && !save && !folders) {
        hr = IFileDialog_QueryInterface(dialog, &IID_IFileOpenDialog, (void **)&open);
        if (FAILED(hr)) goto done;
        hr = IFileOpenDialog_GetResults(open, &items);
        if (FAILED(hr)) goto done;
        DWORD n = 0;
        hr = IShellItemArray_GetCount(items, &n);
        for (DWORD i = 0; SUCCEEDED(hr) && i < n; ++i) {
            hr = IShellItemArray_GetItemAt(items, i, &item);
            if (SUCCEEDED(hr)) { hr = add_item(picker, item); IShellItem_Release(item); item = NULL; }
        }
    } else {
        hr = IFileDialog_GetResult(dialog, &item);
        if (SUCCEEDED(hr)) hr = add_item(picker, item);
    }
done:
    if (item) IShellItem_Release(item);
    if (items) IShellItemArray_Release(items);
    if (open) IFileOpenDialog_Release(open);
    if (dialog) IFileDialog_Release(dialog);
    if (filters) for (size_t i = 0; i < count; ++i) {
        free((void *)filters[i].pszName); free((void *)filters[i].pszSpec);
    }
    free(filters); free(wide_title); free(wide_dir); free(wide_name);
    CoUninitialize();
    return hr == HRESULT_FROM_WIN32(ERROR_CANCELLED) ? 0 : SUCCEEDED(hr) && picker->count ? 1 : -1;
}
#endif
