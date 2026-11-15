import Foundation
import Testing
@testable import Rune

// The routing and per-thread engine model, compared event by event with a literal copy of the
// code they replaced. A Linux teardown keeps running until the sequence says it finished
// (`shortcuts/service/routing_tests.rs`, r410).

/// A failed walk assertion, thrown so a walk stops at its first difference.
struct ShortcutWalkFailure: Error, CustomStringConvertible {
    let description: String
}

/// `assert!` for the walks: throws `ShortcutWalkFailure` with `message` when `condition` fails.
func shortcutWalkRequire(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw ShortcutWalkFailure(description: message()) }
}

/// The sequences of `length` letters drawn from `0..<letters`, each passed to `run`
/// (`machine_tests.rs::every_sequence`).
func everyShortcutSequence(letters: Int, length: Int, _ run: ([Int]) throws -> Void) rethrows {
    var sequence = [Int](repeating: 0, count: length)
    var total = 1
    for _ in 0..<length { total *= letters }
    for code in 0..<total {
        var rest = code
        for i in 0..<length {
            sequence[i] = rest % letters
            rest /= letters
        }
        try run(sequence)
    }
}

/// An owner thread, as the model sees it: an identity and nothing more.
private final class RoutingThread {}

private typealias ThreadID = ObjectIdentifier

private func address(_ wake: Waker) -> ObjectIdentifier { ObjectIdentifier(wake) }

private enum Outcome: Equatable, CustomStringConvertible {
    case attached
    /// The attach replaced this engine, whose teardown is now running.
    case replacing(engine: UInt32)
    case refused
    case ran(engine: UInt32, wake: ObjectIdentifier)
    case queued(wake: ObjectIdentifier)
    case drained(ran: [UInt32], dropped: [UInt32])
    case closed(jobs: [UInt32], engine: UInt32?)
    /// Parked behind a running teardown, to finish when it does.
    case blocked
    /// That thread is inside a teardown or parked, so it can't do anything else.
    case skipped

    var description: String {
        switch self {
        case .attached: return "Attached"
        case .replacing(let e): return "Replacing{engine: \(e)}"
        case .refused: return "Refused"
        case .ran(let e, let w): return "Ran{engine: \(e), wake: \(w.hashValue)}"
        case .queued(let w): return "Queued{wake: \(w.hashValue)}"
        case .drained(let r, let d): return "Drained{ran: \(r), dropped: \(d)}"
        case .closed(let j, let e): return "Closed{jobs: \(j), engine: \(e.map(String.init) ?? "nil")}"
        case .blocked: return "Blocked"
        case .skipped: return "Skipped"
        }
    }
}

/// An engine's number is also the generation of the host that installed it.
private enum Op {
    case attach(Waker, UInt32)
    case call(UInt32)
    case drain
    case close
    case releaseEngine(UInt32)

    var isCall: Bool {
        if case .call = self { return true }
        return false
    }
}

/// Teardowns still running, oldest first, each with the wake and generation of the attach it
/// holds up, the operations parked behind them, and each thread's guard, by its generation. A
/// thread's later attach takes the place of its guard here, and the guard it replaced never
/// closes.
private struct Schedule {
    var teardowns: [(thread: ThreadID, attaching: (wake: Waker, host: UInt32)?)] = []
    var parked: [(thread: ThreadID, op: Op)] = []
    var guards: [ThreadID: UInt32] = [:]

    func busy(_ thread: ThreadID) -> Bool {
        teardowns.contains { $0.thread == thread } || parked.contains { $0.thread == thread }
    }

    func view() -> [[ThreadID]] {
        [teardowns.map(\.thread), parked.map(\.thread)]
    }
}

private struct EngineEntry: Equatable {
    let thread: ThreadID
    let engine: UInt32
}

/// Who owns the service, its wake, its waiting jobs, the Linux engine and the per-thread ones.
private struct RouteView: Equatable {
    let owner: ThreadID?
    let wake: ObjectIdentifier?
    let jobs: [UInt32]
    let engine: UInt32?
    let engines: [EngineEntry]
}

private func sorted(_ engines: [ThreadID: UInt32]) -> [EngineEntry] {
    engines.map { EngineEntry(thread: $0.key, engine: $0.value) }.sorted { $0.engine < $1.engine }
}

