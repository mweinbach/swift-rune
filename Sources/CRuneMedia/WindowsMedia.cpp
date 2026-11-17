#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <wrl/client.h>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <new>
#include "CRuneMedia.h"
#include "WindowsAudio.h"
#include "WindowsMediaFoundation.h"
#include "WindowsVideoGPU.h"
#include "RuneVideoClock.h"
#include <algorithm>

using Microsoft::WRL::ComPtr;
using rune_mf::api;
using rune_mf::Apartment;
using rune_mf::failure;

namespace {

constexpr double ticksPerSecond = 10000000.0;

struct FrameSample {
    ComPtr<IMFSample> sample;
    LONGLONG time = 0;
    LONG stride = 0;
    RunePictureInfo picture{};
    UINT32 codedWidth = 0, codedHeight = 0;
    rune_video::Crop crop{};
};

} // namespace

struct RuneMedia {
    RuneMediaInfo info{};
    std::unique_ptr<wchar_t[]> uri;
    CO_MTA_USAGE_COOKIE mta = nullptr;
    bool started = false;
    bool headless = false;
    bool playing = false;
    bool audioOpened = false;
    bool reachedEOF = false;
    bool canSeek = false;
    double anchor = 0;
    using Clock = std::chrono::steady_clock;
    Clock::time_point anchorTick = Clock::now();
    double rate = 1;
    bool nv12 = false;
    rune_video::Ring ring;
    RunePictureInfo picture{};
    UINT32 nativeMatrix = 0;
    UINT32 nativeRange = 0;
    bool firstVideoSample = true;
    rune_video::Crop crop{};
    LONG stride = 0;
    UINT32 decodedWidth = 0;
    UINT32 decodedHeight = 0;
    UINT32 appliedRotation = 0;
    LONGLONG lastDelivered = -1;
    ComPtr<IMFSourceReader> reader;
    FrameSample current;
    FrameSample next;
    RuneWindowsAudio audio;

    ~RuneMedia() {
        audio.close();
        current.sample.Reset();
        next.sample.Reset();
        reader.Reset();
        if (started) api().shutdown();
        if (mta) CoDecrementMTAUsage(mta);
    }

    void releaseAudio(HRESULT reason = S_OK) {
        audio.close();
        audioOpened = false;
        if (FAILED(reason))
            std::fprintf(stderr, "Rune video: audio output unavailable (HRESULT 0x%08lx)\n", static_cast<unsigned long>(reason));
    }

    double clock() const {
        const double elapsed = std::chrono::duration<double>(Clock::now() - anchorTick).count();
        const double now = anchor + (playing ? elapsed * rate : 0);
        return info.duration < 0 || now < info.duration ? now : info.duration;
    }
};

