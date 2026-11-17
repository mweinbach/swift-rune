#if defined(_WIN32)
#include "include/RuneMicrophone.h"

#include <windows.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <new>

#if __has_include(<windows.security.authorization.appcapabilityaccess.h>)
#include <appmodel.h>
#include <roapi.h>
#include <winstring.h>
#include <windows.security.authorization.appcapabilityaccess.h>
#endif

static void describe_failure(HRESULT hr, const char *operation, char *error, size_t size) {
    if (!error || !size) return;
    const char *detail = "Windows audio error";
    switch (hr) {
        case E_ACCESSDENIED: detail = "microphone access denied by Windows privacy settings"; break;
        case HRESULT_FROM_WIN32(ERROR_NOT_FOUND): detail = "no default microphone is connected"; break;
        case AUDCLNT_E_DEVICE_INVALIDATED:
        case AUDCLNT_E_RESOURCES_INVALIDATED: detail = "the microphone was disconnected or reconfigured"; break;
        case AUDCLNT_E_UNSUPPORTED_FORMAT: detail = "the requested sample format is unavailable"; break;
        case AUDCLNT_E_SERVICE_NOT_RUNNING: detail = "Windows Audio service is stopped"; break;
        case E_OUTOFMEMORY: detail = "out of memory"; break;
        case E_INVALIDARG: detail = "invalid argument"; break;
    }
    std::snprintf(error, size, "%s: %s (HRESULT 0x%08lx)", operation, detail,
                  static_cast<unsigned long>(hr));
}

int rune_mic_permission(void) {
#if defined(____x_ABI_CWindows_CSecurity_CAuthorization_CAppCapabilityAccess_CIAppCapabilityStatics_INTERFACE_DEFINED__)
    namespace capability = ABI::Windows::Security::Authorization::AppCapabilityAccess;
    // CheckAccess inspects policy without requesting access or creating an audio stream.
    HRESULT apartment = RoInitialize(RO_INIT_MULTITHREADED);
    if (FAILED(apartment) && apartment != RPC_E_CHANGED_MODE) return 0;
    int result = 0;
    HSTRING type = nullptr, name = nullptr;
    capability::IAppCapabilityStatics *factory = nullptr;
    capability::IAppCapability *microphone = nullptr;
    const wchar_t class_name[] = L"Windows.Security.Authorization.AppCapabilityAccess.AppCapability";
    const wchar_t capability_name[] = L"microphone";
    HRESULT hr = WindowsCreateString(class_name, ARRAYSIZE(class_name) - 1, &type);
    if (SUCCEEDED(hr)) hr = WindowsCreateString(capability_name, ARRAYSIZE(capability_name) - 1, &name);
    if (SUCCEEDED(hr)) hr = RoGetActivationFactory(type, IID_PPV_ARGS(&factory));
    if (SUCCEEDED(hr)) hr = factory->Create(name, &microphone);
    capability::AppCapabilityAccessStatus access;
    if (SUCCEEDED(hr) && SUCCEEDED(microphone->CheckAccess(&access))) {
        switch (access) {
            case capability::AppCapabilityAccessStatus_Allowed: result = 1; break;
            case capability::AppCapabilityAccessStatus_DeniedByUser: result = -1; break;
            case capability::AppCapabilityAccessStatus_DeniedBySystem: result = -2; break;
            // Unpackaged Win32 processes may have no manifest capability declaration.
            // WASAPI checks effective device access on an explicit recording request.
            case capability::AppCapabilityAccessStatus_NotDeclaredByApp: {
                UINT32 length = 0;
                if (GetCurrentPackageFullName(&length, nullptr) == ERROR_INSUFFICIENT_BUFFER) result = -2;
                break;
            }
            default: break;
        }
    }
    if (microphone) microphone->Release();
    if (factory) factory->Release();
    WindowsDeleteString(name);
    WindowsDeleteString(type);
    if (SUCCEEDED(apartment)) RoUninitialize();
    return result;
#else
    return 0;
#endif
}

struct RuneMic {
    IMMDeviceEnumerator *devices = nullptr;
    wchar_t *endpoint_id = nullptr;
    ULONGLONG next_device_check = 0;
    IAudioClient *client = nullptr;
    IAudioCaptureClient *capture = nullptr;
    HANDLE ready = nullptr;
    float *packet = nullptr;
    UINT32 packet_capacity = 0, packet_frames = 0, next_frame = 0;
    uint32_t rate = 0;
    uint16_t channels = 0;
    bool synthetic = false, paused = false, running = false, release_apartment = false;
    ULONGLONG next_tick = 0;
    uint64_t generated = 0;
    uint32_t fractional_frames = 0;

