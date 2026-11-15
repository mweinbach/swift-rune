import Testing
import Foundation
@testable import Rune
import RuneMotion
#if os(macOS) && canImport(AppKit)
import AppKit
#endif

/// upstream-delta-3 up-a11y-1: #975 (6f85c4ea) macOS headings, #980 (1e08ee48) Increase Contrast,
/// announcer held across the first tree, key-owning group, #981 (d9068287) headless contrast
/// presets, #962 (f1f54ce8) RUNE_OPEN_INACTIVE.
@Suite("Up A11y Platform Parity")
struct UpA11yPlatformParityTests {

    // MARK: - #975 AXHeading with its level

    @Test func headingLevelValueIsLevelPlusOneDefaultTwoClamped() {
        // `self.0.level().map_or(2, |l| l + 1).clamp(1, 9)`.
        #expect(AccessibilityHeading.macRoleName == "AXHeading")
        #expect(AccessibilityHeading.macLevelValue(level: nil) == 2)
        #expect(AccessibilityHeading.macLevelValue(level: 0) == 1)
        #expect(AccessibilityHeading.macLevelValue(level: 1) == 2)
        #expect(AccessibilityHeading.macLevelValue(level: 2) == 3)
        #expect(AccessibilityHeading.macLevelValue(level: 8) == 9)
        #expect(AccessibilityHeading.macLevelValue(level: 40) == 9)
        #expect(AccessibilityHeading.macLevelValue(level: -3) == 1)
    }

    #if os(macOS) && canImport(AppKit)
    @MainActor
    @Test func headingsReachVoiceOverAsAXHeadingWithTheirLevel() {
        #expect(AppKitAccessibilityMapper.nsRole(for: .heading).rawValue == "AXHeading")

        // The session title (`headingLevel(1)`) and a turn heading (`headingLevel(2)`), as the
        // runtime projects them: AccessKit's level one less.
        let rt = Runtime(state: 0, viewport: Vec2(400, 200), pixelScale: 1.0) { (_: Int, _: inout Cx<Int>) in
            col().children([
                text("Session").key("title").headingLevel(1),
                text("Prompt 1 of 2").key("turn").headingLevel(2),
                text("Plain").key("plain").role(.heading),
            ])
        }
        _ = rt.frame(at: 0.0)
        let tree = rt.accessibilitySnapshot()
        func find(_ id: String, in n: AccessibilityNode) -> AccessibilityNode? {
            if n.id == id { return n }
            for c in n.children { if let f = find(id, in: c) { return f } }
            return nil
        }
        let title = try! #require(find("title", in: tree))
        let turn = try! #require(find("turn", in: tree))
        let plain = try! #require(find("plain", in: tree))
        #expect(title.level == 0)
        #expect(turn.level == 1)
        #expect(plain.level == nil)

        let titleEl = AppKitAccessibilityMapper.buildElement(from: title)
        #expect(titleEl.accessibilityRole()?.rawValue == "AXHeading")
        #expect((titleEl.accessibilityValue() as? NSNumber)?.intValue == 1)
        #expect(titleEl.accessibilityLabel() == "Session")
        let turnEl = AppKitAccessibilityMapper.buildElement(from: turn)
        #expect((turnEl.accessibilityValue() as? NSNumber)?.intValue == 2)
        let plainEl = AppKitAccessibilityMapper.buildElement(from: plain)
        #expect((plainEl.accessibilityValue() as? NSNumber)?.intValue == 2)

        // Checked before the text value fallback: a heading carrying a value still says its level.
        let valued = AccessibilityNode(id: "h", role: .heading, label: "H", value: "ignored", level: 3)
        #expect((AppKitAccessibilityMapper.buildElement(from: valued).accessibilityValue() as? NSNumber)?.intValue == 4)
        // Other roles keep their string value.
        let field = AccessibilityNode(id: "f", role: .textInput, label: "F", value: "abc")
        #expect(AppKitAccessibilityMapper.buildElement(from: field).accessibilityValue() as? String == "abc")
    }
    #endif

    // MARK: - #980 (a) Cx.systemIncreasedContrast

