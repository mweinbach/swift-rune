import Foundation

/// Tracks where key releases go (`crates/rune/src/runtime/input/key_releases.rs`).
/// Releases belonging to an IME composition are eaten unheard; others route to the focus
/// where their key went down, even after focus moves away before key-up.
public struct KeyReleases: Sendable {
    public enum Eat: Equatable, Sendable {
        case none
        /// The release of the key that confirmed or cancelled a composition.
        case one
        /// This many non-repeat keys went down while a composition was open.
        case keys(UInt32)
    }

    public struct Held: Equatable, Sendable {
        public var keys: UInt32
        public var focus: String?
    }

    public private(set) var eat: Eat = .none
    public private(set) var held: Held? = nil

    public init() {}

    /// A non-modifier key went down while composing or not; `focus` provides the current focus path.
    public mutating func down(composing: Bool, repeat isRepeat: Bool, focus: () -> String?) {
        if composing {
            switch (eat, isRepeat) {
            case (.keys(let n), false):
                eat = .keys(n &+ 1)
            case (_, false):
                eat = .keys(1)
            case (.none, true):
                eat = .one
            case (_, true):
                break
            }
        } else if !isRepeat {
            eat = .none
            let nextKeys: UInt32 = (held?.keys ?? 0) &+ 1
            held = Held(keys: nextKeys, focus: focus())
        }
    }

    /// An IME consumed a key event: its upcoming release should come back unheard once.
    public mutating func imeTookKey() {
        if eat == .none {
            eat = .one
        }
    }

    /// A key came up while composing with no logical release to dispatch.
    /// Keeps `.one` reserved for the key that eventually ends the composition.
    public mutating func composingRelease() {
        if case .keys(let n) = eat {
            eat = n > 1 ? .keys(n - 1) : .one
        }
    }

    /// Returns `true` if the input method consumes this release.
    public mutating func eat(composing: Bool) -> Bool {
        if composing {
            composingRelease()
            return true
        }
        switch eat {
        case .keys(let n):
            eat = n > 1 ? .keys(n - 1) : .none
            return true
        case .one:
            eat = .none
            return true
        case .none:
            return false
        }
    }

    /// Returns the focus path where the matching press occurred, decrementing the held counter.
    public mutating func route() -> String? {
        guard var current = held else { return nil }
        let path = current.focus
        if current.keys > 1 {
            current.keys -= 1
            held = current
        } else {
            held = nil
        }
        return path
    }

    /// Window lost keyboard focus: forgets all held keys and composition release guards.
    public mutating func lost() {
        self = KeyReleases()
    }
}

extension Runtime {
    internal var isAnyImeComposing: Bool {
        if inputMachines.appIme.isComposing {
            return true
        }
        if let fp = focusedPath,
           let idx = nodeByPath[fp],
           let lens = flatNodes[idx].el.handlers.editLens {
            return lens.get(state).preedit != nil
        }
        return false
    }
}
