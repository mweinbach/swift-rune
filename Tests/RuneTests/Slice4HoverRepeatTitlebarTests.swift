import Dispatch
import Foundation
import Testing
@testable import Rune

@Suite("Slice 4: Hover Delays, Press Repeat & Titlebar Press Parity Tests")
struct Slice4HoverRepeatTitlebarTests {

    // MARK: - Helpers (hover_delay_tests.rs)

    private static let hoverDelayPair: (enter: Double, leave: Double) = (0.5, 0.25)

    private func settle(_ state: inout KitHoverDelayPhase?, inside: Bool, now: Double) -> [KitHoverDelayEffect] {
        stepKitHoverDelayState(&state, .settle(
            inside: inside,
            mayEnter: true,
            enterDelay: Self.hoverDelayPair.enter,
            leaveDelay: Self.hoverDelayPair.leave,
            now: now
        ))
    }

    private func due(_ state: inout KitHoverDelayPhase?, now: Double) -> [KitHoverDelayEffect] {
        stepKitHoverDelayState(&state, .due(now: now))
    }

    private func makeHoverDelayRuntime() -> Runtime<[Bool]> {
        let rt = Runtime(state: [Bool](), viewport: Vec2(200, 200), pixelScale: 1.0, systemDark: true) { _, _ in
            col().wFull().hFull().child(
                el().key("zone").size(16, 100)
                    .onHover { s, inside, _ in s.append(inside) }
                    .hoverDelays(0.04, 0.1)
            )
        }
        _ = rt.frame(at: 0.0)
        rt.pointerMove(to: Vec2(100, 50), at: 0.0)
        _ = rt.frame(at: 0.0)
        return rt
    }

    private struct LeavingState {
        var gone: Bool? = nil
        var heard: [Bool] = []
    }

    private func runLeaving(rest: Double, instant: Bool) -> [Bool] {
        let rt = Runtime(state: LeavingState(), viewport: Vec2(200, 200), pixelScale: 1.0, systemDark: true) { s, _ in
            let root: El<LeavingState> = col().wFull().hFull()
            if s.gone == nil {
                return root.child(
                    el().key("zone").size(16, 100)
                        .onHover { st, inside, _ in st.heard.append(inside) }
                        .hoverDelays(0.04, 0.1)
                )
            }
            return root
        }
        var t = 0.0
        _ = rt.frame(at: t)
        rt.pointerMove(to: Vec2(8, 50), at: t)
        t += rest
        _ = rt.frame(at: t)
        rt.update(at: t) { s, tx in
            s.gone = instant
            if instant { tx.instant() }
        }
        for _ in 0..<60 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        return rt.state.heard
    }

    // MARK: - Group A: hover_delay_tests.rs (8 tests)

    @Test("hover_delay: an enter waits out its delay then reports")
    func anEnterWaitsOutItsDelayThenReports() {
        var s: KitHoverDelayPhase? = nil
        #expect(settle(&s, inside: true, now: 1.0) == [.wakeAt(1.5)])
        #expect(settle(&s, inside: true, now: 1.2).isEmpty, "still inside: the wait runs on")
        #expect(due(&s, now: 1.4).isEmpty)
        #expect(due(&s, now: 1.5) == [.report(true)])
        #expect(s == .shown)
    }

    @Test("hover_delay: leaving before the enter is due reports nothing and its wake is stale")
    func leavingBeforeTheEnterIsDueReportsNothingAndItsWakeIsStale() {
        var s: KitHoverDelayPhase? = nil
        _ = settle(&s, inside: true, now: 1.0)
        #expect(settle(&s, inside: false, now: 1.1).isEmpty)
        #expect(s == nil)
        #expect(settle(&s, inside: true, now: 1.3) == [.wakeAt(1.8)])
        #expect(due(&s, now: 1.5).isEmpty)
        #expect(s == .enterDue(due: 1.8))
    }

    @Test("hover_delay: a shown hover leaves after the exit delay unless the pointer comes back")
    func aShownHoverLeavesAfterTheExitDelayUnlessThePointerComesBack() {
        var s: KitHoverDelayPhase? = .shown
        #expect(settle(&s, inside: false, now: 2.0) == [.wakeAt(2.25)])
        #expect(settle(&s, inside: true, now: 2.1).isEmpty, "back inside: still shown, no report")
        #expect(s == .shown)
        #expect(due(&s, now: 2.25).isEmpty)
        _ = settle(&s, inside: false, now: 3.0)
        #expect(due(&s, now: 3.25) == [.report(false)])
        #expect(s == nil)
    }