    ~RuneMic() {
        if (running && client) client->Stop();
        if (capture) capture->Release();
        if (client) client->Release();
        if (devices) devices->Release();
        CoTaskMemFree(endpoint_id);
        if (ready) CloseHandle(ready);
        delete[] packet;
        if (release_apartment) CoUninitialize();
    }

    HRESULT open_device() {
        HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        release_apartment = SUCCEEDED(hr);
        if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) return hr;
        IMMDevice *endpoint = nullptr;
        hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&devices));
        if (SUCCEEDED(hr)) hr = devices->GetDefaultAudioEndpoint(eCapture, eConsole, &endpoint);
        if (SUCCEEDED(hr)) hr = endpoint->GetId(&endpoint_id);
        if (SUCCEEDED(hr)) hr = endpoint->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                                    reinterpret_cast<void **>(&client));
        if (endpoint) endpoint->Release();
        if (FAILED(hr)) return hr;
        next_device_check = GetTickCount64() + 1000;

        WAVEFORMATEX pcm = {};
        pcm.wFormatTag = WAVE_FORMAT_IEEE_FLOAT;
        pcm.nChannels = channels;
        pcm.nSamplesPerSec = rate;
        pcm.wBitsPerSample = 32;
        pcm.nBlockAlign = static_cast<WORD>(channels * sizeof(float));
        pcm.nAvgBytesPerSec = rate * pcm.nBlockAlign;
        const DWORD flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                            AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
        hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, 0, 0, &pcm, nullptr);
        if (FAILED(hr)) return hr;
        ready = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!ready) return HRESULT_FROM_WIN32(GetLastError());
        hr = client->SetEventHandle(ready);
        if (SUCCEEDED(hr)) hr = client->GetService(IID_PPV_ARGS(&capture));
        if (SUCCEEDED(hr)) hr = client->GetBufferSize(&packet_capacity);
        return hr;
    }

    HRESULT receive(DWORD timeout) {
        // An endpoint can stay connected after the user changes the default input.
        // Interrupt the take just as for a disconnected microphone.
        if (devices && GetTickCount64() >= next_device_check) {
            next_device_check = GetTickCount64() + 1000;
            IMMDevice *current = nullptr;
            wchar_t *id = nullptr;
            HRESULT status = devices->GetDefaultAudioEndpoint(eCapture, eConsole, &current);
            if (SUCCEEDED(status)) status = current->GetId(&id);
            if (SUCCEEDED(status) && std::wcscmp(id, endpoint_id) != 0) status = AUDCLNT_E_DEVICE_INVALIDATED;
            CoTaskMemFree(id);
            if (current) current->Release();
            if (FAILED(status)) return status;
        }
        UINT32 frames = 0;
        HRESULT hr = capture->GetNextPacketSize(&frames);
        if (FAILED(hr)) return hr;
        if (!frames) {
            DWORD waited = WaitForSingleObject(ready, timeout);
            if (waited == WAIT_FAILED) return HRESULT_FROM_WIN32(GetLastError());
            hr = capture->GetNextPacketSize(&frames);
            if (FAILED(hr) || !frames) return hr;
        }

        BYTE *source = nullptr;
        DWORD flags = 0;
        hr = capture->GetBuffer(&source, &frames, &flags, nullptr, nullptr);
        if (FAILED(hr) || hr == AUDCLNT_S_BUFFER_EMPTY) return hr;
        if (frames > packet_capacity || (!source && !(flags & AUDCLNT_BUFFERFLAGS_SILENT))) {
            capture->ReleaseBuffer(frames);
            return E_UNEXPECTED;
        }
        const size_t count = static_cast<size_t>(frames) * channels * sizeof(float);
        if (flags & AUDCLNT_BUFFERFLAGS_SILENT) std::memset(packet, 0, count);
        else std::memcpy(packet, source, count);
        hr = capture->ReleaseBuffer(frames);
        if (SUCCEEDED(hr)) packet_frames = frames;
        return hr;
    }

    void generate(DWORD timeout) {
        ULONGLONG now = GetTickCount64();
        if (now < next_tick) {
            DWORD wait = static_cast<DWORD>(next_tick - now);
            Sleep(wait < timeout ? wait : timeout);
            if (GetTickCount64() < next_tick) return;
        }
        next_tick += 10;
        const uint32_t hundredths = rate + fractional_frames;
        packet_frames = hundredths / 100;
        fractional_frames = hundredths % 100;
        for (UINT32 frame = 0; frame < packet_frames; ++frame) {
            double phase = static_cast<double>((generated++ * 440) % rate) / rate;
            float value = static_cast<float>(0.25 * std::sin(phase * 6.283185307179586));
            for (uint16_t ch = 0; ch < channels; ++ch) packet[frame * channels + ch] = value;
        }
    }
};

