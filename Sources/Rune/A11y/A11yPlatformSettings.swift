import Foundation

#if os(macOS) && canImport(AppKit)
import AppKit
#elseif canImport(UIKit) && !os(watchOS)
import UIKit
#endif

// MARK: - Headings on macOS (`vendor/accesskit_macos.patch`, upstream #975)

/// How a heading reaches VoiceOver: AppKit's heading role with its level as the value, as WebKit
/// and Chromium give it. AccessKit's published macOS adapter said `"Heading"`, a role neither
/// AppKit nor VoiceOver knows, so the rotor and VO-Command-H found no heading.
public enum AccessibilityHeading {
    /// `NSAccessibilityRole` of a heading (`Role::Heading => ns_string!("AXHeading")`).
    public static let macRoleName = "AXHeading"

    /// A heading's `accessibilityValue`: its level. Rune stores the level one less (AccessKit's
    /// convention, `AccessibilityNode.level`), and ARIA's default is 2; clamped to 1...9.
    public static func macLevelValue(level: Int?) -> Int {
        min(max(level.map { $0 + 1 } ?? 2, 1), 9)
    }
}

// MARK: - Key-owning groups (`a11y/node.rs`, upstream #980)

/// The role-context rules `a11y_role` reads of an element's handlers.
public enum AccessibilityRoleRules {
    /// A group that takes its own keys (`El::on_key`) and no press (a game's surface: arrows,
    /// Space) is no button even when it steers by drag: Return or Space doesn't press it. As the
    /// web mirror has it, a labelled one stays a group.
    public static func ownsKeys(role: ElementRole, hasKeyHandler: Bool, hasPress: Bool, hasDoublePress: Bool) -> Bool {
        role == .group && hasKeyHandler && !hasPress && !hasDoublePress
    }

    /// `RoleCtx::pressable`: a primary handler (`Handlers::has_primary`: press, double press,
    /// hover, drag, drag out) and not a key-owning group.
    public static func pressable(hasPrimary: Bool, ownsKeys: Bool) -> Bool {
        hasPrimary && !ownsKeys
    }
}

public extension El {
    /// `owns_keys` of `a11y_role`: a `.group` with `onKey` and neither `onClick`/`onClickPress`
    /// nor `onDoubleClick`.
    var a11yOwnsKeys: Bool {
        AccessibilityRoleRules.ownsKeys(
            role: role,
            hasKeyHandler: handlers.onKey != nil,
            hasPress: handlers.onClick != nil || handlers.onClickPress != nil,
            hasDoublePress: handlers.onDoubleClick != nil
        )
    }

    /// `RoleCtx::pressable` of `a11y_role`.
    var a11yPressable: Bool {
        let h = handlers
        let hasPrimary = h.onClick != nil || h.onClickPress != nil || h.onDoubleClick != nil
            || h.onHover != nil || h.onDrag != nil || h.dragOut != nil
        return AccessibilityRoleRules.pressable(hasPrimary: hasPrimary, ownsKeys: a11yOwnsKeys)
    }
}

// MARK: - Increase Contrast & the capture presets (`platform/preferences.rs`, upstream #980/#981)

public extension SystemPreferences {
    /// `RUNE_INCREASE_CONTRAST=1`: `increasedContrast()` on, for captures and checks
    /// (`increased_contrast_preset`).
    static func increasedContrastPreset(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        env["RUNE_INCREASE_CONTRAST"] == "1"
    }

    /// `RUNE_CONTRAST=aquatic|desert|dusk|night-sky` (`contrast_preset`).
    static func contrastPreset(_ env: [String: String] = ProcessInfo.processInfo.environment) -> SystemContrast? {
        SystemContrast.fromEnvironment(env)
    }

    /// Whether the system asks apps for more contrast: macOS's Increase Contrast (Accessibility >
    /// Display), iOS's Increase Contrast, or a Windows contrast theme. `RUNE_INCREASE_CONTRAST=1`
    /// reports it on without turning it on for the whole machine (`increased_contrast`).
    static func increasedContrast(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if increasedContrastPreset(env) { return true }
        #if os(macOS) && canImport(AppKit)
        return NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        #elseif canImport(UIKit) && !os(watchOS)
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated { UIAccessibility.isDarkerSystemColorsEnabled }
        #elseif os(Windows)
        return SystemPreferences.current().contrast != nil
        #else
        return false
        #endif
    }
}

