// Run with the checked-in rgbw.mp4 fixture. The same public C ABI feeds Swift's desktop Player.
#include <windows.h>
#include <d3d11.h>
#include <wrl/client.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <memory>
#include <vector>
#include "CRuneMedia.h"
#include "../../../Sources/CRuneMedia/WindowsVideoGPU.h"

using Microsoft::WRL::ComPtr;
using Picture = std::unique_ptr<RuneMediaPicture, decltype(&rune_media_picture_release)>;
static bool readVisible(RuneMediaPicture *picture, UINT width, UINT height, std::vector<uint8_t> &result) {
    result.resize(size_t(width) * (height + height / 2));
    auto texture = static_cast<ID3D11Texture2D *>(rune_media_picture_texture(picture));
    if (!texture) {
        auto bytes = rune_media_picture_bytes(picture);
        if (!bytes) return false;
        std::copy_n(bytes, result.size(), result.data());
        return true;
    }
    D3D11_TEXTURE2D_DESC desc{};
    texture->GetDesc(&desc);
    if (desc.Format != DXGI_FORMAT_NV12 || desc.Width < width || desc.Height < height) return false;
    ComPtr<ID3D11Device> device; texture->GetDevice(&device);
    ComPtr<ID3D11DeviceContext> context; device->GetImmediateContext(&context);
    desc.Usage = D3D11_USAGE_STAGING; desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    desc.BindFlags = desc.MiscFlags = 0;
    ComPtr<ID3D11Texture2D> staging;
    if (FAILED(device->CreateTexture2D(&desc, nullptr, &staging))) return false;
    context->CopyResource(staging.Get(), texture);
    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (FAILED(context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped))) return false;
    auto bytes = static_cast<const uint8_t *>(mapped.pData);
    for (UINT row = 0; row < height + height / 2; ++row) {
        const UINT storageRow = row < height ? row : desc.Height + row - height;
        std::copy_n(bytes + size_t(mapped.RowPitch) * storageRow, width, result.data() + size_t(row) * width);
    }
    context->Unmap(staging.Get(), 0); return true;
}

static bool pixel(RuneMediaPicture *picture, UINT width, UINT height, int yuv[3]) {
    std::vector<uint8_t> bytes;
    if (!readVisible(picture, width, height, bytes)) return false;
    yuv[0] = bytes[0]; yuv[1] = bytes[size_t(width) * height]; yuv[2] = bytes[size_t(width) * height + 1];
    return true;
}

static bool narrowChromaRows() {
    constexpr UINT width = 30, height = 18;
    std::vector<uint8_t> expected(width * (height + height / 2));
    for (size_t i = 0; i < expected.size(); ++i) expected[i] = uint8_t(i * 7 + i / width);
    ComPtr<IMFSample> sample;
    ComPtr<IMFMediaBuffer> buffer;
    if (FAILED(MFCreateSample(&sample)) || FAILED(MFCreateMemoryBuffer(DWORD(expected.size()), &buffer))) return false;
    BYTE *bytes;
    if (FAILED(buffer->Lock(&bytes, nullptr, nullptr))) return false;
    std::copy(expected.begin(), expected.end(), bytes);
    buffer->Unlock();
    if (FAILED(buffer->SetCurrentLength(DWORD(expected.size()))) || FAILED(sample->AddBuffer(buffer.Get()))) return false;
    rune_video::Ring ring;
    ring.gpu = rune_video::openDevice(nullptr);
    RuneMediaPicture *raw = nullptr;
    if (ring.capture(sample.Get(), width, height, {0, 0, width, height}, &raw) != S_OK) return false;
    Picture held(raw, rune_media_picture_release);
    std::vector<uint8_t> actual;
    if (!readVisible(raw, width, height, actual) || actual != expected) return false;
    std::printf("30x18 patterned NV12 luma + chroma verified in full; GPU ring=%d\n", rune_media_picture_texture(raw) != nullptr);
    return true;
}

static bool decoderArraySlice() {
    rune_video::Ring ring;
    ring.gpu = rune_video::openDevice(nullptr);
    if (!ring.gpu) { std::puts("No hardware device for DXGI array test"); return true; }
    constexpr UINT width = 32, height = 20;
    std::vector<uint8_t> first(width * (height + height / 2), 64), second(first.size());
    for (size_t i = 0; i < second.size(); ++i) second[i] = uint8_t(i * 3 + i / width + 11);
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = width; desc.Height = height; desc.ArraySize = 2;
    desc.MipLevels = desc.SampleDesc.Count = 1; desc.Format = DXGI_FORMAT_NV12;
    D3D11_SUBRESOURCE_DATA initial[] = {{first.data(), width, 0}, {second.data(), width, 0}};
    ComPtr<ID3D11Texture2D> source;
    ComPtr<IMFSample> sample;
    ComPtr<IMFMediaBuffer> buffer;
    if (FAILED(ring.gpu->device->CreateTexture2D(&desc, initial, &source)) ||
        FAILED(MFCreateDXGISurfaceBuffer(__uuidof(ID3D11Texture2D), source.Get(), 1, FALSE, &buffer)) ||
        FAILED(MFCreateSample(&sample)) || FAILED(sample->AddBuffer(buffer.Get()))) return false;
    rune_video::Crop crop{2, 2, 30, 18};
    RuneMediaPicture *raw = nullptr;
    if (ring.capture(sample.Get(), width, height, crop, &raw) != S_OK) return false;
    Picture held(raw, rune_media_picture_release);
    if (!rune_media_picture_dxgi_source(raw) || rune_media_picture_bytes(raw)) return false;
    source.Reset(); sample.Reset(); buffer.Reset();
    std::vector<uint8_t> actual;
    if (!readVisible(raw, crop.width, crop.height, actual)) return false;
    for (UINT row = 0; row < crop.height + crop.height / 2; ++row) {
        UINT sourceRow = row < crop.height ? row + crop.y : height + crop.y / 2 + row - crop.height;
        if (!std::equal(actual.begin() + row * crop.width, actual.begin() + (row + 1) * crop.width,
                        second.begin() + sourceRow * width + crop.x)) return false;
    }
    std::puts("An IMFDXGIBuffer array slice copied to a retained GPU texture with exact cropped luma and chroma.");
    return true;
}