    @Test("hover_delay: zero delays report at once")
    func zeroDelaysReportAtOnce() {
        var s: KitHoverDelayPhase? = nil
        let effects = stepKitHoverDelayState(&s, .settle(
            inside: true,
            mayEnter: true,
            enterDelay: 0.0,
            leaveDelay: 0.0,
            now: 0.0
        ))
        #expect(effects == [.report(true)])
        #expect(s == .shown)
    }

    @Test("hover_delay: a press or blur keeps an enter from starting but not a shown hover from staying")
    func aPressOrBlurKeepsAnEnterFromStartingButNotAShownHoverFromStaying() {
        var s: KitHoverDelayPhase? = nil
        #expect(stepKitHoverDelayState(&s, .settle(
            inside: true,
            mayEnter: false,
            enterDelay: Self.hoverDelayPair.enter,
            leaveDelay: Self.hoverDelayPair.leave,
            now: 0.0
        )).isEmpty)
        #expect(s == nil)

        var shown: KitHoverDelayPhase? = .shown
        #expect(stepKitHoverDelayState(&shown, .settle(
            inside: true,
            mayEnter: false,
            enterDelay: Self.hoverDelayPair.enter,
            leaveDelay: Self.hoverDelayPair.leave,
            now: 0.0
        )).isEmpty)
        #expect(shown == .shown)
    }

    @Test("hover_delay: a press stops an enter wait but not a leave wait")
    func aPressStopsAnEnterWaitButNotALeaveWait() {
        var entering: KitHoverDelayPhase? = .enterDue(due: 1.0)
        #expect(stepKitHoverDelayState(&entering, .pressed).isEmpty)
        #expect(entering == nil)

        var leaving: KitHoverDelayPhase? = .leaveDue(due: 1.0)
        #expect(stepKitHoverDelayState(&leaving, .pressed).isEmpty)
        #expect(leaving == .leaveDue(due: 1.0))
    }

    @Test("hover_delay: ending reports a leave only to a hover that heard the enter")
    func endingReportsALeaveOnlyToAHoverThatHeardTheEnter() {
        let cases: [(KitHoverDelayPhase?, Bool)] = [
            (.shown, true),
            (.leaveDue(due: 1.0), true),
            (.enterDue(due: 1.0), false),
            (nil, false),
        ]
        for (initial, heard) in cases {
            var s = initial
            let effects = stepKitHoverDelayState(&s, .ended)
            #expect(effects == (heard ? [.report(false)] : []))
            #expect(s == nil)
        }
    }

    @Test("hover_delay: the list reports waits in the order they started")
    func theListReportsWaitsInTheOrderTheyStarted() {
        var list = KitHoverDelayList()
        _ = list.step("a", .settle(inside: true, mayEnter: true, enterDelay: 0.0, leaveDelay: 0.0, now: 0.0))
        _ = list.step("b", .settle(inside: true, mayEnter: true, enterDelay: 0.5, leaveDelay: 0.25, now: 0.0))
        // `a` starts its leave after `b` started its enter.
        _ = list.step("a", .settle(inside: false, mayEnter: true, enterDelay: 0.5, leaveDelay: 0.5, now: 0.0))
        #expect(list.paths == ["b", "a"])
        #expect(list.waiting)
        let forgotA = list.forget("a")
        #expect(forgotA, "a had heard its enter")
        let forgotB = list.forget("b")
        #expect(!forgotB)
        #expect(list.isEmpty && !list.waiting)
    }

    // MARK: - Group B: tests/hover_delays.rs (9 tests)

    @Test("hover_delays: an enter waits for the pointer to rest")
    func anEnterWaitsForThePointerToRest() {
        let rt = makeHoverDelayRuntime()
        var t = 0.0
        rt.pointerMove(to: Vec2(8, 50), at: t)
        t += 0.03
        _ = rt.frame(at: t)
        #expect(rt.state.isEmpty, "not yet")
        #expect(rt.nextWakeDeadline(after: t) != nil, "the wait asks for a frame")
        t += 0.015
        _ = rt.frame(at: t)
        #expect(rt.state == [true])
        // Moving within it reports nothing more.
        rt.pointerMove(to: Vec2(10, 60), at: t)
        t += 0.1
        _ = rt.frame(at: t)
        #expect(rt.state == [true])
    }

    @Test("hover_delays: a pass shorter than the delay reports nothing")
    func aPassShorterThanTheDelayReportsNothing() {
        let rt = makeHoverDelayRuntime()
        var t = 0.0
        rt.pointerMove(to: Vec2(8, 50), at: t)
        t += 0.02
        _ = rt.frame(at: t)
        rt.pointerMove(to: Vec2(100, 50), at: t)
        t += 0.1
        _ = rt.frame(at: t)
        #expect(rt.state.isEmpty)
    }

    @Test("hover_delays: a leave waits out its grace and a return keeps it")
    func aLeaveWaitsOutItsGraceAndAReturnKeepsIt() {
        let rt = makeHoverDelayRuntime()
        var t = 0.0
        rt.pointerMove(to: Vec2(8, 50), at: t)
        t += 0.05
        _ = rt.frame(at: t)
        #expect(rt.state == [true])
        rt.pointerMove(to: Vec2(100, 50), at: t)
        t += 0.05
        _ = rt.frame(at: t)
        rt.pointerMove(to: Vec2(8, 50), at: t)
        t += 0.2
        _ = rt.frame(at: t)
        #expect(rt.state == [true], "back within the grace")
        rt.pointerMove(to: Vec2(100, 50), at: t)
        t += 0.09
        _ = rt.frame(at: t)
        #expect(rt.state == [true])
        t += 0.02
        _ = rt.frame(at: t)
        #expect(rt.state == [true, false])
    }

    @Test("hover_delays: a press cancels the wait and the next move starts it again")
    func aPressCancelsTheWaitAndTheNextMoveStartsItAgain() {
        let rt = makeHoverDelayRuntime()
        var t = 0.0
        rt.pointerMove(to: Vec2(8, 50), at: t)
        t += 0.02
        _ = rt.frame(at: t)
        rt.pointerDown(at: Vec2(8, 50), at: t)
        t += 0.1
        _ = rt.frame(at: t)
        #expect(rt.state.isEmpty)
        rt.pointerUp(at: Vec2(8, 50), at: t)
        rt.pointerMove(to: Vec2(9, 50), at: t)
        t += 0.03
        _ = rt.frame(at: t)
        #expect(rt.state.isEmpty)
        t += 0.02
        _ = rt.frame(at: t)
        #expect(rt.state == [true])
    }

    @Test("hover_delays: blur cancels pending enters and ends shown hover without a grace")
    func blurCancelsPendingEntersAndEndsShownHoverWithoutAGrace() {
        let rt = makeHoverDelayRuntime()
        var t = 0.0
        rt.windowFocus(true, at: t)
        rt.pointerMove(to: Vec2(8, 50), at: t)
        t += 0.02
        _ = rt.frame(at: t)
        rt.windowFocus(false, at: t)
        t += 0.2
        _ = rt.frame(at: t)
        #expect(rt.state.isEmpty, "a pending enter cannot open under a still pointer once blurred")
        rt.windowFocus(true, at: t)
        rt.pointerMove(to: Vec2(8, 50), at: t)
        t += 0.05
        _ = rt.frame(at: t)
        #expect(rt.state == [true])
        rt.windowFocus(false, at: t)
        _ = rt.frame(at: t)
        #expect(rt.state == [true, false], "blur ends even a hover with exit grace")
    }

    @Test("hover_delays: a move over a window that isnt key starts the wait")
    func aMoveOverAWindowThatIsntKeyStartsTheWait() {
        let rt = makeHoverDelayRuntime()
        var t = 0.0
        rt.windowFocus(true, at: t)
        rt.windowFocus(false, at: t)
        rt.pointerMove(to: Vec2(8, 50), at: t)
        t += 0.03
        _ = rt.frame(at: t)
        #expect(rt.state.isEmpty, "not yet")
        t += 0.015
        _ = rt.frame(at: t)
        #expect(rt.state == [true])
        rt.windowFocus(true, at: t)
        rt.windowFocus(false, at: t)
        _ = rt.frame(at: t)
        #expect(rt.state == [true, false])
        t += 0.2
        _ = rt.frame(at: t)
        #expect(rt.state == [true, false], "a still pointer doesn't reopen it")
        rt.pointerMove(to: Vec2(9, 50), at: t)
        t += 0.05
        _ = rt.frame(at: t)
        #expect(rt.state == [true, false, true], "the next move does")
    }

    @Test("hover_delays: leaving the window cancels a pending enter")
    func leavingTheWindowCancelsAPendingEnter() {
        let rt = makeHoverDelayRuntime()
        var t = 0.0
        rt.pointerMove(to: Vec2(8, 50), at: t)
        t += 0.02
        _ = rt.frame(at: t)
        rt.pointerExit(at: t)
        t += 0.2
        _ = rt.frame(at: t)
        #expect(rt.state.isEmpty)
    }

    @Test("hover_delays: a zone leaving before its enter reports nothing")
    func aZoneLeavingBeforeItsEnterReportsNothing() {
        #expect(runLeaving(rest: 0.02, instant: false).isEmpty, "through its exit")
        #expect(runLeaving(rest: 0.02, instant: true).isEmpty, "at once")
    }

    @Test("hover_delays: a shown zone leaving hears its leave")
    func aShownZoneLeavingHearsItsLeave() {
        #expect(runLeaving(rest: 0.05, instant: false) == [true, false], "through its exit")
        #expect(runLeaving(rest: 0.05, instant: true) == [true, false], "at once")
    }

    // MARK: - Group C: press_repeat_tests.rs (5 tests)

    private func armedRepeat(_ seq: inout PressRepeatSeq, path: String, due: Double) -> (PressRepeatState, [PressRepeatEffect]) {
        var state: PressRepeatState = .idle
        let effects = stepPressRepeat(seq: &seq, state: &state, event: .arm(path: path, due: due))
        return (state, effects)
    }

    @Test("press_repeat: an arm keeps its attempt and wakes at its due time")
    func anArmKeepsItsAttemptAndWakesAtItsDueTime() {
        var seq = PressRepeatSeq()
        let (state, effects) = armedRepeat(&seq, path: "row", due: 1.5)
        guard case .armed(let attempt, let path, let due) = state else {
            Issue.record("expected armed state, got \(state)")
            return
        }
        #expect(path == "row")
        #expect(due == 1.5)
        #expect(effects == [.wakeAt(1.5)])
        #expect(state.attempt == attempt)
    }

    @Test("press_repeat: a due fires once at or after its time")
    func aDueFiresOnceAtOrAfterItsTime() {
        var seq = PressRepeatSeq()
        var (state, _) = armedRepeat(&seq, path: "row", due: 1.5)
        let attempt = state.attempt!
        let early = stepPressRepeat(seq: &seq, state: &state, event: .due(attempt: attempt, now: 1.0))
        #expect(early.isEmpty, "before its time")
        #expect(state.attempt == attempt, "still armed")
        let fired = stepPressRepeat(seq: &seq, state: &state, event: .due(attempt: attempt, now: 1.5))
        #expect(fired == [.fire("row")])
        #expect(state == .idle)
        let again = stepPressRepeat(seq: &seq, state: &state, event: .due(attempt: attempt, now: 9.0))
        #expect(again.isEmpty, "a spent repeat fires nothing")
    }

    @Test("press_repeat: a wake for an earlier arm changes nothing")
    func aWakeForAnEarlierArmChangesNothing() {
        var seq = PressRepeatSeq()
        var (state, _) = armedRepeat(&seq, path: "row", due: 1.5)
        let first = state.attempt!
        _ = stepPressRepeat(seq: &seq, state: &state, event: .end)
        let (state2, _) = armedRepeat(&seq, path: "row", due: 5.0)
        state = state2
        let stale = stepPressRepeat(seq: &seq, state: &state, event: .due(attempt: first, now: 9.0))
        #expect(stale.isEmpty, "an earlier arm's wake fires nothing")
        #expect(state.attempt != nil, "the later arm still waits")
    }

    @Test("press_repeat: a release ends the repeat")
    func aReleaseEndsTheRepeat() {
        var seq = PressRepeatSeq()
        var (state, _) = armedRepeat(&seq, path: "row", due: 1.5)
        let attempt = state.attempt!
        _ = stepPressRepeat(seq: &seq, state: &state, event: .end)
        #expect(state == .idle)
        #expect(stepPressRepeat(seq: &seq, state: &state, event: .due(attempt: attempt, now: 2.0)).isEmpty)
    }

    @Test("press_repeat: an arm for another element is the new one")
    func anArmForAnotherElementIsTheNewOne() {
        var seq = PressRepeatSeq()
        var (state, _) = armedRepeat(&seq, path: "row", due: 1.5)
        let first = state.attempt!
        _ = stepPressRepeat(seq: &seq, state: &state, event: .arm(path: "cell", due: 2.0))
        let second = state.attempt!
        #expect(first != second, "a new arm is a new attempt")
        #expect(state == .armed(attempt: second, path: "cell", due: 2.0))
    }

    // MARK: - Group D: pointer_hit.rs:358 & titlebar_press.rs:254,290 (3 tests)

    @Test("pointer_hit: a double press on nothing in the native titlebar band takes the titlebar action")
    func aDoublePressOnNothingInTheNativeTitlebarBandTakesTheTitlebarAction() {
        let rt = Runtime(state: (), viewport: Vec2(200, 200), pixelScale: 1.0, systemDark: true) { _, _ in
            col().size(200, 200).child(el().key("button").size(40, 40).onClick { _ in })
        }
        _ = rt.frame(at: 0.0)
        func double(_ x: Float, _ y: Float) -> [TitlebarAction?] {
            var actions: [TitlebarAction?] = []
            for _ in 0..<2 {
                let pt = Vec2(x, y)
                rt.pointerMove(to: pt, at: 0.0)
                rt.pointerDown(at: pt, at: 0.0)
                actions.append(rt.takeTitlebarAction())
                rt.pointerUp(at: pt, at: 0.0)
            }
            return actions
        }
        #expect(double(100, 10) == [nil, nil], "no native band, nothing to do")
        rt.setNativeTitlebarBand(28.0)
        #expect(double(100, 10) == [nil, .doubleClick], "the system drags; Rune adds the double click")
        #expect(double(100, 60) == [nil, nil], "below the band")
        #expect(double(20, 10) == [nil, nil], "a button in the band keeps its presses")
    }

    @Test("titlebar_press: focus loss cancels titlebar press")
    func focusLossCancelsTitlebarPress() {
        let walk = TitlebarWalk(caption: true)
        let rt = walk.rt
        let region = TitlebarWalk.region
        rt.pointerDown(at: region, at: 0.0)
        rt.pointerDown(at: region, button: .secondary, at: 0.0)
        rt.windowFocus(false, at: 0.0)
        rt.windowFocus(true, at: 0.0)
        #expect(rt.takeTitlebarAction() == .drag)
        rt.pointerUp(at: region, button: .secondary, at: 0.0)
        #expect(rt.takeWindowMenu() == nil)
        rt.pointerDown(at: region, at: 0.0)
        #expect(rt.takeTitlebarAction() == .drag)
        rt.pointerDown(at: region, at: 0.0)
        #expect(rt.takeTitlebarAction() == .doubleClick)
    }

    private final class WalkCoordinator: @unchecked Sendable {
        let jobs: [(Bool, TitlebarWalk.Letter)]
        private let lock = NSLock()
        private var nextIndex = 0
        private(set) var total = 0
        private(set) var failures: [String] = []

        init(jobs: [(Bool, TitlebarWalk.Letter)]) {
            self.jobs = jobs
        }

        func nextJob() -> (Bool, TitlebarWalk.Letter)? {
            lock.lock()
            defer { lock.unlock() }
            guard nextIndex < jobs.count else { return nil }
            let job = jobs[nextIndex]
            nextIndex += 1
            return job
        }

        func record(ran: Int, failure: String?) {
            lock.lock()
            total += ran
            if let failure { failures.append(failure) }
            lock.unlock()
        }
    }

    @Test("titlebar_press: every short sequence of titlebar presses leaves what dev left")
    func everyShortSequenceOfTitlebarPressesLeavesWhatDevLeft() {
        let jobs: [(Bool, TitlebarWalk.Letter)] = [false, true].flatMap { cap in
            TitlebarWalk.Letter.allCases.map { (cap, $0) }
        }
        let coordinator = WalkCoordinator(jobs: jobs)
        let workers = min(ProcessInfo.processInfo.activeProcessorCount, 8)

        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            var walks = [TitlebarWalk(caption: false), TitlebarWalk(caption: true)]
            var localRan = 0
            var localFailure: String? = nil

            while let (caption, first) = coordinator.nextJob() {
                var seq = [first]
                TitlebarWalk.visit(
                    walk: &walks[caption ? 1 : 0],
                    sequence: &seq,
                    ran: &localRan,
                    failure: &localFailure
                )
            }
            coordinator.record(ran: localRan, failure: localFailure)
        }

        #expect(coordinator.failures.isEmpty, "sequences differ from dev: \(coordinator.failures)")
        #expect(coordinator.total > 100_000, "only \(coordinator.total) sequences ran")
    }
}

