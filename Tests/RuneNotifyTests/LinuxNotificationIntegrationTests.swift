#if os(Linux)
import CRuneNotify
import Dispatch
import Glibc
import class Foundation.ProcessInfo
import Testing
@testable import RuneNotify

/// Run through scripts/test-linux-notifications.py to use a private session bus.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RUNE_TEST_NOTIFICATION_BUS"] == "1"))
struct LinuxNotificationIntegrationTests {
    @Test func actionReplyReplacementAndRemoval() throws {
        let service = NotificationService()
        #expect(service.isAvailable)
        try service.registerWithResult(.init(id: "dev.rune.notify.test", name: "Rune Fixture")).get()
        let event = DispatchSemaphore(value: 0)
        let clicks = NotifyLock(initialState: [NotificationClick]())
        let testWindow: UInt32 = 0x72756E65
        rune_notify_linux_window_opened(testWindow, 1) { _, _ in }
        rune_notify_linux_window_visible(testWindow, 1)
        defer { rune_notify_linux_window_closed(testWindow) }
        service.onClick { click in
            clicks.withLock { $0.append(click) }
            if click.action == "default" { service.bringToFront() }
            event.signal()
        }
        defer { service.clearClickHandler() }
        let note: Notification = Notification(id: "n-🦦", title: "One", body: "A < B")
            .info("thread", "alpha")
            .action(id: "default", label: "Open")
            .reply(id: "compose", placeholder: "Say something", label: "Send")
        #expect(service.post(note))
        #expect(event.wait(timeout: .now() + 5) == .success)
        #expect(clicks.withLock { $0.last?.action } == "default")
        var token: UnsafeMutablePointer<CChar>?
        #expect(rune_notify_linux_take_activation(testWindow, &token) != 0)
        if let token {
            #expect(String(cString: token) == "notification-action-token")
            free(token)
        } else {
            Issue.record("The window did not receive the notification's activation token")
        }
        #expect(rune_notify_linux_take_activation(testWindow, &token) == 0)

        var updated = note
        updated.title = "Two"
        updated.info = [("thread", "β")]
        #expect(service.post(updated))
        #expect(event.wait(timeout: .now() + 5) == .success)
        #expect(clicks.withLock { $0.last?.input(for: "compose") } == "你好 🦦")
        #expect(clicks.withLock { $0.last?.get("thread") } == "β")
        #expect(clicks.withLock { $0.last?.id } == "n-🦦")
        service.remove(ids: ["n-🦦", "unknown"])
        #expect(service.post(note))
        #expect(event.wait(timeout: .now() + 5) == .success)
        #expect(clicks.withLock { $0.last?.action } == nil)
        #expect(clicks.withLock { $0.count } == 3)
        service.remove(ids: ["n-🦦"])
    }
}
#endif