namespace {

HRESULT selectFormat(IMFSourceReader *reader, DWORD stream, REFGUID major, REFGUID subtype,
                     UINT32 rotation = 0) {
    ComPtr<IMFMediaType> out;
    HRESULT hr = api().mediaType(&out);
    if (SUCCEEDED(hr)) hr = out->SetGUID(MF_MT_MAJOR_TYPE, major);
    if (SUCCEEDED(hr)) hr = out->SetGUID(MF_MT_SUBTYPE, subtype);
    if (SUCCEEDED(hr) && rotation) hr = out->SetUINT32(MF_MT_VIDEO_ROTATION, rotation);
    if (SUCCEEDED(hr)) hr = reader->SetCurrentMediaType(stream, nullptr, out.Get());
    return hr;
}

void updateColor(RuneMedia &m, IMFMediaType *decoded) {
    UINT32 matrix = MFGetAttributeUINT32(decoded, MF_MT_YUV_MATRIX, 0);
    UINT32 range = MFGetAttributeUINT32(decoded, MF_MT_VIDEO_NOMINAL_RANGE, 0);
    if (!matrix) matrix = m.nativeMatrix;
    if (!range) range = m.nativeRange;
    m.picture.bt709 = matrix == MFVideoTransferMatrix_BT709 ||
        (matrix != MFVideoTransferMatrix_BT601 && m.picture.height >= 720);
    m.picture.full_range = range == MFNominalRange_0_255;
}

HRESULT updateNV12Type(RuneMedia &m, IMFMediaType *decoded, UINT32 width, UINT32 height) {
    if (width < 2 || height < 2 || width > 16384 || height > 16384) return MF_E_INVALIDMEDIATYPE;
    rune_video::Crop crop{0, 0, width & ~1u, height & ~1u};
    MFVideoArea area{};
    UINT32 length = 0;
    if (SUCCEEDED(decoded->GetBlob(MF_MT_MINIMUM_DISPLAY_APERTURE, reinterpret_cast<UINT8 *>(&area), sizeof(area), &length)) &&
        length == sizeof(area) && area.Area.cx > 0 && area.Area.cy > 0) {
        crop.x = static_cast<UINT32>(std::max<int>(0, area.OffsetX.value)) & ~1u;
        crop.y = static_cast<UINT32>(std::max<int>(0, area.OffsetY.value)) & ~1u;
        if (crop.x >= width || crop.y >= height) return MF_E_INVALIDMEDIATYPE;
        crop.width = std::min<UINT32>(area.Area.cx, width - crop.x) & ~1u;
        crop.height = std::min<UINT32>(area.Area.cy, height - crop.y) & ~1u;
    } else if (m.firstVideoSample && m.crop.width && m.crop.height &&
               m.crop.x + m.crop.width <= width && m.crop.y + m.crop.height <= height) {
        // A decoder may first report the visible size and then switch to
        // macroblock-aligned storage without repeating the original aperture.
        crop = m.crop;
    }
    if (!crop.width || !crop.height) return MF_E_INVALIDMEDIATYPE;
    m.decodedWidth = width; m.decodedHeight = height;
    m.crop = crop;
    m.picture.width = crop.width; m.picture.height = crop.height;
    m.picture.natural_width = crop.width;
    UINT32 numerator, denominator;
    if (SUCCEEDED(MFGetAttributeRatio(decoded, MF_MT_PIXEL_ASPECT_RATIO, &numerator, &denominator)) && numerator && denominator)
        m.picture.natural_width = static_cast<UINT32>(std::min(double(UINT32_MAX), std::max(1.0, std::round(double(crop.width) * numerator / denominator))));
    updateColor(m, decoded);
    return S_OK;
}

HRESULT prepareReader(RuneMedia &m, bool audioOnly) {
    ComPtr<IMFAttributes> options;
    HRESULT hr = api().attributes(&options, 2);
    if (SUCCEEDED(hr)) hr = options->SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, TRUE);
    if (SUCCEEDED(hr) && m.nv12) hr = options->SetUINT32(MF_SOURCE_READER_DISABLE_DXVA, !m.ring.gpu);
    if (SUCCEEDED(hr) && m.ring.gpu) hr = options->SetUnknown(MF_SOURCE_READER_D3D_MANAGER, m.ring.gpu->manager.Get());
    if (SUCCEEDED(hr)) hr = options->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, !m.nv12 || m.ring.gpu != nullptr);
    if (SUCCEEDED(hr)) hr = api().open(m.uri.get(), options.Get(), &m.reader);
    if (FAILED(hr)) return hr;

    PROPVARIANT value{};
    m.info.duration = -1;
    if (SUCCEEDED(m.reader->GetPresentationAttribute(MF_SOURCE_READER_MEDIASOURCE, MF_PD_DURATION, &value))
        && value.vt == VT_UI8)
        m.info.duration = static_cast<double>(value.uhVal.QuadPart) / ticksPerSecond;
    PropVariantClear(&value);
    if (SUCCEEDED(m.reader->GetPresentationAttribute(MF_SOURCE_READER_MEDIASOURCE,
                                                    MF_SOURCE_READER_MEDIASOURCE_CHARACTERISTICS, &value))
        && value.vt == VT_UI4)
        m.canSeek = (value.ulVal & MFMEDIASOURCE_CAN_SEEK) != 0;
    PropVariantClear(&value);

    ComPtr<IMFMediaType> video, audio;
    if (!audioOnly) m.reader->GetNativeMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &video);
    m.reader->GetNativeMediaType(MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, &audio);
    m.info.has_audio = audio != nullptr;
    if (!video) {
        if (!audio) return MF_E_INVALIDSTREAMNUMBER;
        return selectFormat(m.reader.Get(), MF_SOURCE_READER_FIRST_AUDIO_STREAM, MFMediaType_Audio, MFAudioFormat_PCM);
    }

    UINT32 numerator = 0, denominator = 0;
    if (SUCCEEDED(MFGetAttributeRatio(video.Get(), MF_MT_FRAME_RATE, &numerator, &denominator))
        && numerator && denominator)
        m.info.frame_duration = static_cast<double>(denominator) / numerator;
    else if (m.nv12)
        m.info.frame_duration = 1.0 / 30.0;
    // Preserve the track's storage orientation during color conversion. Rune exposes
    // the original pixels and applies their display transform when drawing the frame.
    const UINT32 sourceRotation = MFGetAttributeUINT32(video.Get(), MF_MT_VIDEO_ROTATION, 0);
    hr = m.reader->SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS, FALSE);
    if (SUCCEEDED(hr)) hr = m.reader->SetStreamSelection(MF_SOURCE_READER_FIRST_VIDEO_STREAM, TRUE);
    if (FAILED(hr)) return hr;
    if (m.nv12) {
        hr = selectFormat(m.reader.Get(), MF_SOURCE_READER_FIRST_VIDEO_STREAM, MFMediaType_Video, MFVideoFormat_NV12, sourceRotation);
        if (FAILED(hr) && sourceRotation)
            hr = selectFormat(m.reader.Get(), MF_SOURCE_READER_FIRST_VIDEO_STREAM, MFMediaType_Video, MFVideoFormat_NV12);
    } else {
        hr = selectFormat(m.reader.Get(), MF_SOURCE_READER_FIRST_VIDEO_STREAM, MFMediaType_Video, MFVideoFormat_RGB32, sourceRotation);
        if (FAILED(hr) && sourceRotation)
            hr = selectFormat(m.reader.Get(), MF_SOURCE_READER_FIRST_VIDEO_STREAM, MFMediaType_Video, MFVideoFormat_RGB32);
    }
    if (FAILED(hr)) return hr;
    ComPtr<IMFMediaType> decoded;
    hr = m.reader->GetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, &decoded);
    if (SUCCEEDED(hr)) hr = MFGetAttributeSize(decoded.Get(), MF_MT_FRAME_SIZE, &m.decodedWidth, &m.decodedHeight);
    if (FAILED(hr)) return hr;
    if (m.nv12) {
        m.nativeMatrix = MFGetAttributeUINT32(video.Get(), MF_MT_YUV_MATRIX, 0);
        m.nativeRange = MFGetAttributeUINT32(video.Get(), MF_MT_VIDEO_NOMINAL_RANGE, 0);
        m.firstVideoSample = true;
        m.crop = {};
        hr = updateNV12Type(m, decoded.Get(), m.decodedWidth, m.decodedHeight);
        if (FAILED(hr)) return hr;
        m.info.width = m.crop.width; m.info.height = m.crop.height;
        m.info.rotation_clockwise = static_cast<int>(MFGetAttributeUINT32(decoded.Get(), MF_MT_VIDEO_ROTATION, sourceRotation));
        return S_OK;
    }
    const UINT32 remaining = MFGetAttributeUINT32(decoded.Get(), MF_MT_VIDEO_ROTATION, 0);
    if (remaining >= 360 || remaining % 90 || sourceRotation >= 360 || sourceRotation % 90) return MF_E_INVALIDMEDIATYPE;
    m.appliedRotation = (sourceRotation + 360 - remaining) % 360;
    m.info.rotation_clockwise = static_cast<int>(sourceRotation);
    const bool swapped = m.appliedRotation == 90 || m.appliedRotation == 270;
    m.info.width = swapped ? m.decodedHeight : m.decodedWidth;
    m.info.height = swapped ? m.decodedWidth : m.decodedHeight;
    if (!m.info.width || !m.info.height || m.info.width > 16384 || m.info.height > 16384) return MF_E_INVALIDMEDIATYPE;
    UINT32 rawStride = 0;
    if (SUCCEEDED(decoded->GetUINT32(MF_MT_DEFAULT_STRIDE, &rawStride)))
        m.stride = static_cast<LONG>(rawStride);
    else
        hr = api().stride(MFVideoFormat_RGB32.Data1, m.decodedWidth, &m.stride);
    return hr;
}

