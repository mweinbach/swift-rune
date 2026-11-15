import Foundation
import RuneMotion

// MARK: - Hover hold under moving layout (`crates/rune/src/runtime/input/hover.rs`)

/// Hover under a pointer that hasn't moved while layout carries content under it: a row
/// expanding and the rows below sliding, a growth stack, a flight, a glide the app asked for.
/// As on macOS, where tracking areas enter and exit as the mouse moves and re-sync once layout
/// settles, hover doesn't light each row that passes: it waits for the motion to settle or the
/// pointer to move. What leaves the tree or turns inert lets go at once, and presses are never
/// held (`hover.rs::HoverHold`).
internal struct HoverHold: Sendable, Equatable {
    /// `hover.rs::Hold`.
    internal enum Hold: Sendable, Equatable {
        /// Hover follows the pointer, and moving layout may hold it.
        case free
        /// The last pass held hover: moving layout carried an element whose hover would change.
        case held
        /// The pointer moved, pressed or a hand scrolled while layout moved: hover follows the
        /// pointer until the motion settles.
        case released
    }

    internal private(set) var hold: Hold = .free

    internal init() {}

    /// The last pass held hover.
    internal var held: Bool { hold == .held }

    /// Hover follows the pointer until layout settles.
    internal var released: Bool { hold == .released }

    /// Notes whether this pass held hover. Released, nothing holds it.
    internal mutating func setHeld(_ held: Bool) {
        if hold != .released { hold = held ? .held : .free }
    }

    /// The hand moved: with layout `moving`, hover follows the pointer until it settles.
    internal mutating func release(moving: Bool) {
        if hold != .released { hold = moving ? .released : .free }
    }

    /// Layout settled: a released hold may hold again.
    internal mutating func settled() {
        if hold == .released { hold = .free }
    }
}

// MARK: - Instant scroll hover hold (`crates/rune/src/runtime/scroll/nudge.rs`)

/// An app's instant scroll (`Tx.scrollToInstant` and the like) holds hover under a still
/// pointer: content moved with nothing under the pointer moving, so hover waits out the hold
/// instead of lighting each row an app's own, frame-by-frame glide carries past. The hold is a
/// time on the clock, so it lasts as long on a 30 Hz display as on a 120 Hz one: the frame the
/// scroll lands in holds, and hover resolves once at the pointer when the hold is over. A held
/// nudge draws nothing in between: it asks for one frame at its due time, the frame that ends
/// it (`nudge.rs::Nudge`).
public struct ScrollNudge: Sendable, Equatable {
    /// How long an instant scroll holds hover: the two frames at 60 Hz its frame countdown took
    /// (`NUDGE_HOLD`).
    public static let nudgeHold: Double = 2.0 / 60.0

    /// A deadline comparison's slack, so a frame that lands on the due time ends the hold (`SLACK`).
    static let slack: Double = 1e-6

    /// Where the hold stands (`nudge.rs::Hold`).
    public enum Hold: Sendable, Equatable {
        /// Nothing holds hover.
        case free
        /// An instant scroll landed, and hover holds until this clock time, as `attempt`.
        case held(attempt: AttemptToken, due: Double)
    }

    /// `nudge.rs::Event`.
    public enum Event: Sendable, Equatable {
        /// An app's instant scroll landed at this clock time.
        case arm(now: Double)
        /// A frame at `now`, carrying the `attempt` its arm asked for: the hold ends only if that
        /// is still the armed one.
        case due(attempt: AttemptToken, now: Double)
    }

    /// `nudge.rs::Effect`.
    public enum Effect: Sendable, Equatable {
        /// Wake at this clock time, when the hold is due.
        case wakeAt(Double)
    }

    public var seq: Seq
    public var state: Hold

    public init(seq: Seq = Seq(), state: Hold = .free) {
        self.seq = seq
        self.state = state
    }

    /// `nudge.rs::step`.
    @discardableResult
    public static func step(seq: inout Seq, state: inout Hold, event: Event) -> Effects<Effect> {
        switch event {
        case .arm(let now):
            let attempt = seq.nextAttempt()
            let due = now + nudgeHold
            state = .held(attempt: attempt, due: due)
            return .one(.wakeAt(due))
        case .due(let attempt, let now):
            if case .held(let armed, let due) = state, armed == attempt, due <= now + slack {
                state = .free
            }
            return .none
        }
    }

    /// An instant scroll landed at `now` from the clock: hover holds, and this asks for the wake
    /// that brings the frame the hold ends on.
    @discardableResult
    public mutating func arm(now: Double) -> Effects<Effect> {
        Self.step(seq: &seq, state: &state, event: .arm(now: now))
    }

    /// A frame at `now`, the one its wake asked for: a hold that came due ends.
    public mutating func tick(now: Double) {
        if case .held(let attempt, _) = state {
            Self.step(seq: &seq, state: &state, event: .due(attempt: attempt, now: now))
        }
    }

    /// Hover holds at `now`.
    public func holdAt(now: Double) -> Bool {
        if case .held(_, let due) = state { return now + Self.slack < due }
        return false
    }

