#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <objbase.h>
#include <NotificationActivationCallback.h>
#include <wrl/implements.h>
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>
#include "RuneNotifyActivator.h"

namespace {
using namespace Microsoft::WRL;
using Classic = RuntimeClassFlags<ClassicCom>;

struct Activation {
    std::wstring arguments;
    std::vector<std::pair<std::wstring, std::wstring>> inputs;

    void deliver(RuneNotifyActivation callback, void *context) const {
        std::vector<RuneNotifyInput> borrowed;
        borrowed.reserve(inputs.size());
        for (const auto &pair : inputs)
            borrowed.push_back({pair.first.c_str(), pair.second.c_str()});
        callback(context, arguments.c_str(), borrowed.data(), borrowed.size());
    }
};

struct Waiter {
    std::unique_ptr<Activation> activation;
};

struct Registration {
    std::mutex mutex;
    std::condition_variable changed;
    std::vector<Waiter *> waiters;
    RuneNotifyActivation handler = nullptr;
    void *context = nullptr;
    HRESULT result = E_PENDING;
    bool closed = false;
    bool revoked = false;

    HRESULT activate(const wchar_t *arguments, const NOTIFICATION_USER_INPUT_DATA *inputs,
                     ULONG count) {
        auto activation = std::make_unique<Activation>();
        activation->arguments = arguments ? arguments : L"";
        if (inputs) {
            activation->inputs.reserve(count);
            for (ULONG i = 0; i < count; ++i)
                activation->inputs.emplace_back(inputs[i].Key ? inputs[i].Key : L"",
                                                inputs[i].Value ? inputs[i].Value : L"");
        }

        RuneNotifyActivation handlerToCall;
        void *callbackContext;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (closed) return CO_E_OBJNOTCONNECTED;
            for (auto waiter : waiters) {
                if (!waiter->activation) {
                    waiter->activation = std::move(activation);
                    changed.notify_all();
                    return S_OK;
                }
            }
            handlerToCall = handler;
            callbackContext = context;
        }
        if (!handlerToCall) return CO_E_OBJNOTCONNECTED;
        activation->deliver(handlerToCall, callbackContext);
        return S_OK;
    }
};

class Activator final : public RuntimeClass<Classic, INotificationActivationCallback> {
public:
    explicit Activator(const std::shared_ptr<Registration> &registration) : registration(registration) {}

    HRESULT STDMETHODCALLTYPE Activate(LPCWSTR, LPCWSTR arguments,
                                       const NOTIFICATION_USER_INPUT_DATA *inputs, ULONG count) override {
        try {
            return registration->activate(arguments, inputs, count);
        } catch (const std::bad_alloc &) {
            return E_OUTOFMEMORY;
        } catch (...) {
            return E_FAIL;
        }
    }
private:
    std::shared_ptr<Registration> registration;
};

class Factory final : public RuntimeClass<Classic, IClassFactory> {
public:
    explicit Factory(const std::shared_ptr<Registration> &registration) : registration(registration) {}

    HRESULT STDMETHODCALLTYPE CreateInstance(IUnknown *outer, REFIID iid, void **object) override {
        if (!object) return E_POINTER;
        *object = nullptr;
        if (outer) return CLASS_E_NOAGGREGATION;
        auto activator = Make<Activator>(registration);
        return activator ? activator.CopyTo(iid, object) : E_OUTOFMEMORY;
    }

    HRESULT STDMETHODCALLTYPE LockServer(BOOL) override { return S_OK; }
private:
    std::shared_ptr<Registration> registration;
};

struct ByGuid {
    bool operator()(const GUID &a, const GUID &b) const { return memcmp(&a, &b, sizeof(GUID)) < 0; }
};

std::mutex registryMutex;
std::map<GUID, std::shared_ptr<Registration>, ByGuid> registrations;

HRESULT parseClass(const wchar_t *text, GUID *clsid) {
    if (!text) return E_INVALIDARG;
    const size_t length = wcslen(text);
    if (length == 38 && text[0] == L'{' && text[37] == L'}')
        return IIDFromString(text, clsid);
    if (length != 36) return CO_E_CLASSSTRING;
    wchar_t braced[39] = {L'{'};
    memcpy(braced + 1, text, 36 * sizeof(wchar_t));
    braced[37] = L'}';
    return IIDFromString(braced, clsid);
}

