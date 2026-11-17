import Foundation
import Testing
@testable import Rune

@Suite("Overlay Lifecycle Parity — state_walk_tests, lost_release_tests, overlay/tests & more_tests")
struct OverlayLifecycleParityTests {

    // MARK: - Helpers

    private static func walk<E>(alphabet: [E], maxLen: Int, _ body: ([E]) -> Void) {
        var seq: [E] = []
        seq.reserveCapacity(maxLen)
        func go(_ remaining: Int) {
            body(seq)
            if remaining == 0 { return }
            for elem in alphabet {
                seq.append(elem)
                go(remaining - 1)
                seq.removeLast()
            }
        }
        go(maxLen)
    }

    // MARK: - overlay/state_walk_tests.rs (5 exhaustive walk tests)

    @Test("overlay/state_walk_tests.rs:104 - OverlayQuiet matches dev for every sequence up to length 6")
    func quietMatchesDevForEverySequence() {
        enum QuietOp {
            case timerDue(resting: Bool)
            case draw(presents: Bool?) // nil => not resting; false => unchanged; true => new
            case forget
        }
        struct DevQuiet: Equatable {
            var presented: UInt32? = nil
            var timer: Bool = false

            mutating func apply(_ op: QuietOp, _ n: UInt32) -> (UInt32?, UInt32??) {
                switch op {
                case let .timerDue(resting):
                    if resting { timer = true }
                    return (nil, nil)
                case let .draw(presents):
                    let timerForFrame: UInt32? = timer ? presented : nil
                    timer = false
                    switch presents {
                    case .none:
                        presented = nil
                        return (timerForFrame, .none)
                    case .some(false):
                        return (timerForFrame, .some(presented))
                    case .some(true):
                        presented = n
                        return (timerForFrame, .some(presented))
                    }
                case .forget:
                    presented = nil
                    timer = false
                    return (nil, nil)
                }
            }
        }

        func applyQuiet(_ quiet: inout OverlayQuiet<UInt32>, _ op: QuietOp, _ n: UInt32) -> (UInt32?, UInt32??) {
            switch op {
            case let .timerDue(resting):
                _ = quiet.step(.timerDue(resting: resting))
                return (nil, nil)
            case let .draw(presents):
                let timerFrame = !quiet.step(.frameStarts).isEmpty
                let checked = timerFrame ? quiet.presented : nil
                if let presents {
                    quiet.presentedFrame(rests: true) { slot in
                        if presents { slot = n }
                    }
                    return (checked, .some(quiet.presented))
                } else {
                    quiet.presentedFrame(rests: false) { _ in }
                    return (checked, .none)
                }
            case .forget:
                _ = quiet.step(.forget)
                return (nil, nil)
            }
        }

        let alphabet: [QuietOp] = [
            .timerDue(resting: false),
            .timerDue(resting: true),
            .draw(presents: nil),
            .draw(presents: false),
            .draw(presents: true),
            .forget,
        ]
        var cases = 0
        Self.walk(alphabet: alphabet, maxLen: 6) { seq in
            cases += 1
            var dev = DevQuiet()
            var quiet = OverlayQuiet<UInt32>()
            for (i, op) in seq.enumerated() {
                let n = UInt32(i + 1)
                let lhs = applyQuiet(&quiet, op, n)
                let rhs = dev.apply(op, n)
                #expect(lhs.0 == rhs.0 && lhs.1 == rhs.1)
                #expect(quiet.presented == dev.presented)
                #expect(quiet.hasTimerWaiting == (dev.timer && dev.presented != nil))
            }
        }
        #expect(cases == 55_987)
    }

    private static func devOccludedRetry(now: Double, wait: inout Double) -> Double {
        let lo = WindowPacingConstants.occludedRetry
        let hi = WindowPacingConstants.occludedMax
        let clamped = min(max(wait, lo), hi)
        wait = min(wait * 2.0, hi)
        return now + clamped
    }

    private static func devGate(
        prewarm: Bool,
        occluded: Bool,
        dirty: Bool,
        idle: Bool,
        retry: inout Double?,
        wait: inout Double,
        now: Double
    ) -> (returned: Bool, countedMiss: Bool, nextRetry: Double?) {
        if !prewarm && occluded {
            if retry.map({ $0 <= now }) ?? true {
                retry = devOccludedRetry(now: now, wait: &wait)
                return (true, true, retry)
            }
            return (true, false, retry)
        }
        if !dirty && idle {
            return (true, false, retry)
        }
        if !prewarm, let r = retry, r > now {
            return (true, false, retry)
        }
        if !prewarm {
            retry = nil
        }
        return (false, false, retry)
    }

    private static func oursGate(
        decided: OverlayTurn,
        prewarm: Bool,
        backoff: inout WindowBackoff,
        now: Double
    ) -> (returned: Bool, countedMiss: Bool, nextRetry: Double?) {
        switch decided {
        case let .occluded(recheck):
            if recheck {
                _ = backoff.step(.missed(.occluded, paced: false, now: now))
            }
            return (true, recheck, backoff.deadline)
        case .rest, .backedOff:
            return (true, false, backoff.deadline)
        case .draw:
            if !prewarm {
                _ = backoff.step(.lapsed)
            }
            return (false, false, backoff.deadline)
        }
    }

    private static func backoffStart(at: Double?, wait: Double) -> WindowBackoff {
        var backoff = WindowBackoff.seeded(occluded: wait, hidden: WindowPacingConstants.timeoutRetry)
        if let at {
            _ = backoff.step(.at(at))
        }
        return backoff
    }

    private static func occludedWait(_ backoff: WindowBackoff, now: Double) -> Double {
        var probe = backoff
        _ = probe.step(.missed(.occluded, paced: false, now: now))
        return (probe.deadline ?? now) - now
    }

    @Test("overlay/state_walk_tests.rs:187 - OverlayTurn.decide matches dev for every gate")
    func turnMatchesDevForEveryGate() {
        let now = 100.0
        let ms = 0.001
        let retries: [Double?] = [nil, now - ms, now, now + ms]
        let waits: [Double] = [
            WindowPacingConstants.occludedRetry,
            0.600,
            WindowPacingConstants.occludedMax,
        ]
        var cases = 0
        for bits in 0..<16 {
            let prewarm = (bits & 1) != 0
            let occluded = (bits & 2) != 0
            let dirty = (bits & 4) != 0
            let idle = (bits & 8) != 0
            for start in retries {
                for startWait in waits {
                    cases += 1
                    var reads = 0
                    let decided = OverlayTurn.decide(
                        OverlayTurnGate(
                            prewarm: prewarm,
                            occluded: occluded,
                            dirty: dirty,
                            idle: idle,
                            retry: start
                        ),
                        now: {
                            reads += 1
                            return now
                        }
                    )
                    var devRetry = start
                    var devWait = startWait
                    var ours = Self.backoffStart(at: start, wait: startWait)
                    let arms = Self.oursGate(decided: decided, prewarm: prewarm, backoff: &ours, now: now)
                    let devArms = Self.devGate(
                        prewarm: prewarm,
                        occluded: occluded,
                        dirty: dirty,
                        idle: idle,
                        retry: &devRetry,
                        wait: &devWait,
                        now: now
                    )
                    #expect(arms == devArms)
                    #expect(abs(Self.occludedWait(ours, now: now) - devWait) < 1e-9)
                    #expect(reads <= 1 && (start != nil || reads == 0))
                }
            }
        }
        #expect(cases == 192)
    }