/// One side of the comparison, split where the real code can block.
private protocol RoutingModel: AnyObject {
    var schedule: Schedule { get set }
    func attach(_ thread: ThreadID, _ wake: Waker, _ engine: UInt32) throws -> Outcome
    /// The routing half of an attach by the host of generation `host`, which runs once any
    /// replaced engine is gone.
    func finishAttach(_ thread: ThreadID, _ wake: Waker, _ host: UInt32) throws
    func call(_ thread: ThreadID, _ job: UInt32) throws -> Outcome
    /// A drain by the thread's guard, of generation `host`.
    func drain(_ thread: ThreadID, _ host: UInt32) -> Outcome
    /// The close of the thread's guard, of generation `host`.
    func close(_ thread: ThreadID, _ host: UInt32) -> Outcome
    /// The engine half of a close on Linux.
    func releaseEngine(_ thread: ThreadID, _ host: UInt32) -> Outcome
    func view() -> RouteView
}

private func perform(_ model: some RoutingModel, _ thread: ThreadID, _ op: Op) throws -> Outcome {
    switch op {
    case let .attach(wake, engine):
        let outcome = try model.attach(thread, wake, engine)
        // A parked attach hasn't installed yet; it gets its guard when it does.
        if outcome != .blocked { model.schedule.guards[thread] = engine }
        return outcome
    case .call(let job):
        return try model.call(thread, job)
    case .drain:
        guard let host = model.schedule.guards[thread] else {
            throw ShortcutWalkFailure(description: "only a thread with a guard drains")
        }
        return model.drain(thread, host)
    case .close:
        guard let host = model.schedule.guards.removeValue(forKey: thread) else {
            throw ShortcutWalkFailure(description: "only a thread with a guard closes")
        }
        return model.close(thread, host)
    case .releaseEngine(let host):
        return model.releaseEngine(thread, host)
    }
}

/// The oldest teardown ends. A parked caller holds the routing lock, so it runs before the
/// attach that teardown held up can finish.
private func finishTeardown(_ model: some RoutingModel) throws -> [Outcome] {
    if model.schedule.teardowns.isEmpty { return [.skipped] }
    let (thread, attaching) = model.schedule.teardowns.removeFirst()
    let parked = model.schedule.parked
    model.schedule.parked = []
    let calls = parked.filter { $0.op.isCall }
    let others = parked.filter { !$0.op.isCall }
    var outcomes = try calls.map { try perform(model, $0.thread, $0.op) }
    if let attaching { try model.finishAttach(thread, attaching.wake, attaching.host) }
    outcomes.append(contentsOf: try others.map { try perform(model, $0.thread, $0.op) })
    return outcomes
}

// The routing as it was: Routing's fields, the Linux engine slot and the thread-local engines,
// with the current thread passed in and a job as a number. A running teardown on Linux holds
// the slot's lock.
private struct OldRouting {
    var owner: ThreadID?
    var wake: Waker?
    var jobs: [UInt32] = []
    // differs from dev: routing names the generation of the host it routes to.
    var host: UInt32?
}

/// `leftNewer` and `leftCalls` note that a marked departure took effect.
private final class OldControl: RoutingModel {
    var routing = OldRouting()
    var engine: UInt32?
    var engines: [ThreadID: UInt32] = [:]
    let linux: Bool
    var schedule = Schedule()
    var leftNewer = false
    var leftCalls = false

    init(linux: Bool) { self.linux = linux }

    var slotLocked: Bool { linux && !schedule.teardowns.isEmpty }

    func attach(_ thread: ThreadID, _ wake: Waker, _ engine: UInt32) throws -> Outcome {
        if slotLocked { schedule.parked.append((thread, .attach(wake, engine))); return .blocked }
        let replaced: UInt32?
        if linux {
            replaced = self.engine
            self.engine = engine
        } else {
            replaced = engines.updateValue(engine, forKey: thread)
        }
        if let replaced {
            schedule.teardowns.append((thread, (wake, engine)))
            return .replacing(engine: replaced)
        }
        try finishAttach(thread, wake, engine)
        return .attached
    }

    func finishAttach(_ thread: ThreadID, _ wake: Waker, _ host: UInt32) throws {
        routing.owner = thread
        routing.wake = wake
        routing.host = host
    }

    func call(_ thread: ThreadID, _ job: UInt32) throws -> Outcome {
        if linux {
            if routing.owner == nil { return .refused }
            if slotLocked { schedule.parked.append((thread, .call(job))); return .blocked }
            guard let engine else { return .refused }
            return .ran(engine: engine, wake: address(routing.wake!))
        }
        guard let owner = routing.owner else { return .refused }
        if owner == thread {
            let wake = routing.wake
            guard let engine = engines[thread] else { return .refused }
            return .ran(engine: engine, wake: address(wake!))
        }
        routing.jobs.append(job)
        return .queued(wake: address(routing.wake!))
    }

