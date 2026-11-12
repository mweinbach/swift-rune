import Foundation
import Rune

/// Pointer drag grip state machine (`rune_kit::grip::Grip`).
/// Tracks a held drag from press to release and detects lost releases when pointer moves
/// arrive that the drag handler never observed.
public enum Grip<T: Sendable>: Sendable {
    case idle
    case held(data: T, heard: Vec2?, unheard: Vec2?)

    public var data: T? {
        if case .held(let d, _, _) = self { return d }
        return nil
    }

    public var isHeld: Bool {
        if case .held = self { return true }
        return false
    }

    /// Starts holding `data` at `at`; returns any previously held data whose release was lost.
    @discardableResult
    public mutating func press(_ data: T, at: Vec2? = nil) -> T? {
        replace(with: .held(data: data, heard: at, unheard: nil))
    }

    /// Records the drag's own move at `at` and returns the held data if active.
    public mutating func moved(to at: Vec2) -> T? {
        guard case .held(let data, _, _) = self else { return nil }
        self = .held(data: data, heard: at, unheard: nil)
        return data
    }

    /// Updates the held data or starts holding `data` if idle.
    public mutating func hold(_ data: T) {
        switch self {
        case .held(_, let heard, let unheard):
            self = .held(data: data, heard: heard, unheard: unheard)
        case .idle:
            self = .held(data: data, heard: nil, unheard: nil)
        }
    }

    /// Releases or cancels the grip, returning the held data if any.
    @discardableResult
    public mutating func release() -> T? {
        replace(with: .idle)
    }

    /// Observes a pointer move at `at`; returns the held data if this reveals a lost release.
    @discardableResult
    public mutating func pointerMoved(to at: Vec2) -> T? {
        guard case .held(let data, let heard, let unheard) = self else { return nil }
        if heard == at { return nil }
        if let u = unheard, u != at {
            return release()
        }
        self = .held(data: data, heard: heard, unheard: at)
        return nil
    }

    /// Window lost focus or gesture dropped.
    @discardableResult
    public mutating func lose() -> T? {
        release()
    }

    private mutating func replace(with next: Grip<T>) -> T? {
        let old = self
        self = next
        if case .held(let data, _, _) = old {
            return data
        }
        return nil
    }
}

extension Grip: Equatable where T: Equatable {}