    @Test("overlay/state_walk_tests.rs:218 - occluded misses back off like dev")
    func occludedMissesBackOffLikeDev() {
        struct TurnOp {
            let delta: Double
            let occluded: Bool
        }
        let base = 10.0
        let alphabet: [TurnOp] = [
            TurnOp(delta: 0.0, occluded: true),
            TurnOp(delta: 0.100, occluded: true),
            TurnOp(delta: 0.260, occluded: true),
            TurnOp(delta: 3.0, occluded: true),
            TurnOp(delta: 3.0, occluded: false),
        ]
        Self.walk(alphabet: alphabet, maxLen: 5) { seq in
            var devRetry: Double? = nil
            var devWait = WindowPacingConstants.occludedRetry
            var ours = Self.backoffStart(at: nil, wait: WindowPacingConstants.occludedRetry)
            var now = base
            for op in seq {
                now += op.delta
                let decided = OverlayTurn.decide(
                    OverlayTurnGate(
                        prewarm: false,
                        occluded: op.occluded,
                        dirty: false,
                        idle: true,
                        retry: ours.deadline
                    ),
                    now: { now }
                )
                let oursArms = Self.oursGate(decided: decided, prewarm: false, backoff: &ours, now: now)
                let devArms = Self.devGate(
                    prewarm: false,
                    occluded: op.occluded,
                    dirty: false,
                    idle: true,
                    retry: &devRetry,
                    wait: &devWait,
                    now: now
                )
                #expect(oursArms == devArms)
                #expect(ours.deadline == devRetry)
                #expect(abs(Self.occludedWait(ours, now: now) - devWait) < 1e-9)
            }
        }
    }

    // Each branch copies both models and their complete effect history at the common prefix.
    private static func walkTransitions<Operation, State>(
        alphabet: [Operation], maxLen: Int, initial: State,
        _ step: (inout State, Operation, [Operation]) -> Bool
    ) {
        var path: [Operation] = []
        func visit(_ state: State) -> Bool {
            guard path.count < maxLen else { return true }
            for operation in alphabet {
                path.append(operation)
                var next = state
                guard step(&next, operation, path), visit(next) else { return false }
                path.removeLast()
            }
            return true
        }
        _ = visit(initial)
    }

    @Test("overlay/state_walk_tests.rs:332 - WindowBackoff matches dev for every sequence")
    func overlayBackoffMatchesDevForEverySequence() {
        enum BackoffOp {
            case missed(WindowMissed, paced: Bool)
            case due
            case frame(presents: Bool)
            case at
            case reveal
            case stop
        }
        struct DevBackoff {
            var retry: Double? = nil
            var wait: Double
            mutating func missed(_ missed: WindowMissed, paced: Bool, now: Double) {
                switch missed {
                case .occluded:
                    retry = OverlayLifecycleParityTests.devOccludedRetry(now: now, wait: &wait)
                case .timeout where paced:
                    retry = nil
                case .timeout:
                    retry = now + WindowPacingConstants.timeoutRetry
                case .outdated, .unconfigured:
                    retry = now + WindowPacingConstants.occludedRetry
                }
            }
        }
        let alphabet: [BackoffOp] = [
            .missed(.occluded, paced: false),
            .missed(.timeout, paced: false),
            .missed(.timeout, paced: true),
            .missed(.outdated, paced: false),
            .missed(.unconfigured, paced: false),
            .due,
            .frame(presents: false),
            .frame(presents: true),
            .at,
            .reveal,
            .stop,
        ]
        for (prewarm, scale) in [(false, 1.0), (true, 1.0), (false, 64.0)] {
            let initial = (ours: WindowBackoff(), dev: DevBackoff(wait: WindowPacingConstants.occludedRetry))
            var visited = 0
            Self.walkTransitions(alphabet: alphabet, maxLen: 5, initial: initial) { state, op, path in
                let now = 50.0 + 0.011 * scale * Double(path.count - 1)
                var wakes: Bool?
                switch op {
                case let .missed(missed, paced):
                    let effect = state.ours.step(.missed(missed, paced: paced, now: now))
                    state.dev.missed(missed, paced: paced, now: now)
                    wakes = !effect.isEmpty
                case .due:
                    if let d = state.ours.deadline, d <= now {
                        _ = state.ours.step(.lapsed)
                    }
                    if let d = state.dev.retry, d <= now {
                        state.dev.retry = nil
                    }
                case let .frame(presents):
                    if !prewarm {
                        _ = state.ours.step(.lapsed)
                        state.dev.retry = nil
                    }
                    if presents && !prewarm {
                        _ = state.ours.step(.presented)
                        state.dev.wait = WindowPacingConstants.occludedRetry
                    }
                case .at:
                    if !prewarm {
                        let t = now + WindowPacingConstants.timerFrame
                        _ = state.ours.step(.at(t))
                        state.dev.retry = t
                    }
                case .reveal:
                    _ = state.ours.step(.revealed)
                    state.dev.wait = WindowPacingConstants.occludedRetry
                case .stop:
                    _ = state.ours.step(.lapsed)
                    state.dev.retry = nil
                }
                let expectedWaiting = state.dev.retry.map { $0 > now } ?? false
                guard wakes.map({ $0 == (state.dev.retry != nil) }) ?? true,
                      state.ours.deadline == state.dev.retry,
                      state.ours.waiting(now: now) == expectedWaiting,
                      abs(Self.occludedWait(state.ours, now: now) - state.dev.wait) < 1e-9 else {
                    Issue.record("Backoff differs for \(path), prewarm \(prewarm), scale \(scale): \(state)")
                    return false
                }
                visited += 1
                return true
            }
            #expect(visited == 177_155) // Every nonempty prefix through depth five.
        }
    }

