#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <ole2.h>
#include <shellapi.h>
#include <new>
#include "Drop.h"

// Registered on the thread that owns the HWND. ReleaseStgMedium belongs to the
// IDataObject path; only a legacy WM_DROPFILES recipient calls DragFinish.
struct RuneWinDropTarget final : IDropTarget {
    explicit RuneWinDropTarget(RuneWinWindow *owner) : window(owner) {}
    RuneWinWindow *window;
    LONG references = 1;
    bool overFiles = false;

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (iid != IID_IDropTarget && iid != IID_IUnknown) return E_NOINTERFACE;
        *out = static_cast<IDropTarget *>(this);
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&references); }
    ULONG STDMETHODCALLTYPE Release() override {
        ULONG remaining = InterlockedDecrement(&references);
        if (!remaining) delete this;
        return remaining;
    }

    bool send(RuneWinEventKind kind, IDataObject *object, POINTL screen, bool *hasFiles = nullptr) {
        if (!window) return false;
        POINT at = {screen.x, screen.y};
        ScreenToClient(static_cast<HWND>(rune_win_hwnd(window)), &at);
        if (!object) return rune_win_drop_event(window, kind, nullptr, at.x, at.y) != 0;
        FORMATETC format = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
        STGMEDIUM medium = {};
        if (FAILED(object->GetData(&format, &medium))) return false;
        bool files = medium.tymed == TYMED_HGLOBAL && medium.hGlobal &&
                     DragQueryFileW(static_cast<HDROP>(medium.hGlobal), 0xffffffff, nullptr, 0) > 0;
        if (hasFiles) *hasFiles = files;
        bool took = files && rune_win_drop_event(window, kind, medium.hGlobal, at.x, at.y) != 0;
        ReleaseStgMedium(&medium);
        return took;
    }

    HRESULT STDMETHODCALLTYPE DragEnter(IDataObject *object, DWORD, POINTL at, DWORD *effect) override {
        if (!effect || !object) return E_INVALIDARG;
        overFiles = false;
        bool accepted = !rune_win_drag_mutes_local_targets() && (*effect & DROPEFFECT_COPY) &&
                        send(RUNE_WIN_DROP_ENTER, object, at, &overFiles);
        *effect = accepted ? DROPEFFECT_COPY : DROPEFFECT_NONE;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DragOver(DWORD, POINTL at, DWORD *effect) override {
        if (!effect) return E_INVALIDARG;
        bool accepted = overFiles && send(RUNE_WIN_DROP_OVER, nullptr, at);
        *effect = accepted ? (*effect & DROPEFFECT_COPY) : DROPEFFECT_NONE;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DragLeave() override {
        if (overFiles) send(RUNE_WIN_DROP_LEAVE, nullptr, {});
        overFiles = false;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Drop(IDataObject *object, DWORD, POINTL at, DWORD *effect) override {
        if (!effect || !object) return E_INVALIDARG;
        bool accepted = overFiles && (*effect & DROPEFFECT_COPY) && send(RUNE_WIN_DROP_END, object, at);
        if (overFiles && !accepted) send(RUNE_WIN_DROP_LEAVE, nullptr, at);
        *effect = accepted ? DROPEFFECT_COPY : DROPEFFECT_NONE;
        overFiles = false;
        return S_OK;
    }
};

extern "C" RuneWinDropTarget *rune_win_drop_attach(RuneWinWindow *window) {
    if (FAILED(OleInitialize(nullptr))) return nullptr;
    auto *target = new (std::nothrow) RuneWinDropTarget(window);
    auto hwnd = static_cast<HWND>(rune_win_hwnd(window));
    if (target && SUCCEEDED(RegisterDragDrop(hwnd, target))) {
        DragAcceptFiles(hwnd, FALSE);
        return target;
    }
    if (target) target->Release();
    OleUninitialize();
    return nullptr;
}

extern "C" void rune_win_drop_detach(RuneWinDropTarget *target) {
    if (!target) return;
    auto hwnd = static_cast<HWND>(rune_win_hwnd(target->window));
    target->window = nullptr;
    RevokeDragDrop(hwnd);
    target->Release();
    OleUninitialize();
}
#endif