    /// The clock time a pending hold ends.
    public func due() -> Double? {
        if case .held(_, let due) = state { return due }
        return nil
    }
}

extension Runtime {
    // MARK: Scroll carries & nudges (`hover.rs::scroll_carries`, `offset.rs::step_nudges`)

    /// Viewport `path` moves content under a still pointer on its own at `now`: a glide, or an
    /// app's instant scrolls frame after frame (a glide it steps itself) (`hover.rs::scroll_carries`).
    /// Known gap: upstream also counts stick-bottom slack letting rows down (`s.slack.moving()`),
    /// which depends on `scroll/bottom.rs::Slack`; the Swift port has no slack track yet, so
    /// this term is missing until `Slack` is ported.
    internal func scrollCarries(path: String, at now: Double) -> Bool {
        scrollGlidingPaths.contains(path) || (scrollNudges[path]?.holdAt(now: now) ?? false)
    }

    /// Any viewport carries content on its own at `now` (the scroll half of `layout_moving`).
    internal func anyScrollCarries(at now: Double) -> Bool {
        !scrollGlidingPaths.isEmpty || scrollNudges.values.contains { $0.holdAt(now: now) }
    }

    /// An app's instant scroll moved viewport `path` at `now` (`offset.rs::apply_jumps`): hover
    /// holds for `ScrollNudge.nudgeHold`, and the wake for its due time is the frame that ends it.
    internal func armScrollNudge(path: String, at now: Double) {
        var nudge = scrollNudges[path] ?? ScrollNudge()
        // The arm's due is taken back from the state each frame (`stepScrollNudges`), so a later
        // arm in the same frame wins and nothing here has to keep it.
        _ = nudge.arm(now: now)
        scrollNudges[path] = nudge
    }

    /// Steps the holds an app's instant scrolls armed, and returns the earliest due one still
    /// pending: the frame that carries it resolves hover at the pointer (`offset.rs::step_nudges`).
    @discardableResult
    internal func stepScrollNudges(at now: Double) -> Double? {
        guard !scrollNudges.isEmpty else { return nil }
        var due: Double? = nil
        for path in Array(scrollNudges.keys) {
            guard var nudge = scrollNudges[path] else { continue }
            guard nodeByPath[path] != nil else {
                scrollNudges.removeValue(forKey: path)
                continue
            }
            nudge.tick(now: now)
            if let at = nudge.due() {
                due = due.map { min($0, at) } ?? at
                scrollNudges[path] = nudge
            } else {
                scrollNudges.removeValue(forKey: path)
            }
        }
        return due
    }

    /// The earliest pending nudge due time after `now`, for the frame's end to wake for.
    internal func scrollNudgeWakeDeadline(after now: Double) -> Double? {
        scrollNudges.values.compactMap { $0.due() }.filter { $0 > now }.min()
    }

    // MARK: Held hover (`hover.rs::held_hover`)

    /// While moving layout holds hover, the hovered element, as the cursor and tooltips see it:
    /// what the pointer was over, not what slid under it. `nil` when nothing holds hover; `.some(nil)`
    /// when hover is held but the held element left the tree or turned inert.
    internal func heldHover() -> Int?? {
        guard hoverHold.held, !buttonHoldsPointer() else { return nil }
        return .some(hoveredPath.flatMap { hoverLive($0) })
    }

    /// A button holds the pointer: a primary press, a secondary capture, or a middle/secondary
    /// button's press tint, exactly upstream's `pointer.rs::pointer_captured` (the Swift
    /// `Runtime.pointerCaptured` property also counts drags and drag-outs for hosts).
    internal func buttonHoldsPointer() -> Bool {
        pressedPath != nil || inputMachines.secondaryCapture.isHeld || pressedTint != nil
    }

    // MARK: Hover tracks (`hover.rs::hover_flip`, `paint/tracks.rs::ready_from_rest`)

    /// Readies node `nid`'s hover track, which reads 0 without a track, to move to `to`: false
    /// when it has no track and `to` is the rest value, so there's nothing to do; otherwise it
    /// has a track, made at rest if it had none (`paint/tracks.rs::ready_from_rest`).
    internal func readyHoverFromRest(_ nid: NodeId, to: Float) -> Bool {
        let trackId = Self.hoverTrackId(nid)
        if liveStore.has(trackId, Self.hoverProp) { return true }
        if to == 0.0 { return false }
        liveStore.snap(trackId, Self.hoverProp, to: 0.0)
        return true
    }

    /// What every hover flip of one pass reads (`hover.rs::update_interaction` /
    /// `decide_hold`): the captured press, the innermost `hoverAlone` element under the pointer,
    /// and the `hoverGroupShared` keys the pointer or keyboard focus is in.
    internal struct HoverFlipContext {
        let captured: String?
        let alone: Int?
        let shared: Set<String>
    }

    /// `hover.rs::captured`: the primary press's element, else the secondary capture's.
    internal func hoverCaptured() -> String? {
        if let p = pressedPath { return p }
        if case .held(let path, _, _) = inputMachines.secondaryCapture { return path }
        return nil
    }

