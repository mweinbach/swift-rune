#define NOMINMAX
#include <windows.h>
#include <objbase.h>
#include <NotificationActivationCallback.h>
#include <atomic>
#include <cstdio>
#include <string>
#include <thread>
#include "RuneNotifyActivator.h"

namespace {
constexpr wchar_t arguments[] = L"rune.id=one&rune.action=reply&session=chat";
constexpr wchar_t reply[] = L"R\u00e9ponse \u4e16\u754c";

struct Capture {
    std::atomic<unsigned> count{0};
    bool receivedReply = false;
    DWORD caller = 0;
};

void capture(void *context, const wchar_t *args, const RuneNotifyInput *inputs, size_t count) {
    auto &result = *static_cast<Capture *>(context);
    result.caller = GetCurrentThreadId();
    result.receivedReply = args && wcscmp(args, arguments) == 0 && count == 1 && inputs &&
                           inputs[0].key && wcscmp(inputs[0].key, L"reply") == 0 &&
                           inputs[0].value && wcscmp(inputs[0].value, reply) == 0;
    ++result.count;
}

HRESULT sendActivation(const GUID &clsid, unsigned attempts) {
    INotificationActivationCallback *activator = nullptr;
    HRESULT result = E_UNEXPECTED;
    for (unsigned attempt = 0; attempt < attempts; ++attempt) {
        result = CoCreateInstance(clsid, nullptr, CLSCTX_LOCAL_SERVER,
                                  IID_PPV_ARGS(&activator));
        if (SUCCEEDED(result)) break;
        if (attempt + 1 < attempts) Sleep(20);
    }
    if (!activator) return result;
    NOTIFICATION_USER_INPUT_DATA input = {L"reply", reply};
    result = activator->Activate(L"Rune.ActivationProbe", arguments, &input, 1);
    activator->Release();
    return result;
}

DWORD runClient(const wchar_t *clsid) {
    wchar_t executable[MAX_PATH] = {};
    if (!GetModuleFileNameW(nullptr, executable, MAX_PATH)) return GetLastError();
    std::wstring command = L"\"" + std::wstring(executable) + L"\" client " + clsid;
    STARTUPINFOW startup = {};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process = {};
    if (!CreateProcessW(nullptr, &command[0], nullptr, nullptr, FALSE, 0, nullptr, nullptr,
                        &startup, &process)) return GetLastError();
    DWORD result = ERROR_TIMEOUT;
    if (WaitForSingleObject(process.hProcess, 20000) == WAIT_OBJECT_0) {
        GetExitCodeProcess(process.hProcess, &result);
    } else {
        TerminateProcess(process.hProcess, result);
        WaitForSingleObject(process.hProcess, 3000);
    }
    CloseHandle(process.hProcess);
    CloseHandle(process.hThread);
    return result;
}

#define CHECK(condition) do { if (!(condition)) { \
    std::fprintf(stderr, "Check failed at line %d: %s\n", __LINE__, #condition); return 1; \
} } while (0)

int test() {
    // A fresh class ID needs no registry writes and cannot activate another installed app.
    GUID clsid;
    wchar_t id[39];
    CHECK(SUCCEEDED(CoCreateGuid(&clsid)) && StringFromGUID2(clsid, id, 39));
    Capture first, second, waited;
    CHECK(FAILED(rune_notify_serve_activations(L"invalid", capture, &first)));
    CHECK(SUCCEEDED(rune_notify_serve_activations(id, capture, &first)));
    CHECK(runClient(id) == 0 && first.count == 1 && first.receivedReply);

    CHECK(SUCCEEDED(rune_notify_serve_activations(id, capture, &second)));
    CHECK(runClient(id) == 0 && first.count == 1 && second.count == 1 && second.receivedReply);

    DWORD clientStatus = ERROR_TIMEOUT;
    std::thread client([&] { Sleep(250); clientStatus = runClient(id); });
    const DWORD callingThread = GetCurrentThreadId();
    const HRESULT received = rune_notify_wait_activation(id, 10000, capture, &waited);
    client.join();
    CHECK(clientStatus == 0 && received == S_OK && waited.count == 1 && second.count == 1);
    CHECK(waited.receivedReply && waited.caller == callingThread);
    CHECK(rune_notify_wait_activation(id, 20, capture, &waited) == S_FALSE);
    rune_notify_stop_activations(id);
    CHECK(FAILED(sendActivation(clsid, 1)));

    std::thread coldClient([&] { Sleep(250); clientStatus = runClient(id); });
    const HRESULT cold = rune_notify_wait_activation(id, 10000, capture, &waited);
    coldClient.join();
    CHECK(clientStatus == 0 && cold == S_OK && waited.count == 2 && waited.caller == callingThread);
    CHECK(FAILED(sendActivation(clsid, 1)));
    CHECK(rune_notify_wait_activation(id, 20, capture, &waited) == S_FALSE);
    CHECK(FAILED(sendActivation(clsid, 1)));
    std::puts("Windows toast COM registration, external Unicode reply, replacement, wait and revocation passed.");
    return 0;
}
} // namespace

int wmain(int argc, wchar_t **argv) {
    const bool client = argc == 3 && wcscmp(argv[1], L"client") == 0;
    CHECK(SUCCEEDED(CoInitializeEx(nullptr, client ? COINIT_MULTITHREADED : COINIT_APARTMENTTHREADED)));
    int result;
    if (client) {
        GUID clsid;
        CHECK(SUCCEEDED(IIDFromString(argv[2], &clsid)));
        const HRESULT activated = sendActivation(clsid, 100);
        if (FAILED(activated)) std::fprintf(stderr, "External activation failed: 0x%08lx\n", activated);
        result = FAILED(activated);
    } else {
        result = test();
    }
    CoUninitialize();
    return result;
}
