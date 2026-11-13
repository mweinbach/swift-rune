import Foundation
import Testing
@testable import Rune

/// Full 1:1 port of upstream `crates/rune/src/latest/tests.rs` (all 21 `#[test]`s).
@Suite("Latest Full Parity Tests (21/21)", .serialized)
struct LatestFullParityTests {

    private final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count: Int = 0

        @discardableResult
        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }

        func store(_ value: Int) {
            lock.lock()
            count = value
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private final class LockedList<Element: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Element] = []

        func append(_ item: Element) {
            lock.lock()
            items.append(item)
            lock.unlock()
        }

        var snapshot: [Element] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    private final class Gate: @unchecked Sendable {
        private let started = AtomicCounter()
        private let semaphore = DispatchSemaphore(value: 0)

        func makeWork() -> (@Sendable () -> Void) {
            let started = self.started
            let semaphore = self.semaphore
            return {
                started.store(1)
                semaphore.wait()
            }
        }

        func waitStarted() {
            LatestFullParityTests.eventually("the work starts") { started.value == 1 }
        }

        func open() {
            semaphore.signal()
        }
    }

    private struct DummyError: Error {}

    private func counter() -> (@Sendable () -> Void, AtomicCounter) {
        let count = AtomicCounter()
        return ({ count.increment() }, count)
    }

    private func testPool() -> LatestPool {
        LatestPool(maxThreads: 4, idleExit: 0.05)
    }

    private func makeLatest<T: Sendable>() -> (Latest<T>, AtomicCounter) {
        let (waker, wakes) = counter()
        return (Latest<T>(pool: testPool(), waker: waker), wakes)
    }

    private static func eventually(_ what: String, timeoutSeconds: TimeInterval = 5.0, done: () -> Bool) {
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        while !done() {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                Issue.record("Timed out waiting until \(what)")
                return
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    private func eventually(_ what: String, timeoutSeconds: TimeInterval = 5.0, done: () -> Bool) {
        Self.eventually(what, timeoutSeconds: timeoutSeconds, done: done)
    }

    private func makeSlot() -> (LatestSlot<UInt32>, AtomicCounter) {
        let (waker, wakes) = counter()
        return (LatestSlot<UInt32>(waker: waker), wakes)
    }

    private func ask(_ slot: inout LatestSlot<UInt32>, _ n: UInt32) {
        slot.wait(due: ProcessInfo.processInfo.systemUptime) { n }
    }

    private func start(_ slot: inout LatestSlot<UInt32>) -> LatestAttempt {
        slot.start()!.attempt
    }

    // MARK: - Slot Unit Tests (4)

    // 1. an_answer_lands_only_while_its_attempt_still_runs
    @Test func anAnswerLandsOnlyWhileItsAttemptStillRuns() {
        var (slot, _) = makeSlot()
        ask(&slot, 1)
        let first = start(&slot)
        ask(&slot, 2)
        #expect(slot.land(first, .success(1)) == nil, "superseded while it ran")
        if case .waiting = slot.request {} else {
            Issue.record("the newer request still waits")
        }
        let second = start(&slot)
        #expect(slot.land(first, .success(1)) == nil, "a stale answer can't land on a newer run")
        #expect(slot.land(second, .success(2)) != nil, "the newest wakes")
        #expect(slot.settledValue == .some(2))
        #expect(slot.land(second, .success(3)) == nil, "and lands once")
        #expect(slot.settledValue == .some(2))
    }

    // 2. an_answer_after_a_cancel_changes_nothing
    @Test func anAnswerAfterACancelChangesNothing() {
        var (slot, _) = makeSlot()
        ask(&slot, 1)
        let running = start(&slot)
        slot.cancel()
        #expect(slot.land(running, .success(1)) == nil)
        #expect(slot.settledValue == .some(nil))
        ask(&slot, 2)
        slot.cancel()
        #expect(slot.start() == nil, "a cancelled request never starts")
    }

    // 3. a_waiting_request_starts_once_and_drops_the_untaken_answer
    @Test func aWaitingRequestStartsOnceAndDropsTheUntakenAnswer() {
        var (slot, _) = makeSlot()
        ask(&slot, 1)
        let first = start(&slot)
        #expect(slot.start() == nil, "already running")
        _ = slot.land(first, .success(1))
        ask(&slot, 2)
        #expect(slot.settledValue == nil, "the newer request drops the untaken answer")
    }

    // 4. nothing_or_a_panic_settles_without_a_wake
    @Test func nothingOrAPanicSettlesWithoutAWake() {
        var (slot, wakes) = makeSlot()
        ask(&slot, 1)
        let a = start(&slot)
        #expect(slot.land(a, .success(nil)) == nil)
        #expect(slot.settledValue == .some(nil))
        ask(&slot, 2)
        let b = start(&slot)
        #expect(slot.land(b, .failure(DummyError())) == nil)
        #expect(slot.settledValue == .some(nil))
        #expect(wakes.value == 0)
    }

    // MARK: - Latest Integration Tests (17)

    // 5. the_newest_answer_wins_when_an_older_one_finishes_last
    @Test func theNewestAnswerWinsWhenAnOlderOneFinishesLast() {
        let (search, wakes) = makeLatest() as (Latest<String>, AtomicCounter)
        let gateA = Gate()
        let waitA = gateA.makeWork()
        let aDone = AtomicCounter()
        search.request("a") { q in
            waitA()
            aDone.increment()
            return q
        }
        gateA.waitStarted()
        search.request("ab") { q in q }
        eventually("ab lands") { wakes.value == 1 }
        #expect(search.take() == "ab")

        gateA.open()
        eventually("a finishes") { aDone.value == 1 }
        Thread.sleep(forTimeInterval: 0.005)
        #expect(search.take() == nil, "the older answer is dropped")
        #expect(wakes.value == 1, "and wakes nothing")
    }

    // 6. a_newer_request_drops_an_answer_not_yet_taken
    @Test func aNewerRequestDropsAnAnswerNotYetTaken() {
        let (search, wakes) = makeLatest() as (Latest<String>, AtomicCounter)
        search.request("a") { $0 }
        eventually("a lands") { wakes.value == 1 }
        let gate = Gate()
        let wait = gate.makeWork()
        search.request("ab") { q in
            wait()
            return q
        }
        #expect(search.take() == nil, "a is no longer the newest ask")
        #expect(search.isPending)
        gate.open()
        eventually("ab lands") { wakes.value == 2 }
        #expect(search.take() == "ab")
        #expect(!search.isPending)
    }

    // 7. an_answer_is_taken_once_and_each_landing_wakes_once
    @Test func anAnswerIsTakenOnceAndEachLandingWakesOnce() {
        let (search, wakes) = makeLatest() as (Latest<Int>, AtomicCounter)
        for n in 1...20 {
            search.request(n) { $0 * 10 }
            eventually("the answer lands") { wakes.value == n }
            #expect(search.take() == n * 10)
            #expect(search.take() == nil, "taken once")
        }
        Thread.sleep(forTimeInterval: 0.010)
        #expect(wakes.value == 20, "one wake per answer")
    }

    // 8. debounce_runs_only_the_last_request_of_a_burst_after_a_quiet_wait
    @Test func debounceRunsOnlyTheLastRequestOfABurstAfterAQuietWait() {
        let (waker, wakes) = counter()
        let quiet: TimeInterval = 0.250
        let search = Latest<String>(pool: testPool(), waker: waker).debounce(quiet)
        let ran = LockedList<(String, TimeInterval)>()
        let start = ProcessInfo.processInfo.systemUptime
        var last: TimeInterval = 0
        for q in ["a", "ab", "abc"] {
            last = ProcessInfo.processInfo.systemUptime - start
            search.request(q) { q in
                ran.append((q, ProcessInfo.processInfo.systemUptime - start))
                return q
            }
            Thread.sleep(forTimeInterval: 0.010)
        }
        eventually("abc lands") { wakes.value == 1 }
        #expect(search.take() == "abc")
        let recorded = ran.snapshot
        #expect(recorded.map(\.0) == ["abc"], "superseded requests never ran")
        #expect(recorded[0].1 >= last + quiet, "started after the quiet wait: \(recorded[0].1) vs \(last + quiet)")
    }

    // 9. debounce_waits_before_a_lone_request
    @Test func debounceWaitsBeforeALoneRequest() {
        let (waker, wakes) = counter()
        let search = Latest<TimeInterval>(pool: testPool(), waker: waker).debounce(0.030)
        let start = ProcessInfo.processInfo.systemUptime
        search.request(()) { _ in
            ProcessInfo.processInfo.systemUptime - start
        }
        #expect(search.isPending)
        eventually("it lands") { wakes.value == 1 }
        #expect((search.take() ?? 0) >= 0.030)
    }

    // 10. cancel_drops_pending_and_running_requests
    @Test func cancelDropsPendingAndRunningRequests() {
        let (waker, wakes) = counter()
        let search = Latest<Int>(pool: testPool(), waker: waker).debounce(0.020)
        let gate = Gate()
        let wait = gate.makeWork()
        let finished = AtomicCounter()
        search.request(()) { _ in
            wait()
            finished.increment()
            return 1
        }
        gate.waitStarted()
        search.cancel()
        #expect(!search.isPending)
        gate.open()
        eventually("the running work finishes") { finished.value == 1 }

        let ran = AtomicCounter()
        search.request(()) { _ in
            ran.increment()
            return 2
        }
        search.cancel()
        Thread.sleep(forTimeInterval: 0.060)
        #expect(ran.value == 0, "a debounced request cancelled before it started never runs")
        #expect(search.take() == nil && wakes.value == 0, "nothing lands or wakes")
    }

    // 11. dropping_it_cancels_and_nothing_wakes_after
    @Test func droppingItCancelsAndNothingWakesAfter() {
        let (waker, wakes) = counter()
        let gate = Gate()
        let finished = AtomicCounter()
        do {
            let search = Latest<UInt32>(pool: testPool(), waker: waker)
            let wait = gate.makeWork()
            search.request(()) { _ in
                wait()
                finished.increment()
                return 1
            }
            gate.waitStarted()
        }
        gate.open()
        eventually("the running work finishes") { finished.value == 1 }
        Thread.sleep(forTimeInterval: 0.005)
        #expect(wakes.value == 0)
    }

    // 12. a_panicking_request_settles_and_the_worker_carries_on
    @Test func aPanickingRequestSettlesAndTheWorkerCarriesOn() {
        let pool = LatestPool(maxThreads: 1, idleExit: 0.050)
        let (waker, wakes) = counter()
        let search = Latest<UInt32>(pool: pool, waker: waker)
        search.requestThrows(()) { _ -> UInt32 in
            throw DummyError()
        }
        eventually("the failed request settles it") { !search.isPending }
        search.request(()) { _ in 7 }
        eventually("the next lands") { wakes.value == 1 }
        #expect(search.take() == 7)
        #expect(pool.threads().started == 1, "on the same worker")
    }

    // 13. requests_reuse_a_few_threads_that_exit_when_idle
    @Test func requestsReuseAFewThreadsThatExitWhenIdle() {
        let pool = LatestPool(maxThreads: 2, idleExit: 0.500)
        let lists = (0..<3).map { _ in Latest<UInt64>(pool: pool, waker: nil) }
        for key in UInt64(0)..<200 {
            let list = lists[Int(key % 3)]
            list.request(key) { k in
                if k % 50 == 0 {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                return k
            }
            #expect(pool.threads().live <= 2)
        }
        eventually("every list settles") { lists.allSatisfy { !$0.isPending } }
        #expect(lists[197 % 3].take() == 197)
        #expect(pool.threads().started <= 2, "started \(pool.threads().started) threads")
        eventually("the workers exit") { pool.threads().live == 0 }
    }

    // 14. poll_changes_state_once_per_answer
    @Test func pollChangesStateOncePerAnswer() {
        struct SearchState {
            var hits: String = ""
            var results: Latest<String>
        }
        let (waker, wakes) = counter()
        let state = SearchState(results: Latest<String>(pool: testPool(), waker: waker))
        let rt = Runtime<SearchState>(
            state: state,
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            el().child(text(s.hits))
        }
        rt.poll = { s, _, _ in
            guard let hits = s.results.take() else { return false }
            s.hits = hits
            return true
        }
        _ = rt.frame(at: 0.0)
        let commits = rt.viewCommitCount
        rt.state.results.request("rune") { "\($0).md" }
        eventually("the answer lands") { wakes.value == 1 }
        _ = rt.frame(at: 1.0 / 60.0)
        #expect(rt.state.hits == "rune.md")
        #expect(rt.viewCommitCount == commits + 1, "the landed answer commits")
        _ = rt.frame(at: 2.0 / 60.0)
        _ = rt.frame(at: 3.0 / 60.0)
        #expect(rt.viewCommitCount == commits + 1, "and nothing after it")
    }

    // 15. set_waker_keeps_the_debounce_and_a_pending_request
    @Test func setWakerKeepsTheDebounceAndAPendingRequest() {
        let (waker, wakes) = counter()
        let search = Latest<Int>(pool: testPool(), waker: nil).debounce(0.250)
        search.request(7) { $0 }
        #expect(search.isPending)
        search.setWaker(waker)
        #expect(search.isPending, "the pending request survives")
        Thread.sleep(forTimeInterval: 0.050)
        #expect(wakes.value == 0, "the debounce is still waited out")
        eventually("the request lands") { wakes.value == 1 }
        #expect(search.take() == 7)
    }

    // 16. set_waker_replaces_the_old_waker
    @Test func setWakerReplacesTheOldWaker() {
        let (oldWaker, oldWakes) = counter()
        let (newWaker, newWakes) = counter()
        let search = Latest<Int>(pool: testPool(), waker: oldWaker)
        search.setWaker(newWaker)
        search.request(1) { $0 }
        eventually("it lands") { newWakes.value == 1 }
        #expect(oldWakes.value == 0)
    }

    // 17. request_if_changed_ignores_an_unchanged_key
    @Test func requestIfChangedIgnoresAnUnchangedKey() {
        let (search, wakes) = makeLatest() as (Latest<String>, AtomicCounter)
        let runs = AtomicCounter()
        for _ in 0..<5 {
            search.requestIfChanged(key: "ab") { q in
                runs.increment()
                return q
            }
        }
        eventually("it lands") { wakes.value == 1 }
        search.requestIfChanged(key: "ab") { q in
            runs.increment()
            return q
        }
        Thread.sleep(forTimeInterval: 0.030)
        #expect(runs.value == 1, "one run for one key, even after it landed")
        #expect(wakes.value == 1)
        #expect(search.take() == "ab")

        search.requestIfChanged(key: "abc") { $0 }
        eventually("the new key lands") { wakes.value == 2 }
        #expect(search.take() == "abc")
    }

    // 18. request_if_changed_does_not_push_back_the_debounce
    @Test func requestIfChangedDoesNotPushBackTheDebounce() {
        let (waker, wakes) = counter()
        let search = Latest<Int>(pool: testPool(), waker: waker).debounce(0.250)
        let start = ProcessInfo.processInfo.systemUptime
        search.requestIfChanged(key: 1) { $0 }
        while (ProcessInfo.processInfo.systemUptime - start) < 0.150 {
            search.requestIfChanged(key: 1) { $0 }
            Thread.sleep(forTimeInterval: 0.005)
        }
        eventually("it lands") { wakes.value == 1 }
        #expect((ProcessInfo.processInfo.systemUptime - start) < 1.500)
        #expect(search.take() == 1)
    }

    // 19. cancel_and_request_forget_the_key
    @Test func cancelAndRequestForgetTheKey() {
        let (search, wakes) = makeLatest() as (Latest<Int>, AtomicCounter)
        search.requestIfChanged(key: 1) { $0 }
        eventually("first lands") { wakes.value == 1 }
        search.cancel()
        search.requestIfChanged(key: 1) { $0 + 10 }
        eventually("second lands") { wakes.value == 2 }
        #expect(search.take() == 11)

        search.request(5) { $0 }
        eventually("plain request lands") { wakes.value == 3 }
        #expect(search.take() == 5)
        search.requestIfChanged(key: 1) { $0 + 20 }
        eventually("same key asks again") { wakes.value == 4 }
        #expect(search.take() == 21)
    }

    // 20. request_opt_none_lands_nothing_and_wakes_nothing
    @Test func requestOptNoneLandsNothingAndWakesNothing() {
        let (search, wakes) = makeLatest() as (Latest<Int>, AtomicCounter)
        let ran = AtomicCounter()
        search.requestOpt(3) { _ in
            ran.store(1)
            return nil
        }
        eventually("the work ran") { ran.value == 1 }
        eventually("it settles") { !search.isPending }
        Thread.sleep(forTimeInterval: 0.030)
        #expect(search.take() == nil)
        #expect(wakes.value == 0)

        search.requestOpt(4) { $0 }
        eventually("a Some lands") { wakes.value == 1 }
        #expect(search.take() == 4)
    }

    // 21. request_opt_none_still_supersedes_older_answers
    @Test func requestOptNoneStillSupersedesOlderAnswers() {
        let (search, wakes) = makeLatest() as (Latest<Int>, AtomicCounter)
        let gate = Gate()
        let wait = gate.makeWork()
        search.request(1) { n in
            wait()
            return n
        }
        gate.waitStarted()
        search.requestOpt(2) { _ in nil }
        eventually("it settles") { !search.isPending }
        gate.open()
        Thread.sleep(forTimeInterval: 0.050)
        #expect(search.take() == nil, "the older answer stays dropped")
        #expect(wakes.value == 0)
    }
}