    func drain(_ thread: ThreadID, _ host: UInt32) -> Outcome {
        if linux { return .drained(ran: [], dropped: []) }
        // differs from dev: only the routed host takes the waiting calls; another leaves them.
        if routing.host != host {
            leftCalls = leftCalls || !routing.jobs.isEmpty
            return .drained(ran: [], dropped: [])
        }
        let jobs = routing.jobs
        routing.jobs = []
        // differs from dev: they run on the drainer's engine only if its own host installed it.
        return engines[thread] == host ? .drained(ran: jobs, dropped: []) : .drained(ran: [], dropped: jobs)
    }

    func close(_ thread: ThreadID, _ host: UInt32) -> Outcome {
        let route = routing
        routing = OldRouting()
        if linux {
            if slotLocked { schedule.parked.append((thread, .releaseEngine(host))); return .blocked }
            return releaseEngine(thread, host)
        }
        // differs from dev: a close takes only the engine its own host installed.
        let engine = engines[thread] == host ? engines.removeValue(forKey: thread) : nil
        if engine != nil { schedule.teardowns.append((thread, nil)) }
        return .closed(jobs: route.jobs, engine: engine)
    }

    func releaseEngine(_ thread: ThreadID, _ host: UInt32) -> Outcome {
        if slotLocked { schedule.parked.append((thread, .releaseEngine(host))); return .blocked }
        // differs from dev: a close takes only the engine its own host installed, never a newer one.
        var engine: UInt32? = nil
        if self.engine == host {
            engine = self.engine
            self.engine = nil
        }
        leftNewer = leftNewer || (engine == nil && self.engine != nil)
        if engine != nil { schedule.teardowns.append((thread, nil)) }
        return .closed(jobs: [], engine: engine)
    }

    func view() -> RouteView {
        RouteView(owner: routing.owner, wake: routing.wake.map(address), jobs: routing.jobs, engine: engine, engines: sorted(engines))
    }
}

/// The machine with the glue `ShortcutGuard` and `ShortcutControl` wrap around it.
private final class NewControl: RoutingModel {
    var attachment: ShortcutAttachmentState<UInt32> = .detached
    var engine: UInt32?
    var slotWake: Waker?
    var engines: [ThreadID: UInt32] = [:]
    let linux: Bool
    var schedule = Schedule()

    init(linux: Bool) { self.linux = linux }

    var slotLocked: Bool { linux && !schedule.teardowns.isEmpty }

    func attach(_ thread: ThreadID, _ wake: Waker, _ engine: UInt32) throws -> Outcome {
        if slotLocked { schedule.parked.append((thread, .attach(wake, engine))); return .blocked }
        let replaced: UInt32?
        if linux {
            // differs from dev: the wake travels with the engine's slot, so a call that reaches a
            // newer engine wakes its host, not the host routing still names.
            slotWake = wake
            replaced = self.engine
            self.engine = engine
        } else {
            replaced = engines.updateValue(engine, forKey: thread)
        }
        if let replaced {
            schedule.teardowns.append((thread, (wake, engine)))
            return .replacing(engine: replaced)
        }
        try finishAttach(thread, wake, engine)
        return .attached
    }

    func finishAttach(_ thread: ThreadID, _ wake: Waker, _ host: UInt32) throws {
        let own = address(wake)
        // differs from dev: a host that inherits waiting calls is woken for them.
        for effect in stepShortcutAttachment(&attachment, event: .attach(owner: thread, wake: wake, host: UInt64(host))) {
            guard case .wake(let woken) = effect, address(woken) == own else {
                throw ShortcutWalkFailure(description: "an attach only wakes the host it routes to")
            }
        }
    }

    func call(_ thread: ThreadID, _ job: UInt32) throws -> Outcome {
        switch stepShortcutAttachment(&attachment, event: .call(from: thread, shared: linux)).first {
        case .run(let wake):
            if slotLocked { schedule.parked.append((thread, .call(job))); return .blocked }
            guard let engine = linux ? self.engine : engines[thread] else { return .refused }
            // differs from dev: routing's wake only says a call may run; the engine's slot names
            // the host it wakes.
            let woken: Waker
            if linux {
                guard let slotWake else { throw ShortcutWalkFailure(description: "an engine in the slot has a host") }
                woken = slotWake
            } else {
                woken = wake
            }
            return .ran(engine: engine, wake: address(woken))
        case .wait:
            guard case .wake(let wake) = stepShortcutAttachment(&attachment, event: .post(job)).first else {
                throw ShortcutWalkFailure(description: "a posted job wakes the owner")
            }
            return .queued(wake: address(wake))
        default:
            return .refused
        }
    }

