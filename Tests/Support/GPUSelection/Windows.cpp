#include "../../../Sources/CRuneWin32/AdapterPicker.hpp"
#include <d3d11.h>
#include <cassert>
#include <cstdio>
using Microsoft::WRL::ComPtr;

int main() {
    ComPtr<IDXGIFactory1> factory;
    assert(SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))));
    ComPtr<IDXGIAdapter1> adapter;
    const char *reason = nullptr;
    assert(SUCCEEDED(RuneAdapterPicker::choose(factory.Get(), nullptr, true, adapter, reason)));
    DXGI_ADAPTER_DESC1 desc{};
    assert(SUCCEEDED(adapter->GetDesc1(&desc)));
    printf("desktop selection: %s; %s; PCI %04x:%04x\n", reason, RuneAdapterPicker::lowerUTF8(desc.Description).c_str(), desc.VendorId, desc.DeviceId);
    auto displays = RuneAdapterPicker::displays();
    if (!displays.empty() && displays.front().vendor == desc.VendorId && displays.front().device == desc.DeviceId)
        assert(!strcmp(reason, "desktop display"));
    POINT origin{};
    HMONITOR primary = MonitorFromPoint(origin, MONITOR_DEFAULTTOPRIMARY);
    if (primary) {
        assert(SUCCEEDED(RuneAdapterPicker::choose(factory.Get(), nullptr, true, adapter, reason, primary)));
        printf("existing WGL window monitor choice: %s\n", reason);
    }
    SetEnvironmentVariableW(L"WGPU_ADAPTER_NAME", desc.Description);
    assert(SUCCEEDED(RuneAdapterPicker::choose(factory.Get(), nullptr, false, adapter, reason)) && !strcmp(reason, "WGPU_ADAPTER_NAME"));
    SetEnvironmentVariableW(L"WGPU_ADAPTER_NAME", L"no-such-rune-adapter");
    SetEnvironmentVariableW(L"WGPU_POWER_PREF", L"high");
    assert(SUCCEEDED(RuneAdapterPicker::choose(factory.Get(), nullptr, true, adapter, reason)) && !strcmp(reason, "WGPU_POWER_PREF"));
    assert(SUCCEEDED(RuneAdapterPicker::choose(factory.Get(), &desc.AdapterLuid, true, adapter, reason)) && !strcmp(reason, "WGL surface LUID"));
    LUID missing{0xffffFFFFu, -1};
    assert(FAILED(RuneAdapterPicker::choose(factory.Get(), &missing, true, adapter, reason)) && !adapter);
    SetEnvironmentVariableW(L"WGPU_ADAPTER_NAME", nullptr);
    SetEnvironmentVariableW(L"WGPU_POWER_PREF", nullptr);
    assert(SUCCEEDED(RuneAdapterPicker::choose(factory.Get(), nullptr, false, adapter, reason)));
    ComPtr<ID3D11Device> device;
    assert(SUCCEEDED(D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION, &device, nullptr, nullptr)));
    ComPtr<IDXGIDevice> dxgi;
    ComPtr<IDXGIAdapter> actual;
    DXGI_ADAPTER_DESC selected{};
    assert(SUCCEEDED(device.As(&dxgi)) && SUCCEEDED(dxgi->GetAdapter(&actual)) && SUCCEEDED(actual->GetDesc(&selected)));
    assert(SUCCEEDED(adapter->GetDesc1(&desc)));
    assert(desc.AdapterLuid.LowPart == selected.AdapterLuid.LowPart && desc.AdapterLuid.HighPart == selected.AdapterLuid.HighPart);
    printf("actual D3D11 device LUID %08lx:%08lx by %s; name, power and required LUID checks passed\n", selected.AdapterLuid.HighPart, selected.AdapterLuid.LowPart, reason);
}