RuneMic *rune_mic_open(uint32_t sample_rate, uint16_t channels, int synthetic,
                       char *error, size_t capacity) {
    if (sample_rate < 8000 || sample_rate > 192000 || channels < 1 || channels > 2) {
        describe_failure(E_INVALIDARG, "Opening microphone", error, capacity);
        return nullptr;
    }
    RuneMic *mic = new(std::nothrow) RuneMic();
    HRESULT hr = mic ? S_OK : E_OUTOFMEMORY;
    if (mic) {
        mic->rate = sample_rate;
        mic->channels = channels;
        mic->synthetic = synthetic != 0;
        if (mic->synthetic) {
            mic->packet_capacity = (sample_rate + 99) / 100;
            mic->next_tick = GetTickCount64() + 10;
        } else {
            hr = mic->open_device();
        }
        if (SUCCEEDED(hr)) {
            if (!mic->packet_capacity || mic->packet_capacity > UINT32_MAX / (channels * sizeof(float))) {
                hr = E_UNEXPECTED;
            } else {
                mic->packet = new(std::nothrow) float[static_cast<size_t>(mic->packet_capacity) * channels];
                if (!mic->packet) hr = E_OUTOFMEMORY;
            }
        }
        if (SUCCEEDED(hr) && mic->client) hr = mic->client->Start();
    }
    if (FAILED(hr)) {
        describe_failure(hr, "Opening microphone", error, capacity);
        delete mic;
        return nullptr;
    }
    mic->running = true;
    return mic;
}

int rune_mic_read(RuneMic *mic, float *out, uint32_t capacity_frames, uint32_t timeout_ms,
                  char *error, size_t capacity) {
    if (!mic || !out || !capacity_frames) {
        describe_failure(E_INVALIDARG, "Reading microphone", error, capacity);
        return -1;
    }
    if (mic->paused) return 0;
    if (mic->next_frame == mic->packet_frames) {
        mic->next_frame = mic->packet_frames = 0;
        if (mic->synthetic) {
            mic->generate(timeout_ms);
        } else {
            HRESULT hr = mic->receive(timeout_ms);
            if (FAILED(hr)) {
                describe_failure(hr, "Reading microphone", error, capacity);
                return -1;
            }
        }
    }
    const UINT32 available = mic->packet_frames - mic->next_frame;
    const UINT32 count = capacity_frames < available ? capacity_frames : available;
    const size_t offset = static_cast<size_t>(mic->next_frame) * mic->channels;
    std::memcpy(out, mic->packet + offset, static_cast<size_t>(count) * mic->channels * sizeof(float));
    mic->next_frame += count;
    return static_cast<int>(count);
}

int rune_mic_set_paused(RuneMic *mic, int paused, char *error, size_t capacity) {
    if (!mic) {
        describe_failure(E_INVALIDARG, "Changing microphone state", error, capacity);
        return 0;
    }
    const bool desired = paused != 0;
    if (mic->paused == desired) return 1;
    HRESULT hr = S_OK;
    if (mic->client) {
        if (desired) {
            hr = mic->client->Stop();
            if (SUCCEEDED(hr)) {
                mic->running = false;
                hr = mic->client->Reset();
            }
        } else {
            hr = mic->client->Start();
        }
    }
    if (FAILED(hr)) {
        describe_failure(hr, "Changing microphone state", error, capacity);
        return 0;
    }
    mic->paused = desired;
    mic->running = !desired;
    if (desired) {
        // A partially consumed packet belongs to the take before the pause. Clear
        // it along with the endpoint queue so resume starts on a fresh packet.
        if (mic->synthetic) mic->generated -= mic->packet_frames - mic->next_frame;
        mic->next_frame = mic->packet_frames = 0;
    }
    if (mic->synthetic && !desired) mic->next_tick = GetTickCount64() + 10;
    return 1;
}

void rune_mic_close(RuneMic *mic) { delete mic; }
#endif
