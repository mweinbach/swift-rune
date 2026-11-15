import Foundation
import Testing
@testable import Rune

// Two hosts overlapping, and calls stopped partway through an engine. Three sides play each
// sequence: the code as it was, that code with the marked departure, and the new code. The new
// code must match the marked reference at every event, and the reference must match the old
// code up to the event where the departure first shows (`shortcuts/service/machine_tests.rs`,
// r410). Every side gets its own claim list here, where upstream shares process statics.

private let overlapChord = try! ParsedShortcut.parseOn("ctrl+alt+shift+f18", platform: .mac)
private let overlapID: UInt32 = 0x5000_0000

private let staleClaim = "a replaced engine nobody is using kept its claim"
private let staleConflict = "a conflict came from an engine nobody is using"
private let grabWithoutOwner = "a live engine holds a chord with no owner on record"
private let ownerWithoutGrab = "an owner is on record for a chord no live engine holds"
private let wakeLetsGo = "a call in its wake no longer keeps the engine's claims"
private let staleCloseKeeps = "a replaced host's close left the newer host's engine and handlers"

/// `ShortcutError` as the walks compare it: upstream's `Conflict` carries no owner, and its
/// `Backend` error is the port's `rejectedByOS`.
private enum Answer: Equatable {
    case ok
    case conflict
    case unknownId
    case backend(String)
    case notRunning
    case other(String)

    init(_ result: Result<Void, ShortcutError>) {
        switch result {
        case .success: self = .ok
        case .failure(.alreadyInUse), .failure(.conflict): self = .conflict
        case .failure(.unknownId): self = .unknownId
        case .failure(.rejectedByOS(let why)): self = .backend(why)
        case .failure(.notRunning): self = .notRunning
        case .failure(let error): self = .other("\(error)")
        }
    }
}

private enum Seen: Equatable {
    case skipped
    case done
    case parked
    case answer(Answer)
}

/// The backend's scripted answers (`machine_tests.rs::Rig`).
private final class OverlapRig: @unchecked Sendable {
    var connect: Result<Void, ShortcutError> = .success(())
    var register: Result<Void, ShortcutError> = .success(())
    var unregister: Result<Void, ShortcutError> = .success(())

    /// Runs `body` with one script, then clears the script (`machine_tests.rs::scripted`).
    func scripted<T>(register: Result<Void, ShortcutError>, unregister: Result<Void, ShortcutError>, _ body: () -> T) -> T {
        self.connect = .success(())
        self.register = register
        self.unregister = unregister
        let result = body()
        self.connect = .success(())
        self.register = .success(())
        self.unregister = .success(())
        return result
    }
}

private final class ScriptedDriver: ShortcutBackendDriver {
    let rig: OverlapRig
    init(_ rig: OverlapRig) { self.rig = rig }
    func register(id: UInt32, shortcut: ParsedShortcut) -> Result<Void, ShortcutError> { rig.register }
    func unregister(id: UInt32) -> Result<Void, ShortcutError> { rig.unregister }
}

/// The old engine's process-wide claim list (`OLD_NATIVE`).
private final class OldNative {
    var list: [(id: UInt32, shortcut: ParsedShortcut, title: String)] = []

    func overlapClaims() -> [UInt32] {
        list.filter { $0.shortcut == overlapChord }.map(\.id).sorted()
    }
}

private protocol OverlapEngine: AnyObject {
    func add(_ id: UInt32) -> Result<Void, ShortcutError>
    func remove(_ id: UInt32) -> Result<Void, ShortcutError>
    func held() -> [UInt32]
    func close()
}

/// The engine as it was, with the backend behind a field and its own process-wide list.
private final class OldEngine: OverlapEngine {
    let title = "Overlap"
    let rig: OverlapRig
    let native: OldNative
    var backend: ScriptedDriver?
    var registrations: [UInt32: ParsedShortcut] = [:]

    init(rig: OverlapRig, native: OldNative) {
        self.rig = rig
        self.native = native
    }