// MARK: - Reference Dev Model for `everyShortSequenceOfTitlebarPressesLeavesWhatDevLeft`

private final class TitlebarWalk {
    static let maxLength = 5
    static let interval = 0.3
    static let slop: Float = 4.0
    static let band: Float = 28.0

    static let region = Vec2(100, 50)
    static let regionFar = Vec2(140, 50)
    static let button = Vec2(20, 50)
    static let emptyBand = Vec2(20, 10)
    static let emptyBelow = Vec2(100, 160)

    enum Letter: CaseIterable {
        case region, regionFar, button, emptyBand, emptyBelow
        case secDownRegion, secDownButton, secUpRegion, secUpButton
        case clear, tick, takeAction, takeMenu
    }

    struct DevRun: Equatable {
        var at: Double
        var point: Vec2
        var count: UInt32
    }

    struct DevModel {
        var action: TitlebarAction? = nil
        var run: DevRun? = nil
        var nativeBand: Float
        var secondaryOnRegion = false
        var windowMenu: WindowMenu? = nil

        init(nativeBand: Float) {
            self.nativeBand = nativeBand
        }

        static func follows(_ then: Double, _ was: Vec2, _ now: Double, _ point: Vec2, _ interval: Double) -> Bool {
            now - then <= interval && abs(point.x - was.x) <= slop && abs(point.y - was.y) <= slop
        }