    @Test("overlay/state_walk_tests.rs:578 - OverlaySurfaceState matches dev for every platform/config sequence")
    func surfaceMatchesDevForEverySequence() {
        enum Platform: CaseIterable { case mac, windows, x11, wayland }
        enum Kind: Equatable { case window, layer }
        struct Made: Equatable { let id: UInt32; let kind: Kind }
        enum Owner: Equatable { case live, parked }
        enum Outcome { case ok, window, attach, rescale }
        enum SurfaceOp {
            case prepare(showing: Bool, outcome: Outcome)
            case hideWindow
            case park
            case release
        }
        struct Config { let platform: Platform; let defers: Bool; let callback: Bool }

        struct DevSurface {
            var live: Made? = nil
            var parked: Made? = nil
            var announced: Bool = false
            var heard: [Made?] = []
            var released: [(Owner, Made)] = []

            mutating func apply(_ c: Config, _ op: SurfaceOp, _ n: UInt32) {
                let kind: Kind = (c.platform == .wayland) ? .layer : .window
                switch op {
                case let .prepare(showing, outcome):
                    if live != nil { return }
                    let (creation, attach, rescale): (Bool, Bool, Bool)
                    switch outcome {
                    case .ok: (creation, attach, rescale) = (true, true, true)
                    case .window: (creation, attach, rescale) = (false, true, true)
                    case .attach: (creation, attach, rescale) = (true, false, true)
                    case .rescale: (creation, attach, rescale) = (true, true, false)
                    }
                    let surface = showing || !c.defers
                    let parks = c.platform == .x11
                    if !surface && !parks { return }
                    let made: Made?
                    if c.platform == .wayland {
                        made = creation ? Made(id: n, kind: kind) : nil
                    } else if parked != nil || window(c, creation, attach, n) {
                        if let existingLive = live {
                            live = nil
                            made = existingLive
                        } else if surface {
                            made = unpark(attach)
                        } else {
                            ready(c)
                            return
                        }
                    } else {
                        made = nil
                    }
                    if let made {
                        live = made
                        if made.kind == .window && !rescale { return }
                        ready(c)
                    }
                case .hideWindow:
                    if let current = live, current.kind == .layer { live = nil }
                case .park:
                    guard let current = live, current.kind == .window else { return }
                    if c.platform == .mac || c.platform == .windows {
                        release()
                    } else {
                        live = nil
                        parked = current
                    }
                case .release:
                    release()
                }
            }

            mutating func window(_ c: Config, _ creation: Bool, _ attach: Bool, _ n: UInt32) -> Bool {
                if !creation { return false }
                if c.platform == .mac {
                    if !attach { return false }
                    live = Made(id: n, kind: .window)
                } else {
                    parked = Made(id: n, kind: .window)
                }
                return true
            }

            mutating func unpark(_ attach: Bool) -> Made? {
                guard let w = parked else { return nil }
                parked = nil
                if attach { return w }
                parked = w
                return nil
            }

            mutating func ready(_ c: Config) {
                if !announced && c.callback {
                    announced = true
                    heard.append(live ?? parked)
                }
            }

            mutating func release() {
                if let l = live {
                    live = nil
                    released.append((.live, l))
                } else if let p = parked {
                    parked = nil
                    released.append((.parked, p))
                }
                announced = false
            }
        }

        struct Ours {
            var surface: OverlaySurfaceState<Made, Made> = .initial
            var heard: [Made?] = []
            var released: [(Owner, Made)] = []

            mutating func apply(_ c: Config, _ op: SurfaceOp, _ n: UInt32) {
                let kind: Kind = (c.platform == .wayland) ? .layer : .window
                switch op {
                case let .prepare(showing, outcome):
                    if surface.live != nil { return }
                    let (creation, attach, rescale): (Bool, Bool, Bool)
                    switch outcome {
                    case .ok: (creation, attach, rescale) = (true, true, true)
                    case .window: (creation, attach, rescale) = (false, true, true)
                    case .attach: (creation, attach, rescale) = (true, false, true)
                    case .rescale: (creation, attach, rescale) = (true, true, false)
                    }
                    let wantsSurface = showing || !c.defers
                    let parks = c.platform == .x11
                    if !wantsSurface && !parks { return }
                    let made: Made?
                    if c.platform == .wayland {
                        made = creation ? Made(id: n, kind: kind) : nil
                    } else if surface.parked != nil || window(c, creation, attach, n) {
                        if let existingLive = surface.takeLive() {
                            made = existingLive
                        } else if wantsSurface {
                            made = unpark(attach)
                        } else {
                            ready(c)
                            return
                        }
                    } else {
                        made = nil
                    }
                    if let made {
                        surface.made(made)
                        if made.kind == .window && !rescale { return }
                        ready(c)
                    }
                case .hideWindow:
                    if let current = surface.live, current.kind == .layer {
                        _ = surface.takeLive()
                    }
                case .park:
                    guard let current = surface.live, current.kind == .window else { return }
                    if c.platform == .mac || c.platform == .windows {
                        release()
                    } else if let taken = surface.takeLive() {
                        surface.park(taken)
                        _ = current
                    }
                case .release:
                    release()
                }
            }

            mutating func window(_ c: Config, _ creation: Bool, _ attach: Bool, _ n: UInt32) -> Bool {
                if !creation { return false }
                if c.platform == .mac {
                    if !attach { return false }
                    surface.made(Made(id: n, kind: .window))
                } else {
                    surface.park(Made(id: n, kind: .window))
                }
                return true
            }

            mutating func unpark(_ attach: Bool) -> Made? {
                guard let w = surface.takeParked() else { return nil }
                if attach { return w }
                surface.park(w)
                return nil
            }

            mutating func ready(_ c: Config) {
                if !surface.isAnnounced && c.callback {
                    surface.announce()
                    heard.append(surface.live ?? surface.parked)
                }
            }

            mutating func release() {
                switch surface.release() {
                case let .live(l):
                    released.append((.live, l))
                case let .parked(p):
                    released.append((.parked, p))
                case nil:
                    break
                }
            }
        }

        let alphabet: [SurfaceOp] = [
            .prepare(showing: false, outcome: .ok),
            .prepare(showing: true, outcome: .ok),
            .prepare(showing: false, outcome: .window),
            .prepare(showing: true, outcome: .window),
            .prepare(showing: false, outcome: .attach),
            .prepare(showing: true, outcome: .attach),
            .prepare(showing: false, outcome: .rescale),
            .prepare(showing: true, outcome: .rescale),
            .hideWindow,
            .park,
            .release,
        ]
        var parkedAfterAttach = 0
        var liveAfterRescale = 0
        var releasedLive = 0
        var releasedParked = 0
        for platform in Platform.allCases {
            for (defers, callback) in [(false, false), (false, true), (true, false), (true, true)] {
                let c = Config(platform: platform, defers: defers, callback: callback)
                let initial = (ours: Ours(), dev: DevSurface())
                var visited = 0
                Self.walkTransitions(alphabet: alphabet, maxLen: 5, initial: initial) { state, op, path in
                    let n = UInt32(path.count)
                    let beforeLive = state.dev.live
                    let beforeReleased = state.dev.released.count
                    state.dev.apply(c, op, n)
                    state.ours.apply(c, op, n)
                    if case let .prepare(_, outcome) = op {
                        if outcome == .attach && beforeLive == nil && state.dev.parked != nil { parkedAfterAttach += 1 }
                        if outcome == .rescale && beforeLive == nil && state.dev.live != nil { liveAfterRescale += 1 }
                    }
                    for (owner, _) in state.dev.released[beforeReleased...] {
                        if owner == .live { releasedLive += 1 } else { releasedParked += 1 }
                    }
                    guard state.ours.surface.live == state.dev.live,
                          state.ours.surface.parked == state.dev.parked,
                          state.ours.surface.isAnnounced == state.dev.announced,
                          state.ours.heard == state.dev.heard,
                          state.ours.released.elementsEqual(state.dev.released, by: { $0.0 == $1.0 && $0.1 == $1.1 }) else {
                        Issue.record("Surface differs for \(c), \(path): \(state)")
                        return false
                    }
                    visited += 1
                    return true
                }
                #expect(visited == 177_155)
            }
        }
        #expect(parkedAfterAttach > 0)
        #expect(liveAfterRescale > 0)
        #expect(releasedLive > 0 && releasedParked > 0)
    }

    // MARK: - overlay/lost_release_tests.rs (exhaustive short-sequence property test)