    @Test func increaseContrastPresetIsExactlyOne() {
        #expect(SystemPreferences.increasedContrastPreset(["RUNE_INCREASE_CONTRAST": "1"]))
        #expect(!SystemPreferences.increasedContrastPreset(["RUNE_INCREASE_CONTRAST": "0"]))
        #expect(!SystemPreferences.increasedContrastPreset(["RUNE_INCREASE_CONTRAST": "true"]))
        #expect(!SystemPreferences.increasedContrastPreset(["RUNE_INCREASE_CONTRAST": ""]))
        #expect(!SystemPreferences.increasedContrastPreset([:]))
        // The preset reports it on without touching the machine's setting.
        #expect(SystemPreferences.increasedContrast(["RUNE_INCREASE_CONTRAST": "1"]))
        #expect(SystemPreferences.contrastPreset(["RUNE_CONTRAST": "night-sky"]) == SystemContrast.preset(named: "night-sky"))
        #expect(SystemPreferences.contrastPreset([:]) == nil)
    }

    @Test func systemIncreasedContrastReachesCxAndDirtiesOnlyOnChange() {
        final class Seen: @unchecked Sendable { var values: [Bool] = [] }
        let seen = Seen()
        let rt = Runtime(state: 0, viewport: Vec2(200, 100), pixelScale: 1.0) { (_: Int, cx: inout Cx<Int>) in
            seen.values.append(cx.systemIncreasedContrast())
            return el().key("box").size(10, 10)
        }
        _ = rt.frame(at: 0.0)
        #expect(seen.values.last == false)
        #expect(!rt.systemIncreasedContrast())

        rt.needsCommit = false
        rt.setSystemIncreasedContrast(false)
        #expect(!rt.needsCommit, "no change, no re-run")

        rt.setSystemIncreasedContrast(true)
        #expect(rt.needsCommit, "a change re-runs the view")
        #expect(rt.systemIncreasedContrast())
        _ = rt.frame(at: 0.016)
        #expect(seen.values.last == true)

        rt.needsCommit = false
        rt.setSystemIncreasedContrast(true)
        #expect(!rt.needsCommit)
    }

    @Test func settingsChangeRereadsReducedMotionKeepingTheLaunchFlag() {
        let rt = Runtime(state: 0, viewport: Vec2(200, 100), pixelScale: 1.0) { (_: Int, _: inout Cx<Int>) in
            el().size(10, 10)
        }
        rt.readSystemAccessibilitySettings(forceReducedMotion: true)
        #expect(rt.systemReducedMotion())
    }

    // MARK: - #980 (b) words said as a reader attaches

    @Test func announcementIsRecentForOneAndAHalfSeconds() {
        var a = AccessibilityAnnouncement()
        #expect(!a.recent(now: 0))
        #expect(a.words == nil)
        a.say("Saved", politeness: .assertive, at: 10.0)
        #expect(a.at == 10.0)
        #expect(a.recent(now: 10.0))
        #expect(a.recent(now: 11.499))
        #expect(!a.recent(now: 11.5))
        #expect(a.words?.text == "Saved")
        #expect(a.words?.politeness == .assertive)
        // Every other call ends in a zero-width space, so a repeat still changes the name.
        a.say("Saved", politeness: .assertive, at: 12.0)
        #expect(a.words?.text == "Saved\u{200B}")
    }

    private static func window() -> AccessibilityNode {
        AccessibilityNode(
            id: "root",
            role: .group,
            label: "Window",
            frame: MotionRect.fromXYWH(0, 0, 400, 300),
            children: [AccessibilityNode(id: "b", role: .button, label: "OK", frame: MotionRect.fromXYWH(10, 10, 80, 30))]
        )
    }

