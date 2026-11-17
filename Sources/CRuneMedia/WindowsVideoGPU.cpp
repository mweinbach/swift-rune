#ifdef _WIN32
#define NOMINMAX
#include "WindowsVideoGPU.h"
#include <algorithm>
#include <mferror.h>
#include <cstring>
#include <mutex>
#include <new>

namespace rune_video {
namespace {
struct Libraries {
    HMODULE d3d = LoadLibraryExW(L"d3d11.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    HMODULE dxgi = LoadLibraryExW(L"dxgi.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    decltype(&D3D11CreateDevice) create = rune_mf::MediaAPI::get<decltype(create)>(d3d, "D3D11CreateDevice");
    decltype(&CreateDXGIFactory1) factory = rune_mf::MediaAPI::get<decltype(factory)>(dxgi, "CreateDXGIFactory1");
    ~Libraries() { if (dxgi) FreeLibrary(dxgi); if (d3d) FreeLibrary(d3d); }
};

HRESULT softwarePicture(IMFSample *sample, UINT32 width, UINT32 height, Crop crop, std::vector<uint8_t> &pixels) {
    ComPtr<IMFMediaBuffer> buffer;
    HRESULT hr = sample->ConvertToContiguousBuffer(&buffer);
    if (FAILED(hr)) return hr;
    ComPtr<IMF2DBuffer2> image;
    buffer.As(&image);
    BYTE *base = nullptr, *top = nullptr;
    DWORD size = 0;
    LONG pitch = static_cast<LONG>(width);
    const bool lockedImage = image && SUCCEEDED(image->Lock2DSize(MF2DBuffer_LockFlags_Read, &top, &pitch, &base, &size));
    if (!lockedImage) {
        hr = buffer->Lock(&base, nullptr, &size);
        top = base;
        pitch = static_cast<LONG>(width);
    }
    if (FAILED(hr)) return hr;
    // Decoder surfaces often store 1088 luma rows for a 1080-line media type.
    // Infer the chroma offset from the allocation, then validate both cropped planes.
    const uint64_t offset = top && base && top >= base ? static_cast<uint64_t>(top - base) : UINT64_MAX;
    const uint64_t available = offset <= size ? size - offset : 0;
    const uint64_t inferredRows = pitch > 0 ? 2 * available / (3 * uint64_t(pitch)) : 0;
    const uint64_t rows = inferredRows ? std::max(inferredRows, uint64_t(crop.y) + crop.height) : height;
    if (pitch < static_cast<LONG>(width) || !base || !top || offset > size ||
        uint64_t(pitch) * (rows + (crop.y + crop.height) / 2 - 1) + crop.x + crop.width > available) {
        hr = MF_E_BUFFERTOOSMALL;
    } else {
        try {
            const size_t luma = static_cast<size_t>(crop.width) * crop.height;
            pixels.resize(luma + luma / 2);
            auto copy = [&](BYTE *out, const BYTE *src, UINT32 rows) {
                for (UINT32 y = 0; y < rows; ++y)
                    std::memcpy(out + size_t(y) * crop.width, src + size_t(y) * pitch, crop.width);
            };
            copy(pixels.data(), top + size_t(crop.y) * pitch + crop.x, crop.height);
            copy(pixels.data() + luma, top + size_t(rows + crop.y / 2) * pitch + crop.x, crop.height / 2);
        } catch (const std::bad_alloc &) { hr = E_OUTOFMEMORY; }
    }
    if (lockedImage) image->Unlock2D(); else buffer->Unlock();
    return hr;
}
}

std::shared_ptr<Device> openDevice(const int64_t *luid) {
    static Libraries libraries;
    static std::mutex lock;
    static std::weak_ptr<Device> previous;
    static int64_t previousLuid;
    static bool specific;
    std::lock_guard<std::mutex> guard(lock);
    auto last = previous.lock();
    if (last && specific == (luid != nullptr) &&
        (!luid || *luid == previousLuid) && SUCCEEDED(last->device->GetDeviceRemovedReason())) return last;
    auto manager = rune_mf::MediaAPI::get<decltype(&MFCreateDXGIDeviceManager)>(rune_mf::api().platform, "MFCreateDXGIDeviceManager");
    if (!manager || !libraries.create) return {};
    ComPtr<IDXGIAdapter> adapter;
    if (luid) {
        ComPtr<IDXGIFactory4> factory;
        LUID id;
        std::memcpy(&id, luid, sizeof(id));
        if (!libraries.factory || FAILED(libraries.factory(IID_PPV_ARGS(&factory))) ||
            FAILED(factory->EnumAdapterByLuid(id, IID_PPV_ARGS(&adapter)))) return {};
    }
    auto result = std::make_shared<Device>();
    const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0};
    HRESULT hr = libraries.create(adapter.Get(), adapter ? D3D_DRIVER_TYPE_UNKNOWN : D3D_DRIVER_TYPE_HARDWARE,
                                  nullptr, D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                                  levels, 2, D3D11_SDK_VERSION, &result->device, nullptr, &result->context);
    if (FAILED(hr)) return {};
    ComPtr<ID3D11Multithread> multi;
    if (FAILED(result->context.As(&multi))) return {};
    multi->SetMultithreadProtected(TRUE);
    UINT resetToken = 0;
    if (FAILED(manager(&resetToken, &result->manager)) ||
        FAILED(result->manager->ResetDevice(result->device.Get(), resetToken))) return {};
    previous = result; specific = luid != nullptr; previousLuid = luid ? *luid : 0;
    return result;
}

HRESULT Ring::capture(IMFSample *sample, UINT32 width, UINT32 height, Crop crop, RuneMediaPicture **out) {
    try {
        auto result = std::make_unique<RuneMediaPicture>();
        if (gpu) {
            const HRESULT status = gpu->device->GetDeviceRemovedReason();
            if (FAILED(status)) return status;
        }
        std::shared_ptr<Slot> *free = nullptr;
        if (gpu) {
            for (auto &slot : slots) if (!slot || slot.use_count() == 1) { free = &slot; break; }
            if (!free) return S_FALSE;
            if (!*free) {
                D3D11_TEXTURE2D_DESC desc{};
                desc.Width = crop.width; desc.Height = crop.height;
                desc.MipLevels = desc.ArraySize = desc.SampleDesc.Count = 1;
                desc.Format = DXGI_FORMAT_NV12;
                desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
                auto slot = std::make_shared<Slot>();
                if (FAILED(gpu->device->CreateTexture2D(&desc, nullptr, &slot->texture))) {
                    desc.BindFlags = 0;
                    if (FAILED(gpu->device->CreateTexture2D(&desc, nullptr, &slot->texture))) gpu.reset();
                }
                if (gpu) *free = std::move(slot);
            }
        }
        ComPtr<IMFMediaBuffer> buffer;
        ComPtr<IMFDXGIBuffer> dxgi;
        ComPtr<ID3D11Texture2D> texture;
        UINT index = 0;
        if (gpu && SUCCEEDED(sample->GetBufferByIndex(0, &buffer)) && SUCCEEDED(buffer.As(&dxgi)) &&
            SUCCEEDED(dxgi->GetResource(IID_PPV_ARGS(&texture))) && SUCCEEDED(dxgi->GetSubresourceIndex(&index))) {
            D3D11_TEXTURE2D_DESC desc{}; texture->GetDesc(&desc);
            ComPtr<ID3D11Device> owner; texture->GetDevice(&owner);
            if (owner.Get() != gpu->device.Get() || desc.Format != DXGI_FORMAT_NV12 ||
                index >= desc.MipLevels * desc.ArraySize || desc.Width < crop.x + crop.width || desc.Height < crop.y + crop.height)
                return MF_E_INVALIDMEDIATYPE;
            result->dxgiSource = true;
            D3D11_BOX box{crop.x, crop.y, 0, crop.x + crop.width, crop.y + crop.height, 1};
            gpu->context->CopySubresourceRegion((*free)->texture.Get(), 0, 0, 0, 0, texture.Get(), index, &box);
        } else {
            HRESULT hr = softwarePicture(sample, width, height, crop, result->bytes);
            if (FAILED(hr)) return hr;
            if (gpu) {
                gpu->context->UpdateSubresource((*free)->texture.Get(), 0, nullptr, result->bytes.data(), crop.width, 0);
                // Keep a software decoder’s original planes for GL drivers without texture interop.
            }
        }
        if (gpu) {
            result->slot = *free;
            // All reads of this texture are submitted on its producing immediate context.
            gpu->context->Flush();
        }
        *out = result.release();
        return S_OK;
    } catch (const std::bad_alloc &) { return E_OUTOFMEMORY; }
}
}

void *rune_media_picture_texture(const RuneMediaPicture *p) { return p && p->slot ? p->slot->texture.Get() : nullptr; }
const uint8_t *rune_media_picture_bytes(const RuneMediaPicture *p) { return p && !p->bytes.empty() ? p->bytes.data() : nullptr; }
int rune_media_picture_dxgi_source(const RuneMediaPicture *p) { return p && p->dxgiSource; }
void rune_media_picture_release(RuneMediaPicture *p) { delete p; }
#endif
