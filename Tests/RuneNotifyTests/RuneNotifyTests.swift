import Foundation
import Testing
@testable import RuneNotify
#if canImport(UserNotifications)
import ObjectiveC
import UserNotifications
#endif

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

    @Test func aClickReachesTheHandlerAndCompletes() {
        let fakeClass: AnyClass = {
            if let existing = objc_getClass("RuneMacFakeNotificationResponse") as? AnyClass {
                return existing
            }
            let cls: AnyClass = objc_allocateClassPair(NSObject.self, "RuneMacFakeNotificationResponse", 0)!
            let selfImp: @convention(c) (AnyObject, Selector) -> AnyObject = { obj, _ in obj }
            let idImp: @convention(c) (AnyObject, Selector) -> AnyObject = { _, _ in "n-7" as NSString }
            let infoImp: @convention(c) (AnyObject, Selector) -> AnyObject = { _, _ in
                ["session": "ses_7", "server": "http://127.0.0.1:4096"] as NSDictionary
            }
            let actionImp: @convention(c) (AnyObject, Selector) -> AnyObject = { _, _ in
                "com.apple.UNNotificationDefaultActionIdentifier" as NSString
            }
            class_addMethod(cls, NSSelectorFromString("notification"), unsafeBitCast(selfImp, to: IMP.self), "@@:")
            class_addMethod(cls, NSSelectorFromString("request"), unsafeBitCast(selfImp, to: IMP.self), "@@:")
            class_addMethod(cls, NSSelectorFromString("content"), unsafeBitCast(selfImp, to: IMP.self), "@@:")
            class_addMethod(cls, NSSelectorFromString("identifier"), unsafeBitCast(idImp, to: IMP.self), "@@:")
            class_addMethod(cls, NSSelectorFromString("userInfo"), unsafeBitCast(infoImp, to: IMP.self), "@@:")
            class_addMethod(cls, NSSelectorFromString("actionIdentifier"), unsafeBitCast(actionImp, to: IMP.self), "@@:")
            objc_registerClassPair(cls)
            return cls
        }()

        let got = NotifyLock(initialState: [NotificationClick]())
        let completed = NotifyLock(initialState: false)
        let backend = UserNotificationsBackend()
        backend.setClickHandler { click in
            got.withLock { $0.append(click) }
        }
        defer { backend.setClickHandler(nil) }

        let responseObject: NSObject = (fakeClass as! NSObject.Type).init()
        let centerObject = NSObject()
        let fakeResponse = Unmanaged<UNNotificationResponse>.fromOpaque(
            Unmanaged.passUnretained(responseObject).toOpaque()
        ).takeUnretainedValue()
        let fakeCenter = Unmanaged<UNUserNotificationCenter>.fromOpaque(
            Unmanaged.passUnretained(centerObject).toOpaque()
        ).takeUnretainedValue()
        backend.userNotificationCenter(fakeCenter, didReceive: fakeResponse) {
            completed.withLock { $0 = true }
        }

        let clicks = got.withLock { $0 }
        #expect(clicks.count == 1)
        #expect(clicks[0].id == "n-7")
        #expect(clicks[0].get("session") == "ses_7")
        #expect(clicks[0].info.count == 2)
        #expect(completed.withLock { $0 })
    }
    #endif

    @Test func registrationActivationAndCriticalUrgencyParity() throws {
        let mock = MockNotificationBackend()
        let service = NotificationService(backend: mock)
        let identity = NotificationIdentity(id: "dev.rune.test", name: "Rune Test")
            .activation("rune-notify")

        try service.registerWithResult(identity).get()
        try service.adoptWithResult(identity).get()
        #expect(mock.registeredIdentity == identity)
        try service.serveActivations("{12345678-1234-1234-1234-1234567890ab}").get()
        #expect(service.waitActivation("{12345678-1234-1234-1234-1234567890ab}", timeout: 0.01) == nil)

        let click = service.clickFromURL("rune-notify://notification/n-99?session=ses_9&rune.action=open")
        #expect(click?.id == "n-99")
        #expect(click?.get("session") == "ses_9")
        #expect(click?.action == "open")
        #expect(service.clickFromURL("other-scheme://notification/n-99") == nil)

        let critical = Notification(id: "crit-1", title: "Urgent").urgency(.critical)
        #expect(service.post(critical))
        #expect(mock.activeNotifications.first?.urgency == .critical)

        // Default non-Windows platform parity: returns nil / success cleanly.
        #expect(RuneNotify.clickFromURL("rune-notify://notification/n-1") == nil)
        try RuneNotify.serveActivations("{00000000-0000-0000-0000-000000000000}").get()
        #expect(RuneNotify.waitActivation("{00000000-0000-0000-0000-000000000000}", timeout: 0) == nil)
    }
}