        mutating func pressRegion(now: Double, x: Float, y: Float, interval: Double) {
            action = double(now: now, x: x, y: y, interval: interval) ? .doubleClick : .drag
        }

        mutating func pressEmpty(now: Double, x: Float, y: Float, interval: Double) {
            if y < nativeBand && double(now: now, x: x, y: y, interval: interval) {
                action = .doubleClick
            }
        }

        mutating func clear() {
            run = nil
            secondaryOnRegion = false
        }

        private mutating func double(now: Double, x: Float, y: Float, interval: Double) -> Bool {
            let count: UInt32
            if var last = run, Self.follows(last.at, last.point, now, Vec2(x, y), interval) {
                last.at = now
                last.point = Vec2(x, y)
                last.count += 1
                run = last
                count = last.count
            } else {
                run = DevRun(at: now, point: Vec2(x, y), count: 1)
                count = 1
            }
            if count >= 2 { run = nil }
            return count >= 2
        }

        mutating func secondaryDown(_ region: Bool) {
            secondaryOnRegion = region
        }

        mutating func secondaryUp(_ region: Bool) {
            let was = secondaryOnRegion
            secondaryOnRegion = false
            if was && region { windowMenu = .pointer }
        }

        mutating func takeAction() -> TitlebarAction? {
            defer { action = nil }
            return action
        }