    @Test func firstWholeTreeHoldsRecentWordsAndTheNextUpdateSaysThem() throws {
        let link = AccessibilityLink()
        link.activate()
        var said = AccessibilityAnnouncement()
        said.say("Saved", politeness: .polite, at: 100.0)

        // The whole tree an adapter starts from: the announcer goes out without its words.
        let first = try #require(link.service(rootNode: Self.window(), windowTitle: "W", announcement: said, now: 100.5))
        #expect(first.isFullTree)
        let quiet = try #require(first.updatedNodes.first { $0.id == AccessibilityTreeState.announcerID })
        #expect(quiet.label == nil)
        #expect(quiet.role == .status)
        #expect(quiet.liveRegion == .polite)
        #expect(quiet.frame == MotionRect.fromXYWH(0, 0, 1, 1))
        let firstRoot = try #require(first.updatedNodes.first { $0.id == "root" })
        #expect(firstRoot.children.last?.id == AccessibilityTreeState.announcerID)
        #expect(link.needsFollowUp, "held: the runtime stays dirty")

        // The next update rebuilds the root, whose node carries the announcer, with the words.
        let second = try #require(link.service(rootNode: Self.window(), windowTitle: "W", announcement: said, now: 100.6))
        #expect(!second.isFullTree)
        #expect(second.updatedNodes.contains { $0.id == "root" })
        let spoken = try #require(second.updatedNodes.first { $0.id == AccessibilityTreeState.announcerID })
        #expect(spoken.label == "Saved")
        #expect(!second.updatedNodes.contains { $0.id == "b" })
        #expect(!link.needsFollowUp)

        // Nothing changed since: no update.
        #expect(link.service(rootNode: Self.window(), windowTitle: "W", announcement: said, now: 100.7) == nil)
    }

    @Test func oldWordsGoOutWithTheWholeTreeAndHoldNothing() throws {
        let link = AccessibilityLink()
        link.activate()
        var said = AccessibilityAnnouncement()
        said.say("Done", politeness: .assertive, at: 10.0)
        let first = try #require(link.service(rootNode: Self.window(), windowTitle: "W", announcement: said, now: 20.0))
        #expect(first.isFullTree)
        let node = try #require(first.updatedNodes.first { $0.id == AccessibilityTreeState.announcerID })
        #expect(node.label == "Done")
        #expect(node.liveRegion == .assertive)
        #expect(!link.needsFollowUp)
        #expect(link.service(rootNode: Self.window(), windowTitle: "W", announcement: said, now: 20.1) == nil)
    }

    @Test func wordsSaidAfterTheFirstTreeAreAPlainChange() throws {
        let link = AccessibilityLink()
        link.activate()
        var said = AccessibilityAnnouncement()
        _ = try #require(link.service(rootNode: Self.window(), windowTitle: "W", announcement: said, now: 1.0))
        #expect(!link.needsFollowUp)
        said.say("Copied", politeness: .polite, at: 2.0)
        let next = try #require(link.service(rootNode: Self.window(), windowTitle: "W", announcement: said, now: 2.0))
        #expect(!next.isFullTree)
        #expect(next.updatedNodes.first { $0.id == AccessibilityTreeState.announcerID }?.label == "Copied")
        #expect(!link.needsFollowUp, "only a whole tree holds words back")
    }

    #if os(macOS) && canImport(AppKit)
    /// The live macOS host (`MacOSAccessibilityHost`, which `MacOSApp` and the multi-window host
    /// update every committed tree) holds recent words across a whole tree and says them next.
    @MainActor
    @Test func liveMacHostHoldsRecentWordsAcrossTheTreeAReaderStartsFrom() throws {
        let rt = Runtime(state: 0, viewport: Vec2(300, 200), pixelScale: 1.0) { (_: Int, _: inout Cx<Int>) in
            col().children([el().key("ok").role(.button).focusable().size(80, 30)])
        }
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.01) { _, tx in tx.announce("Saved", .assertive) }
        _ = rt.frame(at: 0.02)
        #expect(rt.a11yAnnouncement.text == "Saved")
        #expect(rt.a11yAnnouncement.politeness == .assertive)
        let said = try #require(rt.a11yAnnouncement.at)

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let host = MacOSAccessibilityHost()
        func update(_ dt: Double) -> Bool {
            host.update(tree: rt.accessibilitySnapshot(), announcement: rt.a11yAnnouncement, now: said + dt, parentView: view) { _, _ in }
        }
        // The whole tree the adapter starts from: no words, and the host must update again.
        #expect(update(0.2), "held: the runtime stays dirty")
        #expect(host.lastSpoken.isEmpty)
        // The next update says them.
        #expect(!update(0.3))
        #expect(host.lastSpoken.map(\.text) == ["Saved"])
        #expect(host.lastSpoken.map(\.politeness) == [.assertive])
        #expect(!update(0.4))
        #expect(host.lastSpoken.isEmpty, "said once")

