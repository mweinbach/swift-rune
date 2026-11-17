// Build from a Visual Studio developer prompt in the package root:
// cl /nologo /std:c++17 /EHsc /I Sources/CRuneWin32/include Tests/Support/WindowsDrag/Smoke.cpp /link ole32.lib shell32.lib shlwapi.lib comctl32.lib user32.lib gdi32.lib uuid.lib
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <ole2.h>
#include <shellapi.h>
#include <cstdio>
#include <cstring>
#include "RuneDragSource.h"

// The default test keeps its two HWNDs on a private desktop. OLE only routes
// physical input on the input desktop, so drive its documented COM protocol
// on this test desktop. The production source still creates and owns every
// IDataObject, IDropSource, window subclass, and completion being exercised.
// Use Smoke.exe --interactive to perform three normal system drag gestures.
static HRESULT WINAPI fixtureDragLoop(IDataObject *, IDropSource *, DWORD, DWORD *);
#define DoDragDrop fixtureDragLoop
#include "../../../Sources/CRuneWin32/OutboundDrag.cpp"
#undef DoDragDrop

static const wchar_t sample[] = L"Rune drag \u65e5\u672c \U0001f422";
static const wchar_t paths[] = L"C:\\Rune drag fixture\\alpha.txt\0C:\\Rune drag fixture two\\\u03b2.tmp\0";
static const unsigned char image[] = {
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
    0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
    0x1f, 0x00, 0x05, 0x00, 0x01, 0xff, 0x89, 0x99, 0x3d, 0x1d, 0x00, 0x00,
    0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};

