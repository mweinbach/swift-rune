#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <ole2.h>
#include <shlobj.h>
#include <new>
#include <stdint.h>
#include "RuneDragSource.h"

namespace {

constexpr UINT_PTR subclassID = 0x52554e44;
thread_local bool inDrag = false;
thread_local bool muteLocalDrops = false;

UINT beginMessage() {
    static const UINT message = RegisterWindowMessageW(L"SwiftRune.DragSource.Begin");
    return message;
}

bool setBytes(IDataObject *data, CLIPFORMAT format, const void *bytes, size_t count,
              const void *prefix = nullptr, size_t prefixSize = 0) {
    if (!format || !bytes || !count || count > SIZE_MAX - prefixSize) return false;
    HGLOBAL block = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, prefixSize + count);
    if (!block) return false;
    auto output = static_cast<uint8_t *>(GlobalLock(block));
    if (!output) { GlobalFree(block); return false; }
    if (prefixSize) memcpy(output, prefix, prefixSize);
    memcpy(output + prefixSize, bytes, count);
    GlobalUnlock(block);
    FORMATETC fmt = {format, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    STGMEDIUM storage = {};
    storage.tymed = TYMED_HGLOBAL;
    storage.hGlobal = block;
    if (SUCCEEDED(data->SetData(&fmt, &storage, TRUE))) return true;
    ReleaseStgMedium(&storage);
    return false;
}

// Find the common shell folder, so Explorer can offer its usual Shell IDList
// Array alongside the filesystem paths. Mixed folders and virtual test paths
// still work through CF_HDROP.
IDataObject *shellFiles(const wchar_t *paths, UINT count) {
    if (!count) return nullptr;
    auto ids = static_cast<PIDLIST_ABSOLUTE *>(calloc(count, sizeof(PIDLIST_ABSOLUTE)));
    auto children = static_cast<PCUITEMID_CHILD *>(calloc(count, sizeof(PCUITEMID_CHILD)));
    PIDLIST_ABSOLUTE parent = nullptr;
    IDataObject *result = nullptr;
    if (ids && children) {
        for (UINT i = 0; i < count; ++i) {
            ids[i] = ILCreateFromPathW(paths);
            if (!ids[i]) break;
            if (i == 0) {
                parent = ILClone(ids[i]);
                if (!parent || !ILRemoveLastID(parent)) break;
            }
            if (!ILIsParent(parent, ids[i], TRUE)) break;
            children[i] = ILFindLastID(ids[i]);
            paths += wcslen(paths) + 1;
            if (i + 1 == count)
                SHCreateDataObject(parent, count, children, nullptr, IID_PPV_ARGS(&result));
        }
    }
    if (ids) for (UINT i = 0; i < count; ++i) if (ids[i]) ILFree(ids[i]);
    if (parent) ILFree(parent);
    free(children);
    free(ids);
    return result;
}

IDataObject *makeData(const RuneWinDragPayload &p) {
    const auto *paths = reinterpret_cast<const wchar_t *>(p.files);
    UINT fileCount = 0;
    if (p.file_units) {
        if (!paths || p.file_units < 3 || p.file_units > SIZE_MAX / sizeof(wchar_t)) return nullptr;
        size_t i = 0;
        while (i < p.file_units - 1) {
            size_t start = i;
            while (i < p.file_units && paths[i]) ++i;
            if (i == start || i >= p.file_units - 1 || fileCount == UINT_MAX) return nullptr;
            ++i;
            ++fileCount;
        }
        if (paths[i]) return nullptr;
    }
    IDataObject *data = shellFiles(paths, fileCount);
    FORMATETC fileFormat = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    bool shellHasPaths = data && data->QueryGetData(&fileFormat) == S_OK;
    if (!data && FAILED(SHCreateDataObject(nullptr, 0, nullptr, nullptr, IID_PPV_ARGS(&data)))) return nullptr;
    bool ok = true;
    if (fileCount && !shellHasPaths) {
        DROPFILES header = {};
        header.pFiles = sizeof(header);
        header.fWide = TRUE;
        ok = setBytes(data, CF_HDROP, paths, p.file_units * sizeof(wchar_t), &header, sizeof(header));
    }
    const wchar_t *text = p.text ? reinterpret_cast<const wchar_t *>(p.text) : (fileCount ? paths : nullptr);
    if (ok && text) ok = setBytes(data, CF_UNICODETEXT, text, (wcslen(text) + 1) * sizeof(wchar_t));
    if (ok && p.png_size)
        ok = setBytes(data, static_cast<CLIPFORMAT>(RegisterClipboardFormatW(L"PNG")), p.png, p.png_size);
    if (ok && (text || p.png_size)) return data;
    data->Release();
    return nullptr;
}

void installPicture(IDataObject *data, const RuneWinDragPayload &p) {
    IDragSourceHelper *helper = nullptr;
    if (FAILED(CoCreateInstance(CLSID_DragDropHelper, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&helper)))) return;
    if (p.rgba && p.width > 0 && p.height > 0 &&
        static_cast<uint64_t>(p.width) * p.height <= p.rgba_size / 4) {
        BITMAPINFO info = {};
        info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        info.bmiHeader.biWidth = p.width;
        info.bmiHeader.biHeight = -p.height;
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = 32;
        void *bits = nullptr;
        HBITMAP bitmap = CreateDIBSection(nullptr, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
        if (bitmap && bits) {
            auto dst = static_cast<uint8_t *>(bits);
            const uint8_t *src = p.rgba;
            size_t count = static_cast<size_t>(p.width) * p.height;
            for (size_t i = 0; i < count; ++i, dst += 4, src += 4) {
                const unsigned alpha = src[3];
                dst[0] = static_cast<uint8_t>((src[2] * alpha + 127) / 255);
                dst[1] = static_cast<uint8_t>((src[1] * alpha + 127) / 255);
                dst[2] = static_cast<uint8_t>((src[0] * alpha + 127) / 255);
                dst[3] = src[3];
            }
            SHDRAGIMAGE picture = {{p.width, p.height}, {p.hotspot_x, p.hotspot_y}, bitmap, CLR_NONE};
            if (SUCCEEDED(helper->InitializeFromBitmap(&picture, data))) bitmap = nullptr;
        }
        if (bitmap) DeleteObject(bitmap);
    } else if (p.file_units) {
        helper->InitializeFromWindow(nullptr, nullptr, data);
    }
    helper->Release();
}

struct Session final : IDropSource {
    HWND window;
    IDataObject *data;
    DWORD operations;
    bool withinApp;
    RuneWinDragDone done;
    void *context;
    LONG references = 1;
    bool active = false;
    bool cancelled = false;

