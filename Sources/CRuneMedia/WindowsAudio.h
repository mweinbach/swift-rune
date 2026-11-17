#ifndef RUNE_WINDOWS_AUDIO_H
#define RUNE_WINDOWS_AUDIO_H

#include <windows.h>
#include <mfplay.h>
#include <mferror.h>
#include <cmath>
#include <new>

// Source Reader supplies Rune's video pixels. MFPlay sends only the selected audio
// track to Windows' streaming audio renderer and supplies its presentation clock.
// The owning media handle serializes public operations. MF invokes callbacks on its
// worker threads, including during shutdown, so the callback has its own COM lifetime.
class RuneWindowsAudio {
    class Events final : public IMFPMediaPlayerCallback {
        LONG refs_ = 1;
        SRWLOCK lock_ = SRWLOCK_INIT;
        int expecting_ = -1;
        HRESULT completion_ = S_OK;
        HRESULT failure_ = S_OK;
        bool ended_ = false;
        HANDLE signal_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);

        ~Events() { if (signal_) CloseHandle(signal_); }
    public:
        HRESULT valid() const { return signal_ ? S_OK : E_OUTOFMEMORY; }
        HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
            if (!out) return E_POINTER;
            *out = nullptr;
            if (iid != __uuidof(IUnknown) && iid != __uuidof(IMFPMediaPlayerCallback)) return E_NOINTERFACE;
            *out = static_cast<IMFPMediaPlayerCallback *>(this);
            AddRef();
            return S_OK;
        }
        ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&refs_); }
        ULONG STDMETHODCALLTYPE Release() override {
            ULONG count = InterlockedDecrement(&refs_);
            if (count == 0) delete this;
            return count;
        }
        void STDMETHODCALLTYPE OnMediaPlayerEvent(MFP_EVENT_HEADER *event) override {
            AcquireSRWLockExclusive(&lock_);
            if (event->eEventType == MFP_EVENT_TYPE_ERROR) {
                failure_ = FAILED(event->hrEvent) ? event->hrEvent : E_FAIL;
            }
            if (event->eEventType == MFP_EVENT_TYPE_PLAYBACK_ENDED) ended_ = true;
            if ((event->eEventType == MFP_EVENT_TYPE_PLAY || event->eEventType == MFP_EVENT_TYPE_POSITION_SET)
                && SUCCEEDED(event->hrEvent)) ended_ = false;
            if (expecting_ == static_cast<int>(event->eEventType) || FAILED(failure_)) {
                completion_ = FAILED(failure_) ? failure_ : event->hrEvent;
                expecting_ = -1;
                SetEvent(signal_);
            }
            ReleaseSRWLockExclusive(&lock_);
        }
        HRESULT status(bool *ended = nullptr) {
            AcquireSRWLockShared(&lock_);
            if (ended) *ended = ended_;
            HRESULT result = failure_;
            ReleaseSRWLockShared(&lock_);
            return result;
        }
        template<class Operation>
        HRESULT complete(MFP_EVENT_TYPE expected, Operation operation) {
            AcquireSRWLockExclusive(&lock_);
            HRESULT result = failure_;
            if (SUCCEEDED(result)) {
                ResetEvent(signal_);
                expecting_ = static_cast<int>(expected);
            }
            ReleaseSRWLockExclusive(&lock_);
            if (FAILED(result)) return result;
            result = operation();
            DWORD wait = SUCCEEDED(result) ? WaitForSingleObject(signal_, 15000) : WAIT_OBJECT_0;
            AcquireSRWLockExclusive(&lock_);
            if (SUCCEEDED(result)) {
                if (wait == WAIT_OBJECT_0) result = completion_;
                else {
                    // An eventual completion can no longer be matched reliably to a request.
                    failure_ = result = HRESULT_FROM_WIN32(wait == WAIT_TIMEOUT ? ERROR_TIMEOUT : ERROR_GEN_FAILURE);
                }
            }
            expecting_ = -1;
            ReleaseSRWLockExclusive(&lock_);
            return result;
        }
    };

    IMFPMediaPlayer *player_ = nullptr;
    Events *events_ = nullptr;

    static HRESULT createPlayer(Events *events, IMFPMediaPlayer **player) {
        // Loading lazily lets a Windows N installation use the rest of Rune without the Media Feature Pack.
        static HMODULE module = LoadLibraryExW(L"mfplay.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!module) return HRESULT_FROM_WIN32(ERROR_MOD_NOT_FOUND);
        static auto create = reinterpret_cast<decltype(&MFPCreateMediaPlayer)>(GetProcAddress(module, "MFPCreateMediaPlayer"));
        return create ? create(nullptr, FALSE, MFP_OPTION_FREE_THREADED_CALLBACK, events, nullptr, player)
                      : HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
    }
    static HRESULT selectAudio(IMFPMediaItem *item) {
        BOOL hasAudio = FALSE, selected = FALSE, hasVideo = FALSE, videoSelected = FALSE;
        HRESULT hr = item->HasAudio(&hasAudio, &selected);
        if (FAILED(hr) || !hasAudio) return FAILED(hr) ? hr : MF_E_INVALIDMEDIATYPE;
        hr = item->HasVideo(&hasVideo, &videoSelected);
        if (FAILED(hr) || (selected && !videoSelected)) return hr;
        DWORD count = 0;
        hr = item->GetNumberOfStreams(&count);
        for (DWORD i = 0; SUCCEEDED(hr) && i < count; ++i) hr = item->SetStreamSelection(i, FALSE);
        for (DWORD i = 0; SUCCEEDED(hr) && i < count; ++i) {
            hr = item->SetStreamSelection(i, TRUE);
            if (SUCCEEDED(hr)) hr = item->HasAudio(&hasAudio, &selected);
            if (SUCCEEDED(hr) && selected) return S_OK;
            if (SUCCEEDED(hr)) hr = item->SetStreamSelection(i, FALSE);
        }
        return FAILED(hr) ? hr : MF_E_INVALIDMEDIATYPE;
    }
public:
    RuneWindowsAudio() = default;
    RuneWindowsAudio(const RuneWindowsAudio&) = delete;
    RuneWindowsAudio& operator=(const RuneWindowsAudio&) = delete;
    ~RuneWindowsAudio() { close(); }

    void close() {
        if (player_) {
            player_->Shutdown();
            player_->Release();
            player_ = nullptr;
        }
        if (events_) { events_->Release(); events_ = nullptr; }
    }
    HRESULT open(const wchar_t *url) {
        close();
        events_ = new (std::nothrow) Events();
        if (!events_) return E_OUTOFMEMORY;
        HRESULT hr = events_->valid();
        if (SUCCEEDED(hr)) hr = createPlayer(events_, &player_);
        IMFPMediaItem *item = nullptr;
        if (SUCCEEDED(hr)) hr = player_->CreateMediaItemFromURL(url, TRUE, 0, &item);
        if (SUCCEEDED(hr)) hr = selectAudio(item);
        if (SUCCEEDED(hr)) hr = events_->complete(MFP_EVENT_TYPE_MEDIAITEM_SET, [&] { return player_->SetMediaItem(item); });
        if (item) item->Release();
        if (FAILED(hr)) close();
        return hr;
    }
    HRESULT setPlaying(bool play) {
        if (!player_) return MF_E_NOT_INITIALIZED;
        HRESULT hr = events_->status();
        MFP_MEDIAPLAYER_STATE state;
        if (SUCCEEDED(hr)) hr = player_->GetState(&state);
        if (FAILED(hr)) return hr;
        if (play && state != MFP_MEDIAPLAYER_STATE_PLAYING)
            return events_->complete(MFP_EVENT_TYPE_PLAY, [&] { return player_->Play(); });
        if (!play && state == MFP_MEDIAPLAYER_STATE_PLAYING)
            return events_->complete(MFP_EVENT_TYPE_PAUSE, [&] { return player_->Pause(); });
        return S_OK;
    }
    HRESULT seek(double seconds) {
        if (!player_) return MF_E_NOT_INITIALIZED;
        if (!std::isfinite(seconds) || seconds < 0 || seconds >= 922337203685.0) return E_INVALIDARG;
        PROPVARIANT position = {};
        position.vt = VT_I8;
        position.hVal.QuadPart = static_cast<LONGLONG>(seconds * 10000000.0);
        return events_->complete(MFP_EVENT_TYPE_POSITION_SET,
            [&] { return player_->SetPosition(MFP_POSITIONTYPE_100NS, &position); });
    }
    HRESULT setRate(float rate) {
        if (!player_) return MF_E_NOT_INITIALIZED;
        if (!std::isfinite(rate) || rate <= 0) return E_INVALIDARG;
        float current = 0;
        HRESULT hr = player_->GetRate(&current);
        if (FAILED(hr) || current == rate) return hr;
        return events_->complete(MFP_EVENT_TYPE_RATE_SET, [&] { return player_->SetRate(rate); });
    }
    HRESULT setVolume(float volume) {
        if (!player_) return MF_E_NOT_INITIALIZED;
        if (!std::isfinite(volume) || volume < 0 || volume > 1) return E_INVALIDARG;
        return player_->SetVolume(volume);
    }
    HRESULT setMuted(bool muted) { return player_ ? player_->SetMute(muted) : MF_E_NOT_INITIALIZED; }
    HRESULT position(double *seconds, bool *ended) {
        if (!seconds || !ended) return E_POINTER;
        if (!player_) return MF_E_NOT_INITIALIZED;
        HRESULT hr = events_->status(ended);
        if (FAILED(hr)) return hr;
        PROPVARIANT value = {};
        hr = *ended ? player_->GetDuration(MFP_POSITIONTYPE_100NS, &value)
                    : player_->GetPosition(MFP_POSITIONTYPE_100NS, &value);
        if (SUCCEEDED(hr)) {
            if (value.vt == VT_I8) *seconds = value.hVal.QuadPart / 10000000.0;
            else if (value.vt == VT_UI8) *seconds = value.uhVal.QuadPart / 10000000.0;
            else hr = E_UNEXPECTED;
        }
        PropVariantClear(&value);
        return hr;
    }
};

#endif
