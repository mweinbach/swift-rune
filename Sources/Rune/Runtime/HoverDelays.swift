import Foundation

/// Phase of a single `El.hoverDelays` element's delayed hover report
/// (`crates/rune/src/runtime/input/hover_delay.rs`).
public enum DelayedHoverPhase: Equatable, Sendable {
    /// The pointer is inside; the enter report fires at `due` (clock seconds).
    case enterDue(due: Double)
    /// The element has heard `true` (`onHoverChange` reported inside).
    case shown
    /// It heard `true` and the pointer left; the leave report fires at `due`.
    case leaveDue(due: Double)
}

/// Event driving a delayed hover element's state machine.
public enum HoverDelayEvent: Equatable, Sendable {
    /// Settle current containment (`inside`) against delays `[enter, leave]` at `now`.
    /// `mayEnter` is false while a press is held, or after a press/blur until the pointer next moves.
    case settle(inside: Bool, mayEnter: Bool, enterDelay: Float, leaveDelay: Float, now: Double)
    /// Frame clock reached `now`: report any wait whose deadline `due <= now`.
    case due(now: Double)
    /// Pointer pressed: cancel a pending enter wait (leave waits continue).
    case pressed
    /// Element left the tree or window lost focus: report `false` only if already shown, and stop waits.
    case ended
}

/// Output effect produced by `stepHoverDelayState(_:event:)`.
public enum HoverDelayEffect: Equatable, Sendable {
    /// Invoke `onHoverChange` with this value.
    case report(Bool)
    /// Wake the runtime at `due` so a pending wait can fire on schedule.
    case wakeAt(Double)
}

/// Advances one delayed hover element's state (`hover_delay::step`).
@discardableResult
public func stepHoverDelayState(_ state: inout DelayedHoverPhase?, event: HoverDelayEvent) -> [HoverDelayEffect] {
    let shown: Bool
    switch state {
    case .shown, .leaveDue:
        shown = true
    case .enterDue, nil:
        shown = false
    }

    switch event {
    case let .settle(inside, mayEnter, enterDelay, leaveDelay, now):
        let want = inside && (shown || mayEnter)
        if want == shown {
            state = shown ? .shown : nil
            return []
        }
        // Already waiting to report `want`.
        switch state {
        case .enterDue, .leaveDue:
            return []
        case .shown, nil:
            break
        }
        let d = Double(want ? enterDelay : leaveDelay)
        if d <= 0.0 {
            state = want ? .shown : nil
            return [.report(want)]
        }
        let due = now + d
        state = want ? .enterDue(due: due) : .leaveDue(due: due)
        return [.wakeAt(due)]

    case let .due(now):
        switch state {
        case let .enterDue(due) where due <= now:
            state = .shown
            return [.report(true)]
        case let .leaveDue(due) where due <= now:
            state = nil
            return [.report(false)]
        default:
            return []
        }

    case .pressed:
        if case .enterDue = state {
            state = nil
        }
        return []

    case .ended:
        state = nil
        return shown ? [.report(false)] : []
    }
}

/// Ordered registry of `hoverDelays` elements (`hover_delay::HoverDelays`).
/// Updating or re-entering moves a path to the back so waits/hovers preserve start order.
public struct HoverDelays: Sendable {
    private var entries: [(path: String, phase: DelayedHoverPhase)] = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    public var paths: [String] { entries.map(\.path) }

    /// Whether any enter or leave wait is currently active.
    public var waiting: Bool {
        entries.contains {
            switch $0.phase {
            case .enterDue, .leaveDue: return true
            case .shown: return false
            }
        }
    }

    /// Earliest pending deadline across all waiting entries, or `nil` when none wait.
    public func nextDue() -> Double? {
        var earliest: Double? = nil
        for (_, phase) in entries {
            let due: Double
            switch phase {
            case let .enterDue(d), let .leaveDue(d):
                due = d
            case .shown:
                continue
            }
            earliest = earliest.map { min($0, due) } ?? due
        }
        return earliest
    }

    public mutating func clear() {
        entries.removeAll()
    }

    /// Removes `path` without emitting a leave effect; returns whether it had already heard enter (`shown` or `leaveDue`).
    @discardableResult
    public mutating func forget(_ path: String) -> Bool {
        guard let idx = entries.firstIndex(where: { $0.path == path }) else { return false }
        let removed = entries.remove(at: idx)
        switch removed.phase {
        case .shown, .leaveDue:
            return true
        case .enterDue:
            return false
        }
    }

    /// Steps `path` with `event` while maintaining start order.
    @discardableResult
    public mutating func step(_ path: String, event: HoverDelayEvent) -> [HoverDelayEffect] {
        let idx = entries.firstIndex(where: { $0.path == path })
        var state = idx.map { entries[$0].phase }
        let effects = stepHoverDelayState(&state, event: event)
        if let idx {
            if let next = state, entries[idx].phase == next {
                return effects
            }
            entries.remove(at: idx)
            if let next = state {
                entries.append((path, next))
            }
        } else if let next = state {
            entries.append((path, next))
        }
        return effects
    }
}