static bool readsBytes(IDataObject *object, CLIPFORMAT format, const void *expected, size_t size) {
    FORMATETC request = {format, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    STGMEDIUM medium = {};
    if (object->QueryGetData(&request) != S_OK || FAILED(object->GetData(&request, &medium))) return false;
    bool matched = false;
    if (medium.tymed == TYMED_HGLOBAL && GlobalSize(medium.hGlobal) >= size) {
        const void *bytes = GlobalLock(medium.hGlobal);
        if (bytes) {
            matched = memcmp(bytes, expected, size) == 0;
            GlobalUnlock(medium.hGlobal);
        }
    }
    ReleaseStgMedium(&medium);
    return matched;
}

static bool readsPaths(IDataObject *object) {
    FORMATETC request = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    STGMEDIUM medium = {};
    if (FAILED(object->GetData(&request, &medium))) return false;
    HDROP drop = static_cast<HDROP>(medium.hGlobal);
    wchar_t path[MAX_PATH];
    const wchar_t *second = paths + wcslen(paths) + 1;
    bool matched = medium.tymed == TYMED_HGLOBAL && DragQueryFileW(drop, ~0u, nullptr, 0) == 2 &&
        DragQueryFileW(drop, 0, path, MAX_PATH) && !wcscmp(path, paths) &&
        DragQueryFileW(drop, 1, path, MAX_PATH) && !wcscmp(path, second);
    ReleaseStgMedium(&medium);
    return matched;
}

struct ProbeTarget final : IDropTarget {
    DWORD requested = DROPEFFECT_COPY;
    unsigned entered = 0, dropped = 0;
    bool payloadOK = false;
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (id != IID_IDropTarget && id != IID_IUnknown) return E_NOINTERFACE;
        *out = static_cast<IDropTarget *>(this);
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return 2; }
    ULONG STDMETHODCALLTYPE Release() override { return 1; }

    HRESULT STDMETHODCALLTYPE DragEnter(IDataObject *, DWORD, POINTL, DWORD *effect) override {
        ++entered;
        *effect &= requested;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DragOver(DWORD, POINTL, DWORD *effect) override {
        *effect &= requested;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DragLeave() override { return S_OK; }
    HRESULT STDMETHODCALLTYPE Drop(IDataObject *object, DWORD, POINTL, DWORD *effect) override {
        ++dropped;
        payloadOK = readsBytes(object, CF_UNICODETEXT, sample, sizeof(sample)) &&
            readsBytes(object, static_cast<CLIPFORMAT>(RegisterClipboardFormatW(L"PNG")), image, sizeof(image)) &&
            readsPaths(object);
        *effect &= payloadOK ? requested : DROPEFFECT_NONE;
        return S_OK;
    }
};

struct Completion {
    unsigned calls = 0;
    uint32_t effect = UINT32_MAX;
    static void record(void *context, uint32_t effect) {
        auto *result = static_cast<Completion *>(context);
        ++result->calls;
        result->effect = effect;
    }
};

static RuneWinDragPayload payload() {
    RuneWinDragPayload p = {};
    p.text = reinterpret_cast<const uint16_t *>(sample);
    p.files = reinterpret_cast<const uint16_t *>(paths);
    p.file_units = sizeof(paths) / sizeof(*paths);
    p.png = image;
    p.png_size = sizeof(image);
    p.operations = DROPEFFECT_COPY | DROPEFFECT_MOVE | DROPEFFECT_LINK;
    p.within_app = 1;
    return p;
}

static HWND source;
static ProbeTarget *controlledTarget;
static bool cancelInLoop;
static bool expectedMute;
static bool manual;
static bool dragging;

static HRESULT WINAPI fixtureDragLoop(IDataObject *object, IDropSource *driver, DWORD allowed, DWORD *effect) {
    if (!controlledTarget) return DoDragDrop(object, driver, allowed, effect);
    if ((rune_win_drag_mutes_local_targets() != 0) != expectedMute) return E_UNEXPECTED;
    if (driver->QueryContinueDrag(FALSE, MK_LBUTTON) != S_OK ||
        driver->GiveFeedback(DROPEFFECT_COPY) != DRAGDROP_S_USEDEFAULTCURSORS) return E_UNEXPECTED;
    if (cancelInLoop) return driver->QueryContinueDrag(TRUE, MK_LBUTTON);

    POINTL point = {5, 5};
    *effect = allowed;
    controlledTarget->DragEnter(object, MK_LBUTTON, point, effect);
    if (!*effect) { controlledTarget->DragLeave(); return DRAGDROP_S_CANCEL; }
    controlledTarget->DragOver(MK_LBUTTON, point, effect);
    if (driver->QueryContinueDrag(FALSE, 0) != DRAGDROP_S_DROP) return E_UNEXPECTED;
    controlledTarget->Drop(object, 0, point, effect);
    return DRAGDROP_S_DROP;
}

static LRESULT CALLBACK fixtureWindow(HWND window, UINT msg, WPARAM w, LPARAM l) {
    if (manual && window == source && msg == WM_LBUTTONDOWN) {
        dragging = true;
        return 0;
    }
    if (manual && msg == WM_CLOSE) PostQuitMessage(1);
    return DefWindowProcW(window, msg, w, l);
}

static bool checkDrop(ProbeTarget &target, DWORD requested) {
    Completion result;
    RuneWinDragPayload p = payload();
    target.requested = requested;
    target.dropped = 0;
    target.entered = 0;
    target.payloadOK = false;
    // Make owned data copies explicit: a posted session outlives this caller's buffers.
    wchar_t text[sizeof(sample) / sizeof(*sample)];
    memcpy(text, sample, sizeof(text));
    p.text = reinterpret_cast<const uint16_t *>(text);
    p.within_app = expectedMute ? 0 : 1;
    MSG msg;
    if (manual) {
        puts("Drag from the Rune source window to the Rune destination window.");
        dragging = false;
        while (!dragging) {
            if (GetMessageW(&msg, nullptr, 0, 0) <= 0) return false;
            DispatchMessageW(&msg);
        }
    }
    if (!rune_win_drag_begin(source, &p, Completion::record, &result)) return false;
    memset(text, 0xa5, sizeof(text));
    while (!result.calls && GetMessageW(&msg, nullptr, 0, 0) > 0) DispatchMessageW(&msg);
    if (cancelInLoop) return result.calls == 1 && result.effect == DROPEFFECT_NONE && !target.dropped;
    printf("requested %lu, completed %lu, entries %u, drops %u, validated formats %s\n",
           requested, (unsigned long)result.effect, target.entered, target.dropped, target.payloadOK ? "yes" : "no");
    return result.calls == 1 && result.effect == requested && target.dropped == 1 && target.payloadOK;
}

int main(int argc, char **argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    manual = argc == 2 && !strcmp(argv[1], "--interactive");
    if (argc != 1 && !manual) return 1;
    wchar_t name[80];
    swprintf_s(name, 80, L"RuneDragTest_%lu_%llu", GetCurrentProcessId(), GetTickCount64());
    HDESK previous = GetThreadDesktop(GetCurrentThreadId());
    HDESK desktop = nullptr;
    if (!manual) {
        desktop = CreateDesktopW(name, nullptr, nullptr, 0, GENERIC_ALL, nullptr);
        if (!desktop || !SetThreadDesktop(desktop)) return 1;
        wchar_t actual[80];
        DWORD bytes;
        if (!GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()), UOI_NAME, actual, sizeof(actual), &bytes)
            || wcscmp(actual, name) != 0) return 2;
    }
    if (FAILED(OleInitialize(nullptr))) return 3;
    WNDCLASSW cls = {};
    cls.lpfnWndProc = fixtureWindow;
    cls.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    cls.hInstance = GetModuleHandleW(nullptr);
    cls.lpszClassName = L"RuneDragFixtureWindow";
    if (!RegisterClassW(&cls)) return 10;
    DWORD style = manual ? WS_OVERLAPPEDWINDOW | WS_VISIBLE : WS_POPUP;
    source = CreateWindowExW(0, cls.lpszClassName, L"Rune source (drag from here)", style,
                             80, 80, 300, 160, nullptr, nullptr, cls.hInstance, nullptr);
    HWND destination = CreateWindowExW(0, cls.lpszClassName, L"Rune destination (drop here)", style,
                                       410, 80, 300, 160, nullptr, nullptr, cls.hInstance, nullptr);
    ProbeTarget target;
    if (!source || !destination || FAILED(RegisterDragDrop(destination, &target))) return 4;

    controlledTarget = manual ? nullptr : &target;
    // A platform dialog or failed modal loop must not hang an unattended test.
    HANDLE watchdog = CreateThread(nullptr, 0, [](void *) -> DWORD {
        Sleep(manual ? 120000 : 30000);
        fputs("Private OLE smoke timed out.\n", stderr);
        ExitProcess(10);
    }, nullptr, 0, nullptr);
    if (!watchdog) return 10;
    CloseHandle(watchdog);
    RuneWinDragPayload p = payload();
    Completion cancelled;
    if (!rune_win_drag_begin(source, &p, Completion::record, &cancelled)) return 5;
    if (rune_win_drag_begin(source, &p, Completion::record, &cancelled)) return 6;
    rune_win_drag_cancel(source);
    rune_win_drag_cancel(source);
    if (cancelled.calls != 1 || cancelled.effect != DROPEFFECT_NONE) return 7;
    bool dropsOK = checkDrop(target, DROPEFFECT_COPY) && checkDrop(target, DROPEFFECT_MOVE) &&
        checkDrop(target, DROPEFFECT_LINK);
    if (!manual && dropsOK) {
        cancelInLoop = true;
        expectedMute = true;
        dropsOK = checkDrop(target, DROPEFFECT_COPY) && !rune_win_drag_mutes_local_targets();
    }
    Completion destroyed;
    if (!rune_win_drag_begin(source, &p, Completion::record, &destroyed)) return 9;
    DestroyWindow(source);
    const bool cancelledOnDestroy = destroyed.calls == 1 && destroyed.effect == DROPEFFECT_NONE;
    RevokeDragDrop(destination);
    DestroyWindow(destination);
    OleUninitialize();
    if (desktop) { SetThreadDesktop(previous); CloseDesktop(desktop); }
    if (dropsOK && cancelledOnDestroy) puts(manual ? "Windows OLE drops passed." : "Private desktop OLE payload and completion tests passed.");
    return dropsOK && cancelledOnDestroy ? 0 : 8;
}