    @Test("overlay/lost_release_tests.rs:412 - every short pointer sequence keeps drag invariants")
    func everyShortSequenceOfPointerEventsKeepsDragInvariants() {
        enum Letter: CaseIterable {
            case seenDown, seenUp, readUp, readDown, cursorMoved, mouseDown, mouseUp, turn, grace, occlude, viewLost
        }
        enum Heard: Equatable {
            case down(Vec2, Int)
            case move(Vec2)
            case up(Vec2)
            case cancel(Vec2)
            case press
        }
        struct Plan { let farPresses: Bool; let farReadings: Bool }
        struct Queued { let down: Bool; let at: Vec2; let press: Int; var forgotten: Bool; var owes: Bool }
        struct Predicted { let press: Int; let down: Vec2; var moved: Bool }

        func makePoint(_ index: Int, far: Bool) -> Vec2 {
            Vec2(far ? (100.0 + 30.0 * Float(index)) : 10.0, 10.0 + 0.125 * Float(index))
        }
        func eventOf(_ p: Vec2) -> Int {
            Int(((p.y - 10.0) / 0.125).rounded())
        }
        func withinSlop(_ a: Vec2, _ b: Vec2) -> Bool {
            let s: Float = 4.0
            return abs(a.x - b.x) <= s && abs(a.y - b.y) <= s
        }

        final class Reference {
            let plan: Plan
            var clock: Double = 0.0
            var queue: [Queued] = []
            var seen: Int = 0
            var owner: [Int] = [0]
            var ups: [Vec2?] = [nil]
            var rose: [Vec2?] = [nil]
            var latest: [Vec2] = [makePoint(0, far: false)]
            var buttons: UInt = 0
            var at: Vec2 = makePoint(0, far: false)
            var nextPressUnderWay: Bool = false
            var lastRead: Vec2? = nil
            var pending: Vec2? = nil
            var holding: Bool = false
            var rising: Double? = nil
            var rebounded: Bool = false
            var owed: Bool = false
            var givenUp: Int = 0
            var occluded: Bool = false
            var drag: Predicted? = nil
            var runtimeAt: Vec2
            var run: (Vec2, Int)? = nil
            var open: Predicted? = nil
            var lastPress: (down: Vec2, moved: Bool, count: Int)? = nil

            init(plan: Plan, runtimeAt: Vec2) {
                self.plan = plan
                self.runtimeAt = runtimeAt
            }

            func event(far: Bool, owner pressOwner: Int) -> Vec2 {
                let index = owner.count
                owner.append(pressOwner)
                return makePoint(index, far: far)
            }

            func deadline() -> Double? {
                guard holding, let since = rising else { return nil }
                let hasQueuedUp = queue.contains { !$0.forgotten && !$0.down }
                return since + (hasQueuedUp ? 2.0 : 0.100)
            }

            @discardableResult
            func read() -> (UInt, Vec2, Double) {
                if holding {
                    if buttons != 0 {
                        if rising != nil {
                            rising = nil
                            rebounded = true
                        } else if !rebounded {
                            latest[seen] = at
                        }
                    } else if rising == nil {
                        rising = clock
                        rebounded = false
                        if rose[seen] == nil { rose[seen] = at }
                    } else if let due = deadline(), clock >= due {
                        giveUp()
                        for i in queue.indices { queue[i].forgotten = true }
                        queue.removeAll { $0.down }
                    }
                }
                if lastRead != at {
                    lastRead = at
                    pending = at
                }
                return (buttons, at, clock)
            }

            func giveUp() {
                holding = false
                rising = nil
                rebounded = false
                givenUp = seen
                if drag != nil { owed = true }
            }

            func expectedCancel(_ press: Int) -> Vec2 {
                ups[press] ?? rose[press] ?? latest[press]
            }

            func landLost(_ expect: inout [Heard]) {
                guard owed else { return }
                owed = false
                guard let d = drag else { return }
                drag = nil
                let cancelAt = expectedCancel(d.press)
                expect.append(.cancel(cancelAt))
                if d.moved || !withinSlop(d.down, cancelAt) { run = nil }
                runtimeAt = cancelAt
            }

            func beforePosition(_ expect: inout [Heard]) {
                if let idx = queue.firstIndex(where: { !$0.forgotten }), queue[idx].owes {
                    queue[idx].owes = false
                    owed = true
                }
                landLost(&expect)
            }

            func position(_ point: Vec2, _ expect: inout [Heard]) {
                guard runtimeAt != point else { return }
                runtimeAt = point
                if var d = drag {
                    expect.append(.move(point))
                    d.moved = d.moved || !withinSlop(d.down, point)
                    drag = d
                }
            }

            func play(_ letter: Letter) -> (at: Vec2?, reading: (UInt, Vec2, Double)?, dispatched: Queued?, expect: [Heard])? {
                var outAt: Vec2? = nil
                var reading: (UInt, Vec2, Double)? = nil
                var dispatched: Queued? = nil
                var expect: [Heard] = []

                switch letter {
                case .seenDown:
                    let owes = holding && (queue.last(where: { !$0.forgotten })?.down ?? true)
                    seen += 1
                    nextPressUnderWay = false
                    let pt = event(far: plan.farPresses, owner: seen)
                    ups.append(nil)
                    rose.append(nil)
                    latest.append(pt)
                    queue.append(Queued(down: true, at: pt, press: seen, forgotten: false, owes: owes))
                    holding = true
                    rising = nil
                    rebounded = false
                    buttons = 1
                    at = pt
                    outAt = pt

                case .seenUp:
                    let pt = event(far: plan.farReadings, owner: seen)
                    if ups[seen] == nil && seen > givenUp { ups[seen] = pt }
                    queue.append(Queued(down: false, at: pt, press: seen, forgotten: false, owes: false))
                    buttons = 0
                    at = pt
                    outAt = pt

                case .readUp:
                    at = event(far: plan.farReadings, owner: seen + (nextPressUnderWay ? 1 : 0))
                    buttons = 0
                    reading = read()

                case .readDown:
                    if buttons == 0 && seen > 0 { nextPressUnderWay = true }
                    at = event(far: plan.farReadings, owner: seen + (nextPressUnderWay ? 1 : 0))
                    buttons = 1
                    reading = read()

                case .cursorMoved:
                    let pt = queue.first?.at ?? event(far: plan.farReadings, owner: seen)
                    beforePosition(&expect)
                    position(pt, &expect)
                    outAt = pt

                case .mouseDown:
                    guard let front = queue.first, front.down else { return nil }
                    queue.removeFirst()
                    if front.owes { owed = true }
                    landLost(&expect)
                    let clicks: Int
                    if let (was, count) = run, withinSlop(was, front.at) { clicks = count + 1 } else { clicks = 1 }
                    run = (front.at, clicks)
                    runtimeAt = front.at
                    drag = Predicted(press: front.press, down: front.at, moved: false)
                    expect.append(.down(front.at, clicks))
                    dispatched = front

                case .mouseUp:
                    guard let front = queue.first, !front.down else { return nil }
                    queue.removeFirst()
                    landLost(&expect)
                    let released = front.forgotten ? runtimeAt : front.at
                    position(released, &expect)
                    if let d = drag {
                        drag = nil
                        expect.append(.up(released))
                        expect.append(.press)
                        if d.moved { run = nil }
                    }
                    let stillHolding = queue.contains { !$0.forgotten && $0.down }
                    holding = stillHolding
                    if !stillHolding {
                        rising = nil
                        rebounded = false
                    }
                    reading = read()
                    dispatched = front

                case .turn:
                    reading = read()
                    beforePosition(&expect)
                    let liveExists = queue.contains { !$0.forgotten }
                    let ahead = holding && (rising != nil || rebounded || liveExists)
                    if !ahead, let pt = pending {
                        pending = nil
                        position(pt, &expect)
                    } else if !ahead {
                        pending = nil
                    }

                case .grace:
                    if let due = deadline() {
                        clock = due
                        reading = read()
                    }

                case .occlude:
                    occluded.toggle()

                case .viewLost:
                    giveUp()
                    queue.removeAll()
                }
                return (outAt, reading, dispatched, expect)
            }

            func check(_ letter: Letter, dispatched: Queued?, heard: [Heard]) -> String? {
                var dropped = false
                for item in heard {
                    let atPos: Vec2
                    let isUp: Bool
                    switch item {
                    case .press:
                        if !dropped { return "a press fired without a normal release" }
                        dropped = false
                        continue
                    case let .down(down, clicks):
                        dropped = false
                        if open != nil { return "a press replaced a drag that hadn't ended" }
                        guard let click = dispatched, click.down, letter == .mouseDown else {
                            return "a drag began without a dispatched press"
                        }
                        if down != click.at { return "press at \(click.at) began at \(down)" }
                        let want: Int
                        if let lp = lastPress, !lp.moved, withinSlop(lp.down, down) { want = lp.count + 1 } else { want = 1 }
                        if clicks != want { return "\(clicks) clicks, reference \(want)" }
                        lastPress = (down, false, clicks)
                        open = Predicted(press: click.press, down: down, moved: false)
                        continue
                    case let .move(at):
                        atPos = at; isUp = false
                    case let .up(at), let .cancel(at):
                        atPos = at; isUp = true
                    }
                    dropped = false
                    guard var cur = open else { return "\(item) on a drag already ended" }
                    let ptOwner = owner[eventOf(atPos)]
                    if ptOwner > cur.press { return "press \(cur.press) heard \(item) from press \(ptOwner)" }
                    cur.moved = cur.moved || !withinSlop(cur.down, atPos)
                    open = cur
                    if var lp = lastPress {
                        lp.moved = cur.moved
                        lastPress = lp
                    }
                    if !isUp { continue }
                    if case .cancel = item {
                        let want = expectedCancel(cur.press)
                        if atPos != want { return "press \(cur.press) cancelled at \(atPos), reference \(want)" }
                    } else {
                        guard let click = dispatched, !click.down, click.press == cur.press, letter == .mouseUp, cur.press > givenUp else {
                            return "press \(cur.press) ended normally after losing its release"
                        }
                        dropped = true
                    }
                    open = nil
                }
                return nil
            }
        }

        // Reuse the mounted runtime and reset its click count before each independent sequence.
        let rt = Runtime<[Heard]>(
            state: [],
            viewport: Vec2(1000, 100),
            view: { _, _ in
                el().key("hit").w(1000).h(100).hit()
                    .onDrag { heard, drag, _ in
                        switch drag.phase {
                        case .down: heard.append(.down(drag.window, drag.clicks))
                        case .move: heard.append(.move(drag.window))
                        case .up: heard.append(drag.isCancelled ? .cancel(drag.window) : .up(drag.window))
                        }
                    }
                    .onClick { heard in heard.append(.press) }
            }
        )
        _ = rt.frame(at: 0.0)

        enum RuntimeInput: Hashable {
            case move(Vec2, Double), down(Vec2, Double), up(Vec2, Double), lost(Vec2, Double)

            func apply(to rt: Runtime<[Heard]>) {
                switch self {
                case let .move(point, time): rt.pointerMove(to: point, at: time)
                case let .down(point, time): rt.pointerDown(at: point, button: .primary, mods: .none, at: time)
                case let .up(point, time): rt.pointerUp(at: point, button: .primary, mods: .none, at: time)
                case let .lost(point, time): rt.pointerReleaseLost(at: point, at: time)
                }
            }
        }
        struct Trace {
            let parent: Int
            let input: RuntimeInput?
            let position: Vec2
            let heard: [Heard]
            var children: [RuntimeInput: Int] = [:]
        }

        // Many panel histories dispatch identical timed inputs to the runtime. Share only
        // complete runtime-input prefixes, including the event, point and clock at every step.
        // The panel, reference, callbacks, capture and deadline still run through every letter.
        let epoch = 0.0
        let initPt = Vec2(5, 5)
        var traces = [Trace(parent: 0, input: nil, position: initPt, heard: [])]
        var liveTrace = -1
        var aborted = false

        func restore(_ index: Int) {
            guard liveTrace != index else { return }
            if let input = traces[index].input {
                restore(traces[index].parent)
                input.apply(to: rt)
                if rt.pointerPosition != traces[index].position || rt.state != traces[index].heard {
                    aborted = true
                    Issue.record("Replaying runtime input \(input) changed its position or callbacks")
                }
            } else {
                rt.cancelPointer(at: epoch)
                rt.pointerDown(at: Vec2(-9999, -9999), button: .secondary, mods: .none, at: epoch)
                rt.pointerUp(at: Vec2(-9999, -9999), button: .secondary, mods: .none, at: epoch)
                rt.pointerMove(to: initPt, at: epoch)
            }
            rt.state.removeAll(keepingCapacity: true)
            liveTrace = index
        }

        func runSequence(plan: Plan, seq: [Letter]) -> Bool {
            var trace = 0
            var heard: [Heard] = []
            func dispatch(_ input: RuntimeInput) {
                if let child = traces[trace].children[input] {
                    trace = child
                } else {
                    restore(trace)
                    input.apply(to: rt)
                    let child = traces.count
                    traces[trace].children[input] = child
                    traces.append(Trace(parent: trace, input: input, position: rt.pointerPosition, heard: rt.state))
                    rt.state.removeAll(keepingCapacity: true)
                    liveTrace = child
                    trace = child
                }
                heard.append(contentsOf: traces[trace].heard)
            }

            let ptr = OverlayPointerState(input: .all, interactive: true)
            let ref = Reference(plan: plan, runtimeAt: initPt)
            let (b0, a0, c0) = ref.read()
            _ = ptr.read(buttons: b0, now: epoch + c0, at: a0, inside: true)

            let steps = seq + [.readUp, .grace, .turn]
            for (stepIdx, letter) in steps.enumerated() {
                heard.removeAll(keepingCapacity: true)
                guard let played = ref.play(letter) else { return false }
                let t = epoch + (played.reading?.2 ?? ref.clock)

                switch letter {
                case .seenDown:
                    if let pt = played.at { ptr.recordClick(down: true, at: pt) }
                case .seenUp:
                    if let pt = played.at { ptr.recordClick(down: false, at: pt) }
                case .readUp, .readDown, .grace:
                    if let (btns, pt, clk) = played.reading {
                        _ = ptr.read(buttons: btns, now: epoch + clk, at: pt, inside: true)
                    }
                case .cursorMoved:
                    if let lost = ptr.takeLostBeforePosition() {
                        dispatch(.lost(lost, t))
                    }
                    if let pt = played.at, traces[trace].position != pt {
                        dispatch(.move(pt, t))
                    }
                case .mouseDown:
                    let edge = ptr.takeEdge(down: true)
                    if let lost = edge.lostRelease {
                        dispatch(.lost(lost, t))
                    }
                    if let pt = edge.point {
                        dispatch(.down(pt, t))
                    }
                case .mouseUp:
                    let edge = ptr.takeEdge(down: false)
                    if let lost = edge.lostRelease {
                        dispatch(.lost(lost, t))
                    }
                    let upPt = edge.point ?? traces[trace].position
                    if traces[trace].position != upPt {
                        dispatch(.move(upPt, t))
                    }
                    dispatch(.up(upPt, t))
                    ptr.released()
                    if let (btns, pt, clk) = played.reading {
                        _ = ptr.read(buttons: btns, now: epoch + clk, at: pt, inside: true)
                    }
                case .turn:
                    if let (btns, pt, clk) = played.reading {
                        _ = ptr.read(buttons: btns, now: epoch + clk, at: pt, inside: true)
                    }
                    if let lost = ptr.takeLostBeforePosition() {
                        dispatch(.lost(lost, t))
                    }
                    if let pt = ptr.takePosition(), traces[trace].position != pt {
                        dispatch(.move(pt, t))
                    }
                case .occlude:
                    break
                case .viewLost:
                    ptr.viewLost()
                }

                let actualDeadline = ptr.deadline(poll: nil, occluded: ref.occluded)
                let expectedDeadline = ref.deadline().map { epoch + $0 }
                if ptr.isCaptured != ref.holding || actualDeadline != expectedDeadline {
                    aborted = true
                    Issue.record("Capture or release deadline differs after step \(stepIdx) (\(letter)) of \(seq): capture \(ptr.isCaptured)/\(ref.holding), deadline \(String(describing: actualDeadline))/\(String(describing: expectedDeadline))")
                    return false
                }
                if heard != played.expect {
                    if !aborted {
                        aborted = true
                        Issue.record("Mismatch at step \(stepIdx) (\(letter)) of seq=\(seq): heard=\(heard) expect=\(played.expect)")
                    }
                    return false
                }
                if let failure = ref.check(letter, dispatched: played.dispatched, heard: heard) {
                    if !aborted {
                        aborted = true
                        Issue.record("Invariant violated (\(seq), \(letter)): \(failure)")
                    }
                    return false
                }
            }
            if ref.open != nil || ref.drag != nil {
                if !aborted {
                    aborted = true
                    Issue.record("Drag did not end after draining seq=\(seq)")
                }
                return false
            }
            return true
        }

        let plans = [
            Plan(farPresses: false, farReadings: false),
            Plan(farPresses: false, farReadings: true),
            Plan(farPresses: true, farReadings: true),
        ]
        for plan in plans {
            var legalSequences = 0
            var stack: [Letter] = []
            func visit() {
                if aborted { return }
                if !stack.isEmpty {
                    guard runSequence(plan: plan, seq: stack) else { return }
                    legalSequences += 1
                }
                if stack.count == 6 || aborted { return }
                for l in Letter.allCases {
                    if aborted { return }
                    stack.append(l)
                    visit()
                    stack.removeLast()
                }
            }
            visit()
            // Counted independently by the pinned Rust reference for each plan at depth six.
            #expect(legalSequences == 744_115)
            if aborted { return }
        }
    }