    func drain(_ thread: ThreadID, _ host: UInt32) -> Outcome {
        if linux { return .drained(ran: [], dropped: []) }
        guard case .jobs(let jobs) = stepShortcutAttachment(&attachment, event: .drain(host: UInt64(host))).first else {
            return .drained(ran: [], dropped: [])
        }
        // The routed host's thread holds its engine.
        return engines[thread] == host ? .drained(ran: jobs, dropped: []) : .drained(ran: [], dropped: jobs)
    }

    func close(_ thread: ThreadID, _ host: UInt32) -> Outcome {
        var released: [UInt32] = []
        for effect in stepShortcutAttachment(&attachment, event: .close) {
            if case .release(let jobs) = effect { released = jobs }
        }
        if linux { return releaseEngine(thread, host) }
        let engine = engines[thread] == host ? engines.removeValue(forKey: thread) : nil
        if engine != nil { schedule.teardowns.append((thread, nil)) }
        return .closed(jobs: released, engine: engine)
    }

    func releaseEngine(_ thread: ThreadID, _ host: UInt32) -> Outcome {
        if slotLocked { schedule.parked.append((thread, .releaseEngine(host))); return .blocked }
        // Only the engine this host installed, with the wake that travels with it.
        if self.engine != host { return .closed(jobs: [], engine: nil) }
        let engine = self.engine
        self.engine = nil
        slotWake = nil
        schedule.teardowns.append((thread, nil))
        return .closed(jobs: [], engine: engine)
    }

    func view() -> RouteView {
        let engines = sorted(self.engines)
        switch attachment {
        case let .attached(owner, wake, _, jobs):
            return RouteView(owner: owner, wake: address(wake), jobs: jobs, engine: engine, engines: engines)
        case .detached, .closed:
            return RouteView(owner: nil, wake: nil, jobs: [], engine: engine, engines: engines)
        }
    }
}

/// The outcomes in order, allowing only the marked wake departure: the same engine ran the call,
/// and the wake names the host whose engine the slot holds.
private func assertOutcomes(_ old: [Outcome], _ new: [Outcome], linux: Bool, at: @autoclosure () -> String) throws -> Bool {
    try shortcutWalkRequire(new.count == old.count, "\(at()): \(new) vs \(old)")
    var departed = false
    for (newOutcome, oldOutcome) in zip(new, old) {
        if case let .ran(a, aWake) = oldOutcome, case let .ran(b, bWake) = newOutcome {
            try shortcutWalkRequire(a == b, "the same engine ran the call: \(at())")
            if aWake != bWake {
                try shortcutWalkRequire(linux, "a wake moved between owner threads: \(at())")
                departed = true
                continue
            }
        }
        try shortcutWalkRequire(newOutcome == oldOutcome, "\(at()): \(newOutcome) vs \(oldOutcome)")
    }
    return departed
}

/// Letters 0..<8 are Attach, Call, Drain and Close from either thread; 8 ends the oldest teardown.
/// Only a thread with a guard drains or closes.
private func play(_ model: some RoutingModel, _ letter: Int, _ threads: [ThreadID], _ wakes: [Waker], _ number: UInt32) throws -> [Outcome] {
    if letter == 8 { return try finishTeardown(model) }
    let thread = threads[letter % 2]
    if model.schedule.busy(thread) { return [.skipped] }
    let op: Op
    switch letter / 2 {
    case 0: op = .attach(wakes[letter % 2], number)
    case 1: op = .call(number)
    case 2: op = .drain
    default: op = .close
    }
    switch op {
    case .drain, .close:
        if model.schedule.guards[thread] == nil { return [.skipped] }
    default:
        break
    }
    return [try perform(model, thread, op)]
}

/// Plays `steps` through both models, each letter with the outcomes given, and returns who
/// routing names at the end.
private func script(linux: Bool, _ steps: [(Int, [Outcome])], _ threads: [ThreadID], _ wakes: [Waker]) throws -> ThreadID? {
    let old = OldControl(linux: linux)
    let new = NewControl(linux: linux)
    for (n, (letter, expected)) in steps.enumerated() {
        let number = UInt32(n + 1)
        let oldSeen = try play(old, letter, threads, wakes, number)
        try shortcutWalkRequire(oldSeen == expected, "linux \(linux), the old routing at \(n): \(oldSeen) vs \(expected)")
        let newSeen = try play(new, letter, threads, wakes, number)
        try shortcutWalkRequire(newSeen == expected, "linux \(linux), the new routing at \(n): \(newSeen) vs \(expected)")
        try shortcutWalkRequire(new.view() == old.view(), "linux \(linux) at \(n)")
    }
    return new.view().owner
}