HRESULT readNext(RuneMedia &m, FrameSample &result) {
    result.sample.Reset();
    while (!m.reachedEOF) {
        DWORD flags = 0;
        HRESULT hr = m.reader->ReadSample(MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, nullptr,
                                           &flags, &result.time, &result.sample);
        if (FAILED(hr)) return hr;
        if (flags & MF_SOURCE_READERF_ERROR) return E_FAIL;
        if ((flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) || (m.nv12 && m.firstVideoSample && result.sample)) {
            ComPtr<IMFMediaType> type;
            UINT32 w = 0, h = 0;
            GUID subtype{};
            if (FAILED(m.reader->GetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, &type))
                || FAILED(MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &w, &h))
                || FAILED(type->GetGUID(MF_MT_SUBTYPE, &subtype))
                || subtype != (m.nv12 ? MFVideoFormat_NV12 : MFVideoFormat_RGB32))
                return MF_E_INVALIDMEDIATYPE;
            if (m.nv12) {
                hr = updateNV12Type(m, type.Get(), w, h);
                if (FAILED(hr)) return hr;
            } else if (w != m.decodedWidth || h != m.decodedHeight) return MF_E_INVALIDMEDIATYPE;
            UINT32 stride = 0;
            if (SUCCEEDED(type->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride)))
                m.stride = static_cast<LONG>(stride);
        }
        m.reachedEOF = (flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0;
        if (result.sample) {
            result.stride = m.stride;
            result.picture = m.picture;
            result.crop = m.crop;
            result.codedWidth = m.decodedWidth; result.codedHeight = m.decodedHeight;
            m.firstVideoSample = false;
            return S_OK;
        }
    }
    return S_FALSE;
}

