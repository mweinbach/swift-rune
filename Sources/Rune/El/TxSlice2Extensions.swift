import Foundation
import RuneMotion

/// What a handler asks of the window and the app (`crates/rune/src/el/tx.rs::Shell`).
public enum Shell: Int, Comparable, Sendable, Hashable {
    case close = 0
    case quit = 1
    case relaunch = 2

    public static func < (lhs: Shell, rhs: Shell) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

internal struct TraceEventRecord: Equatable, Sendable {
    let message: String
}

internal struct TraceChannelRecord: Equatable, Sendable {
    let name: String
    let kind: String
    let value: Float
}

extension Tx {
    internal static let tracingKey = "slice2.tracing"
    internal static let traceEventsKey = "slice2.traceEvents"
    internal static let traceChannelsKey = "slice2.traceChannels"
    internal static let toggleMaximizedKey = "slice2.toggleMaximized"
    internal static let toggleFullScreenKey = "slice2.toggleFullScreen"
    internal static let sentKeysKey = "slice2.sentKeys"
    internal static let announceKey = "slice2.announce"
    internal static let assistiveTechnologyKey = "slice2.assistiveTechnology"
    internal static let fontFamiliesKey = "slice2.fontFamilies"
    internal static let keyRepeatKey = "slice2.keyRepeat"
    internal static let physicalKeyKey = "slice2.physicalKey"
    internal static let keyBaseKey = "slice2.keyBase"
    internal static let inputTimeKey = "slice2.inputTime"
    internal static let shellKey = "slice2.shell"

    /// Highest shell-level exit/close action requested on this `Tx`, if any (`Tx::shell`).
    public var shellRequest: Shell? {
        if (runtimeActions["relaunchApp"] as? Bool) == true || (runtimeActions["relaunchRequested"] as? Bool) == true {
            return .relaunch
        }
        if quitRequested {
            return .quit
        }
        if isCloseWindowRequested {
            return .close
        }
        return runtimeActions[Self.shellKey] as? Shell
    }

    /// Sets the shell lifecycle action (`close`, `quit`, `relaunch`) on this transaction.
    public mutating func setShell(_ shell: Shell) {
        if let cur = runtimeActions[Self.shellKey] as? Shell, cur > shell {
            return
        }
        runtimeActions[Self.shellKey] = shell
        switch shell {
        case .close:
            closeWindow()
        case .quit:
            quit()
        case .relaunch:
            relaunch()
        }
    }

    /// Queues a live-region screen-reader announcement when `how` is non-nil (`Tx::announce`).
    public mutating func announce(_ text: String, _ how: LiveRegionPoliteness?) {
        guard let how else { return }
        announce(text, how)
    }

    /// Moves focus to `key` and controls whether its focus ring displays (`Tx::focus(key, ring)`).
    public mutating func focus(_ key: String, ring: Bool) {
        focus(key, focusVisible: ring)
    }

    /// Restores focus to `key` if no explicit `focus(...)` was asked in the same change (`Tx::return_focus`).
    public mutating func returnFocus(_ key: String, ring: Bool) {
        returnFocus(key, visible: ring)
    }

    /// Whether a keyboard action initiated this handler (`Tx::by_keys`).
    public func byKeysFlag() -> Bool {
        byKeys
    }

    /// Schedules a held-press repeat move delivery after `delay` (`Tx::drag_repeat_after`).
    public mutating func dragRepeatAfter(_ delay: Duration) {
        let comps = delay.components
        dragRepeatAfter(Double(comps.seconds) + Double(comps.attoseconds) * 1e-18)
    }

    // MARK: - Runtime Accessors

    internal var isToggleMaximizedRequested: Bool {
        (runtimeActions[Self.toggleMaximizedKey] as? Bool) == true
    }

    internal var isToggleFullScreenRequested: Bool {
        (runtimeActions[Self.toggleFullScreenKey] as? Bool) == true
    }

    internal var announcementRequest: (text: String, politeness: LiveRegionPoliteness)? {
        runtimeActions[Self.announceKey] as? (text: String, politeness: LiveRegionPoliteness)
    }

    internal var fontFamiliesRequest: (sans: String, mono: String)? {
        runtimeActions["fontFamilies"] as? (sans: String, mono: String)
            ?? (runtimeActions["fontFamilies"] as? (String, String)).map { (sans: $0.0, mono: $0.1) }
    }

    internal var traceEventsRecorded: [String] {
        (runtimeActions[Self.traceEventsKey] as? [String]) ?? []
    }

    internal var traceChannelsRecorded: [(name: String, kind: String, value: Float)] {
        ((runtimeActions[Self.traceChannelsKey] as? [TraceChannelRecord]) ?? [])
            .map { ($0.name, $0.kind, $0.value) }
    }
}