    // MARK: - overlay/tests.rs & overlay/more_tests.rs non-winit/wgpu parity

    @Test("overlay/tests.rs:73 - retained overlay moved while hidden reports new screen rect on show")
    func retainedOverlayMovedWhileHiddenReportsScreenRectOnShow() {
        var latestScreen: [Float]? = nil
        let rt = Runtime(
            state: (),
            viewport: Vec2(100, 50),
            view: { _, _ in
                el().key("root").w(100).h(50).child(
                    el().key("box").absolute(x: 10, y: 5).size(20, 8)
                        .onScreenLayout { _, rect in latestScreen = rect }
                )
            }
        )
        _ = rt.frame(at: 0.0)
        #expect(latestScreen == [10, 5, 20, 8])

        latestScreen = nil
        let queued = rt.setWindowOrigin(Vec2(300, 200))
        #expect(queued)
        _ = rt.frame(at: 0.016)
        #expect(latestScreen == [310, 205, 20, 8])
    }

    @Test("overlay/tests.rs:271,276,285,303 - FrameClock cadence, idle mid-motion, after-idle step, and resume split")
    func overlayFrameClockCadenceAndIdleVsRunningMotion() {
        let frameDt = 1.0 / 60.0
        func makeWidthRuntime() -> Runtime<Float> {
            let rt = Runtime<Float>(
                state: 12.0,
                viewport: Vec2(500, 50),
                view: { w, _ in
                    el().child(el().key("box").size(w, 8).animateLayout())
                }
            )
            rt.setSystemReducedMotion(false)
            return rt
        }

        // Motion starting after idle takes one frame step regardless of idle gap
        func firstPoseAfterIdle(_ idleGap: Double) -> Float {
            let rt = makeWidthRuntime()
            let clock = FrameClock(start: 1.0)
            _ = rt.frame(at: 0.0)
            _ = rt.frame(at: frameDt)
            let preStep = clock.frameStep(at: 1.0 + frameDt, running: rt.isAnimating)
            #expect(preStep.catchUp == 0.0)
            rt.update(at: 1.0 + frameDt) { w, _ in w = 212.0 }
            let step = clock.frameStep(at: 1.0 + frameDt + idleGap, running: rt.isAnimating)
            #expect(step.catchUp == 0.0)
            #expect(abs(step.dt - FrameClock.resumeStep) < 1e-9)
            _ = rt.frame(at: 1.0 + frameDt + step.dt)
            return rt.elements().first { $0.key == "box" }?.rect[2] ?? 0
        }
        let short = firstPoseAfterIdle(frameDt)
        let long = firstPoseAfterIdle(2.0)
        #expect(short > 12.0 && short < 20.0)
        #expect(abs(short - long) < 0.001)

        // Running motion preserves catch-up up to MAX_GAP when paused and resumed; fresh motion starts with resumeStep
        struct Pair { var a: Float; var b: Float }
        let rtPair = Runtime<Pair>(
            state: Pair(a: 12, b: 12),
            viewport: Vec2(500, 50),
            view: { s, _ in
                el().children([
                    el().key("a").size(s.a, 8).animateLayout(),
                    el().key("b").size(s.b, 8).animateLayout(),
                ])
            }
        )
        rtPair.setSystemReducedMotion(false)
        _ = rtPair.frame(at: 0.0)
        rtPair.update(at: 0.0) { s, _ in s.a = 212 }
        _ = rtPair.frame(at: frameDt)
        _ = rtPair.frame(at: frameDt * 2.0)
        _ = rtPair.frame(at: frameDt * 3.0)
        let clock = FrameClock(start: frameDt * 3.0)
        let resumeSplit = clock.frameStep(at: frameDt * 3.0 + 3.0, running: rtPair.isAnimating)
        #expect(abs(resumeSplit.total - FrameClock.maxGap) < 1e-9)
        #expect(abs(resumeSplit.dt - FrameClock.resumeStep) < 1e-9)
        #expect(abs(resumeSplit.catchUp - (FrameClock.maxGap - FrameClock.resumeStep)) < 1e-9)
        if resumeSplit.catchUp > 0 {
            _ = rtPair.frame(at: frameDt * 3.0 + resumeSplit.catchUp)
        }
        rtPair.update(at: frameDt * 3.0 + resumeSplit.catchUp) { s, _ in s.b = 212 }
        _ = rtPair.frame(at: frameDt * 3.0 + resumeSplit.total)
        let aVal = rtPair.elements().first { $0.key == "a" }?.rect[2] ?? 0
        let bVal = rtPair.elements().first { $0.key == "b" }?.rect[2] ?? 0
        #expect(aVal > 50.0 && aVal < 211.0)
        #expect(abs(bVal - short) < 0.05)
    }

