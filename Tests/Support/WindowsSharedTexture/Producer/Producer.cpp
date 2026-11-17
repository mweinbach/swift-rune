#ifdef _WIN32
#include <windows.h>
#include <d3d11_4.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

using Microsoft::WRL::ComPtr;

struct Handle {
    HANDLE value = nullptr;
    ~Handle() { if (value) CloseHandle(value); }
};

static void check(HRESULT result, const char* operation) {
    if (FAILED(result)) {
        std::fprintf(stderr, "%s failed with HRESULT 0x%08lx\n", operation, static_cast<unsigned long>(result));
        std::exit(1);
    }
}

#include "D3D12Fixture.h"

static ComPtr<IDXGIAdapter1> findAdapter(const LUID luid) {
    ComPtr<IDXGIFactory1> factory;
    check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)), "CreateDXGIFactory1");
    for (UINT index = 0; ; ++index) {
        ComPtr<IDXGIAdapter1> adapter;
        HRESULT next = factory->EnumAdapters1(index, &adapter);
        if (next == DXGI_ERROR_NOT_FOUND) break;
        check(next, "EnumAdapters1");
        DXGI_ADAPTER_DESC1 desc{};
        check(adapter->GetDesc1(&desc), "GetDesc1");
        if (desc.AdapterLuid.HighPart == luid.HighPart && desc.AdapterLuid.LowPart == luid.LowPart) return adapter;
    }
    std::fprintf(stderr, "The requested adapter is unavailable\n");
    std::exit(1);
}

static ComPtr<ID3D11Texture2D> makeImage(ID3D11Device* device, const std::wstring& name,
                                          DXGI_FORMAT format, Handle& sharedHandle) {
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = 4;
    desc.Height = 2;
    desc.MipLevels = desc.ArraySize = desc.SampleDesc.Count = 1;
    desc.Format = format;
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED | D3D11_RESOURCE_MISC_SHARED_NTHANDLE;
    ComPtr<ID3D11Texture2D> texture;
    check(device->CreateTexture2D(&desc, nullptr, &texture), "CreateTexture2D");
    ComPtr<IDXGIResource1> resource;
    check(texture.As(&resource), "Query IDXGIResource1");
    check(resource->CreateSharedHandle(nullptr, DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE,
                                      name.c_str(), &sharedHandle.value), "CreateSharedHandle(texture)");
    return texture;
}

static const UINT *imagePixels(bool second) {
    // 0xAARRGGBB becomes B,G,R,A in this little-endian DXGI texture.
    static const UINT firstImage[]  = {0xFFFF0000, 0xFFFF0000, 0xFF00FF00, 0xFF00FF00,
                                0xFF0000FF, 0xFF0000FF, 0xFFFFFF00, 0xFFFFFF00};
    static const UINT secondImage[] = {0xFF00FFFF, 0xFF00FFFF, 0xFFFF00FF, 0xFFFF00FF,
                                0xFFFFFFFF, 0xFFFFFFFF, 0xFF000000, 0xFF000000};
    return second ? secondImage : firstImage;
}

static void writeImage(ID3D11DeviceContext* context, ID3D11Texture2D* texture, ID3D11Query* finished, bool second) {
    context->UpdateSubresource(texture, 0, nullptr, imagePixels(second), 4 * sizeof(UINT), 0);
    context->End(finished);
    context->Flush();
    const ULONGLONG end = GetTickCount64() + 5000;
    HRESULT status;
    while ((status = context->GetData(finished, nullptr, 0, 0)) == S_FALSE) {
        if (GetTickCount64() >= end) {
            std::fprintf(stderr, "Producer's update did not finish\n");
            std::exit(1);
        }
        Sleep(1);
    }
    check(status, "Wait for producer's write");
}