HRESULT atTime(RuneMedia &m, LONGLONG target) {
    const bool backwards = m.current.sample && target < m.current.time;
    const bool farAhead = target > (m.current.sample ? m.current.time : 0) + 10000000;
    if (backwards || (farAhead && m.canSeek)) {
        if (!m.canSeek) return MF_E_INVALIDREQUEST;
        PROPVARIANT position{};
        position.vt = VT_I8;
        position.hVal.QuadPart = target;
        HRESULT hr = m.reader->SetCurrentPosition(GUID_NULL, position);
        if (FAILED(hr)) return hr;
        m.current.sample.Reset();
        m.next.sample.Reset();
        m.reachedEOF = false;
    }
    if (!m.current.sample) {
        HRESULT hr = readNext(m, m.current);
        if (hr != S_OK) return hr;
    }
    for (;;) {
        if (!m.next.sample && !m.reachedEOF) {
            HRESULT hr = readNext(m, m.next);
            if (FAILED(hr)) return hr;
        }
        if (!m.next.sample || m.next.time > target) return S_OK;
        m.current = std::move(m.next);
    }
}

HRESULT copyBGRA(const RuneMedia &m, uint8_t *dst) {
    ComPtr<IMFMediaBuffer> buffer;
    HRESULT hr = m.current.sample->ConvertToContiguousBuffer(&buffer);
    if (FAILED(hr)) return hr;
    ComPtr<IMF2DBuffer2> image;
    buffer.As(&image);
    BYTE *base = nullptr, *top = nullptr;
    DWORD length = 0;
    LONG pitch = m.current.stride;
    const size_t row = static_cast<size_t>(m.decodedWidth) * 4;
    if (image) {
        hr = image->Lock2DSize(MF2DBuffer_LockFlags_Read, &top, &pitch, &base, &length);
    } else {
        hr = buffer->Lock(&base, nullptr, &length);
        if (SUCCEEDED(hr)) {
            const uint64_t offset = pitch < 0 ? static_cast<uint64_t>(-static_cast<int64_t>(pitch)) * (m.decodedHeight - 1) : 0;
            if (offset < length) top = base + offset;
        }
    }
    if (FAILED(hr)) return hr;
    const int64_t topOffset = top && base ? static_cast<int64_t>(reinterpret_cast<uintptr_t>(top))
                                         - static_cast<int64_t>(reinterpret_cast<uintptr_t>(base)) : -1;
    const int64_t last = topOffset + static_cast<int64_t>(pitch) * (m.decodedHeight - 1);
    if (topOffset < 0 || last < 0 || topOffset + row > length || last + row > length) {
        hr = MF_E_BUFFERTOOSMALL;
    } else if (!m.appliedRotation) {
        for (uint32_t y = 0; y < m.info.height; ++y) {
            uint8_t *out = dst + row * y;
            std::memcpy(out, top + static_cast<int64_t>(pitch) * y, row);
            // MFVideoFormat_RGB32 reserves the fourth byte in each BGRX pixel.
            for (size_t x = 3; x < row; x += 4) out[x] = 255;
        }
    } else {
        // Some transforms deliver rotated RGB despite requesting the track's orientation.
        // Map each stored scanline onto those decoded pixels while packing the BGRA output.
        const int64_t right = static_cast<int64_t>(m.decodedWidth - 1) * 4;
        const int64_t bottom = static_cast<int64_t>(m.decodedHeight - 1) * pitch;
        int64_t origin, stepX, stepY;
        switch (m.appliedRotation) {
        case 90:  origin = right;          stepX = pitch;  stepY = -4;     break;
        case 180: origin = bottom + right; stepX = -4;     stepY = -int64_t(pitch); break;
        default:  origin = bottom;         stepX = -int64_t(pitch); stepY = 4; break;
        }
        for (uint32_t y = 0; y < m.info.height; ++y) {
            const uint8_t *scanline = top + (origin + y * stepY);
            for (uint32_t x = 0; x < m.info.width; ++x) {
                std::memcpy(dst, scanline + x * stepX, 3);
                dst[3] = 255;
                dst += 4;
            }
        }
    }
    if (image) image->Unlock2D();
    else buffer->Unlock();
    return hr;
}