    /// `focus.rs::allowed`: not inert and not behind a modal.
    internal func hoverAllowed(_ i: Int) -> Bool {
        let n = flatNodes[i]
        if n.effectiveInert { return false }
        if activeModalPath != nil && !modalMemberPaths.contains(n.path) { return false }
        return true
    }

    /// `hit.rs::node_contains`: node `i`'s drawn rect, inside its clip, holds the pointer. Purely
    /// geometric: an element drawn over it doesn't stop it containing the pointer.
    internal func hoverNodeContains(_ i: Int) -> Bool {
        GroupHoverContext.isPtrInside(
            flatNodes[i],
            ptrPos: pointerPosition,
            topmostPtrPath: nil,
            hitGeometryByPath: hitGeometryByPath,
            presentedRectByPath: presentedRectByPath,
            presentedRectById: [:]
        )
    }

    internal func hoverIsExiting(_ i: Int) -> Bool {
        if case .exiting = scene.phase(flatNodes[i].nodeId) { return true }
        return false
    }

    /// Keyboard focus shows on node `i` or inside it (CSS `:has(:focus-visible)`): a hover group
    /// lights for it as for the pointer (`hover.rs::keyboard_within`).
    internal func hoverKeyboardWithin(_ i: Int) -> Bool {
        focusVisible && isFocusWithin(flatNodes[i].path)
    }

    /// The innermost `hoverAlone` element under the pointer: the elements around it show no
    /// hover (`hover.rs::hovered_alone`).
    internal func hoveredAlone() -> Int? {
        guard pointerPosition.x > -9000, pointerPosition.y > -9000 else { return nil }
        var best: Int? = nil
        for i in flatNodes.indices where flatNodes[i].el.isHoverAlone {
            guard !hoverIsExiting(i), hoverAllowed(i), hoverNodeContains(i) else { continue }
            if best.map({ flatNodes[i].path.count > flatNodes[$0].path.count }) ?? true { best = i }
        }
        return best
    }

    /// The `hoverGroupShared` keys of the elements under the pointer or holding keyboard focus
    /// (`hover.rs::shared_hovered`).
    internal func sharedHovered() -> Set<String> {
        var keys: Set<String> = []
        for i in flatNodes.indices {
            guard let key = flatNodes[i].el.hoverGroupShare else { continue }
            if !hoverIsExiting(i) && hoverAllowed(i) && (hoverNodeContains(i) || hoverKeyboardWithin(i)) {
                keys.insert(key)
            }
        }
        return keys
    }

    internal func hoverFlipContext() -> HoverFlipContext {
        HoverFlipContext(captured: hoverCaptured(), alone: hoveredAlone(), shared: sharedHovered())
    }

    /// Node `i` has a hover track (`hover().a > 0 || hover_group`).
    internal func hasHoverTrack(_ i: Int) -> Bool {
        let el = flatNodes[i].el
        return (el.hoverBg?.a ?? 0) > 0 || el.isHoverGroup || el.hoverGroupShare != nil
    }

    /// Whether node `i`'s hover track goes on (`hover.rs::hover_flip`'s `on`): every hover element
    /// whose drawn rect holds the pointer lights, a shared group the pointer is over, or a group
    /// keyboard focus is in; a held press keeps its own element lit while it's inside. The
    /// innermost `hoverAlone` element under the pointer shadows the elements around it, and a
    /// captured press lets only it and its ancestors light.
    internal func hoverFlipOn(_ i: Int, _ ctx: HoverFlipContext) -> Bool {
        let n = flatNodes[i]
        let isGroup = n.el.isHoverGroup || n.el.hoverGroupShare != nil
        let inside = hoverNodeContains(i)
            || (n.el.hoverGroupShare.map { ctx.shared.contains($0) } ?? false)
            || (isGroup && hoverKeyboardWithin(i))
        let captureInside = inputMachines.secondaryCapture.isHeld ? inside : pressedPointerInside
        let held = ctx.captured == n.path && captureInside
        let allowed = hoverAllowed(i)
        let shadowed = ctx.alone.map { $0 != i && Self.hoverHolds(outer: n.path, inner: flatNodes[$0].path) } ?? false
        let capturedOK = ctx.captured.map { Self.hoverHolds(outer: n.path, inner: $0) } ?? true
        return allowed && (inside || held) && !shadowed && capturedOK
    }

    /// `hover.rs::holds`: `inner` is `outer` or inside it.
    internal static func hoverHolds(outer: String, inner: String) -> Bool {
        inner == outer || inner.hasPrefix(outer + "/")
    }

    /// The hover target node `nid`'s track holds, 0 without one (`store.target(id, P_HOVER).unwrap_or(0.0)`).
    internal func hoverTarget(_ nid: NodeId) -> Float {
        liveStore.target(Self.hoverTrackId(nid), Self.hoverProp) ?? 0.0
    }

    /// The hover curves node `n` goes by: its own `hoverMotion`, else the nearest
    /// `hoverMotionWithin` above it or its anchor's (`Node::hover_motion`).
    internal func hoverMotion(of n: FlatNode) -> (enter: Anim<Float>, exit: Anim<Float>)? {
        hoverCurvesById[n.nodeId]
    }
}
