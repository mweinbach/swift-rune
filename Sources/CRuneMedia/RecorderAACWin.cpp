#ifdef _WIN32
#define NOMINMAX
#include "RuneMicrophone.h"
#include "WindowsMediaFoundation.h"
#include <mferror.h>
#include <wrl/client.h>
#include <cmath>
#include <limits>
#include <memory>
#include <new>

using Microsoft::WRL::ComPtr;
using rune_mf::api;
using rune_mf::failure;

// All operations are performed on the owning recorder worker. Its COM apartment
// outlives the writer and the matching MFShutdown, including on initialization failure.
struct RuneMicAAC {
    rune_mf::Apartment apartment;
    ComPtr<IMFSinkWriter> writer;
    DWORD stream = 0;
    uint32_t rate = 0;
    uint16_t channels = 0;
    uint64_t frames = 0;
    HRESULT result = S_OK;
    bool started = false;
    bool finished = false;

    ~RuneMicAAC() {
        writer.Reset();
        if (started) api().shutdown();
    }
};

namespace {
constexpr uint64_t ticksPerSecond = 10000000;

HRESULT audioType(REFGUID subtype, uint32_t rate, uint16_t channels, IMFMediaType **type) {
    ComPtr<IMFMediaType> media;
    HRESULT hr = api().mediaType(&media);
    if (SUCCEEDED(hr)) hr = media->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    if (SUCCEEDED(hr)) hr = media->SetGUID(MF_MT_SUBTYPE, subtype);
    if (SUCCEEDED(hr)) hr = media->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, channels);
    if (SUCCEEDED(hr)) hr = media->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, rate);
    if (SUCCEEDED(hr)) hr = media->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    if (SUCCEEDED(hr)) hr = media->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                                             subtype == MFAudioFormat_AAC ? 16000u : rate * channels * 2);
    if (SUCCEEDED(hr) && subtype == MFAudioFormat_PCM)
        hr = media->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, channels * 2);
    if (SUCCEEDED(hr)) *type = media.Detach();
    return hr;
}

HRESULT begin(RuneMicAAC &encoder, const wchar_t *path) {
    ComPtr<IMFAttributes> settings;
    HRESULT hr = api().attributes(&settings, 2);
    if (SUCCEEDED(hr)) hr = settings->SetGUID(MF_TRANSCODE_CONTAINERTYPE, MFTranscodeContainerType_MPEG4);
    if (SUCCEEDED(hr)) hr = settings->SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, TRUE);
    if (SUCCEEDED(hr)) hr = api().writer(path, nullptr, settings.Get(), &encoder.writer);
    ComPtr<IMFMediaType> output, input;
    if (SUCCEEDED(hr)) hr = audioType(MFAudioFormat_AAC, encoder.rate, encoder.channels, &output);
    if (SUCCEEDED(hr)) hr = encoder.writer->AddStream(output.Get(), &encoder.stream);
    if (SUCCEEDED(hr)) hr = audioType(MFAudioFormat_PCM, encoder.rate, encoder.channels, &input);
    if (SUCCEEDED(hr)) hr = encoder.writer->SetInputMediaType(encoder.stream, input.Get(), nullptr);
    if (SUCCEEDED(hr)) hr = encoder.writer->BeginWriting();
    return hr;
}

int16_t pcm16(float value) {
    if (!std::isfinite(value)) return 0;
    if (value >= 1.0f) return 32767;
    if (value <= -1.0f) return -32768;
    return static_cast<int16_t>(std::lround(value * 32767.0f));
}