HRESULT statusOf(RuneMedia &m, double *seconds, bool *ended) {
    if (m.audioOpened) {
        HRESULT hr = m.audio.position(seconds, ended);
        if (SUCCEEDED(hr)) {
            m.anchor = *seconds;
            m.anchorTick = RuneMedia::Clock::now();
            return S_OK;
        }
        if (!m.info.width) return hr;
        // Losing an audio endpoint doesn't invalidate decoded pictures. Keep the
        // last known position on the monotonic clock until sound can be reopened.
        m.releaseAudio(hr);
    }
    *seconds = m.clock();
    *ended = m.playing && ((m.info.duration >= 0 && *seconds >= m.info.duration)
                            || (m.info.duration < 0 && m.reachedEOF && m.current.sample
                                && *seconds > m.current.time / ticksPerSecond + m.info.frame_duration));
    return S_OK;
}

} // namespace

static RuneMedia *openMedia(const char *uri, int audio_only, int headless, const int64_t *adapter,
                            RuneMediaInfo *info, RunePictureInfo *picture, char *error, size_t capacity) {
    Apartment apartment;
    if (!uri || !info || !apartment.ready() || !api().available()) {
        failure(error, capacity, "initialization (Windows Media Feature Pack required)", E_NOINTERFACE);
        return nullptr;
    }
    std::unique_ptr<RuneMedia> m(new(std::nothrow) RuneMedia);
    if (!m) { failure(error, capacity, "allocation", E_OUTOFMEMORY); return nullptr; }
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, uri, -1, nullptr, 0);
    if (count <= 1) { failure(error, capacity, "URI conversion", E_INVALIDARG); return nullptr; }
    m->uri.reset(new(std::nothrow) wchar_t[count]);
    if (!m->uri) { failure(error, capacity, "URI allocation", E_OUTOFMEMORY); return nullptr; }
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, uri, -1, m->uri.get(), count);
    HRESULT hr = CoIncrementMTAUsage(&m->mta);
    if (SUCCEEDED(hr)) hr = api().startup(MF_VERSION, MFSTARTUP_FULL);
    if (SUCCEEDED(hr)) {
        m->started = true;
        m->headless = headless != 0;
        if (picture) {
            m->nv12 = true;
            try { if (!m->headless) m->ring.gpu = rune_video::openDevice(adapter); }
            catch (const std::bad_alloc &) { failure(error, capacity, "video device allocation", E_OUTOFMEMORY); return nullptr; }
        }
        hr = prepareReader(*m, audio_only != 0);
        if (FAILED(hr) && hr != MF_E_INVALIDSTREAMNUMBER && m->ring.gpu) {
            m->reader.Reset();
            m->ring.gpu.reset();
            hr = prepareReader(*m, audio_only != 0);
        }
        if (FAILED(hr) && hr != MF_E_INVALIDSTREAMNUMBER && m->nv12) {
            m->reader.Reset();
            m->nv12 = false;
            hr = prepareReader(*m, audio_only != 0);
        }
    }
    if (FAILED(hr)) {
        if (hr == MF_E_INVALIDSTREAMNUMBER && error && capacity)
            std::snprintf(error, capacity, "Media has no playable %s track", audio_only ? "audio" : "video");
        else failure(error, capacity, "opening stream", hr);
        return nullptr;
    }
    *info = m->info;
    if (picture) *picture = m->nv12 ? m->picture : RunePictureInfo{};
    return m.release();
}