// Some MF software decoders return a larger allocation than the coded height.
static bool paddedAndCroppedSoftwareSample() {
    ComPtr<IMFSample> sample;
    ComPtr<IMFMediaBuffer> buffer;
    if (FAILED(MFCreateSample(&sample)) || FAILED(MFCreateMemoryBuffer(72, &buffer))) return false;
    BYTE *bytes;
    if (FAILED(buffer->Lock(&bytes, nullptr, nullptr))) return false;
    // Pitch 8, six stored luma rows, three chroma rows, visible 4x2 at (2,2).
    for (int i = 0; i < 72; ++i) bytes[i] = static_cast<BYTE>(i);
    buffer->Unlock();
    if (FAILED(buffer->SetCurrentLength(72)) || FAILED(sample->AddBuffer(buffer.Get()))) return false;
    rune_video::Ring ring;
    RuneMediaPicture *raw = nullptr;
    if (ring.capture(sample.Get(), 8, 4, {2, 2, 4, 2}, &raw) != S_OK) return false;
    Picture held(raw, rune_media_picture_release);
    const uint8_t expected[] = {18, 19, 20, 21, 26, 27, 28, 29, 58, 59, 60, 61};
    const uint8_t *actual = rune_media_picture_bytes(raw);
    return actual && std::equal(expected, expected + sizeof(expected), actual);
}

int main(int argc, char **argv) {
    if (argc != 2) return 1;
    rune_mf::Apartment apartment;
    if (!apartment.ready()) return 10;
    auto startup = MFStartup(MF_VERSION);
    if (FAILED(startup)) return 10;
    bool padded = paddedAndCroppedSoftwareSample();
    bool narrow = narrowChromaRows();
    bool array = decoderArraySlice();
    MFShutdown();
    if (!padded || !narrow || !array) {
        std::printf("Synthetic NV12 checks: padded software=%d narrow GPU upload=%d cropped DXGI array=%d\n", padded, narrow, array);
        return 11;
    }
    std::puts("Chroma begins after the allocated luma plane; padded cropped fixture passed.");
    for (int mode = 0; mode != 2; ++mode) {
        RuneMediaInfo meta{}; RunePictureInfo info{}; char error[512]{};
        int64_t rejectedAdapter = INT64_MAX;
        std::unique_ptr<RuneMedia, decltype(&rune_media_close)> media(
            rune_media_open_video(argv[1], mode ? &rejectedAdapter : nullptr, &meta, &info, error, sizeof(error)), rune_media_close);
        if (!media || info.width != 64 || info.height != 36) {
            std::printf("open[%d] %s %ux%u matrix=%d full=%d\n", mode, error, info.width, info.height, info.bt709, info.full_range); return 2;
        }
        const int expected[][3] = {{63, 102, 240}, {173, 42, 26}, {32, 240, 118}, {235, 128, 128}};
        std::vector<Picture> held; bool gpu = false;
        for (int n = 0; n < 6; ++n) {
            RuneMediaPicture *raw = nullptr;
            if (rune_media_picture(media.get(), (n % 4) * 0.25 + 0.05, -1, &raw, error, sizeof(error)) != 1) {
                std::printf("decode %s\n", error); return 3;
            }
            held.emplace_back(raw, rune_media_picture_release);
            gpu = rune_media_picture_texture(raw) != nullptr;
            int actual[3];
            if (!pixel(raw, info.width, info.height, actual)) return 4;
            std::printf("adapter=%d gpu=%d dxgi_sample=%d t=%.2f YCbCr=%d,%d,%d\n", mode, gpu, rune_media_picture_dxgi_source(raw), (n%4)*0.25, actual[0], actual[1], actual[2]);
            auto color = rune_media_picture_info(raw);
            if (!color.bt709 || color.full_range) {
                std::printf("Incorrect color metadata on decoded frame: BT709=%d full=%d\n", color.bt709, color.full_range);
                return 12;
            }
            for (int c = 0; c < 3; ++c) if (std::abs(actual[c] - expected[n % 4][c]) > 5) return 5;
        }
        RuneMediaPicture *next = nullptr;
        if (gpu) {
            if (rune_media_picture(media.get(), 0.55, -1, &next, error, sizeof(error)) != 0 || next) return 6;
            held.pop_back();
            if (rune_media_picture(media.get(), 0.55, -1, &next, error, sizeof(error)) != 1 || !next) return 7;
            rune_media_picture_release(next);
        }
        media.reset();
        int old[3]{};
        if (!pixel(held[0].get(), info.width, info.height, old) || std::abs(old[2] - expected[0][2]) > 5) return 8;
        if (mode && gpu) return 9;
        std::printf("first picture survives 5 later decodes and player teardown; GPU ring=%d\n", gpu);
    }
    return 0;
}
