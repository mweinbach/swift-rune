#pragma once
#include "WindowsMediaFoundation.h"
#include "RuneWindowsMedia.h"
#include <d3d11_4.h>
#include <dxgi1_4.h>
#include <wrl/client.h>
#include <array>
#include <memory>
#include <vector>

namespace rune_video {
using Microsoft::WRL::ComPtr;

struct Device {
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<IMFDXGIDeviceManager> manager;
};
std::shared_ptr<Device> openDevice(const int64_t *adapter);

struct Crop { UINT32 x, y, width, height; };
struct Slot { ComPtr<ID3D11Texture2D> texture; };
struct Ring {
    std::shared_ptr<Device> gpu;
    std::array<std::shared_ptr<Slot>, 6> slots{};
    // A publication keeps its slot until the last retained render frame releases it.
    HRESULT capture(IMFSample *sample, UINT32 codedWidth, UINT32 codedHeight,
                    Crop crop, RuneMediaPicture **out);
};
}
struct RuneMediaPicture {
    std::shared_ptr<rune_video::Slot> slot;
    std::vector<uint8_t> bytes;
    bool dxgiSource = false;
};