    @Test("overlay/tests.rs:362,415,525 - hidden commit/retarget keeps elapsed motion and cached reveal avoids settling same-tick update")
    func overlayHiddenCommitAndRetargetMotionParity() {
        struct State { var width: Float = 12; var text: LiveText = LiveText("00") }
        let rt = Runtime(
            state: State(),
            viewport: Vec2(200, 50),
            view: { s, _ in
                el().children([
                    el().key("box").size(s.width, 8).animateLayout(),
                    liveText(s.text).key("live"),
                ])
            }
        )
        rt.setSystemReducedMotion(false)
        _ = rt.frame(at: 0.0)
        rt.setLiveVisible(false)
        rt.update(at: 1.0) { s, _ in s.width = 20 }
        _ = rt.hiddenWake(at: 1.0)
        // Retarget while hidden after 0.5s
        rt.update(at: 1.5) { s, _ in s.width = 30 }
        rt.state.text.set("01")
        rt.setLiveVisible(true)
        _ = rt.frame(at: 1.516)
        let boxW = rt.elements().first { $0.key == "box" }?.rect[2] ?? 0
        #expect(boxW > 12.0 && boxW < 30.0)
        let liveTxt = rt.elements().first { $0.key == "live" }?.text
        #expect(liveTxt == "01")

        // Cached reveal does not settle same-tick update
        let spec = OverlaySpec(
            name: "cached-reveal",
            size: Vec2(120, 40),
            makeState: { Float(8.0) },
            view: { w, _ in el().key("box").size(w, 8).animateLayout() }
        )
        let handle = OverlayHandle(configured: spec.configured(OverlayOptions(prewarm: true)))
        handle.runtime.setSystemReducedMotion(false)
        handle.update { $0 = 12.0 }
        _ = handle.runtime.frame(at: 0.0)
        handle.fadeIn(0.0)
        handle.update { $0 = 20.0 }
        let scene = handle.present(at: 1.0 / 60.0)
        #expect(scene != nil)
        let w = handle.runtime.elements().first { $0.key == "box" }?.rect[2] ?? 0
        #expect(w > 8.0 && w <= 20.0)
    }

