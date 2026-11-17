import Foundation
#if os(macOS) && canImport(AppKit)
import AppKit

/// The input event AppKit is dispatching now, for the hosts' arrival stamps (`input::time::native`).
@MainActor
internal enum MacOSInputEvents {
    /// AppKit's current event when its type is the `kind` being dispatched; nil otherwise, so the
    /// input arrived now (`input::time::native(kind)`).
    static func current(_ kind: HostInputKind) -> NSEvent? {
        guard let event = NSApp?.currentEvent, matches(event.type, kind) else { return nil }
        return event
    }

    /// The arrival stamp for input of `kind` a view override received as `event` (AppKit's
    /// current event while it dispatches it): its timestamp when it is that kind, else AppKit's
    /// current event's when that is, else nil, so it arrived now (`native(kind)`).
    static func timestamp(_ kind: HostInputKind, _ event: NSEvent?) -> Double? {
        if let event, matches(event.type, kind) { return event.timestamp }
        return current(kind)?.timestamp
    }

    /// Whether an event of `type` is input of `kind` (`native`'s `matches`).
    static func matches(_ type: NSEvent.EventType, _ kind: HostInputKind) -> Bool {
        switch kind {
        case .keyPress, .keyRelease:
            return type == .keyDown || type == .keyUp || type == .flagsChanged
        case .pointer:
            switch type {
            case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                 .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .mouseExited:
                return true
            default:
                return false
            }
        case .wheel:
            return type == .scrollWheel
        case .magnify:
            return type == .magnify
        case .rotate:
            return type == .rotate
        case .smartMagnify:
            return type == .smartMagnify
        }
    }
}
#endif