    func register(_ id: UInt32, _ shortcut: ParsedShortcut) -> Result<Void, ShortcutError> {
        if registrations.values.contains(shortcut) { return .failure(.alreadyInUse(owner: nil)) }
        // Another App in this process holds it; some backends (the portal) wouldn't refuse.
        if native.list.contains(where: { $0.shortcut == shortcut }) { return .failure(.alreadyInUse(owner: nil)) }
        if backend == nil {
            switch rig.connect {
            case .success: backend = ScriptedDriver(rig)
            case .failure(let error): return .failure(error)
            }
        }
        if case .failure(let error) = backend!.register(id: id, shortcut: shortcut) {
            if registrations.isEmpty { backend = nil }
            return .failure(error)
        }
        native.list.append((id, shortcut, title))
        registrations[id] = shortcut
        return .success(())
    }

    func unregister(_ id: UInt32) -> Result<Void, ShortcutError> {
        if registrations[id] == nil { return .failure(.unknownId("\(id)")) }
        if let backend, case .failure(let error) = backend.unregister(id: id) { return .failure(error) }
        registrations.removeValue(forKey: id)
        native.list.removeAll { $0.id == id }
        // Drop the connection/listener when the last registration goes away.
        if registrations.isEmpty { backend = nil }
        return .success(())
    }

    func release() {
        backend = nil
        native.list.removeAll { registrations[$0.id] != nil }
        registrations.removeAll()
    }

    deinit { release() }

    func add(_ id: UInt32) -> Result<Void, ShortcutError> { register(id, overlapChord) }
    func remove(_ id: UInt32) -> Result<Void, ShortcutError> { unregister(id) }
    func held() -> [UInt32] { Array(registrations.keys) }
    func close() { release() }
}

extension ShortcutServiceEngine: OverlapEngine {
    fileprivate func add(_ id: UInt32) -> Result<Void, ShortcutError> { register(id: id, shortcut: overlapChord) }
    fileprivate func remove(_ id: UInt32) -> Result<Void, ShortcutError> { unregister(id: id) }
    fileprivate func held() -> [UInt32] {
        switch bindings {
        case .virtual(let registrations), .connected(_, let registrations): return Array(registrations.keys)
        case .disconnected: return []
        }
    }
    fileprivate func close() { release() }
}

private enum Waiter {
    case register(UInt32)
    case unregister(UInt32)
}

/// What every side shares: the hosts, the slot, the handlers and the stopped calls.
private final class Stage<E: OverlapEngine> {
    let fresh: () -> E
    var attached = false
    var open = [false, false]
    var slot: E?
    var handlers = Set<UInt32>()
    /// A call is stopped in its wake, past the engine.
    var inWake = false
    /// What that call still holds.
    var held: E?
    /// A call stopped inside the engine, holding its lock.
    var inside: E?
    /// A call parked on the engine's lock, holding the routing lock.
    var waiting: (engine: E, waiter: Waiter)?
    /// A host whose engine is in the slot but whose attach waits for that routing lock.
    var pending: Int?
    /// The host that installed last, whose engine the slot holds until its close takes it.
    var newest: Int?
    var next: UInt32 = overlapID
    var latest: UInt32?
    /// The first registration this host made, which a successor never sees again.
    var first: UInt32?
    var broken: [String] = []

    init(fresh: @escaping () -> E) { self.fresh = fresh }

    func slotHeld() -> [UInt32] { slot?.held() ?? [] }

    func slotIsInside() -> Bool {
        if let slot, let inside { return slot === inside }
        return false
    }

    /// Every engine something still keeps alive.
    func alive() -> [E] {
        [slot, held, inside, waiting?.engine].compactMap { $0 }
    }

    /// A call reaches `engine`, and the caller lets go of it.
    func finish(_ engine: E, _ waiter: Waiter) -> Seen {
        let onSlot = slot.map { $0 === engine } ?? false
        let result: Result<Void, ShortcutError>
        switch waiter {
        case .register(let id): result = engine.add(id)
        case .unregister(let id): result = engine.remove(id)
        }
        let answer = Answer(result)
        switch (waiter, answer) {
        case (.register(let id), .ok):
            latest = id
            if first == nil { first = id }
        case (.register(let id), _):
            handlers.remove(id)
            if answer == .conflict && onSlot && slotHeld().isEmpty && inside == nil { broken.append(staleConflict) }
        case (.unregister(let id), .ok):
            handlers.remove(id)
        case (.unregister, _):
            break
        }
        return .answer(answer)
    }

