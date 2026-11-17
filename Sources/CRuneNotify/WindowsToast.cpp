#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <roapi.h>
#include <windows.data.xml.dom.h>
#include <windows.ui.notifications.h>
#include <wrl.h>
#include <wrl/wrappers/corewrappers.h>
#include <memory>
#include <new>
#include "include/RuneNotifyToast.h"

namespace {
using namespace ABI::Windows::Data::Xml::Dom;
using namespace ABI::Windows::UI::Notifications;
namespace Foundation = ABI::Windows::Foundation;
namespace Collections = Foundation::Collections;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Wrappers::HString;
using Microsoft::WRL::Wrappers::HStringReference;
using Microsoft::WRL::Wrappers::RoInitializeWrapper;

// Windows limits ToastGeneric to five actions. Rune's XML adds at most one
// input per action. HSTRINGs own the UTF-16 buffers during the Swift callback.
struct ReplyFields {
    HString keys[5], values[5];
    RuneNotifyInput fields[5];
    size_t count = 0;

    void read(IInspectable *args) {
        using Pair = Collections::IKeyValuePair<HSTRING, IInspectable *>;
        ComPtr<IToastActivatedEventArgs2> reply;
        ComPtr<Collections::IPropertySet> properties;
        ComPtr<Collections::IIterable<Pair *>> iterable;
        ComPtr<Collections::IIterator<Pair *>> entries;
        if (FAILED(args->QueryInterface(IID_PPV_ARGS(&reply))) ||
            FAILED(reply->get_UserInput(&properties)) || !properties ||
            FAILED(properties.As(&iterable)) || FAILED(iterable->First(&entries)) || !entries) return;

        boolean more = false;
        if (FAILED(entries->get_HasCurrent(&more))) return;
        while (more && count < ARRAYSIZE(fields)) {
            ComPtr<Pair> pair;
            ComPtr<IInspectable> object;
            ComPtr<Foundation::IPropertyValue> property;
            if (SUCCEEDED(entries->get_Current(&pair)) && pair &&
                SUCCEEDED(pair->get_Key(keys[count].ReleaseAndGetAddressOf())) &&
                SUCCEEDED(pair->get_Value(&object)) && object && SUCCEEDED(object.As(&property)) &&
                SUCCEEDED(property->GetString(values[count].ReleaseAndGetAddressOf()))) {
                fields[count] = { keys[count].GetRawBuffer(nullptr), values[count].GetRawBuffer(nullptr) };
                ++count;
            }
            if (FAILED(entries->MoveNext(&more))) break;
        }
    }
};

struct PostedToast {
    HString app, tag;
    ComPtr<IToastNotification> toast;
    EventRegistrationToken token{};
    CO_MTA_USAGE_COOKIE apartment = nullptr;
    bool attached = false;

    ~PostedToast() {
        if (attached) toast->remove_Activated(token);
        toast.Reset();
        if (apartment) CoDecrementMTAUsage(apartment);
    }

    HRESULT attach(RuneNotifyActivation activate, void *context) {
        // Keep the agile event delegate reachable after the posting thread leaves COM.
        HRESULT status = CoIncrementMTAUsage(&apartment);
        if (FAILED(status)) return status;
        using Handler = Foundation::ITypedEventHandler<ToastNotification *, IInspectable *>;
        using AgileHandler = Microsoft::WRL::Implements<
            Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>, Handler, Microsoft::WRL::FtmBase>;
        auto handler = Microsoft::WRL::Callback<AgileHandler>(
            [activate, context](IToastNotification *, IInspectable *args) -> HRESULT {
                ComPtr<IToastActivatedEventArgs> activation;
                HString arguments;
                if (!args) return E_POINTER;
                HRESULT hr = args->QueryInterface(IID_PPV_ARGS(&activation));
                if (FAILED(hr)) return hr;
                hr = activation->get_Arguments(arguments.GetAddressOf());
                if (FAILED(hr)) return hr;
                ReplyFields reply;
                reply.read(args);
                activate(context, arguments.GetRawBuffer(nullptr), reply.fields, reply.count);
                return S_OK;
            });
        if (!handler) return E_OUTOFMEMORY;
        status = toast->add_Activated(handler.Get(), &token);
        attached = SUCCEEDED(status);
        return status;
    }
};

// Entries remain reachable while Windows can deliver a click. A newer toast
// with the same (app, tag) replaces its previous registration, even at capacity.
SRWLOCK historyLock = SRWLOCK_INIT;
PostedToast *history[64]{};
size_t historyCount = 0;

PostedToast *take(const wchar_t *app, const wchar_t *tag, bool evictOldest) {
    size_t index = 0;
    while (index < historyCount &&
           (wcscmp(history[index]->app.GetRawBuffer(nullptr), app) != 0 ||
            wcscmp(history[index]->tag.GetRawBuffer(nullptr), tag) != 0)) ++index;
    if (index == historyCount) {
        if (!evictOldest || historyCount < ARRAYSIZE(history)) return nullptr;
        index = 0;
    }
    auto *entry = history[index];
    --historyCount;
    for (size_t i = index; i < historyCount; ++i) history[i] = history[i + 1];
    history[historyCount] = nullptr;
    return entry;
}

HRESULT makeToast(const wchar_t *xml, int presentation, PostedToast &entry) {
    ComPtr<IInspectable> object;
    HRESULT hr = RoActivateInstance(HStringReference(RuntimeClass_Windows_Data_Xml_Dom_XmlDocument).Get(), &object);
    if (FAILED(hr)) return hr;
    ComPtr<IXmlDocumentIO> loader;
    if (FAILED(hr = object.As(&loader))) return hr;
    if (FAILED(hr = loader->LoadXml(HStringReference(xml).Get()))) return hr;
    ComPtr<IXmlDocument> document;
    if (FAILED(hr = object.As(&document))) return hr;

    ComPtr<IToastNotificationFactory> factory;
    if (FAILED(hr = RoGetActivationFactory(HStringReference(RuntimeClass_Windows_UI_Notifications_ToastNotification).Get(),
                                            IID_PPV_ARGS(&factory)))) return hr;
    if (FAILED(hr = factory->CreateToastNotification(document.Get(), &entry.toast))) return hr;
    ComPtr<IToastNotification2> options;
    if (FAILED(hr = entry.toast.As(&options))) return hr;
    if (FAILED(hr = options->put_Tag(entry.tag.Get()))) return hr;
    if (FAILED(hr = options->put_Group(HStringReference(L"rune").Get()))) return hr;
    if (presentation == 2) {
        ComPtr<IToastNotification4> priority;
        hr = entry.toast.As(&priority);
        if (hr == E_NOINTERFACE) return S_OK;
        if (FAILED(hr)) return hr;
        return priority->put_Priority(ToastNotificationPriority_High);
    }
    return options->put_SuppressPopup(presentation == 1);
}
}

