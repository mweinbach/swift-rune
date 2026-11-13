import Foundation

/// Shorthand for `Stagger(step: gap, maxDelay: 0, from: from).delay(index: index, count: count)`.
public func stagger(index: Int, count: Int, gap: Float, from: StaggerFrom = .start) -> Float {
    Stagger(step: gap, maxDelay: 0, from: from).delay(index: index, count: count)
}

/// Handle to a step registered in a `Choreography`.
public struct StepId: Sendable, Hashable, Codable {
    public let rawValue: UInt32

    public init(_ rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

/// What a `Cue` waits for on another step.
public enum When: Sendable, Hashable, Codable {
    /// The step started.
    case started
    /// The step's animations logically completed (springs: their duration; tweens: their end).
    case arrived
    /// Every track the step animated is physically at rest (or was taken over).
    case settled
}

/// When a `Choreography` step may start.
public struct Cue: Sendable, Equatable {
    fileprivate var afterStep: (StepId, When)?
    fileprivate var delay: Float
    fileprivate var notBeforeTime: Float

    private init(afterStep: (StepId, When)?, delay: Float, notBeforeTime: Float) {
        self.afterStep = afterStep
        self.delay = delay
        self.notBeforeTime = notBeforeTime
    }

    public static func == (lhs: Cue, rhs: Cue) -> Bool {
        lhs.afterStep?.0 == rhs.afterStep?.0 &&
            lhs.afterStep?.1 == rhs.afterStep?.1 &&
            lhs.delay == rhs.delay &&
            lhs.notBeforeTime == rhs.notBeforeTime
    }

    /// As soon as the choreography starts.
    public static func now() -> Cue {
        Cue(afterStep: nil, delay: 0, notBeforeTime: 0)
    }

    /// `t` seconds after the choreography starts.
    public static func at(_ t: Float) -> Cue {
        Cue(afterStep: nil, delay: t, notBeforeTime: 0)
    }

    public static func started(_ step: StepId) -> Cue {
        Cue(afterStep: (step, .started), delay: 0, notBeforeTime: 0)
    }

    public static func arrived(_ step: StepId) -> Cue {
        Cue(afterStep: (step, .arrived), delay: 0, notBeforeTime: 0)
    }

    public static func settled(_ step: StepId) -> Cue {
        Cue(afterStep: (step, .settled), delay: 0, notBeforeTime: 0)
    }

    /// Wait a further `seconds` after the cue.
    public func after(_ seconds: Float) -> Cue {
        var copy = self
        copy.delay += seconds
        return copy
    }

    /// Never earlier than `t` seconds after the choreography starts (a causal guard).
    public func notBefore(_ t: Float) -> Cue {
        var copy = self
        copy.notBeforeTime = max(copy.notBeforeTime, t)
        return copy
    }
}

/// Type-erased list of property animations recorded by `Choreography` or `Stage`.
public struct Ops: Sendable {
    private struct Op: Sendable {
        var node: NodeId
        var prop: PropId
        var propClass: PropClass
        var laneCount: Int
        var target: MotionLanes
        var curve: Curve
        var blend: Blend
        var delay: Float
        var initialVelocity: MotionLanes?
    }

    private var ops: [Op] = []

    public init() {}

    /// Records an animation of `prop` on `node` to `target`.
    public mutating func animate<T: Animatable>(
        _ node: NodeId,
        _ prop: Prop<T>,
        to target: T,
        anim: Anim<T>
    ) {
        ops.append(Op(
            node: node,
            prop: prop.id,
            propClass: prop.propClass,
            laneCount: T.laneCount,
            target: target.toLanes(),
            curve: anim.curve,
            blend: anim.blend,
            delay: anim.delay,
            initialVelocity: anim.initialVelocity?.lanes
        ))
    }

    fileprivate func apply(
        to store: inout AnimationStore,
        delay: Float,
        snapOnly: Bool,
        out: inout [(TrackId, UInt32)]
    ) {
        for op in ops {
            let t = store.ensure(
                op.node,
                op.prop,
                op.propClass,
                initLanes: op.target,
                count: op.laneCount
            )
            if snapOnly {
                store.setRaw(t, lanes: op.target, count: op.laneCount)
            } else {
                let k = store.nodeTimeScale(op.node)
                let scaledDelay = k > 0 ? delay * k : delay
                _ = store.animateRaw(
                    Int(t),
                    targets: op.target,
                    count: op.laneCount,
                    curve: op.curve,
                    blend: op.blend,
                    delay: op.delay + scaledDelay,
                    velocityRule: .inherit,
                    token: 0,
                    laneVelocities: op.initialVelocity
                )
            }
            let id = store.idOf(Int(t))
            out.append((id, store.epoch(id) ?? 0))
        }
    }
}

/// Event-driven timeline coordinator for multi-step animations (`choreo.rs`).
public struct Choreography: Sendable {
    private enum State: Sendable, Equatable {
        case waiting
        case running(start: Double, first: Int, count: Int)
    }

    private struct Step: Sendable {
        var cue: Cue
        var ops: Ops
        var state: State
    }

    private var steps: [Step] = []
    private var tracks: [(TrackId, UInt32)] = []
    private var t0: Double?

    public init() {}

    /// Adds a step triggered by `cue`.
    @discardableResult
    public mutating func step(_ cue: Cue, _ build: (inout Ops) -> Void) -> StepId {
        var ops = Ops()
        build(&ops)
        steps.append(Step(cue: cue, ops: ops, state: .waiting))
        return StepId(UInt32(steps.count - 1))
    }

    /// Adds a staggered ripple of steps across `items`, each offset by `stagger.delay(index:count:)`.
    @discardableResult
    public mutating func stagger<C: Collection>(
        _ cue: Cue,
        _ stagger: Stagger,
        items: C,
        each: (inout Ops, C.Element) -> Void
    ) -> [StepId] {
        let count = items.count
        var ids: [StepId] = []
        ids.reserveCapacity(count)
        for (i, item) in items.enumerated() {
            let c = cue.after(stagger.delay(index: i, count: count))
            ids.append(step(c) { ops in each(&ops, item) })
        }
        return ids
    }

    /// When `step` started (or will start, if scheduled with a delay).
    public func startTime(of step: StepId) -> Double? {
        let idx = Int(step.rawValue)
        guard idx < steps.count else { return nil }
        if case let .running(start, _, _) = steps[idx].state {
            return start
        }
        return nil
    }

    /// True when every step has started and every track it animated has settled (or been taken over).
    public func isDone(in store: AnimationStore) -> Bool {
        steps.allSatisfy { if case .running = $0.state { return true }; return false } &&
            allSettled(store: store, tracks: tracks[...])
    }

    /// Starts every step whose cue is due or now known. Call at `now` before `store.sample(at: now)`.
    public mutating func tick(store: inout AnimationStore, at now: Double? = nil) {
        if let n = now, n != store.now {
            store.setTime(n)
        }
        let currentNow = store.now
        let origin = t0 ?? currentNow
        if t0 == nil { t0 = origin }

        while true {
            var progressed = false
            for k in steps.indices {
                guard steps[k].state == .waiting else { continue }
                let cue = steps[k].cue
                let base: Double?
                if let (dep, when) = cue.afterStep {
                    base = cueTime(store: store, step: dep, when: when, now: currentNow)
                } else {
                    base = origin
                }
                guard let resolvedBase = base else { continue }
                let at = max(resolvedBase + Double(cue.delay), origin + Double(cue.notBeforeTime))
                let delay = Float(max(0.0, at - currentNow))
                let first = tracks.count
                steps[k].ops.apply(to: &store, delay: delay, snapOnly: false, out: &tracks)
                let count = tracks.count - first
                steps[k].state = .running(start: currentNow + Double(delay), first: first, count: count)
                progressed = true
            }
            if !progressed { break }
        }
    }

    private func cueTime(store: AnimationStore, step: StepId, when: When, now: Double) -> Double? {
        let idx = Int(step.rawValue)
        guard idx < steps.count else { return nil }
        guard case let .running(start, first, count) = steps[idx].state else { return nil }
        let slice = tracks[first..<(first + count)]
        switch when {
        case .started:
            return start
        case .arrived:
            let end = arrival(store: store, tracks: slice, from: start)
            return end.isFinite ? end : nil
        case .settled:
            return allSettled(store: store, tracks: slice) ? now : nil
        }
    }
}

/// Alias matching `choreo.rs` stage/timeline terminology.
public typealias Stage = Choreography

/// `Ops`-based `PhaseAnimator` matching `choreo.rs::PhaseAnimator`.
public struct ChoreographyPhaseAnimator: Sendable {
    private enum Next: Sendable, Equatable {
        case unstarted
        case at(Double)
        case frozen
        case settled
        case done
    }

    private var phases: [Ops] = []
    public private(set) var currentIndex: Int = 0
    private var advanceWhen: When = .arrived
    private var repeatLoop: Bool = true
    private var holdSeconds: Float = 0
    private var tracks: [(TrackId, UInt32)] = []
    private var next: Next = .unstarted

    public init() {}

    public func phase(_ build: (inout Ops) -> Void) -> ChoreographyPhaseAnimator {
        var copy = self
        var ops = Ops()
        build(&ops)
        copy.phases.append(ops)
        return copy
    }

    public func advanceOn(_ when: When) -> ChoreographyPhaseAnimator {
        var copy = self
        copy.advanceWhen = when
        return copy
    }

    public func hold(_ seconds: Float) -> ChoreographyPhaseAnimator {
        var copy = self
        copy.holdSeconds = seconds
        return copy
    }

    public func once() -> ChoreographyPhaseAnimator {
        var copy = self
        copy.repeatLoop = false
        return copy
    }

    public mutating func tick(store: inout AnimationStore, at now: Double? = nil) {
        guard !phases.isEmpty else { return }
        if let n = now, n != store.now {
            store.setTime(n)
        }
        let currentNow = store.now
        let hold = Double(holdSeconds)
        if next == .unstarted {
            tracks.removeAll(keepingCapacity: true)
            phases[0].apply(to: &store, delay: 0, snapOnly: true, out: &tracks)
            next = .at(currentNow)
        }
        if store.reducedMotion { return }

        let targetAt: Double
        switch next {
        case let .at(t):
            targetAt = t
        case .frozen:
            let end = arrival(store: store, tracks: tracks[...], from: currentNow) + hold
            if end.isFinite {
                next = .at(end)
                targetAt = end
            } else {
                return
            }
        case .settled:
            if allSettled(store: store, tracks: tracks[...]) {
                next = .at(currentNow + hold)
            }
            return
        case .unstarted, .done:
            return
        }

        if currentNow < targetAt { return }
        let nextIndex = currentIndex + 1
        if nextIndex >= phases.count && !repeatLoop {
            next = .done
            return
        }
        currentIndex = nextIndex % phases.count
        tracks.removeAll(keepingCapacity: true)
        phases[currentIndex].apply(to: &store, delay: 0, snapOnly: false, out: &tracks)
        switch advanceWhen {
        case .arrived, .started:
            let end = arrival(store: store, tracks: tracks[...], from: currentNow) + hold
            next = end.isFinite ? .at(end) : .frozen
        case .settled:
            next = .settled
        }
    }
}

private func allSettled(store: AnimationStore, tracks: ArraySlice<(TrackId, UInt32)>) -> Bool {
    tracks.allSatisfy { (id, epoch) in
        store.isSettled(id) || store.epoch(id) != epoch
    }
}

private func arrival(store: AnimationStore, tracks: ArraySlice<(TrackId, UInt32)>, from: Double) -> Double {
    tracks.reduce(from) { best, item in
        max(best, store.logicalEnd(item.0) ?? from)
    }
}
