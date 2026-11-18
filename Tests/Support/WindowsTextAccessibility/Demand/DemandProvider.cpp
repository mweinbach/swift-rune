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
    bool insideRequest = false;
    bool activatedSynchronously = false;
};

void activate(void *context) {
    auto &model = *static_cast<Model *>(context);
    ++model.activations;
    model.activatedSynchronously = model.insideRequest && rune_uia_active(model.host) != 0;
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
    return DefWindowProcW(hwnd, message, wparam, lparam);
}

bool runCase(HINSTANCE instance, LONG firstObject, bool zeroExtend) {
    HWND hwnd = CreateWindowExW(0, windowClass, L"", WS_OVERLAPPED, 0, 0, 80, 60,
                                nullptr, nullptr, instance, nullptr);
    if (!hwnd) return false;
    Model model;
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
    request(firstObject, zeroExtend);
    bool first = model.activatedSynchronously && model.activations == 1 &&
                 model.publishedGeneration == model.generation && rune_uia_active(model.host);
    request(OBJID_CLIENT, true);
    request(UiaRootObjectId, false);
    request(0, false);
    bool once = model.activations == 1;
    std::printf("first=%ld encoding=%s ignored_forwarded_dormant=%d synchronous_latest=%d activations=%u published=%u\n",
                static_cast<long>(firstObject), zeroExtend ? "zero-extended" : "signed", dormant, first,
                model.activations, model.publishedGeneration);
    rune_uia_detach(model.host);
    DestroyWindow(hwnd);
    return dormant && first && once;
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
    UnregisterClassW(windowClass, instance);
    return ok ? 0 : 1;
}
