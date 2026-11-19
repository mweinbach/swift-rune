#include "CRuneTestSockets.h"
#include <limits.h>

#ifdef _WIN32
#include <winsock2.h>
typedef SOCKET NativeSocket;
typedef int SocketLength;
static int startup(void) {
    WSADATA data;
    return WSAStartup(MAKEWORD(2, 2), &data);
}
static int last_error(void) { return WSAGetLastError(); }
static void cleanup(void) { WSACleanup(); }
#else
#include <arpa/inet.h>
#include <errno.h>
#include <sys/socket.h>
#include <unistd.h>
typedef int NativeSocket;
typedef socklen_t SocketLength;
#define INVALID_SOCKET (-1)
static int startup(void) { return 0; }
static int last_error(void) { return errno; }
static void cleanup(void) {}
#endif

void rune_test_socket_close(intptr_t handle) {
    NativeSocket fd = (NativeSocket)handle;
#ifdef _WIN32
    shutdown(fd, SD_BOTH);
    closesocket(fd);
#else
    shutdown(fd, SHUT_RDWR);
    close(fd);
#endif
    cleanup();
}

intptr_t rune_test_socket_listen(uint16_t *port, int *error) {
    *error = startup();
    if (*error) return -1;
    NativeSocket fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd == INVALID_SOCKET) {
        *error = last_error();
        cleanup();
        return -1;
    }
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    SocketLength length = sizeof(addr);
    if (bind(fd, (const struct sockaddr *)&addr, length) || listen(fd, 16) ||
        getsockname(fd, (struct sockaddr *)&addr, &length)) {
        *error = last_error();
        rune_test_socket_close((intptr_t)fd);
        return -1;
    }
    *port = ntohs(addr.sin_port);
    return (intptr_t)fd;
}

intptr_t rune_test_socket_accept(intptr_t listener) {
    /* Keep Winsock initialized while a concurrent stop closes the listener. */
    if (startup()) return -1;
    NativeSocket fd = accept((NativeSocket)listener, NULL, NULL);
    if (fd == INVALID_SOCKET) {
        cleanup();
        return -1;
    }
#ifdef SO_NOSIGPIPE
    int enabled = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
#endif
    return (intptr_t)fd;
}

int rune_test_socket_read(intptr_t client, void *bytes, size_t count) {
    int size = count > INT_MAX ? INT_MAX : (int)count;
    return (int)recv((NativeSocket)client, bytes, size, 0);
}

int rune_test_socket_write(intptr_t client, const void *bytes, size_t count) {
    int size = count > INT_MAX ? INT_MAX : (int)count;
#ifdef MSG_NOSIGNAL
    return (int)send((NativeSocket)client, bytes, size, MSG_NOSIGNAL);
#else
    return (int)send((NativeSocket)client, bytes, size, 0);
#endif
}

#if defined(__APPLE__)
#include <TargetConditionals.h>
#if TARGET_OS_OSX
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

typedef void (*rune_async_main_original_t)(void);
typedef void (*rune_async_main_hook_t)(rune_async_main_original_t original);

static void rune_test_keep_alive_source_perform(void *info) { (void)info; }

static void rune_test_async_main_drain_queue(rune_async_main_original_t original) {
    (void)original;
    /* Swift 6.4's default CFMainExecutor calls CFRunLoopRun() once and immediately
     * exits with status 0 if it ever returns. When macOS tests create NSWindow or
     * NSPanel instances, AppKit/HIToolbox's SignalMainThread() asynchronously calls
     * CFRunLoopStop(CFRunLoopGetMain()), prematurely terminating swiftpm-testing-helper
     * mid-suite. Re-entering CFRunLoopRun() keeps MainActor and RunLoop.main alive
     * until Swift Testing finishes all tests and calls exit(status) directly. */
    CFRunLoopRef main_loop = CFRunLoopGetMain();
    CFRunLoopSourceContext ctx = {0};
    ctx.perform = rune_test_keep_alive_source_perform;
    CFRunLoopSourceRef keep_alive = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &ctx);
    if (keep_alive) {
        CFRunLoopAddSource(main_loop, keep_alive, kCFRunLoopCommonModes);
    }
    for (;;) {
        CFRunLoopRun();
    }
}

__attribute__((constructor))
static void rune_test_guard_cf_main_executor(void) {
    const char *prog = getprogname();
    if (!prog || strcmp(prog, "swiftpm-testing-helper") != 0) {
        return;
    }
    rune_async_main_hook_t *hook_slot =
        (rune_async_main_hook_t *)dlsym(RTLD_DEFAULT, "swift_task_asyncMainDrainQueue_hook");
    if (!hook_slot || *hook_slot != NULL) {
        return;
    }
    *hook_slot = rune_test_async_main_drain_queue;
}
#endif
#endif