int32_t rune_notify_windows_show(const wchar_t *app, const wchar_t *xml, const wchar_t *tag,
                                 int presentation, RuneNotifyActivation activate, void *context) {
    if (!app || !*app || !xml || !tag || presentation < 0 || presentation > 2) return E_INVALIDARG;
    RoInitializeWrapper apartment(RO_INIT_MULTITHREADED);
    if (FAILED(apartment) && HRESULT(apartment) != RPC_E_CHANGED_MODE) return apartment;
    std::unique_ptr<PostedToast> entry(new (std::nothrow) PostedToast);
    if (!entry) return E_OUTOFMEMORY;
    HRESULT hr = entry->app.Set(app);
    if (FAILED(hr) || FAILED(hr = entry->tag.Set(tag))) return hr;
    if (FAILED(hr = makeToast(xml, presentation, *entry))) return hr;
    if (activate && FAILED(hr = entry->attach(activate, context))) return hr;
    ComPtr<IToastNotificationManagerStatics> manager;
    if (FAILED(hr = RoGetActivationFactory(HStringReference(RuntimeClass_Windows_UI_Notifications_ToastNotificationManager).Get(),
                                            IID_PPV_ARGS(&manager)))) return hr;
    ComPtr<IToastNotifier> notifier;
    if (FAILED(hr = manager->CreateToastNotifierWithId(entry->app.Get(), &notifier))) return hr;

    PostedToast *previous = nullptr;
    AcquireSRWLockExclusive(&historyLock);
    hr = notifier->Show(entry->toast.Get());
    if (SUCCEEDED(hr)) {
        previous = take(app, tag, activate != nullptr);
        if (activate) history[historyCount++] = entry.release();
    }
    ReleaseSRWLockExclusive(&historyLock);
    delete previous;
    return hr;
}

int32_t rune_notify_windows_remove(const wchar_t *app, const wchar_t *tag) {
    if (!app || !*app || !tag) return E_INVALIDARG;
    RoInitializeWrapper apartment(RO_INIT_MULTITHREADED);
    if (FAILED(apartment) && HRESULT(apartment) != RPC_E_CHANGED_MODE) return apartment;
    ComPtr<IToastNotificationManagerStatics2> manager;
    HRESULT hr = RoGetActivationFactory(HStringReference(RuntimeClass_Windows_UI_Notifications_ToastNotificationManager).Get(),
                                         IID_PPV_ARGS(&manager));
    if (FAILED(hr)) return hr;
    ComPtr<IToastNotificationHistory> center;
    if (FAILED(hr = manager->get_History(&center))) return hr;
    AcquireSRWLockExclusive(&historyLock);
    hr = center->RemoveGroupedTagWithId(HStringReference(tag).Get(), HStringReference(L"rune").Get(),
                                         HStringReference(app).Get());
    auto *removed = SUCCEEDED(hr) ? take(app, tag, false) : nullptr;
    ReleaseSRWLockExclusive(&historyLock);
    delete removed;
    return hr;
}
#endif
