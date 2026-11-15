import Foundation
import Testing
@testable import Rune

/// Port of `crates/rune/src/task/queue.rs` (upstream 4529c6c1, #1026): a serial service queue
/// that borrows a task worker only while it has messages.
@Suite("Task queue (task::queue)", .serialized)
struct TaskQueueTests {
    // MARK: Helpers

    final class Box<V: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: V
        init(_ value: V) { stored = value }
        var value: V { lock.lock(); defer { lock.unlock() }; return stored }
        func update<R>(_ body: (inout V) -> R) -> R {
            lock.lock(); defer { lock.unlock() }
            return body(&stored)
        }
    }

    /// Counts drains scheduled on the real shared task workers.
    static func countingSpawner(_ spawns: Box<Int>) -> QueueSpawner {
        { name, work in
            spawns.update { $0 += 1 }
            RuneTask.spawn(name: name, work: work)
            return true
        }
    }

    /// Polls `condition` until it holds or 10s pass.
    static func waitUntil(_ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
    }

    /// The value a failed `send` hands back, or nil when it was accepted.
    static func rejected<T>(_ result: Result<Void, SendError<T>>) -> T? {
        if case .failure(let error) = result { return error.value }
        return nil
    }

    // MARK: Tests

    @Test func messagesRunInSendOrder() async {
        let seen = Box<[Int]>([])
        let q: Queue<Int> = RuneTask.queue(name: "order") { v in
            seen.update { $0.append(v) }
            return .continue
        }
        for i in 0..<200 {
            #expect((try? q.send(i).get()) != nil)
        }
        #expect(await Self.waitUntil { seen.value.count == 200 })
        #expect(seen.value == Array(0..<200))
        #expect(await Self.waitUntil { !q.inner.isDraining })
        #expect(q.inner.hasHandler)
    }

    @Test func copiesShareOneServiceInSendOrder() async {
        let seen = Box<[String]>([])
        let q: Queue<String> = RuneTask.queue(name: "clone") { v in
            seen.update { $0.append(v) }
            return .continue
        }
        let copy = q
        _ = q.send("a")
        _ = copy.send("b")
        _ = q.send("c")
        #expect(await Self.waitUntil { seen.value.count == 3 })
        #expect(seen.value == ["a", "b", "c"])
    }

    @Test func handlerRunsOneMessageAtATime() async {
        let active = Box(0)
        let maxActive = Box(0)
        let done = Box(0)
        let spawns = Box(0)
        let q: Queue<Int> = RuneTask.queue(name: "serial", each: { _ in
            let now = active.update { $0 += 1; return $0 }
            maxActive.update { $0 = max($0, now) }
            Thread.sleep(forTimeInterval: 0.001)
            active.update { $0 -= 1 }
            done.update { $0 += 1 }
            return .continue
        }, spawner: Self.countingSpawner(spawns))
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            _ = q.send(i)
        }
        #expect(await Self.waitUntil { done.value == 64 })
        #expect(maxActive.value == 1)
        #expect(await Self.waitUntil { !q.inner.isDraining })
        // A drain is scheduled only when none is running, so far fewer drains than sends.
        #expect(spawns.value >= 1)
        #expect(spawns.value <= 64)
    }

    @Test func sendsWhileDrainingReuseTheRunningDrain() async {
        let gate = DispatchSemaphore(value: 0)
        let seen = Box<[Int]>([])
        let spawns = Box(0)
        let q: Queue<Int> = RuneTask.queue(name: "reuse", each: { v in
            if v == 0 { gate.wait() }
            seen.update { $0.append(v) }
            return .continue
        }, spawner: Self.countingSpawner(spawns))
        _ = q.send(0)
        // The drain has taken the handler and is blocked on message 0.
        #expect(await Self.waitUntil { !q.inner.hasHandler })
        _ = q.send(1)
        _ = q.send(2)
        _ = q.send(3)
        #expect(spawns.value == 1)
        #expect(q.inner.pendingCount == 3)
        gate.signal()
        #expect(await Self.waitUntil { seen.value.count == 4 })
        #expect(seen.value == [0, 1, 2, 3])
        #expect(spawns.value == 1)
    }

    @Test func idleQueueSchedulesANewDrainOnSend() async {
        let seen = Box<[Int]>([])
        let spawns = Box(0)
        let q: Queue<Int> = RuneTask.queue(name: "idle", each: { v in
            seen.update { $0.append(v) }
            return .continue
        }, spawner: Self.countingSpawner(spawns))
        _ = q.send(1)
        #expect(await Self.waitUntil { seen.value == [1] && !q.inner.isDraining })
        // Idle: the handler is back and no worker is borrowed.
        #expect(q.inner.hasHandler)
        #expect(spawns.value == 1)
        _ = q.send(2)
        #expect(spawns.value == 2)
        #expect(await Self.waitUntil { seen.value == [1, 2] && !q.inner.isDraining })
        #expect(q.inner.hasHandler)
    }

    @Test func breakDropsPendingMessagesAndFailsLaterSends() async {
        let gate = DispatchSemaphore(value: 0)
        let seen = Box<[Int]>([])
        let q: Queue<Int> = RuneTask.queue(name: "break") { v in
            gate.wait()
            seen.update { $0.append(v) }
            return .break
        }
        _ = q.send(1)
        #expect(await Self.waitUntil { !q.inner.hasHandler })
        #expect((try? q.send(2).get()) != nil)
        #expect((try? q.send(3).get()) != nil)
        gate.signal()
        #expect(await Self.waitUntil { !q.inner.isDraining })
        #expect(seen.value == [1])
        #expect(q.inner.pendingCount == 0)
        #expect(!q.inner.hasHandler)
        switch q.send(4) {
        case .success: Issue.record("send after break must fail")
        case .failure(let error): #expect(error.value == 4)
        }
        #expect(Self.rejected(q.send(5)) == 5)
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(seen.value == [1])
    }

    struct Boom: Error {}

    @Test func throwingHandlerStopsLikeBreak() async {
        let seen = Box<[Int]>([])
        let q: Queue<Int> = RuneTask.queue(name: "throw") { v in
            seen.update { $0.append(v) }
            if v == 2 { throw Boom() }
            return .continue
        }
        _ = q.send(1)
        _ = q.send(2)
        _ = q.send(3)
        #expect(await Self.waitUntil { !q.inner.isDraining && !q.inner.hasHandler })
        // 3 is either dropped from the pending queue or refused after the stop: never handled.
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(seen.value == [1, 2])
        #expect(Self.rejected(q.send(4)) == 4)
    }

    /// Message whose deinit sends to its own queue, as upstream warns: dropping the pending
    /// messages must happen outside the queue lock, and those sends fail on a stopped service.
    final class Msg: Sendable {
        let id: Int
        let target: Box<Queue<Msg>?>
        let drops: Box<[Int]>
        let resent: Box<[Bool]>
        init(_ id: Int, target: Box<Queue<Msg>?>, drops: Box<[Int]>, resent: Box<[Bool]>) {
            self.id = id
            self.target = target
            self.drops = drops
            self.resent = resent
        }
        deinit {
            drops.update { $0.append(id) }
            if id >= 10, let q = target.value {
                let ok: Bool
                switch q.send(Msg(-1, target: Box(nil), drops: Box([]), resent: Box([]))) {
                case .success: ok = true
                case .failure: ok = false
                }
                resent.update { $0.append(ok) }
            }
        }
    }

    @Test func droppedPendingMessagesMaySendWithoutDeadlock() async {
        let gate = DispatchSemaphore(value: 0)
        let target = Box<Queue<Msg>?>(nil)
        let drops = Box<[Int]>([])
        let resent = Box<[Bool]>([])
        let handled = Box<[Int]>([])
        let q: Queue<Msg> = RuneTask.queue(name: "drop") { m in
            gate.wait()
            handled.update { $0.append(m.id) }
            return .break
        }
        target.update { $0 = q }
        _ = q.send(Msg(1, target: target, drops: drops, resent: resent))
        #expect(await Self.waitUntil { !q.inner.hasHandler })
        _ = q.send(Msg(10, target: target, drops: drops, resent: resent))
        _ = q.send(Msg(11, target: target, drops: drops, resent: resent))
        gate.signal()
        #expect(await Self.waitUntil { resent.value.count == 2 })
        #expect(handled.value == [1])
        #expect(Set(drops.value).isSuperset(of: [1, 10, 11]))
        #expect(resent.value == [false, false])
        target.update { $0 = nil }
    }

    @Test func failedSpawnReturnsTheMessageAndKeepsTheService() async {
        let seen = Box<[Int]>([])
        let failNext = Box(true)
        let q: Queue<Int> = RuneTask.queue(name: "spawn-fail", each: { v in
            seen.update { $0.append(v) }
            return .continue
        }, spawner: { name, work in
            if failNext.update({ let f = $0; $0 = false; return f }) { return false }
            RuneTask.spawn(name: name, work: work)
            return true
        })
        #expect(Self.rejected(q.send(7)) == 7)
        #expect(!q.inner.isDraining)
        #expect(q.inner.hasHandler)
        #expect(q.inner.pendingCount == 0)
        #expect((try? q.send(8).get()) != nil)
        #expect(await Self.waitUntil { seen.value == [8] })
    }

    @Test func controlFlowPredicates() {
        #expect(ControlFlow.break.isBreak)
        #expect(!ControlFlow.break.isContinue)
        #expect(ControlFlow.continue.isContinue)
        #expect(!ControlFlow.continue.isBreak)
    }
}