    @Test("overlay/tests.rs:551,565 - focus callback before first show and hide releases held modifiers")
    func overlayFocusCallbackAndModifierReleaseOnHide() {
        var focusEvents: [Bool] = []
        let focusSpec = OverlaySpec(
            name: "focus-pre-show",
            size: Vec2(100, 100),
            makeState: { 0 },
            view: { _, _ in el() }
        ).configured(OverlayOptions()).onFocus { _, focused, _ in
            focusEvents.append(focused)
        }
        let focusHandle = OverlayHandle(configured: focusSpec)
        focusHandle.deliverFocus(true)
        focusHandle.deliverFocus(false)
        #expect(focusEvents == [true, false])
        #expect(focusHandle.windowNumber == nil)

        var modLog: [(ModifierKey, Bool)] = []
        let keySpec = OverlaySpec(
            name: "mod-release",
            size: Vec2(100, 100),
            makeState: { 0 },
            view: { _, _ in el() }
        )
        .configured(OverlayOptions(keyPolicy: .nonActivating, modifierKeys: true))
        .onKey { _, ev, _ in
            if case let .modifier(mod, pressed) = ev.key {
                modLog.append((mod, pressed))
                return true
            }
            return false
        }
        let keyHandle = OverlayHandle(configured: keySpec)
        #expect(keyHandle.runtime.modifierKeysEnabled)
        _ = keyHandle.runtime.frame(at: 0.0)
        keyHandle.fadeIn(0.0)
        _ = keyHandle.runtime.physicalInput(
            .key(key: .altRight, mods: .none, pressed: true, repeat: false),
            at: 0.1
        )
        _ = keyHandle.runtime.physicalInput(
            .key(key: .fn, mods: .none, pressed: true, repeat: false),
            at: 0.2
        )
        keyHandle.hide()
        #expect(modLog.count == 4)
        #expect(modLog[0].0 == .altRight && modLog[0].1 == true)
        #expect(modLog[1].0 == .fn && modLog[1].1 == true)
        #expect(modLog[2].0 == .altRight && modLog[2].1 == false)
        #expect(modLog[3].0 == .fn && modLog[3].1 == false)

        // Focus loss after hide does not re-release already released modifiers
        keyHandle.deliverFocus(false)
        #expect(modLog.count == 4)

        // Shown again, pressing modifier delivers again
        keyHandle.fadeIn(0.0)
        _ = keyHandle.runtime.physicalInput(
            .key(key: .altRight, mods: .none, pressed: true, repeat: false),
            at: 0.3
        )
        #expect(modLog.count == 5 && modLog[4].0 == .altRight && modLog[4].1 == true)
    }

