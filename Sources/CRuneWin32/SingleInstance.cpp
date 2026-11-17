#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include "RuneSingleInstance.h"
#include <algorithm>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace {
constexpr char magic[] = "rune-instance 2";
constexpr char legacyMagic[] = "rune-instance 1";
constexpr DWORD answerWithin = 50;
constexpr DWORD reachFor = 5000;
constexpr DWORD handedWait = 10000;
constexpr size_t maxBody = 1u << 20;

struct Handle {
    HANDLE value;
    explicit Handle(HANDLE value = nullptr) : value(value) {}
    ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
    Handle(const Handle &) = delete;
    Handle &operator=(const Handle &) = delete;
};

// Match the Rust pipe name, including the raw SID bytes in lowercase hex.
bool userSID(HANDLE process, std::vector<unsigned char> &sid) {
    Handle token;
    if (!OpenProcessToken(process, TOKEN_QUERY, &token.value)) return false;
    DWORD size = 0;
    GetTokenInformation(token.value, TokenUser, nullptr, 0, &size);
    if (!size) return false;
    std::vector<unsigned char> data(size);
    if (!GetTokenInformation(token.value, TokenUser, data.data(), size, &size)) return false;
    PSID user = reinterpret_cast<TOKEN_USER *>(data.data())->User.Sid;
    if (!IsValidSid(user)) return false;
    auto first = static_cast<unsigned char *>(user);
    sid.assign(first, first + GetLengthSid(user));
    return true;
}

std::wstring pipeName(const uint16_t *id, size_t idLength, DWORD session, const std::vector<unsigned char> &sid, int generation) {
    std::wstring name = L"\\\\.\\pipe\\rune-instance-" + std::to_wstring(session) + L"-";
    const wchar_t hex[] = L"0123456789abcdef";
    for (unsigned char byte : sid) { name += hex[byte >> 4]; name += hex[byte & 15]; }
    name += L'-';
    for (size_t i = 0; i < idLength; ++i) {
        wchar_t c = wchar_t(id[i]);
        name += (c == L'\\' || c < 32 || (c >= 127 && c <= 159)) ? L'-' : c;
    }
    if (generation) name += L"-" + std::to_wstring(generation);
    // Rust takes 256 Unicode scalars from the full name before converting it to UTF-16.
    if (name.size() > 256) {
        size_t end = 0;
        for (size_t count = 0; count < 256 && end < name.size(); ++count, ++end) {
            if (end + 1 < name.size() && IS_SURROGATE_PAIR(name[end], name[end + 1])) ++end;
        }
        name.resize(end);
    }
    return name;
}

HANDLE createPipe(const std::wstring &name) {
    return CreateNamedPipeW(name.c_str(), PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE | FILE_FLAG_OVERLAPPED,
                            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                            PIPE_UNLIMITED_INSTANCES, 16, 65536, 0, nullptr);
}

DWORD timeLeft(ULONGLONG deadline) {
    ULONGLONG now = GetTickCount64();
    return now < deadline ? static_cast<DWORD>(deadline - now) : 0;
}

// A stack OVERLAPPED must remain alive until even a cancelled kernel operation has finished.
template<class Start>
bool operation(HANDLE pipe, HANDLE event, HANDLE stop, DWORD wait, DWORD &n, Start start) {
    n = 0;
    ResetEvent(event);
    OVERLAPPED op{};
    op.hEvent = event;
    if (!start(&op, &n)) {
        if (GetLastError() != ERROR_IO_PENDING) return false;
        HANDLE events[] = {event, stop};
        if (WaitForMultipleObjects(stop ? 2 : 1, events, FALSE, wait) != WAIT_OBJECT_0) {
            CancelIoEx(pipe, &op);
            GetOverlappedResult(pipe, &op, &n, TRUE);
            SetLastError(ERROR_OPERATION_ABORTED);
            return false;
        }
        return GetOverlappedResult(pipe, &op, &n, FALSE) != FALSE;
    }
    return true;
}

struct Listener {
    Handle pipe;
    Handle event{CreateEventW(nullptr, TRUE, FALSE, nullptr)};
    Handle stop{CreateEventW(nullptr, TRUE, FALSE, nullptr)};
    Handle thread;
    DWORD threadId = 0;
    RuneInstanceQuitting quitting;
    RuneInstanceReceive receive;
    Listener(HANDLE pipe, RuneInstanceQuitting quitting, RuneInstanceReceive receive)
        : pipe(pipe), quitting(quitting), receive(receive) {}
};
SRWLOCK ownerLock = SRWLOCK_INIT;
std::shared_ptr<Listener> owner;