        mutating func takeMenu() -> WindowMenu? {
            defer { windowMenu = nil }
            return windowMenu
        }

        func state() -> (TitlebarPair?, Bool) {
            (run.map { TitlebarPair(at: $0.at, point: $0.point) }, secondaryOnRegion)
        }
    }

    static func stateOf(_ press: TitlebarPressState) -> (TitlebarPair?, Bool) {
        switch press {
        case .rest: return (nil, false)
        case .armed(let p): return (p, false)
        case .secondaryOnRegion(let p): return (p, true)
        }
    }

    let rt: Runtime<()>
    var dev: DevModel
    var now: Double = 0.0
    let caption: Bool

    init(caption: Bool) {
        self.caption = caption
        let rt = Runtime(state: (), viewport: Vec2(200, 200), pixelScale: 1.0, systemDark: true) { _, _ in
            col().size(200, 200)
                .child(el().key("top").size(200, 32))
                .child(
                    row().key("titlebar").size(200, 40).windowDrag()
                        .child(el().key("button").size(40, 40).onClick { _ in })
                )
                .child(el().key("body").size(200, 40))
        }
        rt.doubleClickInterval = Self.interval
        rt.setNativeTitlebarBand(Self.band)
        if caption { rt.setCaption(TitlebarCaption(height: Self.band)) }
        _ = rt.frame(at: 0.0)
        self.rt = rt
        self.dev = DevModel(nativeBand: Self.band)
    }