    func call(_ waiter: Waiter) -> Seen {
        guard attached, let engine = slot else {
            if case .register(let id) = waiter { handlers.remove(id) }
            return .answer(.notRunning)
        }
        if slotIsInside() {
            waiting = (engine, waiter)
            return .parked
        }
        return finish(engine, waiter)
    }

    func register() -> Seen {
        if waiting != nil { return .skipped }
        next += 1
        handlers.insert(next)
        return call(.register(next))
    }

    func unregister() -> Seen {
        guard let id = latest, waiting == nil else { return .skipped }
        return call(.unregister(id))
    }

    /// Unregisters the first chord this host registered, which the successor no longer has.
    func unregisterFirst() -> Seen {
        guard let id = first, waiting == nil else { return .skipped }
        return call(.unregister(id))
    }

    /// The engine goes in the slot under the slot's own lock; the attach then waits for routing.
    func attach(_ host: Int) -> Seen {
        slot = fresh()
        newest = host
        if waiting != nil {
            pending = host
            return .parked
        }
        finishAttach(host)
        return .done
    }

    func finishAttach(_ host: Int) {
        open[host] = true
        attached = true
    }

    /// Any close ends routing. `own`: it also takes the slot's engine and clears the handlers.
    func close(_ host: Int, own: Bool) -> Seen {
        open[host] = false
        attached = false
        if !own { return .done }
        if let engine = slot {
            slot = nil
            engine.close()
        }
        handlers.removeAll()
        return .done
    }

    /// The call inside leaves. A call parked behind it takes the engine and lets go of routing,
    /// and only then can an attach waiting for routing finish.
    func leave() -> Seen {
        inside = nil
        guard let parked = waiting else { return .done }
        waiting = nil
        let seen = finish(parked.engine, parked.waiter)
        if let host = pending {
            pending = nil
            finishAttach(host)
        }
        return seen
    }
}

private protocol Overlap: AnyObject {
    associatedtype E: OverlapEngine
    var stage: Stage<E> { get }
    var rig: OverlapRig { get }
    func stopInWake()
    /// Whether `host`'s close takes the slot's engine and clears the handlers.
    func closesOwn(_ host: Int) -> Bool
    func claims() -> [UInt32]
}

/// The code as it was, or with `departures` the same code plus the marked change.
private final class Reference: Overlap {
    let stage: Stage<OldEngine>
    let departures: Bool
    let native: OldNative
    let rig: OverlapRig

    init(departures: Bool, rig: OverlapRig, native: OldNative) {
        self.departures = departures
        self.rig = rig
        self.native = native
        self.stage = Stage { OldEngine(rig: rig, native: native) }
    }

    func stopInWake() {
        // differs from dev: a call lets go of the engine before its wake.
        if departures { return }
        stage.held = stage.slot
    }

    func closesOwn(_ host: Int) -> Bool {
        // differs from dev: a replaced host's close leaves the newer host's engine and handlers.
        !departures || stage.newest == host
    }

    func claims() -> [UInt32] { native.overlapClaims() }
}

/// The new code around the real engine: a call holds nothing during its wake.
private final class NewOverlap: Overlap {
    let stage: Stage<ShortcutServiceEngine>
    let processClaims: ShortcutProcessClaims
    let rig: OverlapRig

    init(rig: OverlapRig, claims: ShortcutProcessClaims) {
        self.rig = rig
        self.processClaims = claims
        self.stage = Stage {
            ShortcutServiceEngine(
                title: "Overlap",
                wayland: true,
                sink: { _, _ in },
                connect: { _, _ in rig.connect.map { ScriptedDriver(rig) as any ShortcutBackendDriver } },
                bindings: .disconnected,
                claims: claims
            )
        }
    }

    func stopInWake() {}
    /// A guard takes only its own generation's engine, and only the newest host's close clears
    /// the handlers.
    func closesOwn(_ host: Int) -> Bool { stage.newest == host }
    func claims() -> [UInt32] { processClaims.claimedIDs(for: overlapChord).sorted() }
}