public extension Runtime {
    /// The capture presets (`RUNE_CONTRAST`, `RUNE_INCREASE_CONTRAST`), never the machine's own
    /// settings, so a headless snap shows an app in a contrast theme or under Increase Contrast
    /// and runs stay reproducible (`tooling.rs` `runtime_for`, #981).
    func applyCapturePresets(_ env: [String: String] = ProcessInfo.processInfo.environment) {
        setSystemContrast(SystemPreferences.contrastPreset(env))
        setSystemIncreasedContrast(SystemPreferences.increasedContrastPreset(env))
    }

    /// What a native window reads of the system as it opens and gains focus: the contrast theme
    /// and Increase Contrast (`window.rs`, `window/events.rs`).
    func readSystemContrastSettings() {
        setSystemContrast(SystemPreferences.current().contrast)
        setSystemIncreasedContrast(SystemPreferences.increasedContrast())
    }

    /// The system's accessibility settings changed (the a11y inbox's `settings`, macOS's
    /// `NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification`): reduced motion, the
    /// contrast theme and Increase Contrast are read again at once. `forceReducedMotion`: the
    /// launch's `--reduced-motion` flag, which the system can't turn off.
    func readSystemAccessibilitySettings(forceReducedMotion: Bool = false) {
        let prefs = SystemPreferences.current()
        setSystemReducedMotion(forceReducedMotion || prefs.reducedMotion)
        setSystemContrast(prefs.contrast)
        setSystemIncreasedContrast(SystemPreferences.increasedContrast())
    }

    /// The update to send an accessibility adapter (`a11y_update`): this runtime's tree with
    /// `Tx::announce`'s live region as the root's last child. A whole tree with words said in
    /// the last 1.5 s goes out without them and the runtime stays dirty, so the next update
    /// carries them as a change a reader that just attached hears (#980).
    func accessibilityUpdate(
        link: AccessibilityLink,
        now: Double = AccessibilityAnnouncement.clock(),
        actionHandler: ((String, AccessibilityAction, String?) -> Bool)? = nil
    ) -> AccessibilityTreeUpdate? {
        let update = link.service(
            rootNode: accessibilitySnapshot(),
            windowTitle: windowTitle ?? "",
            announcement: a11yAnnouncement,
            now: now,
            actionHandler: actionHandler
        )
        if link.needsFollowUp { markNeedsCommit() }
        return update
    }
}

// MARK: - RUNE_OPEN_INACTIVE (`window.rs`, `window/event_loop.rs`, upstream #962)

/// A tool's launch (an accessibility probe, a capture) leaves the user's focus and keyboard
/// where they are, as `App::open_inactive` does.
public enum OpenInactiveLaunch {
    public static let variable = "RUNE_OPEN_INACTIVE"

    /// `std::env::var_os("RUNE_OPEN_INACTIVE").is_some()`: set, whatever its value.
    public static func isRequested(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        env[variable] != nil
    }

    /// The launch's `open_inactive`: the app's own, or the variable's.
    public static func openInactive(app: Bool, env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        app || isRequested(env)
    }

    /// Whether the launch activates the app (`activate_ignoring_other_apps`): not an accessory's,
    /// and not under `RUNE_OPEN_INACTIVE`. The activation policy stays the app's own: only an
    /// accessory switches to `.accessory`.
    public static func activatesAtLaunch(accessory: Bool, env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        !accessory && !isRequested(env)
    }
}

#if os(macOS) && canImport(AppKit)

// MARK: - The workspace's display options (`a11y/macos.rs` `DisplayOptions`, upstream #980)

/// The workspace's accessibility display options (Increase Contrast, Reduce Motion, Reduce
/// Transparency) changed: the runtime reads them again at once, as Windows' `WM_SETTINGCHANGE`
/// does, rather than at the window's next activation. Owned by the window's accessibility
/// adapter; its observer is removed when it goes.
public final class MacOSDisplayOptionsWatcher {
    private nonisolated(unsafe) var center: NotificationCenter?
    private nonisolated(unsafe) var token: NSObjectProtocol?

    public init(onChange: @escaping @MainActor () -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        self.center = center
        token = center.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onChange() }
        }
    }

    public var isWatching: Bool { token != nil }

    deinit {
        if let center, let token {
            center.removeObserver(token)
        }
    }
}

#endif
