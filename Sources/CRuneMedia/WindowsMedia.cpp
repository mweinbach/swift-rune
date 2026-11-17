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
    LONG stride = 0;
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

    double clock() const {
        const double elapsed = std::chrono::duration<double>(Clock::now() - anchorTick).count();
        const double now = anchor + (playing ? elapsed * rate : 0);
        return info.duration < 0 || now < info.duration ? now : info.duration;
    }
};

namespace {

HRESULT selectFormat(IMFSourceReader *reader, DWORD stream, REFGUID major, REFGUID subtype) {
    ComPtr<IMFMediaType> out;
    HRESULT hr = api().mediaType(&out);
    if (SUCCEEDED(hr)) hr = out->SetGUID(MF_MT_MAJOR_TYPE, major);
    if (SUCCEEDED(hr)) hr = out->SetGUID(MF_MT_SUBTYPE, subtype);
    if (SUCCEEDED(hr)) hr = reader->SetCurrentMediaType(stream, nullptr, out.Get());
    return hr;
}

HRESULT prepareReader(RuneMedia &m, bool audioOnly) {
    ComPtr<IMFAttributes> options;
    HRESULT hr = api().attributes(&options, 2);
    if (SUCCEEDED(hr)) hr = options->SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, TRUE);
    if (SUCCEEDED(hr)) hr = options->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
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
    if (!video && !audio) return MF_E_INVALIDMEDIATYPE;
    if (!video)
        return selectFormat(m.reader.Get(), MF_SOURCE_READER_FIRST_AUDIO_STREAM, MFMediaType_Audio, MFAudioFormat_PCM);

    UINT32 numerator = 0, denominator = 0;
    if (SUCCEEDED(MFGetAttributeRatio(video.Get(), MF_MT_FRAME_RATE, &numerator, &denominator))
        && numerator && denominator)
        m.info.frame_duration = static_cast<double>(denominator) / numerator;
    hr = m.reader->SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS, FALSE);
    if (SUCCEEDED(hr)) hr = m.reader->SetStreamSelection(MF_SOURCE_READER_FIRST_VIDEO_STREAM, TRUE);
    if (SUCCEEDED(hr)) hr = selectFormat(m.reader.Get(), MF_SOURCE_READER_FIRST_VIDEO_STREAM,
                                         MFMediaType_Video, MFVideoFormat_RGB32);
    if (FAILED(hr)) return hr;
    ComPtr<IMFMediaType> decoded;
    hr = m.reader->GetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, &decoded);
    if (SUCCEEDED(hr)) hr = MFGetAttributeSize(decoded.Get(), MF_MT_FRAME_SIZE, &m.info.width, &m.info.height);
    if (FAILED(hr)) return hr;
    // The video processor can rotate the pixels while converting them to RGB32.
    // Apply only the correction that still belongs to its negotiated output.
    const UINT32 rotation = MFGetAttributeUINT32(decoded.Get(), MF_MT_VIDEO_ROTATION, 0);
    if (rotation < 360 && rotation % 90 == 0) m.info.rotation_clockwise = static_cast<int>(rotation);
    if (!m.info.width || !m.info.height || m.info.width > 16384 || m.info.height > 16384) return MF_E_INVALIDMEDIATYPE;
    UINT32 rawStride = 0;
    if (SUCCEEDED(decoded->GetUINT32(MF_MT_DEFAULT_STRIDE, &rawStride)))
        m.stride = static_cast<LONG>(rawStride);
    else
        hr = api().stride(MFVideoFormat_RGB32.Data1, m.info.width, &m.stride);
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
        if (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) {
            ComPtr<IMFMediaType> type;
            UINT32 w = 0, h = 0;
            GUID subtype{};
            if (FAILED(m.reader->GetCurrentMediaType(MF_SOURCE_READER_FIRST_VIDEO_STREAM, &type))
                || FAILED(MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &w, &h))
                || FAILED(type->GetGUID(MF_MT_SUBTYPE, &subtype))
                || w != m.info.width || h != m.info.height || subtype != MFVideoFormat_RGB32)
                return MF_E_INVALIDMEDIATYPE;
            UINT32 stride = 0;
            if (SUCCEEDED(type->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride)))
                m.stride = static_cast<LONG>(stride);
        }
        m.reachedEOF = (flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0;
        if (result.sample) {
            result.stride = m.stride;
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
        m.current.sample.Attach(m.next.sample.Detach());
        m.current.time = m.next.time;
        m.current.stride = m.next.stride;
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
    const size_t row = static_cast<size_t>(m.info.width) * 4;
    if (image) {
        hr = image->Lock2DSize(MF2DBuffer_LockFlags_Read, &top, &pitch, &base, &length);
    } else {
        hr = buffer->Lock(&base, nullptr, &length);
        if (SUCCEEDED(hr)) {
            const uint64_t offset = pitch < 0 ? static_cast<uint64_t>(-static_cast<int64_t>(pitch)) * (m.info.height - 1) : 0;
            if (offset < length) top = base + offset;
        }
    }
    if (FAILED(hr)) return hr;
    const int64_t topOffset = top && base ? static_cast<int64_t>(reinterpret_cast<uintptr_t>(top))
                                         - static_cast<int64_t>(reinterpret_cast<uintptr_t>(base)) : -1;
    const int64_t last = topOffset + static_cast<int64_t>(pitch) * (m.info.height - 1);
    if (topOffset < 0 || last < 0 || topOffset + row > length || last + row > length) {
        hr = MF_E_BUFFERTOOSMALL;
    } else {
        for (uint32_t y = 0; y < m.info.height; ++y) {
            uint8_t *out = dst + row * y;
            std::memcpy(out, top + static_cast<int64_t>(pitch) * y, row);
            // MFVideoFormat_RGB32 reserves the fourth byte in each BGRX pixel.
            for (size_t x = 3; x < row; x += 4) out[x] = 255;
        }
    }
    if (image) image->Unlock2D();
    else buffer->Unlock();
    return hr;
}

HRESULT statusOf(RuneMedia &m, double *seconds, bool *ended) {
    if (m.audioOpened) return m.audio.position(seconds, ended);
    *seconds = m.clock();
    *ended = m.playing && ((m.info.duration >= 0 && *seconds >= m.info.duration)
                            || (m.info.duration < 0 && m.reachedEOF && m.current.sample
                                && *seconds > m.current.time / ticksPerSecond + m.info.frame_duration));
    return S_OK;
}

} // namespace