/// Letters: 0, 1 attach a host; 2, 3 close one; 4 register the chord; 5 unregister the latest;
/// 6, 7 a call stops in its wake and goes; 8 a call stops inside the engine; 9 it leaves;
/// 10 it leaves and the backend then refuses what was waiting; 11 unregister the first chord.
private func overlapPlay<W: Overlap>(_ world: W, _ letter: Int) -> Seen {
    let own = (letter == 2 || letter == 3) && world.closesOwn(letter - 2)
    let stage = world.stage
    let reachable = stage.attached && stage.slot != nil
    switch letter {
    case 0, 1:
        if stage.open[letter] || stage.pending != nil { return .skipped }
        return stage.attach(letter)
    case 2, 3:
        if !stage.open[letter - 2] || stage.inside != nil || stage.waiting != nil { return .skipped }
        return stage.close(letter - 2, own: own)
    case 4:
        return stage.register()
    case 5:
        return stage.unregister()
    case 6:
        if stage.inWake || !reachable || stage.slotIsInside() || stage.waiting != nil { return .skipped }
        stage.inWake = true
        world.stopInWake()
        return .done
    case 7:
        if !stage.inWake { return .skipped }
        stage.inWake = false
        stage.held = nil
        return .done
    case 8:
        if stage.inside != nil || !reachable || stage.waiting != nil { return .skipped }
        stage.inside = stage.slot
        return .done
    case 9:
        if stage.inside == nil { return .skipped }
        return stage.leave()
    case 10:
        if stage.inside == nil || stage.waiting == nil { return .skipped }
        let broken: Result<Void, ShortcutError> = .failure(.rejectedByOS("refused"))
        return world.rig.scripted(register: broken, unregister: broken) { stage.leave() }
    default:
        return stage.unregisterFirst()
    }
}

private func overlapCheck<W: Overlap>(_ world: W) {
    let claims = world.claims()
    let stage = world.stage
    let live = stage.slotHeld()
    let alive = stage.alive().flatMap { $0.held() }
    if stage.inside == nil && stage.waiting == nil && claims.contains(where: { !live.contains($0) }) { stage.broken.append(staleClaim) }
    if alive.contains(where: { !claims.contains($0) }) { stage.broken.append(grabWithoutOwner) }
    if claims.contains(where: { !alive.contains($0) }) { stage.broken.append(ownerWithoutGrab) }
}

/// `(seen, attached, open, handlers, claims, live, wake)` (`machine_tests.rs::OverlapView`).
private struct OverlapView: Equatable, CustomStringConvertible {
    var seen: Seen
    var attached: Bool
    var open: [Bool]
    var handlers: [UInt32]
    var claims: [UInt32]
    var live: [UInt32]
    var wake: [UInt32]

    var description: String { "(\(seen), \(attached), \(open), \(handlers), \(claims), \(live), \(wake))" }
}

private func overlapView<W: Overlap>(_ world: W, _ seen: Seen) -> OverlapView {
    let stage = world.stage
    // Claims only an engine that a call in its wake alone keeps still holds.
    var wake: [UInt32] = []
    if let held = stage.held, !(stage.slot.map { $0 === held } ?? false) { wake = held.held() }
    return OverlapView(
        seen: seen,
        attached: stage.attached,
        open: stage.open,
        handlers: stage.handlers.sorted(),
        claims: world.claims(),
        live: stage.slotHeld().sorted(),
        wake: wake.sorted()
    )
}

/// What the code as it was does with `sequence`, and which invariants it broke.
private func overlapDevTrace(_ sequence: [Int], _ found: inout Set<String>) throws -> [OverlapView] {
    let native = OldNative()
    var trace: [OverlapView] = []
    do {
        let dev = Reference(departures: false, rig: OverlapRig(), native: native)
        for letter in sequence {
            let seen = overlapPlay(dev, letter)
            overlapCheck(dev)
            trace.append(overlapView(dev, seen))
        }
        found.formUnion(dev.stage.broken)
    }
    try shortcutWalkRequire(native.overlapClaims().isEmpty, "\(sequence)")
    return trace
}

