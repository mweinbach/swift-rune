import Foundation
import Testing
@testable import Rune

/// Direct port of `crates/rune/src/runtime/motion/live_latch_tests.rs`.
@Suite("Rune Live Latch Parity Tests (motion/live_latch_tests.rs)")
struct LiveLatchParityTests {
    private final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        func load() -> Int {
            lock.lock()
            let v = count
            lock.unlock()
            return v
        }
    }

    private final class DevWake {
        private let lock = NSLock()
        private var pending = false
        private var visible = true
        let fired: AtomicCounter

        init(fired: AtomicCounter) {
            self.fired = fired
        }

        func setVisible(_ v: Bool) {
            lock.lock()
            let was = visible
            visible = v
            let shouldFire = v && !was && pending
            lock.unlock()
            if shouldFire { fired.increment() }
        }

        func notify() {
            lock.lock()
            let was = pending
            pending = true
            let shouldFire = !was && visible
            lock.unlock()
            if shouldFire { fired.increment() }
        }

        func isPending() -> Bool {
            lock.lock()
            let v = pending
            lock.unlock()
            return v
        }

        func swapPendingFalse() -> Bool {
            lock.lock()
            let was = pending
            pending = false
            lock.unlock()
            return was
        }
    }

    private final class Dev {
        var visible = true
        var dirty = false
        var subs = true
        let wake: DevWake

        init(fired: AtomicCounter) {
            self.wake = DevWake(fired: fired)
        }

        func setVisible(_ v: Bool) {
            wake.setVisible(v)
            visible = v
        }

        func publish() { wake.notify() }
        func pending() -> Bool { visible && (dirty || wake.isPending()) }
        func subscribe(_ sampled: Bool) { dirty = sampled }
        func prune(_ sampled: Bool) {
            let d = dirty
            subscribe(sampled)
            dirty = dirty && d
        }
        func set() { dirty = true }
        func take() -> Bool { visible && wake.swapPendingFalse() }
        func latchBegin(_ pending: Bool) -> Bool {
            if !visible || !subs { return false }
            if !pending && !dirty { return false }
            dirty = false
            return true
        }
        func latchEnd(_ active: Bool) -> Bool {
            dirty = dirty || active
            return dirty
        }
    }

    private enum Ev: CaseIterable {
        case publish
        case show
        case hide
        case subscribeTrue
        case subscribeFalse
        case pruneTrue
        case pruneFalse
        case set
        case take
        case latchBegin
        case latchEndTrue
    }

    private static func walk(_ events: [Ev]) {
        let firedDev = AtomicCounter()
        let firedNew = AtomicCounter()
        let dev = Dev(fired: firedDev)
        let new = LiveLane { firedNew.increment() }
        var wokeDev = false
        var wokeNew = false
        var readingDev = false
        var readingNew = false

        for (i, ev) in events.enumerated() {
            let answerDev: Bool?
            let answerNew: Bool?
            switch ev {
            case .publish:
                dev.publish()
                new.publish()
                (answerDev, answerNew) = (nil, nil)
            case .show:
                dev.setVisible(true)
                new.setVisible(true)
                (answerDev, answerNew) = (nil, nil)
            case .hide:
                dev.setVisible(false)
                new.setVisible(false)
                (answerDev, answerNew) = (nil, nil)
            case .subscribeTrue:
                dev.subscribe(true)
                new.subscribed(true)
                (answerDev, answerNew) = (nil, nil)
            case .subscribeFalse:
                dev.subscribe(false)
                new.subscribed(false)
                (answerDev, answerNew) = (nil, nil)
            case .pruneTrue:
                let keepDev = dev.dirty
                dev.prune(true)
                let keepNew = new.dirty
                new.subscribed(true)
                new.pruned(keepNew)
                precondition(keepDev == keepNew)
                (answerDev, answerNew) = (nil, nil)
            case .pruneFalse:
                let keepDev = dev.dirty
                dev.prune(false)
                let keepNew = new.dirty
                new.subscribed(false)
                new.pruned(keepNew)
                precondition(keepDev == keepNew)
                (answerDev, answerNew) = (nil, nil)
            case .set:
                dev.set()
                new.set()
                (answerDev, answerNew) = (nil, nil)
            case .take:
                let a = dev.take()
                let b = new.take()
                wokeDev = wokeDev || a
                wokeNew = wokeNew || b
                (answerDev, answerNew) = (a, b)
            case .latchBegin:
                let a = dev.latchBegin(wokeDev || dev.pending())
                let b = new.latchBegin(can: wokeNew || new.pending(), hasSubs: dev.subs)
                readingDev = a
                readingNew = b
                wokeDev = false
                wokeNew = false
                (answerDev, answerNew) = (a, b)
            case .latchEndTrue:
                let a: Bool? = readingDev ? dev.latchEnd(true) : nil
                let b: Bool? = readingNew ? new.latchEnd(active: true) : nil
                (answerDev, answerNew) = (a, b)
            }
            #expect(answerDev == answerNew, "answer differed after \(ev) at step \(i)")
            #expect(dev.visible == new.visible, "visible differed after \(ev) at step \(i)")
            #expect(dev.pending() == new.pending(), "pending differed after \(ev) at step \(i)")
            #expect(firedDev.load() == firedNew.load(), "wake count differed after \(ev) at step \(i)")
        }
    }

    @Test("live_latch_tests::every_short_sequence_matches_dev")
    func everyShortSequenceMatchesDev() {
        let events = Ev.allCases
        Self.walk([])
        let n = events.count
        var powN = 1
        for len in 1...6 {
            powN *= n
            var seq = Array(repeating: Ev.publish, count: len)
            for startCode in 0..<powN {
                var code = startCode
                for k in 0..<len {
                    seq[k] = events[code % n]
                    code /= n
                }
                Self.walk(seq)
            }
        }
    }

    @Test("live_latch_tests::a_publish_while_the_frame_reads_survives")
    func aPublishWhileTheFrameReadsSurvives() {
        let lane = LiveLane {}
        lane.subscribed(true)
        lane.publish()
        #expect(lane.take())
        lane.publish()
        #expect(lane.latchBegin(can: true, hasSubs: true))
        #expect(!lane.latchEnd(active: false))
        #expect(lane.pending())
        #expect(lane.take())
        #expect(!lane.pending())
    }

    @Test("live_latch_tests::a_hidden_window_keeps_one_wake_for_show")
    func aHiddenWindowKeepsOneWakeForShow() {
        let fired = AtomicCounter()
        let lane = LiveLane { fired.increment() }
        lane.setVisible(false)
        lane.publish()
        lane.publish()
        #expect(fired.load() == 0)
        #expect(!lane.pending())
        #expect(!lane.take())
        #expect(!lane.latchBegin(can: true, hasSubs: true))
        lane.setVisible(true)
        #expect(fired.load() == 1)
        #expect(lane.take())
        #expect(!lane.take())
        #expect(fired.load() == 1)
    }

    @Test("live_latch_tests::hiding_and_showing_between_a_publish_and_its_frame_keeps_one_wake")
    func hidingAndShowingBetweenAPublishAndItsFrameKeepsOneWake() {
        let fired = AtomicCounter()
        let lane = LiveLane { fired.increment() }
        lane.publish()
        #expect(fired.load() == 1)
        lane.setVisible(false)
        lane.setVisible(true)
        #expect(fired.load() == 2)
        #expect(lane.take())
        #expect(!lane.take())
        #expect(fired.load() == 2)
    }

    @Test("live_latch_tests::two_publishes_before_one_frame_coalesce")
    func twoPublishesBeforeOneFrameCoalesce() {
        let fired = AtomicCounter()
        let lane = LiveLane { fired.increment() }
        lane.publish()
        lane.publish()
        #expect(fired.load() == 1)
        #expect(lane.take())
        #expect(!lane.take())
        #expect(fired.load() == 1)
    }

    @Test("live_latch_tests::an_app_thread_set_wakes_an_idle_window")
    func anAppThreadSetWakesAnIdleWindow() {
        let fired = AtomicCounter()
        let lane = LiveLane { fired.increment() }
        let value = Live<Float>(0.0)
        let sub = value.source.subscribe(lane.waker)
        defer { sub.isActive = false }
        #expect(!lane.pending())
        #expect(value.set(1.0))
        #expect(fired.load() == 1)
        #expect(lane.pending())
        #expect(lane.take())

        lane.setVisible(false)
        #expect(value.set(2.0))
        #expect(fired.load() == 1)
        #expect(!lane.pending())
        lane.setVisible(true)
        #expect(fired.load() == 2)
        #expect(lane.take())
        #expect(!lane.take())
        #expect(fired.load() == 2)
    }

    @Test("live_latch_tests::an_empty_frame_leaves_the_state_untouched")
    func anEmptyFrameLeavesTheStateUntouched() {
        let lane = LiveLane {}
        #expect(lane.state == .idle)
        #expect(!lane.take())
        #expect(lane.state == .idle)
        #expect(!lane.latchBegin(can: false, hasSubs: true))
        #expect(lane.state == .idle)

        lane.state = .latching(dirty: false)
        #expect(!lane.latchBegin(can: false, hasSubs: true))
        #expect(lane.state == .latching(dirty: false))

        lane.state = .pending
        #expect(!lane.take())
        #expect(lane.state == .pending)

        #expect(!lane.latchBegin(can: true, hasSubs: false))
        #expect(lane.state == .pending)
    }

    @Test("live_latch_tests::a_live_only_set_keeps_the_frame_due")
    func aLiveOnlySetKeepsTheFrameDue() {
        let lane = LiveLane {}
        #expect(!lane.pending())
        lane.set()
        #expect(lane.pending())
        #expect(!lane.take())
        #expect(lane.latchBegin(can: false, hasSubs: true))
        #expect(!lane.latchEnd(active: false))
        #expect(!lane.pending())
    }

    @Test("live_latch_tests::nothing_reads_without_sources_or_while_hidden")
    func nothingReadsWithoutSourcesOrWhileHidden() {
        let lane = LiveLane {}
        lane.subscribed(true)
        #expect(!lane.latchBegin(can: true, hasSubs: false))
        lane.setVisible(false)
        #expect(!lane.latchBegin(can: true, hasSubs: true))
    }
}
