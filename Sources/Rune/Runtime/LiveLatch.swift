// MARK: - Live Wake Latch State Machine (`crates/rune/src/runtime/motion/live_latch.rs`)

/// Whether a window has live work, as one explicit state machine (`rune::runtime::motion::live_latch::LiveWake`).
enum LiveWakeState: Equatable, Sendable {
    /// Hidden: no frame latches or draws. `dirty` is work kept for the frame after showing.
    case hidden(dirty: Bool)
    /// Visible, and nothing waits.
    case idle
    /// Visible, with a value waiting for the next frame.
    case pending
    /// A frame has taken the shared wake and is reading what it published. `dirty` is work that
    /// landed after the take, or a value still moving, kept for the next frame.
    case latching(dirty: Bool)

    /// Work kept for a later frame.
    var dirty: Bool {
        switch self {
        case .hidden(let d), .latching(let d): return d
        case .pending: return true
        case .idle: return false
        }
    }

    /// One transition (`LiveWake::step`). Returns `(nextState, answer)`.
    func step(_ event: LiveLatchEvent) -> (LiveWakeState, Bool) {
        switch (self, event) {
        case (.hidden(let dirty), .show):
            return (dirty ? .pending : .idle, dirty)
        case (_, .show):
            return (self, self.dirty)
        case (let s, .hide):
            return (.hidden(dirty: s.dirty), false)
        case (.hidden, .subscribe(let sampled)):
            return (.hidden(dirty: sampled), sampled)
        case (_, .subscribe(let sampled)):
            return (sampled ? .pending : .idle, sampled)
        case (let s, .prune(let keep)):
            let nextDirty = s.dirty && keep
            switch s {
            case .hidden:
                return (.hidden(dirty: nextDirty), nextDirty)
            default:
                return (nextDirty ? .pending : .idle, nextDirty)
            }
        case (.hidden, .set):
            return (.hidden(dirty: true), true)
        case (_, .set):
            return (.pending, true)
        case (_, .latchBegin):
            return (.latching(dirty: false), true)
        case (.hidden(let dirty), .latchEnd(let active)):
            return (.hidden(dirty: dirty || active), active)
        case (_, .latchEnd(let active)):
            return (active ? .pending : .idle, active)
        }
    }
}

/// Something that changes whether a window has live work to do (`LiveEvent`).
enum LiveLatchEvent: Equatable, Sendable {
    case show
    case hide
    case subscribe(sampled: Bool)
    case prune(keep: Bool)
    case set
    case latchBegin
    case latchEnd(active: Bool)
}

/// A window's live wake: the state machine above paired with the shared `LiveWake`
/// publishers notify (`rune::runtime::motion::live_latch::LiveLane`).
final class LiveLane {
    let waker: LiveWake
    private var state: LiveWakeState

    init(waker: LiveWake) {
        self.waker = waker
        self.state = .idle
    }

    var visible: Bool {
        if case .hidden = state { return false }
        return true
    }

    var dirty: Bool {
        state.dirty
    }

    /// Whether a value waits for this window. Hidden windows keep their wake for show.
    func pending() -> Bool {
        switch state {
        case .hidden:
            return false
        case .pending:
            return true
        case .idle:
            return waker.isVisiblePending
        case .latching(let d):
            return d || waker.isVisiblePending
        }
    }

    @discardableResult
    func setVisible(_ visible: Bool) -> Bool {
        let woke = waker.visibleReturningWoke(visible)
        apply(visible ? .show : .hide)
        return woke
    }

    func subscribed(_ sampled: Bool) {
        apply(.subscribe(sampled: sampled))
    }

    func pruned(_ keep: Bool) {
        apply(.prune(keep: keep))
    }

    /// A live-only event published a value without a commit.
    func set() {
        apply(.set)
    }

    /// Takes the shared wake for this frame; a hidden window leaves it for show.
    @discardableResult
    func take() -> Bool {
        guard visible else { return false }
        return waker.takeVisible()
    }

    /// Whether the frame should read its sources now.
    func latchBegin(can: Bool, hasSubs: Bool) -> Bool {
        guard visible, hasSubs, can || state.dirty else { return false }
        return apply1(.latchBegin)
    }

    /// Whether a read value is still moving.
    @discardableResult
    func latchEnd(active: Bool) -> Bool {
        apply1(.latchEnd(active: active))
    }

    private func apply(_ event: LiveLatchEvent) {
        let (next, _) = state.step(event)
        state = next
    }

    private func apply1(_ event: LiveLatchEvent) -> Bool {
        let (next, answer) = state.step(event)
        state = next
        return answer
    }
}