/// The departure the marked reference shows against dev, or nil when they agree. Every event is
/// checked, so a later event that differs for another reason still fails the walk. differs from
/// dev: a call lets go of its engine before its wake, so dev alone still holds the claims of an
/// engine nothing but that call keeps, and every registration those claims refused.
private func approvedDifference(
    _ dev: OverlapView,
    _ want: OverlapView,
    target: UInt32?,
    registering: Bool,
    departed: inout Set<UInt32>,
    kept: Set<UInt32>,
    sequence: [Int],
    n: Int
) throws -> String? {
    if dev == want { return nil }
    let at = "\(sequence) at \(n)\ndev \(dev)\nwant \(want)"
    try shortcutWalkRequire(want.attached == dev.attached && want.open == dev.open, "the hosts agree: \(at)")
    // differs from dev: a replaced host's close leaves the newer host's engine and handlers, so
    // `kept`, what they held then, may still stand where dev's close took it.
    let onlyKept = { (dev: [UInt32], want: [UInt32]) -> Bool in
        dev.allSatisfy { want.contains($0) } && want.allSatisfy { dev.contains($0) || kept.contains($0) }
    }
    if dev.seen == want.seen && dev.wake == want.wake
        && onlyKept(dev.handlers, want.handlers) && onlyKept(dev.claims, want.claims) && onlyKept(dev.live, want.live) {
        return staleCloseKeeps
    }
    // An event that did nothing, stopped in its wake, or parked is not an answer, and must keep
    // its exact kind: only the answers may move under the departure.
    switch (dev.seen, want.seen) {
    case (.answer, .answer): break
    case let (before, after): try shortcutWalkRequire(before == after, "an event kind changed for another reason: \(at)")
    }
    func answer(_ view: OverlapView) -> Answer? {
        if case .answer(let a) = view.seen { return a }
        return nil
    }
    let (before, after) = (answer(dev), answer(want))
    var allowed = departed.union(dev.wake)
    if before != after {
        let succeeded = (before == .conflict || before == .unknownId) && after == .ok
        var backend = false
        if before == .conflict, case .backend = after { backend = true }
        // differs from dev: the chord dev refused while its replaced engine still held it is
        // registered here, so the successor's own duplicate check refuses the one dev took.
        let occupied = before == .ok && after == .conflict
        if occupied {
            let gained = want.live.filter { !dev.live.contains($0) }
            try shortcutWalkRequire(!gained.isEmpty && gained.allSatisfy { departed.contains($0) },
                "a registration was refused with no approved registration holding the chord in \(at)")
            if let target { allowed.insert(target) }
        }
        try shortcutWalkRequire(succeeded || backend || occupied, "an answer changed for another reason: \(String(describing: before)) -> \(String(describing: after)) in \(at)")
        if succeeded {
            guard let id = target else { throw ShortcutWalkFailure(description: "a call that succeeded where dev refused has an id") }
            if registering {
                // Only the claim a call still held in its wake can refuse dev's registration.
                try shortcutWalkRequire(!dev.wake.isEmpty, "a registration succeeded with no wake-held claim: \(at)")
                departed.insert(id)
            } else {
                // An unregister can only succeed where dev lacked the chord if the departure
                // registered it on an earlier event.
                try shortcutWalkRequire(departed.contains(id), "an unregister succeeded where dev never had the chord: \(at)")
            }
        }
    }
    func aside(_ dev: [UInt32], _ want: [UInt32]) -> (lost: [UInt32], gained: [UInt32]) {
        (dev.filter { !want.contains($0) }, want.filter { !dev.contains($0) })
    }
    let (lost, gained) = aside(dev.claims, want.claims)
    try shortcutWalkRequire(lost.allSatisfy { allowed.contains($0) }, "a claim went for another reason in \(at)")
    try shortcutWalkRequire(gained.allSatisfy { departed.contains($0) || kept.contains($0) }, "a claim appeared for another reason in \(at)")
    for (lost, gained) in [aside(dev.handlers, want.handlers), aside(dev.live, want.live)] {
        try shortcutWalkRequire(lost.allSatisfy { allowed.contains($0) }, "a handler or engine entry went for another reason in \(at)")
        try shortcutWalkRequire(gained.allSatisfy { departed.contains($0) || kept.contains($0) }, "a handler or engine entry appeared for another reason in \(at)")
    }
    return wakeLetsGo
}