bool readMessage(Listener &server, std::vector<uint8_t> &message, size_t &start, size_t &length, bool &answers) {
    BYTE buf[4096];
    for (;;) {
        if (message.size() >= sizeof(magic)) {
            answers = std::memcmp(message.data(), magic, sizeof(magic)) == 0;
            if (!answers && std::memcmp(message.data(), legacyMagic, sizeof(legacyMagic)) != 0) return false;
            start = sizeof(magic) + (answers ? sizeof(uint32_t) : 0);
            if (answers && message.size() >= start) {
                uint32_t len;
                std::memcpy(&len, message.data() + sizeof(magic), sizeof(len));
                length = len; // Windows targets are little-endian.
                if (length > maxBody) return false;
                if (message.size() >= start + length) break;
            }
        }
        DWORD got;
        bool ok = operation(server.pipe.value, server.event.value, server.stop.value, INFINITE, got,
                            [&](OVERLAPPED *o, DWORD *n) { return ReadFile(server.pipe.value, buf, sizeof(buf), n, o); });
        if (!ok || got == 0) {
            if (answers || !start || (GetLastError() != ERROR_BROKEN_PIPE && GetLastError() != ERROR_NO_DATA)) return false;
            length = message.size() - start;
            break;
        }
        message.insert(message.end(), buf, buf + got);
        if (message.size() > sizeof(magic) + sizeof(uint32_t) + maxBody) return false;
    }
    return length <= maxBody && (length == 0 || MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        reinterpret_cast<const char *>(message.data() + start), static_cast<int>(length), nullptr, 0) > 0);
}

DWORD WINAPI serve(void *arg) {
    std::unique_ptr<std::shared_ptr<Listener>> held(static_cast<std::shared_ptr<Listener> *>(arg));
    Listener &server = **held;
    while (WaitForSingleObject(server.stop.value, 0) == WAIT_TIMEOUT) {
        DWORD n;
        bool connected = operation(server.pipe.value, server.event.value, server.stop.value, INFINITE, n,
            [&](OVERLAPPED *o, DWORD *) { return ConnectNamedPipe(server.pipe.value, o); });
        if (connected || GetLastError() == ERROR_PIPE_CONNECTED) {
            std::vector<uint8_t> message;
            size_t start = 0, length = 0;
            bool answers = false;
            if (readMessage(server, message, start, length, answers)) {
                bool quitting = server.quitting() != 0;
                if (answers) {
                    BYTE reply = quitting ? 'Q' : 'A';
                    if (operation(server.pipe.value, server.event.value, server.stop.value, answerWithin, n,
                        [&](OVERLAPPED *o, DWORD *num) { return WriteFile(server.pipe.value, &reply, 1, num, o); })) {
                        // The peer closes after reading its reply. A bounded read keeps the ACK
                        // available until then and lets release interrupt even an unresponsive peer.
                        BYTE trailing;
                        operation(server.pipe.value, server.event.value, server.stop.value, answerWithin, n,
                            [&](OVERLAPPED *o, DWORD *num) { return ReadFile(server.pipe.value, &trailing, 1, num, o); });
                    }
                }
                if (!answers || !quitting) server.receive(message.data() + start, static_cast<uint32_t>(length));
            }
        }
        DisconnectNamedPipe(server.pipe.value);
    }
    return 0;
}

void listen(HANDLE pipe, RuneInstanceQuitting quitting, RuneInstanceReceive receive) {
    auto next = std::make_shared<Listener>(pipe, quitting, receive);
    if (!next->event.value || !next->stop.value) return;
    AcquireSRWLockExclusive(&ownerLock);
    if (!owner) {
        auto argument = std::unique_ptr<std::shared_ptr<Listener>>(new std::shared_ptr<Listener>(next));
        next->thread.value = CreateThread(nullptr, 0, serve, argument.get(), 0, &next->threadId);
        if (next->thread.value) {
            argument.release();
            owner = next;
        }
    }
    ReleaseSRWLockExclusive(&ownerLock);
}

enum class Sent { delivered, quitting, gone, nobody };