int main(int argc, char** argv) {
    if (argc != 4) {
        std::fprintf(stderr, "Usage: SharedTextureProducer <ASCII name prefix> <adapter high> <adapter low>\n");
        return 2;
    }
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    const std::string prefix(argv[1]);
    const std::wstring name(prefix.begin(), prefix.end());
    LUID luid{};
    luid.HighPart = std::strtol(argv[2], nullptr, 10);
    luid.LowPart = std::strtoul(argv[3], nullptr, 10);
    auto adapter = findAdapter(luid);
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    check(D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                            nullptr, 0, D3D11_SDK_VERSION, &device, nullptr, &context), "D3D11CreateDevice");
    Handle imageHandle, wrongHandle, fenceHandle;
    ComPtr<ID3D11Device5> device5;
    check(device.As(&device5), "Query ID3D11Device5");
    ComPtr<ID3D11Fence> fence;
    ComPtr<ID3D11Texture2D> image, wrong;
    ComPtr<ID3D12Device> device12;
    ComPtr<ID3D12Resource> image12, wrong12;
    ComPtr<ID3D12Fence> fence12;
    if (GetEnvironmentVariableW(L"RUNE_TEST_D3D12_PRODUCER", nullptr, 0) != 0) {
        check(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&device12)), "D3D12CreateDevice");
        image12 = makeImage12(device12.Get(), name + L"-bgra", DXGI_FORMAT_B8G8R8A8_UNORM, imageHandle);
        wrong12 = makeImage12(device12.Get(), name + L"-rgba", DXGI_FORMAT_R8G8B8A8_UNORM, wrongHandle);
        check(device12->CreateFence(0, D3D12_FENCE_FLAG_SHARED, IID_PPV_ARGS(&fence12)), "D3D12 CreateFence");
        check(device12->CreateSharedHandle(fence12.Get(), nullptr, GENERIC_ALL, (name + L"-fence").c_str(),
                                           &fenceHandle.value), "D3D12 CreateSharedHandle(fence)");
        check(device5->OpenSharedFence(fenceHandle.value, IID_PPV_ARGS(&fence)), "Open D3D12 fence");
    } else {
        image = makeImage(device.Get(), name + L"-bgra", DXGI_FORMAT_B8G8R8A8_UNORM, imageHandle);
        wrong = makeImage(device.Get(), name + L"-rgba", DXGI_FORMAT_R8G8B8A8_UNORM, wrongHandle);
        check(device5->CreateFence(0, D3D11_FENCE_FLAG_SHARED, IID_PPV_ARGS(&fence)), "CreateFence");
        check(fence->CreateSharedHandle(nullptr, GENERIC_ALL, (name + L"-fence").c_str(), &fenceHandle.value),
              "CreateSharedHandle(fence)");
    }
    D3D11_QUERY_DESC query{D3D11_QUERY_EVENT, 0};
    ComPtr<ID3D11Query> finished;
    check(device->CreateQuery(&query, &finished), "CreateQuery");
    auto write = [&](bool second) {
        if (device12) writeImage12(device12.Get(), image12.Get(), imagePixels(second));
        else writeImage(context.Get(), image.Get(), finished.Get(), second);
    };
    write(false);
    std::puts("ready");

    char command[64];
    while (std::fgets(command, sizeof(command), stdin)) {
        command[std::strcspn(command, "\r\n")] = '\0';
        if (!std::strcmp(command, "overwrite")) {
            write(true);
            std::puts("overwritten");
        } else if (!std::strcmp(command, "value")) {
            std::printf("%llu\n", fence12 ? fence12->GetCompletedValue() : fence->GetCompletedValue());
        } else if (!std::strncmp(command, "wait ", 5)) {
            const UINT64 value = std::strtoull(command + 5, nullptr, 10);
            Handle event;
            event.value = CreateEventW(nullptr, FALSE, FALSE, nullptr);
            if (!event.value) return 1;
            check(fence->SetEventOnCompletion(value, event.value), "SetEventOnCompletion");
            if (WaitForSingleObject(event.value, 5000) != WAIT_OBJECT_0) {
                std::fprintf(stderr, "Producer release fence did not reach %llu\n", value);
                return 1;
            }
            std::printf("%llu\n", fence12 ? fence12->GetCompletedValue() : fence->GetCompletedValue());
        } else if (!std::strcmp(command, "quit")) {
            std::puts("done");
            return 0;
        } else {
            std::fprintf(stderr, "Unknown producer command %s\n", command);
            return 2;
        }
    }
    return 0;
}
#else
int main() { return 77; }
#endif