RuneMedia *rune_media_open(const char *uri, int audio_only, int headless,
                           RuneMediaInfo *info, char *error, size_t capacity) {
    return openMedia(uri, audio_only, headless, nullptr, info, nullptr, error, capacity);
}

RuneMedia *rune_media_open_video(const char *uri, const int64_t *adapter, RuneMediaInfo *info,
                                 RunePictureInfo *picture, char *error, size_t capacity) {
    if (!picture) { failure(error, capacity, "video metadata", E_INVALIDARG); return nullptr; }
    return openMedia(uri, 0, 0, adapter, info, picture, error, capacity);
}

RuneMedia *rune_media_open_still(const char *uri, RuneMediaInfo *info, RunePictureInfo *picture,
                                 char *error, size_t capacity) {
    if (!picture) { failure(error, capacity, "still metadata", E_INVALIDARG); return nullptr; }
    return openMedia(uri, 0, 1, nullptr, info, picture, error, capacity);
}

void rune_media_close(RuneMedia *m) {
    Apartment apartment;
    delete m;
}

static HRESULT selectFrame(RuneMedia *m, double seconds) {
    const bool poll = seconds < 0;
    bool ended = false;
    HRESULT hr = S_OK;
    if (SUCCEEDED(hr) && poll) hr = statusOf(*m, &seconds, &ended);
    if (SUCCEEDED(hr) && poll && m->playing) seconds += rune_media_present_lead() * m->rate;
    if (!poll && m->headless && m->nv12) seconds += m->info.frame_duration * 0.5;
    if (SUCCEEDED(hr)) {
        if (!std::isfinite(seconds) || seconds > 9e11) hr = E_INVALIDARG;
        else {
            // At the exact end, a seek can land past the last sample.
            if (m->info.duration > 0 && seconds >= m->info.duration) {
                const double halfFrame = m->info.frame_duration > 0 ? m->info.frame_duration * 0.5 : 0.001;
                seconds = std::fmax(0.0, m->info.duration - halfFrame);
            }
            hr = atTime(*m, static_cast<LONGLONG>(std::llround(seconds * ticksPerSecond)));
        }
    }
    return (hr == S_OK && poll && m->lastDelivered == m->current.time) ? S_FALSE : hr;
}

int rune_media_picture(RuneMedia *m, double seconds, double retainingTime, RuneMediaPicture **picture, char *error, size_t capacity) {
    if (!m || !picture || !std::isfinite(seconds)) {
        failure(error, capacity, "picture arguments", E_INVALIDARG); return -1;
    }
    *picture = nullptr;
    if (!m->nv12) return 2;
    if (!m->info.width) return 0;
    Apartment apartment;
    auto capture = [&]() {
        HRESULT hr = selectFrame(m, seconds);
        if (hr != S_OK) return hr;
        if (retainingTime >= 0 && retainingTime == double(m->current.time) / ticksPerSecond) return S_FALSE;
        auto &sample = m->current;
        return m->ring.capture(sample.sample.Get(), sample.codedWidth, sample.codedHeight, sample.crop, picture);
    };
    HRESULT hr = apartment.ready() ? capture() : apartment.status;
    if (FAILED(hr) && apartment.ready() && m->ring.gpu &&
        (FAILED(m->ring.gpu->device->GetDeviceRemovedReason()) || hr == MF_E_HW_MFT_FAILED_START_STREAMING ||
         hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET)) {
        const RunePictureInfo expected = m->picture;
        m->next = {}; m->current = {};
        m->reader.Reset();
        m->ring = {};
        m->reachedEOF = false;
        m->lastDelivered = -1;
        hr = prepareReader(*m, false);
        if (SUCCEEDED(hr) && (m->picture.width != expected.width || m->picture.height != expected.height))
            hr = MF_E_INVALIDMEDIATYPE;
        if (SUCCEEDED(hr)) hr = capture();
    }
    if (hr == S_FALSE) return 0;
    if (FAILED(hr)) { failure(error, capacity, "NV12 video picture", hr); return -1; }
    (*picture)->info = m->current.picture;
    m->lastDelivered = m->current.time;
    return 1;
}