@Suite("Shortcut routing walks (`shortcuts/service/routing_tests.rs`, r410)", .serialized)
struct ShortcutRoutingWalkTests {
    private let threadTokens = [RoutingThread(), RoutingThread()]
    private var threads: [ThreadID] { threadTokens.map(ObjectIdentifier.init) }

    /// The cases a host generation must leave as they were: the newest host's close takes its own
    /// engine, the routed host runs the calls waiting for it, and any close still ends routing and
    /// releases those calls.
    @Test("the_newest_hosts_close_and_drain_and_any_close_ending_routing_stay_as_they_were (`routing_tests.rs:353`)")
    func theNewestHostsCloseAndDrainAndAnyCloseEndingRoutingStayAsTheyWere() throws {
        let threads = self.threads
        let wakes = [Waker {}, Waker {}]
        let (w0, w1) = (address(wakes[0]), address(wakes[1]))
        // Off Linux: the owner drains a call from the other thread, then closes and takes its engine.
        var routed = try script(linux: false, [
            (0, [.attached]),
            (3, [.queued(wake: w0)]),
            (4, [.drained(ran: [2], dropped: [])]),
            (6, [.closed(jobs: [], engine: 1)]),
            (8, []),
        ], threads, wakes)
        #expect(routed == nil)
        // The routed host drains the call that waits for it, though another host attached first.
        routed = try script(linux: false, [
            (0, [.attached]),
            (1, [.attached]),
            (2, [.queued(wake: w1)]),
            (5, [.drained(ran: [3], dropped: [])]),
        ], threads, wakes)
        #expect(routed == threads[1])
        // A replaced host's close still ends routing and releases its successor's waiting caller.
        routed = try script(linux: false, [
            (0, [.attached]),
            (1, [.attached]),
            (2, [.queued(wake: w1)]),
            (6, [.closed(jobs: [3], engine: 1)]),
            (3, [.refused]),
        ], threads, wakes)
        #expect(routed == nil)
        // On Linux: a lone host's close takes its engine.
        routed = try script(linux: true, [
            (0, [.attached]),
            (2, [.ran(engine: 1, wake: w0)]),
            (6, [.closed(jobs: [], engine: 1)]),
            (8, []),
        ], threads, wakes)
        #expect(routed == nil)
        // The newest host's close takes its own engine, once the one it replaced has gone.
        routed = try script(linux: true, [
            (0, [.attached]),
            (1, [.replacing(engine: 1)]),
            (8, []),
            (7, [.closed(jobs: [], engine: 2)]),
            (8, []),
            (2, [.refused]),
        ], threads, wakes)
        #expect(routed == nil)
    }

    @Test("every_attachment_sequence_matches_the_old_routing (`routing_tests.rs:405`)")
    func everyAttachmentSequenceMatchesTheOldRouting() throws {
        let threads = self.threads
        let wakes = [Waker {}, Waker {}]
        var (departed, leftNewer, leftCalls) = (false, false, false)
        for linux in [false, true] {
            try everyShortcutSequence(letters: 9, length: 6) { sequence in
                let old = OldControl(linux: linux)
                let new = NewControl(linux: linux)
                for (n, letter) in sequence.enumerated() {
                    let number = UInt32(n + 1)
                    let expected = try play(old, letter, threads, wakes, number)
                    let actual = try play(new, letter, threads, wakes, number)
                    let at = { "linux \(linux), \(sequence) at \(n)" }
                    if try assertOutcomes(expected, actual, linux: linux, at: at()) { departed = true }
                    try shortcutWalkRequire(new.view() == old.view(), at())
                    try shortcutWalkRequire(new.schedule.view() == old.schedule.view(), at())
                    if linux && actual.contains(where: { if case .ran = $0 { return true }; return false }) {
                        try shortcutWalkRequire(new.schedule.teardowns.isEmpty, "a call reached an engine during a teardown: \(sequence) at \(n)")
                    }
                }
                leftNewer = leftNewer || old.leftNewer
                leftCalls = leftCalls || old.leftCalls
            }
        }
        #expect(departed, "the walk never saw a call that reached the engine a newer host installed")
        #expect(leftNewer, "the walk never saw a replaced host's close leave the newer engine")
        #expect(leftCalls, "the walk never saw a replaced host's drain leave the calls to the routed host")
    }
}