    Session(HWND hwnd, IDataObject *object, const RuneWinDragPayload &p, RuneWinDragDone fn, void *ctx)
        : window(hwnd), data(object), operations(p.operations & 7), withinApp(p.within_app != 0), done(fn), context(ctx) {}
    ~Session() { data->Release(); }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (iid != IID_IUnknown && iid != IID_IDropSource) return E_NOINTERFACE;
        *out = static_cast<IDropSource *>(this);
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&references); }
    ULONG STDMETHODCALLTYPE Release() override {
        ULONG left = InterlockedDecrement(&references);
        if (!left) delete this;
        return left;
    }
    HRESULT STDMETHODCALLTYPE QueryContinueDrag(BOOL escape, DWORD keys) override {
        if (escape || cancelled) return DRAGDROP_S_CANCEL;
        return (keys & MK_LBUTTON) ? S_OK : DRAGDROP_S_DROP;
    }
    HRESULT STDMETHODCALLTYPE GiveFeedback(DWORD) override { return DRAGDROP_S_USEDEFAULTCURSORS; }
    void complete(DWORD effect) {
        auto fn = done;
        auto ctx = context;
        Release();
        OleUninitialize();
        fn(ctx, effect);
    }
};

LRESULT CALLBACK procedure(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp, UINT_PTR id, DWORD_PTR ref) {
    auto *session = reinterpret_cast<Session *>(ref);
    if (msg == beginMessage()) {
        if (session->active) return 0;
        DWORD effect = DROPEFFECT_NONE;
        if (!inDrag && !session->cancelled) {
            session->active = true;
            inDrag = true;
            muteLocalDrops = !session->withinApp;
            if (GetCapture() == hwnd) ReleaseCapture();
            HRESULT hr = DoDragDrop(session->data, session, session->operations, &effect);
            effect = (hr == DRAGDROP_S_DROP && !session->cancelled) ? effect & session->operations : DROPEFFECT_NONE;
            if (effect & DROPEFFECT_COPY) effect = DROPEFFECT_COPY;
            else if (effect & DROPEFFECT_MOVE) effect = DROPEFFECT_MOVE;
            muteLocalDrops = false;
            inDrag = false;
        }
        RemoveWindowSubclass(hwnd, procedure, id);
        session->complete(effect);
        return 0;
    }
    if (msg == WM_NCDESTROY) {
        RemoveWindowSubclass(hwnd, procedure, id);
        session->cancelled = true;
        if (!session->active) session->complete(DROPEFFECT_NONE);
    }
    return DefSubclassProc(hwnd, msg, wp, lp);
}

} // namespace

extern "C" int rune_win_drag_mutes_local_targets(void) { return muteLocalDrops; }

extern "C" int rune_win_drag_begin(void *window, const RuneWinDragPayload *p, RuneWinDragDone done, void *context) {
    auto hwnd = static_cast<HWND>(window);
    if (!hwnd || !p || !(p->operations & 7) || !done || inDrag || !beginMessage() ||
        GetWindowThreadProcessId(hwnd, nullptr) != GetCurrentThreadId()) return 0;
    DWORD_PTR existing;
    if (GetWindowSubclass(hwnd, procedure, subclassID, &existing) || FAILED(OleInitialize(nullptr))) return 0;
    IDataObject *data = makeData(*p);
    Session *session = data ? new (std::nothrow) Session(hwnd, data, *p, done, context) : nullptr;
    if (!session) {
        if (data) data->Release();
        OleUninitialize();
        return 0;
    }
    installPicture(data, *p);
    if (SetWindowSubclass(hwnd, procedure, subclassID, reinterpret_cast<DWORD_PTR>(session))) {
        if (PostMessageW(hwnd, beginMessage(), 0, 0)) return 1;
        RemoveWindowSubclass(hwnd, procedure, subclassID);
    }
    session->Release();
    OleUninitialize();
    return 0;
}

extern "C" void rune_win_drag_cancel(void *window) {
    HWND hwnd = static_cast<HWND>(window);
    DWORD_PTR ref;
    if (hwnd && GetWindowSubclass(hwnd, procedure, subclassID, &ref)) {
        auto *s = reinterpret_cast<Session *>(ref);
        s->cancelled = true;
        if (s->active) PostMessageW(hwnd, WM_NULL, 0, 0);
        else {
            RemoveWindowSubclass(hwnd, procedure, subclassID);
            s->complete(DROPEFFECT_NONE);
        }
    }
}
#endif
