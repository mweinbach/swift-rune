#pragma once

#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <cstdio>

namespace rune_mf {

inline int failure(char *error, size_t capacity, const char *action, HRESULT status) {
    if (error && capacity) {
        std::snprintf(error, capacity, "Media Foundation %s failed (HRESULT 0x%08lx)",
                      action, static_cast<unsigned long>(status));
    }
    return 0;
}

// Windows N can run the rest of Rune without installing the Media Feature Pack.
struct MediaAPI {
    HMODULE platform = LoadLibraryExW(L"mfplat.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    HMODULE readwrite = LoadLibraryExW(L"mfreadwrite.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);

    template<class T>
    static T get(HMODULE module, const char *name) {
        return module ? reinterpret_cast<T>(reinterpret_cast<void *>(GetProcAddress(module, name))) : nullptr;
    }
    decltype(&MFStartup) startup = get<decltype(&MFStartup)>(platform, "MFStartup");
    decltype(&MFShutdown) shutdown = get<decltype(&MFShutdown)>(platform, "MFShutdown");
    decltype(&MFCreateAttributes) attributes = get<decltype(&MFCreateAttributes)>(platform, "MFCreateAttributes");
    decltype(&MFCreateMediaType) mediaType = get<decltype(&MFCreateMediaType)>(platform, "MFCreateMediaType");
    decltype(&MFGetStrideForBitmapInfoHeader) stride = get<decltype(&MFGetStrideForBitmapInfoHeader)>(platform, "MFGetStrideForBitmapInfoHeader");
    decltype(&MFCreateSourceReaderFromURL) open = get<decltype(&MFCreateSourceReaderFromURL)>(readwrite, "MFCreateSourceReaderFromURL");

    decltype(&MFCreateMemoryBuffer) buffer = get<decltype(&MFCreateMemoryBuffer)>(platform, "MFCreateMemoryBuffer");
    decltype(&MFCreateSample) sample = get<decltype(&MFCreateSample)>(platform, "MFCreateSample");
    decltype(&MFCreateSinkWriterFromURL) writer = get<decltype(&MFCreateSinkWriterFromURL)>(readwrite, "MFCreateSinkWriterFromURL");

    bool canWrite() const { return startup && shutdown && attributes && mediaType && buffer && sample && writer; }
    bool available() const { return startup && shutdown && attributes && mediaType && stride && open; }

    ~MediaAPI() {
        if (readwrite) FreeLibrary(readwrite);
        if (platform) FreeLibrary(platform);
    }
};

inline MediaAPI &api() {
    static MediaAPI value;
    return value;
}

struct Apartment {
    HRESULT status = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    bool ready() const { return SUCCEEDED(status) || status == RPC_E_CHANGED_MODE; }
    ~Apartment() { if (SUCCEEDED(status)) CoUninitialize(); }
};

} // namespace rune_mf