Sent send(const std::wstring &name, const std::vector<unsigned char> &sid, DWORD session,
          const uint8_t *message, DWORD length, ULONG &pid) {
    if (!length) return Sent::nobody;
    ULONGLONG deadline = GetTickCount64() + answerWithin;
    Handle pipe;
    for (;;) {
        pipe.value = CreateFileW(name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
                                 FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
        if (pipe.value != INVALID_HANDLE_VALUE) break;
        DWORD err = GetLastError();
        if (err == ERROR_FILE_NOT_FOUND) return Sent::gone;
        DWORD remaining = timeLeft(deadline);
        if (err != ERROR_PIPE_BUSY || !remaining) return Sent::nobody;
        if (!WaitNamedPipeW(name.c_str(), remaining)) {
            return GetLastError() == ERROR_FILE_NOT_FOUND ? Sent::gone : Sent::nobody;
        }
    }
    DWORD remoteSession;
    if (!GetNamedPipeServerProcessId(pipe.value, &pid) ||
        !ProcessIdToSessionId(pid, &remoteSession) || remoteSession != session) return Sent::nobody;
    Handle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid));
    std::vector<unsigned char> remoteSID;
    if (!process.value || !userSID(process.value, remoteSID) || remoteSID != sid) return Sent::nobody;
    AllowSetForegroundWindow(pid);
    Handle event(CreateEventW(nullptr, TRUE, FALSE, nullptr));
    if (!event.value) return Sent::nobody;
    DWORD n;
    if (!operation(pipe.value, event.value, nullptr, timeLeft(deadline), n,
        [&](OVERLAPPED *o, DWORD *num) { return WriteFile(pipe.value, message, length, num, o); }) || n != length) return Sent::nobody;
    BYTE reply = 0;
    if (!operation(pipe.value, event.value, nullptr, timeLeft(deadline), n,
        [&](OVERLAPPED *o, DWORD *num) { return ReadFile(pipe.value, &reply, 1, num, o); }) || n != 1) return Sent::nobody;
    if (reply == 'A') return Sent::delivered;
    return reply == 'Q' ? Sent::quitting : Sent::nobody;
}
} // namespace

extern "C" int32_t rune_win_instance_process_alive(uint32_t pid) {
    Handle process(OpenProcess(SYNCHRONIZE, FALSE, pid));
    return process.value && WaitForSingleObject(process.value, 0) == WAIT_TIMEOUT;
}

extern "C" int32_t rune_win_instance_claim(const uint16_t *id, size_t idLength, const uint8_t *message, uint32_t length,
                                            uint32_t handedPid, RuneInstanceQuitting quitting, RuneInstanceReceive receive) {
    DWORD session;
    std::vector<unsigned char> sid;
    if ((!id && idLength) || (!message && length) || !quitting || !receive || !ProcessIdToSessionId(GetCurrentProcessId(), &session) ||
        !userSID(GetCurrentProcess(), sid)) return 1;
    ULONGLONG waitHanded = GetTickCount64() + handedWait;
    for (int generation = 0; generation < 8; ++generation) {
        std::wstring name = pipeName(id, idLength, session, sid, generation);
        ULONGLONG deadline = GetTickCount64() + reachFor;
        for (;;) {
            HANDLE pipe = createPipe(name);
            if (pipe != INVALID_HANDLE_VALUE) {
                listen(pipe, quitting, receive);
                return 1;
            }
            if (GetLastError() != ERROR_ACCESS_DENIED) return 1;
            if (handedPid && timeLeft(waitHanded) && rune_win_instance_process_alive(handedPid)) {
                Sleep(1);
                continue;
            }
            ULONG server = 0;
            Sent result = send(name, sid, session, message, length, server);
            if (result == Sent::delivered) return 0;
            if (result == Sent::quitting) {
                handedPid = server;
                waitHanded = GetTickCount64() + handedWait;
                continue;
            }
            if (result == Sent::gone && timeLeft(deadline)) continue;
            if (result == Sent::gone) return 1;
            break;
        }
    }
    return 1;
}

extern "C" void rune_win_instance_release(void) {
    AcquireSRWLockExclusive(&ownerLock);
    auto released = std::move(owner);
    if (released) SetEvent(released->stop.value);
    ReleaseSRWLockExclusive(&ownerLock);
    if (released && released->threadId != GetCurrentThreadId())
        WaitForSingleObject(released->thread.value, INFINITE);
}

namespace {
BOOL CALLBACK findFront(HWND window, LPARAM result) {
    DWORD pid = 0;
    GetWindowThreadProcessId(window, &pid);
    if (pid != GetCurrentProcessId() || !IsWindowVisible(window) || GetWindow(window, GW_OWNER) ||
        (GetWindowLongPtrW(window, GWL_EXSTYLE) & WS_EX_TOOLWINDOW)) return TRUE;
    *reinterpret_cast<HWND *>(result) = window;
    return FALSE;
}
}
extern "C" void rune_win_instance_raise_front(void) {
    HWND window = nullptr;
    EnumWindows(findFront, reinterpret_cast<LPARAM>(&window));
    if (window) {
        if (IsIconic(window)) ShowWindow(window, SW_RESTORE);
        SetForegroundWindow(window);
    }
}
#endif