HRESULT writeSamples(RuneMicAAC &encoder, const float *samples, uint32_t count) {
    const uint64_t sampleCount = static_cast<uint64_t>(count) * encoder.channels;
    if (sampleCount > std::numeric_limits<DWORD>::max() / sizeof(int16_t)) return E_INVALIDARG;
    if (encoder.frames > static_cast<uint64_t>(std::numeric_limits<LONGLONG>::max()) / ticksPerSecond - count)
        return HRESULT_FROM_WIN32(ERROR_ARITHMETIC_OVERFLOW);
    const DWORD bytes = static_cast<DWORD>(sampleCount * sizeof(int16_t));
    ComPtr<IMFMediaBuffer> buffer;
    HRESULT hr = api().buffer(bytes, &buffer);
    BYTE *data = nullptr;
    if (SUCCEEDED(hr)) hr = buffer->Lock(&data, nullptr, nullptr);
    if (FAILED(hr)) return hr;
    auto *destination = reinterpret_cast<int16_t *>(data);
    for (size_t i = 0; i < sampleCount; ++i) destination[i] = pcm16(samples[i]);
    hr = buffer->Unlock();
    if (SUCCEEDED(hr)) hr = buffer->SetCurrentLength(bytes);
    ComPtr<IMFSample> sample;
    if (SUCCEEDED(hr)) hr = api().sample(&sample);
    if (SUCCEEDED(hr)) hr = sample->AddBuffer(buffer.Get());
    const LONGLONG start = static_cast<LONGLONG>(encoder.frames * ticksPerSecond / encoder.rate);
    const LONGLONG end = static_cast<LONGLONG>((encoder.frames + count) * ticksPerSecond / encoder.rate);
    if (SUCCEEDED(hr)) hr = sample->SetSampleTime(start);
    if (SUCCEEDED(hr)) hr = sample->SetSampleDuration(end - start);
    if (SUCCEEDED(hr)) hr = encoder.writer->WriteSample(encoder.stream, sample.Get());
    if (SUCCEEDED(hr)) encoder.frames += count;
    return hr;
}
} // namespace

RuneMicAAC *rune_mic_aac_open(const char *path, uint32_t rate, uint16_t channels, char *error, size_t capacity) {
    if (!path || !*path) {
        failure(error, capacity, "AAC output path", E_INVALIDARG);
        return nullptr;
    }
    if ((rate != 44100 && rate != 48000) || (channels != 1 && channels != 2)) {
        if (error && capacity)
            std::snprintf(error, capacity, "Windows AAC recording supports 44100 or 48000 Hz with one or two channels");
        return nullptr;
    }
    if (!api().canWrite()) {
        if (error && capacity)
            std::snprintf(error, capacity, "Install the Windows Media Feature Pack to record AAC audio");
        return nullptr;
    }
    const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, nullptr, 0);
    if (!length) {
        failure(error, capacity, "UTF-8 output path", HRESULT_FROM_WIN32(GetLastError()));
        return nullptr;
    }
    std::unique_ptr<wchar_t[]> wide(new (std::nothrow) wchar_t[length]);
    std::unique_ptr<RuneMicAAC> encoder(new (std::nothrow) RuneMicAAC());
    if (!wide || !encoder) {
        failure(error, capacity, "AAC allocation", E_OUTOFMEMORY);
        return nullptr;
    }
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide.get(), length)) {
        failure(error, capacity, "converting UTF-8 output path", HRESULT_FROM_WIN32(GetLastError()));
        return nullptr;
    }
    encoder->rate = rate;
    encoder->channels = channels;
    HRESULT hr = encoder->apartment.ready() ? api().startup(MF_VERSION, MFSTARTUP_FULL) : encoder->apartment.status;
    encoder->started = SUCCEEDED(hr);
    if (SUCCEEDED(hr)) hr = begin(*encoder, wide.get());
    if (FAILED(hr)) {
        failure(error, capacity, "opening the MPEG-4 file and AAC encoder", hr);
        return nullptr;
    }
    return encoder.release();
}

int rune_mic_aac_write(RuneMicAAC *encoder, const float *samples, uint32_t frames, char *error, size_t capacity) {
    if (!encoder || (!samples && frames) || encoder->finished)
        return failure(error, capacity, "invalid AAC write", E_INVALIDARG);
    if (SUCCEEDED(encoder->result) && frames) encoder->result = writeSamples(*encoder, samples, frames);
    return SUCCEEDED(encoder->result) ? 1 : failure(error, capacity, "encoding PCM to AAC", encoder->result);
}

int rune_mic_aac_finish(RuneMicAAC *encoder, char *error, size_t capacity) {
    if (!encoder) return failure(error, capacity, "invalid AAC finalization", E_INVALIDARG);
    if (!encoder->finished) {
        encoder->finished = true;
        if (SUCCEEDED(encoder->result))
            encoder->result = encoder->frames ? encoder->writer->Finalize() : MF_E_NO_SAMPLE_TIMESTAMP;
        encoder->writer.Reset();
    }
    if (!encoder->frames && encoder->result == MF_E_NO_SAMPLE_TIMESTAMP) {
        if (error && capacity) std::snprintf(error, capacity, "No audio samples were recorded");
        return 0;
    }
    return SUCCEEDED(encoder->result) ? 1 : failure(error, capacity, "finalizing MPEG-4 audio", encoder->result);
}

void rune_mic_aac_close(RuneMicAAC *encoder) {
    delete encoder;
}
#endif
