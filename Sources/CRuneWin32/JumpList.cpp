#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <wrl/client.h>
#include <string>
#include <unordered_set>
#include <vector>
#include <memory>
#include "RuneWinShellItems.h"

using Microsoft::WRL::ComPtr;

namespace {
const PROPERTYKEY titleKey = {{0xf29f85e0, 0x4ff9, 0x1068, {0xab, 0x91, 0x08, 0x00, 0x2b, 0x27, 0xb3, 0xd9}}, 2};
const wchar_t *wide(const uint16_t *s) { return reinterpret_cast<const wchar_t *>(s); }

// Preserve embedded quotes and trailing backslashes when Explorer launches the link.
std::wstring quoteArgument(const wchar_t *s) {
    std::wstring out(1, L'"');
    size_t slashes = 0;
    for (; *s; ++s) {
        if (*s == L'\\') { ++slashes; continue; }
        if (*s == L'"') out.append(slashes + 1, L'\\');
        out.append(slashes, L'\\');
        slashes = 0;
        out.push_back(*s);
    }
    out.append(slashes * 2, L'\\');
    out.push_back(L'"');
    return out;
}

void collectRemoved(IObjectArray *items, std::unordered_set<std::wstring> &arguments) {
    UINT count = 0;
    if (FAILED(items->GetCount(&count))) return;
    std::vector<wchar_t> buffer(32768);
    for (UINT i = 0; i < count; ++i) {
        ComPtr<IShellLinkW> link;
        if (FAILED(items->GetAt(i, IID_PPV_ARGS(&link))) ||
            FAILED(link->GetArguments(buffer.data(), static_cast<int>(buffer.size())))) continue;
        const std::wstring command = std::wstring(L"app ") + buffer.data();
        int argc = 0;
        wchar_t **argv = CommandLineToArgvW(command.c_str(), &argc);
        if (argv && argc > 1) arguments.emplace(argv[argc - 1]);
        LocalFree(argv);
    }
}
}

struct RuneWinJumpDraft {
    ComPtr<ICustomDestinationList> list;
    ComPtr<IObjectCollection> entries;
    std::unordered_set<std::wstring> removed;
    std::wstring program, prefix, category;
    bool tasks = true, inList = false;

    HRESULT append() {
        UINT count = 0;
        HRESULT hr = entries->GetCount(&count);
        if (FAILED(hr) || !count) return hr;
        if (tasks) return list->AddUserTasks(entries.Get());
        // A privacy policy can hide custom categories. Tasks and allowed categories still commit.
        list->AppendCategory(category.c_str(), entries.Get());
        return S_OK;
    }
    HRESULT newCollection() {
        entries.Reset();
        return CoCreateInstance(CLSID_EnumerableObjectCollection, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&entries));
    }
    ~RuneWinJumpDraft() {
        if (inList) list->AbortList();
    }
};

int32_t rune_win_jump_begin(RuneWinJumpDraft **out, const uint16_t *lead) {
    *out = nullptr;
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(hr)) return hr;
    auto draft = std::unique_ptr<RuneWinJumpDraft>(new RuneWinJumpDraft);
    std::vector<wchar_t> path(32768);
    DWORD length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (!length) hr = HRESULT_FROM_WIN32(GetLastError());
    else if (length == path.size()) hr = HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER);
    else {
        draft->program.assign(path.data(), length);
        if (lead) draft->prefix = quoteArgument(wide(lead)) + L" ";
        hr = CoCreateInstance(CLSID_DestinationList, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&draft->list));
    }
    if (SUCCEEDED(hr)) {
        PWSTR appID = nullptr;
        if (SUCCEEDED(GetCurrentProcessExplicitAppUserModelID(&appID))) {
            hr = draft->list->SetAppID(appID);
            CoTaskMemFree(appID);
        }
    }
    if (SUCCEEDED(hr)) {
        ComPtr<IObjectArray> removed;
        UINT slots = 0;
        hr = draft->list->BeginList(&slots, IID_PPV_ARGS(&removed));
        if (SUCCEEDED(hr)) {
            draft->inList = true;
            collectRemoved(removed.Get(), draft->removed);
            hr = draft->newCollection();
        }
    }
    if (FAILED(hr)) {
        draft.reset();
        CoUninitialize();
        return hr;
    }
    *out = draft.release();
    return S_OK;
}

int32_t rune_win_jump_category(RuneWinJumpDraft *draft, const uint16_t *name) {
    HRESULT hr = draft->append();
    if (FAILED(hr)) return hr;
    draft->tasks = false;
    draft->category = wide(name);
    return draft->newCollection();
}

int32_t rune_win_jump_item(RuneWinJumpDraft *draft, const uint16_t *title, const uint16_t *arg,
                           const uint16_t *description) {
    if (!draft->tasks && draft->removed.count(wide(arg))) return S_OK;
    ComPtr<IShellLinkW> link;
    HRESULT hr = CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&link));
    if (SUCCEEDED(hr)) hr = link->SetPath(draft->program.c_str());
    if (SUCCEEDED(hr)) hr = link->SetArguments((draft->prefix + quoteArgument(wide(arg))).c_str());
    if (SUCCEEDED(hr)) hr = link->SetIconLocation(draft->program.c_str(), 0);
    if (SUCCEEDED(hr) && *description) hr = link->SetDescription(wide(description));
    ComPtr<IPropertyStore> properties;
    if (SUCCEEDED(hr)) hr = link.As(&properties);
    PROPVARIANT value = {};
    value.vt = VT_LPWSTR;
    value.pwszVal = const_cast<wchar_t *>(wide(title));
    if (SUCCEEDED(hr)) hr = properties->SetValue(titleKey, value);
    if (SUCCEEDED(hr)) hr = properties->Commit();
    if (SUCCEEDED(hr)) hr = draft->entries->AddObject(link.Get());
    return hr;
}

int32_t rune_win_jump_commit(RuneWinJumpDraft *draft) {
    HRESULT hr = draft->append();
    if (SUCCEEDED(hr)) hr = draft->list->CommitList();
    if (SUCCEEDED(hr)) draft->inList = false;
    return hr;
}

void rune_win_jump_dispose(RuneWinJumpDraft *draft) {
    delete draft;
    CoUninitialize();
}
#endif
