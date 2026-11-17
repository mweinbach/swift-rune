#pragma once
#ifdef _WIN32
#include <windows.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <algorithm>
#include <string>
#include <vector>
#include "../CRuneGPUSelection/include/RuneGPUSelection.h"

namespace RuneAdapterPicker {
using Microsoft::WRL::ComPtr;

inline std::string lowerUTF8(std::wstring value) {
    if (value.empty()) return {};
    CharLowerBuffW(&value[0], (DWORD)value.size());
    int length = WideCharToMultiByte(CP_UTF8, 0, value.data(), (int)value.size(), nullptr, 0, nullptr, nullptr);
    if (length <= 0) return {};
    std::string out(length, '\0');
    WideCharToMultiByte(CP_UTF8, 0, value.data(), (int)value.size(), &out[0], length, nullptr, nullptr);
    return out;
}

inline bool environment(const wchar_t *key, std::string &out) {
    SetLastError(ERROR_SUCCESS);
    DWORD size = GetEnvironmentVariableW(key, nullptr, 0);
    if (!size) { out.clear(); return GetLastError() == ERROR_SUCCESS; }
    std::wstring value(size, L'\0');
    DWORD used = GetEnvironmentVariableW(key, &value[0], size);
    if (used >= size) return false;
    value.resize(used);
    out = lowerUTF8(value);
    return true;
}

inline std::vector<RuneGPUIDs> displays() {
    std::vector<RuneGPUIDs> result;
    for (DWORD i = 0;; ++i) {
        DISPLAY_DEVICEW display{};
        display.cb = sizeof(display);
        if (!EnumDisplayDevicesW(nullptr, i, &display, 0)) break;
        if (!(display.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP)) continue;
        RuneGPUIDs ids{};
        if (!rune_gpu_pci_ids(lowerUTF8(display.DeviceID).c_str(), &ids)) continue;
        auto match = [&](const RuneGPUIDs &x) { return x.vendor == ids.vendor && x.device == ids.device; };
        auto it = std::find_if(result.begin(), result.end(), match);
        if (display.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE) {
            if (it != result.end()) result.erase(it);
            result.insert(result.begin(), ids);
        } else if (it == result.end()) result.push_back(ids);
    }
    return result;
}

// WGL owns the surface. When GL exposes its LUID it is a hard interoperability
// constraint, even if the user requested another device. No GPU device is created here.
inline HRESULT choose(IDXGIFactory1 *factory, const LUID *required, bool presented,
                      ComPtr<IDXGIAdapter1> &selected, const char *&reason, HMONITOR surfaceMonitor = nullptr) {
    selected.Reset();
    struct Candidate { ComPtr<IDXGIAdapter1> adapter; DXGI_ADAPTER_DESC1 desc; std::string name; };
    std::vector<Candidate> choices;
    for (UINT i = 0;; ++i) {
        ComPtr<IDXGIAdapter1> a;
        HRESULT hr = factory->EnumAdapters1(i, &a);
        if (hr == DXGI_ERROR_NOT_FOUND) break;
        if (FAILED(hr)) return hr;
        DXGI_ADAPTER_DESC1 desc{};
        if (FAILED(a->GetDesc1(&desc))) continue;
        if (required) {
            if (required->LowPart == desc.AdapterLuid.LowPart && required->HighPart == desc.AdapterLuid.HighPart) {
                selected = a; reason = "WGL surface LUID"; return S_OK;
            }
        } else if (!(desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE)) choices.push_back({a, desc, lowerUTF8(desc.Description)});
    }
    if (required || choices.empty()) return DXGI_ERROR_NOT_FOUND;
    std::vector<RuneGPUAdapter> infos;
    for (const auto &c : choices) infos.push_back({c.name.c_str(), "", c.desc.VendorId, c.desc.DeviceId, RuneGPUOther, true, false});
    std::string value;
    if (environment(L"WGPU_ADAPTER_NAME", value)) {
        int index = rune_gpu_by_name(infos.data(), (int)infos.size(), value.c_str());
        if (index >= 0) { selected = choices[index].adapter; reason = "WGPU_ADAPTER_NAME"; return S_OK; }
    }
    bool power = environment(L"WGPU_POWER_PREF", value) && (value == "high" || value == "low" || value == "none");
    if (!power && presented) {
        // The current WGL DC already belongs to a window. Preserve the actual
        // monitor's adapter for a secondary display when the driver omitted its LUID.
        if (surfaceMonitor) {
            for (const auto &c : choices) {
                for (UINT j = 0;; ++j) {
                    ComPtr<IDXGIOutput> output;
                    if (FAILED(c.adapter->EnumOutputs(j, &output))) break;
                    DXGI_OUTPUT_DESC desc{};
                    if (SUCCEEDED(output->GetDesc(&desc)) && desc.AttachedToDesktop && desc.Monitor == surfaceMonitor) {
                        selected = c.adapter; reason = "WGL surface monitor"; return S_OK;
                    }
                }
            }
        }
        auto ids = displays();
        int index = rune_gpu_by_display(infos.data(), (int)infos.size(), ids.data(), (int)ids.size());
        if (index >= 0) { selected = choices[index].adapter; reason = "desktop display"; return S_OK; }
    }
    ComPtr<IDXGIFactory6> modern;
    if (SUCCEEDED(factory->QueryInterface(IID_PPV_ARGS(&modern)))) {
        auto preference = power && value == "high" ? DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE : DXGI_GPU_PREFERENCE_MINIMUM_POWER;
        for (UINT i = 0;; ++i) {
            ComPtr<IDXGIAdapter1> a;
            if (FAILED(modern->EnumAdapterByGpuPreference(i, preference, IID_PPV_ARGS(&a)))) break;
            DXGI_ADAPTER_DESC1 desc{};
            if (SUCCEEDED(a->GetDesc1(&desc)) && !(desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE)) {
                selected = a; reason = power ? "WGPU_POWER_PREF" : "lowest power"; return S_OK;
            }
        }
    }
    selected = choices.front().adapter; reason = "first hardware adapter"; return S_OK;
}
}
#endif