    func reset() {
        _ = rt.cancelPointerForFocusLoss(at: 0.0)
        rt.kitHooks.titlebar.press = .rest
        rt.kitHooks.titlebar.action = nil
        _ = rt.takeWindowMenu()
        dev = DevModel(nativeBand: Self.band)
        now = 0.0
    }

    func onRegion(_ point: Vec2) -> Bool {
        caption && (point == Self.region || point == Self.regionFar)
    }

    func press(_ point: Vec2, ask: (inout DevModel) -> Void) {
        dev.action = nil
        rt.pointerDown(at: point, at: now)
        rt.pointerUp(at: point, at: now)
        ask(&dev)
    }

    func play(_ letter: Letter) -> String? {
        let t = now
        switch letter {
        case .region:
            press(Self.region) { $0.pressRegion(now: t, x: Self.region.x, y: Self.region.y, interval: Self.interval) }
        case .regionFar:
            press(Self.regionFar) { $0.pressRegion(now: t, x: Self.regionFar.x, y: Self.regionFar.y, interval: Self.interval) }
        case .button:
            press(Self.button) { _ in }
        case .emptyBand:
            press(Self.emptyBand) { $0.pressEmpty(now: t, x: Self.emptyBand.x, y: Self.emptyBand.y, interval: Self.interval) }
        case .emptyBelow:
            press(Self.emptyBelow) { $0.pressEmpty(now: t, x: Self.emptyBelow.x, y: Self.emptyBelow.y, interval: Self.interval) }
        case .secDownRegion, .secDownButton:
            let point = letter == .secDownRegion ? Self.region : Self.button
            rt.pointerDown(at: point, button: .secondary, at: t)
            dev.secondaryDown(onRegion(point))
        case .secUpRegion, .secUpButton:
            let point = letter == .secUpRegion ? Self.region : Self.button
            rt.pointerUp(at: point, button: .secondary, at: t)
            dev.secondaryUp(onRegion(point))
        case .clear:
            rt.clearTitlebarPress()
            dev.clear()
        case .tick:
            now += 0.5
        case .takeAction:
            let ours = rt.takeTitlebarAction()
            let ref = dev.takeAction()
            if ours != ref { return "take action \(String(describing: ours)), dev \(String(describing: ref))" }
        case .takeMenu:
            let ours = rt.takeWindowMenu()
            let ref = dev.takeMenu()
            if ours != ref { return "take menu \(String(describing: ours)), dev \(String(describing: ref))" }
        }
        return compare(letter)
    }

    func compare(_ letter: Letter) -> String? {
        if rt.kitHooks.titlebar.action != dev.action {
            return "after \(letter): action \(String(describing: rt.kitHooks.titlebar.action)), dev \(String(describing: dev.action)), press \(rt.kitHooks.titlebar.press)"
        }
        let ours = Self.stateOf(rt.kitHooks.titlebar.press)
        let ref = dev.state()
        if ours.0 != ref.0 || ours.1 != ref.1 {
            return "after \(letter): press \(ours), dev \(ref)"
        }
        return nil
    }

    static func visit(
        walk: inout TitlebarWalk,
        sequence: inout [Letter],
        ran: inout Int,
        failure: inout String?
    ) {
        guard failure == nil else { return }
        ran += 1
        walk.reset()
        for letter in sequence {
            if let why = walk.play(letter) {
                failure = "cap=\(walk.caption) \(sequence): \(why)"
                return
            }
        }
        if sequence.count == maxLength { return }
        for letter in Letter.allCases {
            sequence.append(letter)
            visit(walk: &walk, sequence: &sequence, ran: &ran, failure: &failure)
            sequence.removeLast()
        }
    }
}