    @Test("overlay/more_tests.rs:39,216,322,770,781 - input switch waits for drag, request ordering, drag-out threshold & hidden drag end")
    func overlayInputSwitchRequestsAndDragOutParity() {
        // Request collapse order: set_input, place, resize, update, show/hide
        let spec = OverlaySpec(
            name: "req-order",
            size: Vec2(100, 100),
            makeState: { 0 },
            view: { n, _ in text("n=\(n)") }
        )
        let h = OverlayHandle(spec: spec)
        h.show()
        h.update { $0 += 1 }
        h.place(edge: .bottom, margin: 24)
        h.setAlign(.end, inset: 12)
        h.resize(Vec2(300, 80))
        h.update { $0 *= 3 }
        h.hide()
        #expect(!h.isVisible)
        #expect(h.readState { $0 } == 3)
        #expect(h.placementSpec.edge == .bottom && h.placementSpec.margin == 24)
        #expect(h.placementSpec.align == .end && h.placementSpec.inset == 12)
        #expect(h.size == Vec2(300, 80))

        // Quiet accent/contrast updates
        _ = h.present(at: 0.0)
        h.setAccent(h.runtime.systemAccent())
        let pink = SystemAccent(
            lightAccent: Color.srgb(1, 0.05, 0.4),
            darkAccent: Color.srgb(1, 0.05, 0.4)
        )
        h.setAccent(pink)
        #expect(h.runtime.systemAccent() == pink)
        #expect(h.isDirty)

        // Drag-out release past threshold does not start OS drag, and hidden overlay still runs onDragOutEnd
        struct DragState { var starts = 0; var ended: [DragOutcome] = [] }
        let rt = Runtime(
            state: DragState(),
            viewport: Vec2(200, 50),
            view: { _, _ in
                el().key("tile").size(100, 40)
                    .dragOut { _ in
                        var item = DragItem()
                        item.text = "tile"
                        return item
                    }
                    .onDragStart { s, _ in s.starts += 1 }
                    .onDragOutEnd { s, outcome, _ in s.ended.append(outcome) }
            }
        )
        _ = rt.frame(at: 0.0)
        rt.pointerMove(to: Vec2(10, 10), at: 0.01)
        rt.pointerDown(at: Vec2(10, 10), button: .primary, mods: .none, at: 0.02)
        rt.pointerUp(at: Vec2(60, 10), button: .primary, mods: .none, at: 0.03)
        #expect(rt.takeDragOutStart() == nil)
        #expect(rt.state.starts == 0)

        // Hidden overlay still delivers finishDragOut when activeDragOut was started
        rt.pointerMove(to: Vec2(10, 10), at: 0.10)
        rt.pointerDown(at: Vec2(10, 10), button: .primary, mods: .none, at: 0.11)
        rt.pointerMove(to: Vec2(50, 10), at: 0.12)
        let started = rt.takeDragOutStart()
        #expect(started != nil)
        rt.setLiveVisible(false)
        rt.finishDragOut(.copied, at: 0.2)
        #expect(rt.state.ended == [.copied])

        // more_tests.rs:39 - overlay_input_switch_waits_for_owned_drag_release
        let dragOverlay = OverlayHandle(
            spec: OverlaySpec<[String]>(
                name: "drag-input-switch",
                size: Vec2(120, 60),
                options: OverlayOptions(input: .all),
                makeState: { [] },
                view: { _, _ in
                    el().key("drag").size(120, 60)
                        .onDrag { s, _, _ in s.append("drag") }
                        .onDragEnd { s, _, _ in s.append("up") }
                }
            )
        )
        _ = dragOverlay.runtime.frame(at: 0.0)
        dragOverlay.runtime.pointerDown(at: Vec2(20, 20), button: .primary, mods: .none, at: 0.01)
        #expect(dragOverlay.runtime.pointerCaptured)
        dragOverlay.setInput(.none)
        #expect(dragOverlay.options.input == .all)
        #expect(dragOverlay.pendingInput == OverlayInput.none)
        #expect(!dragOverlay.applyInput())
        dragOverlay.runtime.pointerUp(at: Vec2(40, 20), button: .primary, mods: .none, at: 0.02)
        #expect(!dragOverlay.runtime.pointerCaptured)
        #expect(dragOverlay.applyInput())
        #expect(dragOverlay.options.input == .none)
        #expect(dragOverlay.pendingInput == nil)

        // Escape drag-cancel & focus-loss cancellation clear pointerCaptured (`pointer.rs:107-153`).
        dragOverlay.setInput(.all)
        _ = dragOverlay.applyInput()
        dragOverlay.runtime.pointerDown(at: Vec2(20, 20), button: .primary, mods: .none, at: 0.03)
        dragOverlay.runtime.pointerMove(to: Vec2(40, 20), at: 0.035)
        #expect(dragOverlay.runtime.pointerCaptured)
        #expect(dragOverlay.runtime.keyDown(KeyEvent(key: .escape, mods: .none), at: 0.04))
        #expect(!dragOverlay.runtime.pointerCaptured)

        dragOverlay.runtime.pointerDown(at: Vec2(20, 20), button: .primary, mods: .none, at: 0.05)
        #expect(dragOverlay.runtime.pointerCaptured)
        _ = dragOverlay.runtime.cancelPointerForFocusLoss(at: 0.055)
        #expect(!dragOverlay.runtime.pointerCaptured)

        dragOverlay.runtime.pointerDown(at: Vec2(20, 20), button: .secondary, mods: .none, at: 0.06)
        #expect(dragOverlay.runtime.pointerCaptured)
        _ = dragOverlay.runtime.cancelPointerForFocusLoss(at: 0.065)
        #expect(!dragOverlay.runtime.pointerCaptured)
    }

    @Test("overlay/more_tests.rs:792,953 - animated reveal enters from offset and Windows fade alpha steps linearly")
    func overlayAnimatedRevealAndWindowsFadeAlpha() {
        for animateReveal in [true, false] {
            let spec = OverlaySpec(
                name: "anim-reveal-\(animateReveal)",
                size: Vec2(200, 100),
                makeState: { false },
                view: { card, _ -> El<Bool> in
                    var root: El<Bool> = el().size(200, 100)
                    if card {
                        root = root.child(
                            el().key("card").size(100, 40)
                                .transition(.offset(x: 0, y: -24))
                        )
                    }
                    return root
                }
            ).configured(OverlayOptions()).animateReveal(animateReveal)
            let h = OverlayHandle(configured: spec)
            h.runtime.setSystemReducedMotion(false)
            _ = h.runtime.frame(at: 0.0)
            h.update { $0 = true }
            h.fadeIn(0.0)
            _ = h.present(at: 5.0)
            let y = h.runtime.elements().first { $0.key == "card" }?.rect[1] ?? 0
            if animateReveal {
                #expect(y < -5.0 && h.runtime.isAnimating)
                _ = h.present(at: 5.1)
                let later = h.runtime.elements().first { $0.key == "card" }?.rect[1] ?? 0
                #expect(later > y)
            } else {
                #expect(y == 0.0)
            }
        }

        let now = 0.0
        let length = 0.200
        let end = now + length
        #expect(WindowsOverlayFade.alpha(end: end, length: length, now: now) == 255)
        #expect(WindowsOverlayFade.alpha(end: end, length: length, now: now + 0.100) == 128)
        #expect(WindowsOverlayFade.alpha(end: end, length: length, now: end) == 0)
        #expect(WindowsOverlayFade.alpha(end: end, length: length, now: end + 0.050) == 0)
        #expect(WindowsOverlayFade.alpha(end: end, length: 0.0, now: now) == 0)
    }

    @Test("overlay/tests.rs:633 & more_tests.rs:1 - Pixels update visibility gating and PerfWarn quiet/rest tracking")
    func overlayPixelsAndPerfWarnQuietTracking() {
        final class WakeCounter: @unchecked Sendable {
            private let lock = NSLock()
            var count = 0
            func inc() { lock.lock(); count += 1; lock.unlock() }
        }
        let pixels = Pixels()
        pixels.set(width: 1, height: 1, rgba: [255, 255, 255, 255])
        let handle = OverlayHandle(
            spec: OverlaySpec<Pixels>(
                name: "pixels-wake",
                size: Vec2(20, 20),
                makeState: { pixels },
                view: { px, _ in el().size(4, 4).pixels(px) }
            )
        )
        _ = handle.runtime.frame(at: 0.0)
        handle.fadeIn(0.0)
        _ = handle.present(at: 0.0)
        handle.hide()
        let wakes = WakeCounter()
        handle.runtime.setLiveWaker { wakes.inc() }

        // Hidden overlay: Pixels.set wakes 0 times and reports !livePending until shown.
        pixels.set(width: 1, height: 1, rgba: [1, 2, 3, 255])
        #expect(wakes.count == 0)
        #expect(!handle.runtime.livePending)

        // resumeLive() catches up and wakes once on show.
        handle.resumeLive()
        #expect(wakes.count == 1)
        #expect(handle.runtime.livePending)
        #expect(handle.isDirty)

        // Shown: subsequent Pixels.set wakes immediately.
        _ = handle.runtime.frame(at: 0.016)
        let beforeShownSet = wakes.count
        pixels.set(width: 1, height: 1, rgba: [4, 5, 6, 255])
        #expect(wakes.count == beforeShownSet + 1)

        // hide() stops live wakes again.
        handle.hide()
        let beforeHiddenSet = wakes.count
        pixels.set(width: 1, height: 1, rgba: [7, 8, 9, 255])
        #expect(wakes.count == beforeHiddenSet)

        // Quiet timer skipping: identical drawn output with `OverlayQuiet`
        var quiet = OverlayQuiet<UInt64>()
        quiet.presentedFrame(rests: true) { $0 = 42 }
        _ = quiet.step(.timerDue(resting: true))
        let effects = quiet.step(.frameStarts)
        #expect(effects == [.timerFrame])
        #expect(quiet.presented == 42)
    }
}