        // VoiceOver attaches: its first request activates the adapter, whose next update is the
        // whole tree that reader starts from.
        final class Count { var n = 0 }
        let activations = Count()
        host.onActivate = { activations.n += 1 }
        #expect(!host.isActivated)
        let kids = host.accessibilityChildren()
        #expect(host.isActivated)
        #expect(activations.n == 1)
        let announcer = try #require(kids.last as? RuneNSAccessibilityElement)
        #expect(announcer.nodeId == AccessibilityTreeState.announcerID)
        #expect(announcer.accessibilityLabel() == "Saved")
        _ = host.accessibilityChildren()
        #expect(activations.n == 1, "activated once")

        // Words said 0.5 s ago are still recent: held from that tree, then said to the new reader.
        #expect(update(0.5))
        #expect(host.lastSpoken.isEmpty)
        let quiet = try #require(host.accessibilityChildren().last as? RuneNSAccessibilityElement)
        #expect(quiet.accessibilityLabel() == nil)
        #expect(!update(0.6))
        #expect(host.lastSpoken.map(\.text) == ["Saved"])
    }

    /// The stamp's `announced` (`a11y/tree.rs`): words from a live-only handler, which commit
    /// nothing, still change the stamp, so the live host updates and speaks them at once.
    @MainActor
    @Test func liveOnlyAnnouncementChangesTheStampWithoutACommit() throws {
        let rt = Runtime(state: 0, viewport: Vec2(300, 200), pixelScale: 1.0) { (_: Int, _: inout Cx<Int>) in
            col().children([el().key("ok").role(.button).focusable().size(80, 30)])
        }
        _ = rt.frame(at: 0.0)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let host = MacOSAccessibilityHost()
        #expect(!host.announcementChanged(rt.a11yAnnouncement), "nothing said yet")
        host.update(tree: rt.accessibilitySnapshot(), announcement: rt.a11yAnnouncement, now: 10, parentView: view) { _, _ in }

        let commits = rt.viewCommitCount
        rt.update(at: 0.01) { _, tx in
            tx.liveOnly()
            tx.announce("Copied")
        }
        _ = rt.frame(at: 0.02)
        #expect(rt.viewCommitCount == commits, "a live-only handler commits nothing")
        #expect(host.announcementChanged(rt.a11yAnnouncement), "the stamp's announced count changed")
        let said = try #require(rt.a11yAnnouncement.at)
        #expect(!host.update(tree: rt.accessibilitySnapshot(), announcement: rt.a11yAnnouncement, now: said, parentView: view) { _, _ in })
        #expect(host.lastSpoken.map(\.text) == ["Copied"])
        #expect(host.sentAnnouncementCount == rt.a11yAnnouncement.count)
        #expect(!host.announcementChanged(rt.a11yAnnouncement), "sent: the stamp matches again")

        // The same words again are a new announcement (the count, not the text).
        rt.update(at: 0.03) { _, tx in
            tx.liveOnly()
            tx.announce("Copied")
        }
        #expect(host.announcementChanged(rt.a11yAnnouncement))
    }

    @MainActor
    @Test func liveMacHostSaysNothingOfOldWordsInAWholeTree() throws {
        let rt = Runtime(state: 0, viewport: Vec2(300, 200), pixelScale: 1.0) { (_: Int, _: inout Cx<Int>) in
            col().children([el().key("ok").role(.button).focusable().size(80, 30)])
        }
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.01) { _, tx in tx.announce("Done") }
        _ = rt.frame(at: 0.02)
        let said = try #require(rt.a11yAnnouncement.at)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let host = MacOSAccessibilityHost()
        // A reader already asking before the first tree: that first tree is the one it starts from.
        host.activate()
        #expect(host.isActivated)
        #expect(!host.update(tree: rt.accessibilitySnapshot(), announcement: rt.a11yAnnouncement, now: said + 5, parentView: view) { _, _ in })
        #expect(host.lastSpoken.isEmpty, "a whole tree raises no events")
        let announcer = try #require(host.accessibilityChildren().last as? RuneNSAccessibilityElement)
        #expect(announcer.accessibilityLabel() == "Done")

        // Words said later are a change, spoken at once.
        rt.update(at: 0.03) { _, tx in tx.announce("Copied") }
        _ = rt.frame(at: 0.04)
        let later = try #require(rt.a11yAnnouncement.at)
        #expect(!host.update(tree: rt.accessibilitySnapshot(), announcement: rt.a11yAnnouncement, now: later, parentView: view) { _, _ in })
        #expect(host.lastSpoken.map(\.text) == ["Copied\u{200B}"])
        #expect(host.lastSpoken.map(\.politeness) == [.polite])
    }
    #endif

    // MARK: - #980 (c) a key-owning group stays a group

    @Test func keyOwningGroupWithoutPressIsNoButton() {
        #expect(AccessibilityRoleRules.ownsKeys(role: .group, hasKeyHandler: true, hasPress: false, hasDoublePress: false))
        #expect(!AccessibilityRoleRules.ownsKeys(role: .group, hasKeyHandler: true, hasPress: true, hasDoublePress: false))
        #expect(!AccessibilityRoleRules.ownsKeys(role: .group, hasKeyHandler: true, hasPress: false, hasDoublePress: true))
        #expect(!AccessibilityRoleRules.ownsKeys(role: .group, hasKeyHandler: false, hasPress: false, hasDoublePress: false))
        #expect(!AccessibilityRoleRules.ownsKeys(role: .button, hasKeyHandler: true, hasPress: false, hasDoublePress: false))
        #expect(!AccessibilityRoleRules.pressable(hasPrimary: true, ownsKeys: true))
        #expect(AccessibilityRoleRules.pressable(hasPrimary: true, ownsKeys: false))
        #expect(!AccessibilityRoleRules.pressable(hasPrimary: false, ownsKeys: false))

        // The new-session game surface: arrows and Space by `onKey`, steered by drag.
        let game: El<Int> = el().key("game").label("Brick Breaker").focusable()
            .onKey { _, _, _ in true }
            .onDrag { _, _, _ in }
        #expect(game.role == .group)
        #expect(game.a11yOwnsKeys)
        #expect(!game.a11yPressable)

        // A press makes it a button as before.
        let pressed: El<Int> = el().key("b").onKey { _, _, _ in true }.onClick { (_: inout Int) in }
        #expect(pressed.role == .button)
        #expect(!pressed.a11yOwnsKeys)
        #expect(pressed.a11yPressable)

        let rt = Runtime(state: 0, viewport: Vec2(300, 200), pixelScale: 1.0) { (_: Int, _: inout Cx<Int>) in
            col().children([
                el().key("game").label("Brick Breaker").focusable().size(200, 100)
                    .onKey { _, _, _ in true }
                    .onDrag { _, _, _ in },
                el().key("steer").focusable().size(50, 20).onDrag { _, _, _ in },
                el().key("hover").size(50, 20).onHover { _, _, _ in },
            ])
        }
        _ = rt.frame(at: 0.0)
        func find(_ id: String, in n: AccessibilityNode) -> AccessibilityNode? {
            if n.id == id { return n }
            for c in n.children { if let f = find(id, in: c) { return f } }
            return nil
        }
        let tree = rt.accessibilitySnapshot()
        let node = find("game", in: tree)
        #expect(node?.role == .group, "owns its keys: no button though it steers by drag")
        #expect(node?.actions.contains(.press) == false)
        #expect(node?.actions.contains(.focus) == true)
        // The same focusable group without its keys is pressable by drag: a button (`roles::group`).
        #expect(find("steer", in: tree)?.role == .button)
        // One the keyboard can't reach stays a group.
        #expect(find("hover", in: tree)?.role == .group)
    }

    // MARK: - #981 headless runs start with the contrast presets only

    @Test func headlessRuntimeAppliesOnlyTheCapturePresets() {
        let rt = Runtime(state: 0, viewport: Vec2(200, 100), pixelScale: 1.0) { (_: Int, _: inout Cx<Int>) in
            el().size(10, 10)
        }
        rt.applyCapturePresets(["RUNE_CONTRAST": "night-sky", "RUNE_INCREASE_CONTRAST": "1"])
        #expect(rt.systemContrast() == SystemContrast.preset(named: "night-sky"))
        #expect(rt.systemIncreasedContrast())
        rt.applyCapturePresets(["RUNE_CONTRAST": "Aquatic"])
        #expect(rt.systemContrast() == SystemContrast.preset(named: "aquatic"))
        #expect(!rt.systemIncreasedContrast())
        // Without them nothing is on, whatever the machine says.
        rt.applyCapturePresets([:])
        #expect(rt.systemContrast() == nil)
        #expect(!rt.systemIncreasedContrast())
    }

    /// `App::headless_runtime` builds through `tooling::runtime_for`, which applies the presets.
    @MainActor
    @Test func appHeadlessRuntimeAppliesTheCapturePresets() {
        let app = App<Int>("presets", size: Vec2(200, 100), init: { 0 }, view: { _, _ in el().size(10, 10) })
        let env = Env(systemDark: false, scale: 1.0)
        let themed = app.headlessRuntime(
            size: Vec2(200, 100), env: env,
            processEnvironment: ["RUNE_CONTRAST": "desert", "RUNE_INCREASE_CONTRAST": "1"]
        )
        #expect(themed.systemContrast() == SystemContrast.preset(named: "desert"))
        #expect(themed.systemIncreasedContrast())
        let plain = app.headlessRuntime(size: Vec2(200, 100), env: env, processEnvironment: ["RUNE_INCREASE_CONTRAST": "true"])
        #expect(plain.systemContrast() == nil)
        #expect(!plain.systemIncreasedContrast(), "exactly 1")
    }

    // MARK: - #962 RUNE_OPEN_INACTIVE

    @Test func openInactiveVariableLeavesFocusAndActivationAlone() {
        #expect(OpenInactiveLaunch.variable == "RUNE_OPEN_INACTIVE")
        #expect(!OpenInactiveLaunch.isRequested([:]))
        // `var_os(..).is_some()`: set at all, even empty.
        #expect(OpenInactiveLaunch.isRequested(["RUNE_OPEN_INACTIVE": ""]))
        #expect(OpenInactiveLaunch.isRequested(["RUNE_OPEN_INACTIVE": "1"]))
        #expect(OpenInactiveLaunch.openInactive(app: false, env: ["RUNE_OPEN_INACTIVE": "1"]))
        #expect(OpenInactiveLaunch.openInactive(app: true, env: [:]))
        #expect(!OpenInactiveLaunch.openInactive(app: false, env: [:]))
        #expect(OpenInactiveLaunch.activatesAtLaunch(accessory: false, env: [:]))
        #expect(!OpenInactiveLaunch.activatesAtLaunch(accessory: false, env: ["RUNE_OPEN_INACTIVE": "1"]))
        #expect(!OpenInactiveLaunch.activatesAtLaunch(accessory: true, env: [:]))
        // Win32: an unfocused first show never activates (`SW_SHOWNOACTIVATE`), otherwise `SW_SHOW`.
        #expect(OpenInactiveLaunch.win32ShowCommand(openInactive: true) == 4)
        #expect(OpenInactiveLaunch.win32ShowCommand(openInactive: false) == 5)
        #expect(OpenInactiveLaunch.win32ShowCommand(
            openInactive: OpenInactiveLaunch.openInactive(app: false, env: ["RUNE_OPEN_INACTIVE": ""])) == 4)
    }

    // MARK: - #980 display options observer owned by the adapter

    #if os(macOS) && canImport(AppKit)
    @MainActor
    @Test func displayOptionsChangeCallsBackUntilTheAdapterGoes() {
        final class Count { var n = 0 }
        let count = Count()
        var watcher: MacOSDisplayOptionsWatcher? = MacOSDisplayOptionsWatcher { count.n += 1 }
        #expect(watcher?.isWatching == true)
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(count.n == 1)
        watcher = nil
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(count.n == 1, "removed on deinit")
        _ = watcher

        let host = MacOSAccessibilityHost()
        #expect(!host.watchesDisplayOptions)
        host.watchDisplayOptions {}
        #expect(host.watchesDisplayOptions)
    }
    #endif
}
