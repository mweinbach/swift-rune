// Exercise the production HWND subclass without starting a screen reader or exposing a window.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <ole2.h>
#include <uiautomation.h>
#include <cstdint>
#include <cstdio>
#include <initializer_list>
#include "RuneAccessibility.h"

namespace {
constexpr wchar_t windowClass[] = L"RuneProviderDemandTest";
constexpr LRESULT forwardedResult = 0x5357;
constexpr LONG ignoredObject = OBJID_TITLEBAR;

struct Model {
    RuneUiaHost *host = nullptr;
    unsigned generation = 0;
    unsigned publishedGeneration = 0;
    unsigned activations = 0;
    unsigned paints = 0;
    bool ready = true;
    bool insideRequest = false;
    bool activatedSynchronously = false;
};

void activate(void *context) {
    auto &model = *static_cast<Model *>(context);
    ++model.activations;
    model.activatedSynchronously = model.insideRequest && rune_uia_active(model.host) != 0;
    if (!model.ready) return;
    RuneUiaNode node{};
    node.id = 1;
    node.width = 24;
    node.height = 16;
    node.toggle = node.selected = node.expanded = -1;
    char name[64];
    std::snprintf(name, sizeof(name), "Row generation %u", model.generation);
    rune_uia_begin(model.host, "Demand fixture");
    rune_uia_add(model.host, node, "row", "text", name, "", "", "");
    rune_uia_commit(model.host);
    model.publishedGeneration = model.generation;
}

LRESULT CALLBACK windowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_GETOBJECT && static_cast<LONG>(lparam) == ignoredObject) return forwardedResult;
    if (message == WM_PAINT) {
        auto *model = reinterpret_cast<Model *>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
        if (model) ++model->paints;
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
}

bool runCase(HINSTANCE instance, LONG firstObject, bool zeroExtend, bool deferFirst = false) {
    HWND hwnd = CreateWindowExW(0, windowClass, L"", WS_OVERLAPPED, 0, 0, 80, 60,
                                nullptr, nullptr, instance, nullptr);
    if (!hwnd) return false;
    Model model;
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(&model));
    model.host = rune_uia_attach(hwnd);
    if (!model.host) { DestroyWindow(hwnd); return false; }
    rune_uia_on_demand(model.host, &model, activate);

    // A 64-bit sender can zero-extend or sign-extend an MSAA object id.
    auto request = [&](LONG id, bool asUnsigned) {
        const LPARAM value = asUnsigned ? static_cast<LPARAM>(static_cast<std::uint32_t>(id))
                                        : static_cast<LPARAM>(id);
        model.insideRequest = true;
        LRESULT result = SendMessageW(hwnd, WM_GETOBJECT, 0, value);
        model.insideRequest = false;
        return result;
    };

    bool dormant = rune_uia_active(model.host) == 0 && model.activations == 0;
    for (unsigned i = 0; i < 8; ++i) {
        ++model.generation;
        if (request(ignoredObject, i % 2 != 0) != forwardedResult ||
            rune_uia_active(model.host) || model.activations != 0 || model.publishedGeneration != 0) dormant = false;
    }
    bool deferred = true;
    const unsigned activations = deferFirst ? 2 : 1;
    const unsigned priorPaints = model.paints;
    if (deferFirst) {
        model.ready = false;
        request(OBJID_CLIENT, false);
        deferred = model.activatedSynchronously && model.activations == 1 && model.publishedGeneration == 0;
        ++model.generation;
        model.ready = true;
    }
    request(firstObject, zeroExtend);
    if (deferFirst && model.paints != priorPaints) deferred = false;
    bool first = model.activatedSynchronously && model.activations == activations &&
                 model.publishedGeneration == model.generation && rune_uia_active(model.host);
    request(OBJID_CLIENT, true);
    request(UiaRootObjectId, false);
    request(0, false);
    bool once = model.activations == activations;
    std::printf("first=%ld encoding=%s ignored_forwarded_dormant=%d synchronous_latest=%d activations=%u published=%u deferred=%d\n",
                static_cast<long>(firstObject), zeroExtend ? "zero-extended" : "signed", dormant, first,
                model.activations, model.publishedGeneration, deferFirst);
    rune_uia_detach(model.host);
    DestroyWindow(hwnd);
    return dormant && deferred && first && once;
}
} // namespace

int main() {
    HINSTANCE instance = GetModuleHandleW(nullptr);
    WNDCLASSW wc{};
    wc.hInstance = instance;
    wc.lpfnWndProc = windowProc;
    wc.lpszClassName = windowClass;
    if (!RegisterClassW(&wc)) return 1;
    bool ok = true;
    for (const LONG id : {static_cast<LONG>(UiaRootObjectId), static_cast<LONG>(OBJID_CLIENT), 0L}) {
        if (!runCase(instance, id, false)) ok = false;
        if (!runCase(instance, id, true)) ok = false;
    }
    if (!runCase(instance, UiaRootObjectId, false, true)) ok = false;
    UnregisterClassW(windowClass, instance);
    return ok ? 0 : 1;
}
