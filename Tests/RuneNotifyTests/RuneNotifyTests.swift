import Foundation
import Testing
@testable import RuneNotify

@Suite("RuneNotify Tests")
struct RuneNotifyTests {
    #if canImport(UserNotifications)
    @Test func unbundledTestBinaryCannotPostToUserNotifications() {
        #expect(!UserNotificationsBackend.isBundledApp)
        #expect(!RuneNotify.isAvailable)
        let posted = RuneNotify.post(
            Notification(id: "n-1", title: "Response ready")
                .body("Fix the build")
        )
        #expect(!posted)
        RuneNotify.remove(ids: ["n-1"])
    }
    #endif

    @Test func notificationBuilderSetsAllFields() {
        let n = Notification(id: "build-1", title: "Build Finished")
            .subtitle("swift-rune")
            .body("All targets passed")
            .info("session", "ses_42")
            .info("workspace", "/tmp/proj")
            .action(id: "open", label: "Open")
            .reply(id: "reply", placeholder: "Type a message", label: "Send")
            .sound(.default)
            .urgency(.timeSensitive)
            .category("custom.cat")

        #expect(n.id == "build-1")
        #expect(n.title == "Build Finished")
        #expect(n.subtitle == "swift-rune")
        #expect(n.body == "All targets passed")
        #expect(n.info.count == 2)
        #expect(n.actions.count == 2)
        #expect(n.sound == .default)
        #expect(n.urgency == .timeSensitive)
        #expect(n.categoryIdentifier == "custom.cat")
    }

    @Test func mockBackendPostsReplacesRemovesAndDeliversClicks() {
        let mock = MockNotificationBackend()
        let service = NotificationService(backend: mock)

        let receivedClicks = NotifyLock(initialState: [NotificationClick]())
        service.onClick { click in
            receivedClicks.withLock { $0.append(click) }
        }

        let first = Notification(id: "n-1", title: "First")
            .body("Body 1")
            .info("session", "ses_1")
            .action(id: "view", label: "View")
            .reply(id: "reply", placeholder: "Reply...", label: "Send")

        #expect(service.post(first))
        #expect(mock.activeNotifications.count == 1)
        #expect(mock.registeredCategories.count == 1)

        // Posting with same ID replaces the active notification.
        let replacement = Notification(id: "n-1", title: "Updated")
            .body("Body 2")
            .info("session", "ses_2")
            .action(id: "view", label: "View")
            .reply(id: "reply", placeholder: "Reply...", label: "Send")

        #expect(service.post(replacement))
        #expect(mock.activeNotifications.count == 1)
        #expect(mock.activeNotifications[0].title == "Updated")
        #expect(mock.postedHistory.count == 2)

        // Default click
        let defaultClick = mock.simulateClick(notificationId: "n-1")
        #expect(defaultClick.id == "n-1")
        #expect(defaultClick.get("session") == "ses_2")
        #expect(defaultClick.action == nil)

        // Button + reply click
        let replyClick = mock.simulateClick(
            notificationId: "n-1",
            actionId: "reply",
            inputText: "Looks good!"
        )
        #expect(replyClick.action == "reply")
        #expect(replyClick.input(for: "reply") == "Looks good!")
        #expect(receivedClicks.withLock { $0.count } == 2)

        service.remove(ids: ["n-1"])
        #expect(mock.activeNotifications.isEmpty)
        #expect(mock.removedIds == ["n-1"])
    }

    @Test func mockBackendUnavailableAndFocusAndBringToFront() {
        let mock = MockNotificationBackend(available: false, appFocused: true)
        let service = NotificationService(backend: mock)

        #expect(!service.isAvailable)
        #expect(service.isAppFocused)
        #expect(!service.post(Notification(id: "x", title: "Should drop")))
        #expect(mock.activeNotifications.isEmpty)

        mock.setAvailable(true)
        mock.setAppFocused(false)
        #expect(service.isAvailable)
        #expect(!service.isAppFocused)

        service.bringToFront()
        #expect(mock.bringToFrontCount == 1)
    }

    @Test func categoryHasherIsDeterministicAndOrderSensitive() {
        let a1: [NotificationAction] = [.button(id: "ok", label: "OK")]
        let a2: [NotificationAction] = [.button(id: "ok", label: "OK")]
        let a3: [NotificationAction] = [.button(id: "cancel", label: "Cancel")]

        let h1 = NotificationCategoryHasher.identifier(for: a1)
        let h2 = NotificationCategoryHasher.identifier(for: a2)
        let h3 = NotificationCategoryHasher.identifier(for: a3)

        #expect(h1 == h2)
        #expect(h1 != h3)
        #expect(h1.hasPrefix("rune."))
    }

    #if canImport(UserNotifications)
    @Test func parseClickFiltersSystemActionsAndExtractsReplyText() {
        let defaultTap = UserNotificationsBackend.parseClick(
            identifier: "n-7",
            userInfo: ["session": "ses_7", "count": 42],
            actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier",
            userText: nil
        )
        #expect(defaultTap.id == "n-7")
        #expect(defaultTap.get("session") == "ses_7")
        #expect(defaultTap.get("count") == nil)
        #expect(defaultTap.action == nil)

        let replyTap = UserNotificationsBackend.parseClick(
            identifier: "n-8",
            userInfo: ["session": "ses_8"],
            actionIdentifier: "reply-btn",
            userText: "Ship it"
        )
        #expect(replyTap.action == "reply-btn")
        #expect(replyTap.input(for: "reply-btn") == "Ship it")
    }
    #endif
}
