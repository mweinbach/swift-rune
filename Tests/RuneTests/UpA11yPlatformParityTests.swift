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

    @Test func runtimeAnnouncementIsHeldAcrossTheFirstTree() throws {
        let rt = Runtime(state: 0, viewport: Vec2(300, 200), pixelScale: 1.0) { (_: Int, _: inout Cx<Int>) in
            col().children([el().key("ok").role(.button).focusable().size(80, 30)])
        }
        rt.windowTitle = "Probe"
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.01) { _, tx in tx.announce("Saved", .assertive) }
        _ = rt.frame(at: 0.02)
        #expect(rt.a11yAnnouncement.text == "Saved")
        #expect(rt.a11yAnnouncement.politeness == .assertive)
        let said = try #require(rt.a11yAnnouncement.at)

        let link = AccessibilityLink()
        link.activate()
        rt.needsCommit = false
        let first = try #require(rt.accessibilityUpdate(link: link, now: said + 0.2))
        #expect(first.isFullTree)
        #expect(first.updatedNodes.first { $0.id == AccessibilityTreeState.announcerID }?.label == nil)
        #expect(rt.needsCommit, "held words keep the runtime dirty")

        let second = try #require(rt.accessibilityUpdate(link: link, now: said + 0.3))
        let words = try #require(second.updatedNodes.first { $0.id == AccessibilityTreeState.announcerID })
        #expect(words.label == "Saved")
        #expect(words.liveRegion == .assertive)
    }

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
            ])
        }
        _ = rt.frame(at: 0.0)
        func find(_ id: String, in n: AccessibilityNode) -> AccessibilityNode? {
            if n.id == id { return n }
            for c in n.children { if let f = find(id, in: c) { return f } }
            return nil
        }
        let node = find("game", in: rt.accessibilitySnapshot())
        #expect(node?.role == .group)
        #expect(node?.actions.contains(.press) == false)
        #expect(node?.actions.contains(.focus) == true)
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