// The factory is always registered and revoked in the same MTA. The calling
// app can be an STA UI thread, or an uninitialized command-line process.
void runServer(GUID clsid, std::shared_ptr<Registration> registration) {
    const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    auto factory = Make<Factory>(registration);
    DWORD cookie = 0;
    HRESULT result = initialized;
    if (SUCCEEDED(result))
        result = factory ? CoRegisterClassObject(clsid, factory.Get(), CLSCTX_LOCAL_SERVER,
                                                REGCLS_MULTIPLEUSE, &cookie) : E_OUTOFMEMORY;
    {
        std::unique_lock<std::mutex> lock(registration->mutex);
        registration->result = result;
        registration->changed.notify_all();
        if (SUCCEEDED(result))
            registration->changed.wait(lock, [&] { return registration->closed; });
    }
    if (cookie) CoRevokeClassObject(cookie);
    {
        std::lock_guard<std::mutex> lock(registration->mutex);
        registration->revoked = true;
        registration->changed.notify_all();
    }
    factory.Reset();
    if (SUCCEEDED(initialized)) CoUninitialize();
}

HRESULT attach(const GUID &clsid, Waiter *waiter, RuneNotifyActivation callback, void *context,
               std::shared_ptr<Registration> &registration) {
    std::lock_guard<std::mutex> registryLock(registryMutex);
    auto it = registrations.find(clsid);
    const bool isNew = it == registrations.end();
    registration = isNew ? std::make_shared<Registration>() : it->second;
    std::unique_lock<std::mutex> lock(registration->mutex);
    if (waiter) registration->waiters.push_back(waiter);
    else {
        registration->handler = callback;
        registration->context = context;
    }
    if (isNew) {
        registrations.emplace(clsid, registration);
        try {
            std::thread(runServer, clsid, registration).detach();
        } catch (...) {
            registrations.erase(clsid);
            throw;
        }
        registration->changed.wait(lock, [&] { return registration->result != E_PENDING; });
        if (FAILED(registration->result)) registrations.erase(clsid);
    }
    return registration->result;
}

void closeRegistration(const GUID &clsid, const std::shared_ptr<Registration> &temporary) {
    std::lock_guard<std::mutex> registryLock(registryMutex);
    auto it = registrations.find(clsid);
    if (it == registrations.end() || (temporary && it->second != temporary)) return;
    auto registration = it->second;
    std::unique_lock<std::mutex> lock(registration->mutex);
    if (temporary && (registration->handler || !registration->waiters.empty())) return;
    registration->closed = true;
    registration->changed.notify_all();
    registration->changed.wait(lock, [&] { return registration->revoked; });
    registrations.erase(it);
}
} // namespace

extern "C" int32_t rune_notify_serve_activations(const wchar_t *id, RuneNotifyActivation callback,
                                                void *context) {
    GUID clsid;
    const HRESULT parsed = parseClass(id, &clsid);
    if (FAILED(parsed)) return parsed;
    if (!callback) return E_INVALIDARG;
    try {
        std::shared_ptr<Registration> registration;
        return attach(clsid, nullptr, callback, context, registration);
    } catch (const std::bad_alloc &) { return E_OUTOFMEMORY; }
      catch (...) { return E_FAIL; }
}

extern "C" int32_t rune_notify_wait_activation(const wchar_t *id, uint32_t timeout,
                                              RuneNotifyActivation callback, void *context) {
    GUID clsid;
    const HRESULT parsed = parseClass(id, &clsid);
    if (FAILED(parsed)) return parsed;
    if (!callback) return E_INVALIDARG;
    try {
        Waiter waiter;
        std::shared_ptr<Registration> registration;
        const HRESULT result = attach(clsid, &waiter, nullptr, nullptr, registration);
        if (FAILED(result)) return result;
        {
            std::unique_lock<std::mutex> lock(registration->mutex);
            registration->changed.wait_for(lock, std::chrono::milliseconds(timeout),
                                           [&] { return waiter.activation || registration->closed; });
            // A timed-out wait must stop intercepting subsequent COM calls,
            // even if another class is still registering on the registry lock.
            auto &waiters = registration->waiters;
            waiters.erase(std::find(waiters.begin(), waiters.end(), &waiter));
        }
        closeRegistration(clsid, registration);
        if (!waiter.activation) return S_FALSE;
        waiter.activation->deliver(callback, context);
        return S_OK;
    } catch (const std::bad_alloc &) { return E_OUTOFMEMORY; }
      catch (...) { return E_FAIL; }
}

extern "C" void rune_notify_stop_activations(const wchar_t *id) {
    GUID clsid;
    if (SUCCEEDED(parseClass(id, &clsid))) closeRegistration(clsid, nullptr);
}
#endif