int rune_media_frame(RuneMedia *m, double seconds, uint8_t *pixels, size_t length,
                     char *error, size_t capacity) {
    if (!m || m->nv12 || !std::isfinite(seconds) || !m->info.width || !pixels
        || length < static_cast<size_t>(m->info.width) * m->info.height * 4) {
        failure(error, capacity, "frame buffer", E_INVALIDARG); return -1;
    }
    Apartment apartment;
    HRESULT hr = apartment.ready() ? selectFrame(m, seconds) : apartment.status;
    if (hr == S_FALSE) return 0;
    if (SUCCEEDED(hr)) hr = copyBGRA(*m, pixels);
    if (FAILED(hr)) { failure(error, capacity, "video decode", hr); return -1; }
    m->lastDelivered = m->current.time;
    return 1;
}

double rune_media_last_picture_time(const RuneMedia *m) {
    return m && m->lastDelivered >= 0 ? double(m->lastDelivered) / ticksPerSecond : -1.0;
}

int rune_media_transport(RuneMedia *m, int playing, double seek, double rate, double volume,
                         int muted, char *error, size_t capacity) {
    if (!m || !std::isfinite(seek) || !std::isfinite(rate) || rate <= 0
        || !std::isfinite(volume) || volume < 0 || volume > 1)
        return failure(error, capacity, "transport parameters", E_INVALIDARG);
    Apartment apartment;
    if (!apartment.ready()) return failure(error, capacity, "COM initialization", apartment.status);
    double time = m->clock();
    bool ended = false;
    if (m->audioOpened) {
        HRESULT hr = statusOf(*m, &time, &ended);
        if (FAILED(hr)) return failure(error, capacity, "audio position", hr);
        if (muted || volume == 0) m->releaseAudio();
    }
    if (seek >= 0) time = m->info.duration >= 0 ? std::fmin(seek, m->info.duration) : seek;
    // Opening the audio endpoint is deferred until playback first needs it.
    const bool needsAudio = !m->headless && m->info.has_audio && playing && !muted && volume > 0;
    bool newAudio = false;
    if (!m->audioOpened && needsAudio) {
        HRESULT hr = m->audio.open(m->uri.get());
        if (FAILED(hr)) {
            if (!m->info.width) return failure(error, capacity, "audio output", hr);
            m->releaseAudio(hr);
        } else {
            m->audioOpened = true;
            newAudio = true;
        }
    }
    if (m->audioOpened) {
        HRESULT hr = S_OK;
        if (seek >= 0 || (newAudio && time > 0)) hr = m->audio.seek(time);
        if (SUCCEEDED(hr) && (newAudio || rate != m->rate)) hr = m->audio.setRate(static_cast<float>(rate));
        if (SUCCEEDED(hr)) hr = m->audio.setVolume(static_cast<float>(volume));
        if (SUCCEEDED(hr)) hr = m->audio.setMuted(muted != 0);
        if (SUCCEEDED(hr) && (newAudio || seek >= 0 || ended || m->playing != (playing != 0)))
            hr = m->audio.setPlaying(playing != 0);
        if (FAILED(hr)) {
            if (!m->info.width) return failure(error, capacity, "audio transport", hr);
            m->releaseAudio(hr);
        }
    }
    m->anchor = time;
    m->anchorTick = RuneMedia::Clock::now();
    m->playing = playing != 0;
    m->rate = rate;
    if (seek >= 0) m->lastDelivered = -1;
    return 1;
}

int rune_media_status(RuneMedia *m, double *seconds, int *ended, char *error, size_t capacity) {
    if (!m || !seconds || !ended) return failure(error, capacity, "status input", E_INVALIDARG);
    Apartment apartment;
    bool done = false;
    HRESULT hr = apartment.ready() ? statusOf(*m, seconds, &done) : apartment.status;
    if (FAILED(hr)) return failure(error, capacity, "playback clock", hr);
    *ended = done ? 1 : 0;
    return 1;
}

double rune_media_next_video_delay(RuneMedia *m) {
    if (!m || !m->playing) return rune_media_refresh_period();
    Apartment apartment;
    double time = 0;
    bool ended = false;
    if (!apartment.ready() || FAILED(statusOf(*m, &time, &ended))) return rune_media_refresh_period();
    if (m->next.sample)
        return rune_media_refresh_wake((m->next.time / ticksPerSecond - time) / m->rate);
    // The last picture stays on screen through its entire duration. EOS needs the
    // actual media time, so do not bring this last wake forward to a display slot.
    if (m->reachedEOF && m->info.duration >= 0)
        return std::fmax(0.001, (m->info.duration - time) / m->rate);
    return rune_media_refresh_period();
}
#endif