/// Replays `sequence`. Returns whether its last letter did anything.
private func overlapReplay(_ sequence: [Int], _ found: inout Set<String>, _ fired: inout Set<String>) throws -> Bool {
    let dev = try overlapDevTrace(sequence, &found)
    let native = OldNative()
    let claims = ShortcutProcessClaims()
    var moved = false
    do {
        let rig = OverlapRig()
        let reference = Reference(departures: true, rig: rig, native: native)
        let new = NewOverlap(rig: rig, claims: claims)
        var departed = Set<UInt32>()
        var kept = Set<UInt32>()
        for (n, letter) in sequence.enumerated() {
            try shortcutWalkRequire(new.stage.next == reference.stage.next, "\(sequence) at \(n)")
            let target: UInt32?
            let registering: Bool
            switch letter {
            case 4: (target, registering) = (new.stage.next + 1, true)
            case 5: (target, registering) = (new.stage.latest, false)
            case 9, 10:
                switch new.stage.waiting?.waiter {
                case .register(let id): (target, registering) = (id, true)
                case .unregister(let id): (target, registering) = (id, false)
                case nil: (target, registering) = (nil, false)
                }
            case 11: (target, registering) = (new.stage.first, false)
            default: (target, registering) = (nil, false)
            }
            let expected = overlapPlay(reference, letter)
            let actual = overlapPlay(new, letter)
            if (letter == 2 || letter == 3) && expected == .done && !reference.closesOwn(letter - 2) {
                kept.formUnion(reference.stage.handlers)
                kept.formUnion(reference.stage.slotHeld())
            }
            moved = actual != .skipped
            overlapCheck(new)
            try shortcutWalkRequire(new.stage.broken.isEmpty, "\(new.stage.broken): \(sequence) at \(n)")
            let want = overlapView(reference, expected)
            let got = overlapView(new, actual)
            try shortcutWalkRequire(got == want, "\(sequence) at \(n)\nnew \(got)\nwant \(want)")
            if let departure = try approvedDifference(dev[n], want, target: target, registering: registering, departed: &departed, kept: kept, sequence: sequence, n: n) {
                fired.insert(departure)
            }
        }
    }
    try shortcutWalkRequire(claims.claimedIDs(for: overlapChord).isEmpty && native.overlapClaims().isEmpty, "\(sequence)")
    return moved
}

private func overlapWalk(_ sequence: inout [Int], depth: Int, _ found: inout Set<String>, _ fired: inout Set<String>) throws {
    for letter in 0..<12 {
        sequence.append(letter)
        if try overlapReplay(sequence, &found, &fired) && sequence.count < depth {
            try overlapWalk(&sequence, depth: depth, &found, &fired)
        }
        sequence.removeLast()
    }
}

@Suite("Shortcut overlap walks (`shortcuts/service/machine_tests.rs`, r410)", .serialized)
struct ShortcutOverlapWalkTests {
    @Test("an_attach_waits_for_a_call_parked_on_routing (`machine_tests.rs:749`)")
    func anAttachWaitsForACallParkedOnRouting() {
        let rig = OverlapRig()
        let native = OldNative()
        let claims = ShortcutProcessClaims()
        do {
            let dev = Reference(departures: false, rig: rig, native: native)
            let new = NewOverlap(rig: rig, claims: claims)
            // Attach A, a call stops inside A's engine, a registration parks behind it, B attaches, the
            // call inside leaves.
            let script: [(Int, Seen)] = [(0, .done), (8, .done), (4, .parked), (1, .parked), (9, .answer(.ok))]
            for (n, (letter, expected)) in script.enumerated() {
                let (devSeen, newSeen) = (overlapPlay(dev, letter), overlapPlay(new, letter))
                #expect(devSeen == expected && newSeen == expected, "event \(n)")
                #expect(overlapView(new, newSeen) == overlapView(dev, devSeen), "event \(n)")
                if n == 3 {
                    #expect(dev.stage.attached && dev.stage.open == [true, false], "B waits while the parked call holds routing")
                }
            }
            // The parked call ran on A's engine, which still holds the chord, and then B took over.
            #expect(dev.stage.attached && dev.stage.open == [true, true], "B takes over once the call lets go of routing")
        }
    }