RuneMedia *rune_media_open(const char *uri, int audio_only, int headless,
                           RuneMediaInfo *info, char *error, size_t capacity) {
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
        hr = prepareReader(*m, audio_only != 0);
    }
    if (FAILED(hr)) { failure(error, capacity, "opening stream", hr); return nullptr; }
    *info = m->info;
    return m.release();
}

void rune_media_close(RuneMedia *m) {
    Apartment apartment;
    delete m;
}

int rune_media_frame(RuneMedia *m, double seconds, uint8_t *pixels, size_t length,
                     char *error, size_t capacity) {
    if (!m || !std::isfinite(seconds) || !m->info.width || !pixels
        || length < static_cast<size_t>(m->info.width) * m->info.height * 4) {
        failure(error, capacity, "frame buffer", E_INVALIDARG); return -1;
    }
    Apartment apartment;
    const bool poll = seconds < 0;
    bool ended = false;
    HRESULT hr = apartment.ready() ? S_OK : apartment.status;
    if (SUCCEEDED(hr) && poll) hr = statusOf(*m, &seconds, &ended);
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
    if (hr == S_FALSE || (SUCCEEDED(hr) && poll && m->lastDelivered == m->current.time)) return 0;
    if (SUCCEEDED(hr)) hr = copyBGRA(*m, pixels);
    if (FAILED(hr)) { failure(error, capacity, "video decode", hr); return -1; }
    m->lastDelivered = m->current.time;
    return 1;
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
        HRESULT hr = m->audio.position(&time, &ended);
        if (FAILED(hr)) return failure(error, capacity, "audio position", hr);
    }
    if (seek >= 0) time = m->info.duration >= 0 ? std::fmin(seek, m->info.duration) : seek;
    // Opening the audio endpoint is deferred until playback first needs it.
    const bool needsAudio = !m->headless && m->info.has_audio && playing && !muted && volume > 0;
    bool newAudio = false;
    if (!m->audioOpened && needsAudio) {
        HRESULT hr = m->audio.open(m->uri.get());
        if (FAILED(hr)) return failure(error, capacity, "audio output", hr);
        m->audioOpened = true;
        newAudio = true;
    }
    if (m->audioOpened) {
        HRESULT hr = S_OK;
        if (seek >= 0 || (newAudio && time > 0)) hr = m->audio.seek(time);
        if (SUCCEEDED(hr) && (newAudio || rate != m->rate)) hr = m->audio.setRate(static_cast<float>(rate));
        if (SUCCEEDED(hr)) hr = m->audio.setVolume(static_cast<float>(volume));
        if (SUCCEEDED(hr)) hr = m->audio.setMuted(muted != 0);
        if (SUCCEEDED(hr) && (newAudio || seek >= 0 || ended || m->playing != (playing != 0)))
            hr = m->audio.setPlaying(playing != 0);
        if (FAILED(hr)) return failure(error, capacity, "audio transport", hr);
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
#endif
