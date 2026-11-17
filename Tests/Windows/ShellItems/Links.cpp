// Build with TrayMenu.cpp as a standalone executable; it never publishes a tray or Jump List.
#include "../../../Sources/CRuneWin32/JumpList.cpp"
#include <cstdio>
bool testTrayMenu();

namespace {
bool samePath(const wchar_t *left, const wchar_t *right) {
    // The shell may expand 8.3 directory names even when the executable was launched by its short path.
    wchar_t lhs[MAX_PATH] = {}, rhs[MAX_PATH] = {};
    return GetLongPathNameW(left, lhs, MAX_PATH) && GetLongPathNameW(right, rhs, MAX_PATH) && !_wcsicmp(lhs, rhs);
}

bool testLinks() {
    const auto u = [](const wchar_t *s) { return reinterpret_cast<const uint16_t *>(s); };
    RuneWinJumpDraft draft;
    wchar_t path[MAX_PATH];
    if (!GetModuleFileNameW(nullptr, path, MAX_PATH) || FAILED(draft.newCollection())) return false;
    draft.program = path;
    const wchar_t *lead = L"--profile=C:\\path with spaces\\";
    const wchar_t *argument = L"rune://item with \"quotes\" and trailing slash\\";
    draft.prefix = quoteArgument(lead) + L" ";
    if (FAILED(rune_win_jump_item(&draft, u(L"Example"), u(argument), u(L"Item description")))) return false;
    ComPtr<IShellLinkW> link;
    if (FAILED(draft.entries->GetAt(0, IID_PPV_ARGS(&link)))) return false;
    wchar_t args[512] = {}, desc[128] = {}, target[MAX_PATH] = {}, icon[MAX_PATH] = {};
    int iconIndex = -1;
    if (FAILED(link->GetArguments(args, 512)) || FAILED(link->GetDescription(desc, 128)) ||
        FAILED(link->GetPath(target, MAX_PATH, nullptr, 0)) ||
        FAILED(link->GetIconLocation(icon, MAX_PATH, &iconIndex))) return false;
    int argc = 0;
    auto **argv = CommandLineToArgvW((std::wstring(L"app ") + args).c_str(), &argc);
    bool quoted = argv && argc == 3 && !wcscmp(lead, argv[1]) && !wcscmp(argument, argv[2]);
    LocalFree(argv);
    ComPtr<IPropertyStore> properties;
    PROPVARIANT title = {};
    if (FAILED(link.As(&properties)) || FAILED(properties->GetValue(titleKey, &title))) return false;
    wchar_t expandedIcon[MAX_PATH] = {};
    ExpandEnvironmentStringsW(icon, expandedIcon, MAX_PATH);
    bool titleOK = title.vt == VT_LPWSTR && !wcscmp(title.pwszVal, L"Example");
    bool fields = titleOK && !wcscmp(desc, L"Item description") && samePath(target, path) &&
                  samePath(expandedIcon, path) && iconIndex == 0;
    if (!fields) {
        std::printf("title type=%u matches=%d description=%ls target=%ls icon=%ls index=%d expected=%ls\n",
                    title.vt, titleOK, desc, target, expandedIcon, iconIndex, path);
    }
    PropVariantClear(&title);
    collectRemoved(draft.entries.Get(), draft.removed);
    draft.tasks = false;
    if (FAILED(draft.newCollection()) ||
        FAILED(rune_win_jump_item(&draft, u(L"Removed entry"), u(argument), u(L""))) ||
        FAILED(rune_win_jump_item(&draft, u(L"Fresh entry"), u(L"rune://new"), u(L"")))) return false;
    UINT count = 0;
    bool removed = SUCCEEDED(draft.entries->GetCount(&count)) && count == 1 && draft.removed.count(argument);
    std::printf("links arguments=%d fields=%d removedExcluded=%d\n", quoted, fields, removed);
    return quoted && fields && removed;
}
}

int main() {
    if (FAILED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) return 2;
    bool menu = testTrayMenu(), links = testLinks();
    CoUninitialize();
    std::printf("menu flags/order/selection=%d\n", menu);
    return menu && links ? 0 : 1;
}