    @Test("a_parked_unregister_finishes_on_the_engine_it_captured_and_the_successor_forgets_it (`machine_tests.rs:770`)")
    func aParkedUnregisterFinishesOnTheEngineItCapturedAndTheSuccessorForgetsIt() {
        let rig = OverlapRig()
        let native = OldNative()
        let claims = ShortcutProcessClaims()
        do {
            let dev = Reference(departures: false, rig: rig, native: native)
            let new = NewOverlap(rig: rig, claims: claims)
            // The parked unregister answers Ok on the engine that captured the chord; B never had it.
            let script: [(Int, Seen)] = [(0, .done), (4, .answer(.ok)), (8, .done), (5, .parked), (1, .parked), (9, .answer(.ok)), (11, .answer(.unknownId))]
            for (n, (letter, expected)) in script.enumerated() {
                let (devSeen, newSeen) = (overlapPlay(dev, letter), overlapPlay(new, letter))
                #expect(devSeen == expected && newSeen == expected, "event \(n)")
                #expect(overlapView(new, newSeen) == overlapView(dev, devSeen), "event \(n)")
            }
            #expect(new.stage.open == [true, true], "B attaches once the parked call lets go of routing")
            #expect(new.stage.handlers.isEmpty, "both hosts forgot the chord")
        }
    }

    /// The closes a host generation must leave as they were: the newest host's close takes its own
    /// engine and handlers, and any close ends routing.
    @Test("the_newest_hosts_close_and_any_close_ending_routing_stay_as_they_were (`machine_tests.rs:791`)")
    func theNewestHostsCloseAndAnyCloseEndingRoutingStayAsTheyWere() {
        let scripts: [[Int]] = [[0, 4, 2], [0, 1, 4, 3], [0, 4, 1, 4, 3, 2]]
        for script in scripts {
            let rig = OverlapRig()
            let dev = Reference(departures: false, rig: rig, native: OldNative())
            let new = NewOverlap(rig: rig, claims: ShortcutProcessClaims())
            for (n, letter) in script.enumerated() {
                let (devSeen, newSeen) = (overlapPlay(dev, letter), overlapPlay(new, letter))
                #expect(newSeen != .skipped, "\(script) at \(n)")
                #expect(overlapView(new, newSeen) == overlapView(dev, devSeen), "\(script) at \(n)")
            }
            #expect(!new.stage.attached && new.stage.slot == nil, "the close took its own engine: \(script)")
            #expect(new.stage.handlers.isEmpty && new.claims().isEmpty, "and cleared its handlers and claims: \(script)")
        }
        // A replaced host's close still ends routing, whoever holds it.
        let new = NewOverlap(rig: OverlapRig(), claims: ShortcutProcessClaims())
        for letter in [0, 1, 2] { #expect(overlapPlay(new, letter) == .done) }
        #expect(!new.stage.attached && new.stage.open == [false, true], "routing ended")
        #expect(overlapPlay(new, 4) == .answer(.notRunning), "a call after it is refused")
    }

    @Test("a_walk_difference_needs_the_marked_departure (`machine_tests.rs:818`)")
    func aWalkDifferenceNeedsTheMarkedDeparture() {
        func view(_ seen: Seen) -> OverlapView {
            OverlapView(seen: seen, attached: true, open: [false, false], handlers: [], claims: [], live: [], wake: [])
        }
        func rejected(_ dev: OverlapView, _ want: OverlapView, _ registering: Bool) -> Bool {
            var departed = Set<UInt32>()
            do {
                _ = try approvedDifference(dev, want, target: 7, registering: registering, departed: &departed, kept: [], sequence: [], n: 0)
                return false
            } catch {
                return true
            }
        }
        #expect(rejected(view(.done), view(.parked), false), "a parked event is not a completed one")
        #expect(rejected(view(.answer(.conflict)), view(.answer(.ok)), true), "a registration with no wake-held claim is not the departure")
    }

    @Test("every_overlap_sequence_differs_from_dev_only_at_its_marked_departure (`machine_tests.rs:827`)")
    func everyOverlapSequenceDiffersFromDevOnlyAtItsMarkedDeparture() throws {
        var found = Set<String>()
        var fired = Set<String>()
        var sequence: [Int] = []
        try overlapWalk(&sequence, depth: 7, &found, &fired)
        for invariant in [staleClaim, staleConflict] {
            #expect(found.contains(invariant), "the walk never saw the old code break this, so it proves nothing: \(invariant)")
        }
        #expect(fired.contains(wakeLetsGo), "the departure never took effect")
        #expect(fired.contains(staleCloseKeeps), "a replaced host's close never left the newer host's engine")
    }
}
