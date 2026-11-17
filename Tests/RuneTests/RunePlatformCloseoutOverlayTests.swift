import Testing
#if os(macOS)
import QuartzCore
import AppKit
#endif
@testable import Rune

@Suite("RunePlatformCloseoutOverlayTests")
struct RunePlatformCloseoutOverlayTests {
    // MARK: - Helpers

    private static let downPoint = Vec2(20, 20)
    private static let upPoint = Vec2(100, 100)
    private static let unseenGrace = OverlayHold.unseenUpGraceSeconds
    private static let queuedGrace = OverlayHold.queuedUpGraceSeconds
    private static let fadeDuration = 0.200
    private static let afterDuration = 5.0

    private static var seenDown: OverlayHoldEvent { .seen(down: true, at: downPoint, over: true) }
    private static var seenUp: OverlayHoldEvent { .seen(down: false, at: upPoint, over: true) }

    private static func sample(_ buttonDown: Bool, _ now: Double, _ at: Vec2) -> OverlayHoldEvent {
        .sampled(buttonDown: buttonDown, now: now, at: at)
    }

    // MARK: - platform/macos/hold_tests.rs (14 tests)

    @Test("hold: a lost release while dragging gives the press up once where the button rose")
    func holdLostReleaseWhileDragging() {
        var hold = OverlayHold()
        let now = 100.0
        #expect(hold.step(Self.seenDown).isEmpty)
        _ = hold.step(.dispatched(down: true))
        #expect(hold.step(Self.sample(true, now, Vec2(40, 40))).isEmpty)
        if case .pressed = hold.state {} else { Issue.record("expected pressed, got \(hold.state)") }
        _ = hold.step(Self.sample(false, now, Vec2(50, 50)))
        if case .releasing = hold.state {} else { Issue.record("expected releasing, got \(hold.state)") }
        #expect(hold.deadline == now + Self.unseenGrace)
        #expect(hold.step(Self.sample(false, now + 0.099, Vec2(60, 60))).isEmpty)
        #expect(hold.isCaptured)
        #expect(hold.step(Self.sample(false, now + Self.unseenGrace, Vec2(70, 70))) == [.releaseLost(Vec2(50, 50))])
        #expect(hold == OverlayHold())
        #expect(hold.deadline == nil)
        #expect(hold.step(Self.sample(false, now + 1.0, Vec2(80, 80))).isEmpty)
    }

    @Test("hold: a quick press queued before the release reaches the runtime stays held")
    func holdQuickPressQueuedBeforeRelease() {
        var hold = OverlayHold()
        _ = hold.step(Self.seenDown)
        _ = hold.step(Self.seenUp)
        #expect(hold.step(.dispatched(down: true)) == [.deliver(Self.downPoint)])
        #expect(hold.step(Self.seenDown).isEmpty)
        #expect(hold.step(.dispatched(down: false)) == [.deliver(Self.upPoint)])
        _ = hold.step(.released)
        #expect(hold.isCaptured)
        #expect(hold.step(.dispatched(down: true)) == [.deliver(Self.downPoint)])
        _ = hold.step(Self.seenUp)
        #expect(hold.step(.dispatched(down: false)) == [.deliver(Self.upPoint)])
        _ = hold.step(.released)
        #expect(hold == OverlayHold())
    }

    @Test("hold: two queued presses with no up between end the first between them")
    func holdTwoQueuedPressesWithNoUpBetween() {
        var hold = OverlayHold()
        let now = 100.0
        _ = hold.step(Self.seenDown)
        _ = hold.step(Self.sample(false, now, Vec2(50, 50)))
        #expect(hold.step(Self.seenDown).isEmpty)
        if case .pressed = hold.state {} else { Issue.record("expected pressed, got \(hold.state)") }
        #expect(hold.step(.dispatched(down: true)) == [.deliver(Self.downPoint)])
        #expect(hold.step(.dispatched(down: true)) == [.releaseLost(Vec2(50, 50)), .deliver(Self.downPoint)])
        _ = hold.step(Self.seenUp)
        #expect(hold.step(.dispatched(down: false)) == [.deliver(Self.upPoint)])
        _ = hold.step(.released)
        #expect(hold == OverlayHold())
    }

    @Test("hold: a press that beats the grace ends the dispatched press where the button rose")
    func holdPressBeatsGrace() {
        var hold = OverlayHold()
        let now = 100.0
        _ = hold.step(Self.seenDown)
        _ = hold.step(.dispatched(down: true))
        _ = hold.step(Self.sample(false, now, Vec2(50, 50)))
        #expect(hold.step(Self.seenDown).isEmpty)
        if case .pressed = hold.state {} else { Issue.record("expected pressed, got \(hold.state)") }
        #expect(hold.deadline == nil)
        #expect(hold.step(.dispatched(down: true)) == [.releaseLost(Vec2(50, 50)), .deliver(Self.downPoint)])
    }

    @Test("hold: a sample that beats the next press keeps the release point")
    func holdSampleBeatsNextPress() {
        var hold = OverlayHold()
        let now = 100.0
        _ = hold.step(Self.seenDown)
        _ = hold.step(.dispatched(down: true))
        _ = hold.step(Self.sample(false, now, Vec2(50, 50)))
        #expect(hold.step(Self.sample(true, now, Vec2(55, 55))).isEmpty)
        #expect(hold.deadline == nil)
        _ = hold.step(Self.seenDown)
        #expect(hold.step(.dispatched(down: true)) == [.releaseLost(Vec2(50, 50)), .deliver(Self.downPoint)])
    }

    @Test("hold: a rebounding button gives up where it first rose after a fresh grace")
    func holdReboundingButtonFreshGrace() {
        var hold = OverlayHold()
        let now = 100.0
        _ = hold.step(Self.seenDown)
        _ = hold.step(.dispatched(down: true))
        _ = hold.step(Self.sample(false, now, Vec2(50, 50)))
        _ = hold.step(Self.sample(true, now, Vec2(55, 55)))
        let later = now + 1.0
        _ = hold.step(Self.sample(false, later, Vec2(60, 60)))
        #expect(hold.deadline == later + Self.unseenGrace)
        #expect(hold.step(Self.sample(false, later + Self.unseenGrace, Vec2(70, 70))) == [.releaseLost(Vec2(50, 50))])
    }

    @Test("hold: acknowledging an older up keeps the queued press's release")
    func holdAckOlderUpKeepsQueuedPressRelease() {
        var hold = OverlayHold()
        let now = 100.0
        _ = hold.step(Self.seenDown)
        _ = hold.step(.dispatched(down: true))
        _ = hold.step(Self.seenUp)
        _ = hold.step(Self.seenDown)
        _ = hold.step(Self.sample(false, now, Vec2(50, 50)))
        _ = hold.step(.dispatched(down: false))
        _ = hold.step(.released)
        _ = hold.step(Self.sample(false, now, Vec2(70, 70)))
        _ = hold.step(.dispatched(down: true))
        #expect(hold.deadline == now + Self.unseenGrace)
        #expect(hold.step(Self.sample(false, now + Self.unseenGrace, Vec2(80, 80))) == [.releaseLost(Vec2(50, 50))])
    }

    @Test("hold: a position ends the press before the front click without taking it")
    func holdPositionEndsPressBeforeFrontClick() {
        var hold = OverlayHold()
        _ = hold.step(Self.seenDown)
        _ = hold.step(.seen(down: true, at: Vec2(30, 30), over: true))
        #expect(hold.step(.positioning).isEmpty)
        #expect(hold.step(.dispatched(down: true)) == [.deliver(Self.downPoint)])
        #expect(hold.step(.positioning) == [.releaseLost(Self.downPoint)])
        #expect(hold.step(.dispatched(down: true)) == [.deliver(Vec2(30, 30))])
    }

    @Test("hold: with no rise read a press ends where it was last read down")
    func holdNoRiseEndsWhereLastReadDown() {
        var hold = OverlayHold()
        let now = 100.0
        _ = hold.step(Self.sample(false, now, Vec2(5, 5)))
        _ = hold.step(Self.seenDown)
        _ = hold.step(.dispatched(down: true))
        _ = hold.step(Self.sample(true, now, Vec2(25, 25)))
        _ = hold.step(.seen(down: true, at: Vec2(30, 30), over: true))
        #expect(hold.step(.dispatched(down: true)) == [.releaseLost(Vec2(25, 25)), .deliver(Vec2(30, 30))])
    }

    @Test("hold: a press after a lost release starts a new hold")
    func holdPressAfterLostReleaseStartsNewHold() {
        var hold = OverlayHold()
        let now = 100.0
        _ = hold.step(Self.seenDown)
        _ = hold.step(Self.sample(false, now, Vec2(50, 50)))
        #expect(hold.step(Self.sample(false, now + Self.unseenGrace, Vec2(50, 50))) == [.releaseLost(Vec2(50, 50))])
        _ = hold.step(Self.seenDown)
        #expect(hold.isCaptured)
        #expect(hold.step(Self.sample(true, now + 1.0, Vec2(50, 50))).isEmpty)
    }

    @Test("hold: a queued up gets the longer grace")
    func holdQueuedUpGetsLongerGrace() {
        var hold = OverlayHold()
        let now = 100.0
        _ = hold.step(Self.seenDown)
        _ = hold.step(Self.seenUp)
        _ = hold.step(Self.sample(false, now, Vec2(20, 20)))
        #expect(hold.deadline == now + Self.queuedGrace)
        #expect(hold.step(Self.sample(false, now + 1.999, Vec2(20, 20))).isEmpty)
        #expect(hold.step(Self.sample(false, now + Self.queuedGrace, Vec2(30, 30))) == [.releaseLost(Vec2(20, 20))])
    }

    @Test("hold: an up with no seen press stays free and still dispatches")
    func holdUpWithNoSeenPressStaysFree() {
        var hold = OverlayHold()
        _ = hold.step(Self.seenUp)
        #expect(!hold.isCaptured)
        #expect(hold.step(.dispatched(down: true)).isEmpty)
        #expect(hold.step(.dispatched(down: false)) == [.deliver(Self.upPoint)])
    }

    @Test("hold: losing the view gives up where the pointer was and hiding stays silent")
    func holdLosingViewGivesUpAndStoppingStaysSilent() {
        var hold = OverlayHold()
        _ = hold.step(Self.seenDown)
        _ = hold.step(Self.sample(true, 100.0, Vec2(25, 15)))
        #expect(hold.step(.viewLost(last: Vec2(5, 5))) == [.releaseLost(Vec2(25, 15))])
        #expect(hold.step(.viewLost(last: Vec2(25, 15))) == [.releaseLost(Vec2(25, 15))])
        #expect(hold == OverlayHold())
        _ = hold.step(Self.seenDown)
        #expect(hold.step(.stopped).isEmpty)
        #expect(hold == OverlayHold())
    }

    @Test("hold: the button is known up once a sample or the monitor says so")
    func holdButtonKnownUpOnceSampleOrMonitorSaysSo() {
        var hold = OverlayHold()
        let now = 100.0
        #expect(!hold.isButtonUp)
        _ = hold.step(Self.seenDown)
        #expect(!hold.isButtonUp)
        _ = hold.step(.dispatched(down: true))
        #expect(!hold.isButtonUp)
        _ = hold.step(Self.seenUp)
        #expect(hold.isButtonUp)
        _ = hold.step(.dispatched(down: false))
        _ = hold.step(.released)
        _ = hold.step(Self.seenDown)
        _ = hold.step(.dispatched(down: true))
        _ = hold.step(Self.sample(false, now, Vec2(30, 30)))
        #expect(hold.isButtonUp)
        _ = hold.step(Self.sample(true, now, Vec2(30, 30)))
        #expect(hold.isButtonUp)
        _ = hold.step(Self.seenDown)
        #expect(!hold.isButtonUp)
    }

    // MARK: - platform/macos/pointer_tests.rs (11 tests)

    @Test("pointer: handlerless hit releases native ownership in every input mode")
    func pointerHandlerlessHitReleasesNativeOwnershipInEveryMode() {
        for mode in [OverlayInput.regions, OverlayInput.none] {
            let pointer = OverlayPointerState(
                input: .regions,
                regions: [MotionRect.fromXYWH(10, 10, 20, 20)]
            )
            pointer.recordClick(down: true, at: Vec2(20, 20))
            let downEdge = pointer.takeEdge(down: true)
            #expect(downEdge.point == Vec2(20, 20))
            #expect(pointer.isCaptured)
            pointer.recordClick(down: false, at: Vec2(50, 50))
            pointer.input = mode
            let upEdge = pointer.takeEdge(down: false)
            #expect(upEdge.point == Vec2(50, 50))
            pointer.released()
            #expect(!pointer.isCaptured)
            #expect(!pointer.hit(Vec2(50, 50)))
        }
    }

    @Test("pointer: a click-through overlay that follows nothing never samples the pointer")
    func pointerClickThroughNeverSamples() {
        let pointer = OverlayPointerState(input: .none)
        #expect(!pointer.isWanted)
        pointer.followPointer = true
        #expect(pointer.isWanted)
        pointer.followPointer = false
        _ = pointer.apply(.seen(down: true, at: .zero, over: true))
        #expect(pointer.isWanted)
        pointer.stopped()
        for input in [OverlayInput.regions, OverlayInput.all] {
            pointer.input = input
            #expect(pointer.isWanted)
        }
    }

    @Test("pointer: lost up recovers once after grace using release position")
    func pointerLostUpRecoversOnceAfterGrace() {
        let pointer = OverlayPointerState(
            input: .regions,
            regions: [MotionRect.fromXYWH(10, 10, 30, 30)]
        )
        pointer.recordClick(down: true, at: Vec2(20, 20))
        let now = 200.0
        pointer.observeRelease(buttons: 1, now: now, at: Vec2(40, 40))
        pointer.observeRelease(buttons: 0, now: now, at: Vec2(50, 50))
        pointer.observeRelease(buttons: 0, now: now + 0.099, at: Vec2(60, 60))
        #expect(pointer.isCaptured)
        pointer.observeRelease(buttons: 0, now: now + 0.100, at: Vec2(70, 70))
        #expect(!pointer.isCaptured)
        #expect(pointer.hold.clicks.isEmpty)
        #expect(pointer.takeRecoveredRelease() == Vec2(50, 50))
        pointer.observeRelease(buttons: 0, now: now + 1.0, at: Vec2(80, 80))
        #expect(pointer.takeRecoveredRelease() == nil)
    }

    @Test("pointer: queued up and next down keep their ownership until dispatched")
    func pointerQueuedUpAndNextDownKeepOwnership() {
        let pointer = OverlayPointerState(
            input: .regions,
            regions: [MotionRect.fromXYWH(10, 10, 30, 30)]
        )
        pointer.recordClick(down: true, at: Vec2(20, 20))
        pointer.recordClick(down: false, at: Vec2(100, 100))
        let now = 200.0
        pointer.observeRelease(buttons: 0, now: now, at: Vec2(100, 100))
        pointer.observeRelease(buttons: 0, now: now + 1.0, at: Vec2(100, 100))
        #expect(pointer.isCaptured)
        #expect(pointer.recoveredRelease == nil)
        pointer.recordClick(down: true, at: Vec2(20, 20))
        _ = pointer.takeEdge(down: true)
        _ = pointer.takeEdge(down: false)
        pointer.released()
        #expect(pointer.recoveredRelease == nil)
        #expect(pointer.isCaptured)
        _ = pointer.takeEdge(down: true)
        pointer.released()
        #expect(!pointer.isCaptured)
    }

    @Test("pointer: undelivered click releases capture after stall")
    func pointerUndeliveredClickReleasesAfterStall() {
        let pointer = OverlayPointerState(
            input: .regions,
            regions: [MotionRect.fromXYWH(10, 10, 30, 30)]
        )
        pointer.recordClick(down: true, at: Vec2(20, 20))
        pointer.recordClick(down: false, at: Vec2(20, 20))
        let now = 200.0
        pointer.observeRelease(buttons: 0, now: now, at: Vec2(20, 20))
        pointer.observeRelease(buttons: 0, now: now + 1.999, at: Vec2(20, 20))
        #expect(pointer.isCaptured)
        pointer.observeRelease(buttons: 0, now: now + 2.0, at: Vec2(20, 20))
        #expect(!pointer.isCaptured)
        #expect(pointer.hold.clicks.isEmpty)
        #expect(!pointer.hit(Vec2(50, 50)))
    }

    @Test("pointer: lost view releases capture where the pointer was")
    func pointerLostViewReleasesCapture() {
        let pointer = OverlayPointerState(
            input: .regions,
            regions: [MotionRect.fromXYWH(10, 10, 30, 30)]
        )
        pointer.recordClick(down: true, at: Vec2(20, 20))
        pointer.read(buttons: 1, now: 200.0, at: Vec2(25, 15), inside: true, displayChanged: false)
        pointer.viewLost()
        #expect(!pointer.isCaptured)
        #expect(pointer.hold.clicks.isEmpty)
        #expect(pointer.takeRecoveredRelease() == Vec2(25, 15))
    }

    @Test("pointer: rejected down cannot poison later click and owned up survives exit")
    func pointerRejectedDownCannotPoisonLaterClick() {
        let pointer = OverlayPointerState(
            input: .regions,
            regions: [MotionRect.fromXYWH(10, 10, 30, 30)]
        )
        pointer.recordClick(down: true, at: Vec2(1, 1))
        pointer.recordClick(down: true, at: Vec2(20, 20))
        pointer.recordClick(down: false, at: Vec2(100, 100))
        #expect(pointer.hold.clicks == [
            OverlayHoldClick(down: true, at: Vec2(20, 20), ends: nil),
            OverlayHoldClick(down: false, at: Vec2(100, 100), ends: nil),
        ])
        #expect(pointer.hit(Vec2(100, 100)))
        pointer.stopped()
        #expect(!pointer.hit(Vec2(100, 100)))
    }

    @Test("pointer: a covered overlay rests its poll but keeps a lost release's deadline")
    func pointerCoveredOverlayRestsPollKeepsLostDeadline() {
        let pointer = OverlayPointerState(input: .all)
        let now = 200.0
        let poll = now + 0.008
        #expect(pointer.deadline(poll: poll, occluded: false) == poll)
        #expect(pointer.deadline(poll: poll, occluded: true) == nil)
        pointer.recordClick(down: true, at: Vec2(20, 20))
        _ = pointer.takeEdge(down: true)
        #expect(pointer.deadline(poll: poll, occluded: true) == nil)
        pointer.observeRelease(buttons: 0, now: now, at: Vec2(20, 20))
        let due = now + 0.100
        #expect(pointer.deadline(poll: poll, occluded: true) == due)
        #expect(pointer.deadline(poll: poll, occluded: false) == poll)
        pointer.observeRelease(buttons: 0, now: due, at: Vec2(20, 20))
        #expect(pointer.deadline(poll: poll, occluded: true) == nil)
    }

    @Test("pointer: a queued press hands over the release lost before it")
    func pointerQueuedPressHandsOverLostRelease() {
        let pointer = OverlayPointerState(input: .all)
        pointer.recordClick(down: true, at: Vec2(20, 20))
        pointer.observeRelease(buttons: 0, now: 200.0, at: Vec2(50, 50))
        pointer.recordClick(down: true, at: Vec2(30, 30))
        let first = pointer.takeEdge(down: true)
        #expect(first.lostRelease == nil && first.point == Vec2(20, 20))
        let second = pointer.takeEdge(down: true)
        #expect(second.lostRelease == Vec2(50, 50) && second.point == Vec2(30, 30))
    }

    @Test("pointer: a sample beating the next press delivers lost release at rise position")
    func pointerSampleBeatingNextPressDeliversLostReleaseAtRise() {
        let pointer = OverlayPointerState(input: .all)
        let now = 200.0
        pointer.recordClick(down: true, at: Vec2(10, 10))
        _ = pointer.takeEdge(down: true)
        pointer.observeRelease(buttons: 0, now: now, at: Vec2(50, 50))
        pointer.observeRelease(buttons: 1, now: now, at: Vec2(70, 70))
        pointer.recordClick(down: true, at: Vec2(70, 70))
        let edge = pointer.takeEdge(down: true)
        #expect(edge.lostRelease == Vec2(50, 50))
        #expect(edge.point == Vec2(70, 70))
    }

    @Test("pointer: a press lost before any sample delivers lost release at its own down")
    func pointerPressLostBeforeSampleDeliversOwnDown() {
        let pointer = OverlayPointerState(input: .all)
        pointer.read(buttons: 0, now: 200.0, at: Vec2(5, 5), inside: true, displayChanged: false)
        pointer.recordClick(down: true, at: Vec2(50, 10))
        let first = pointer.takeEdge(down: true)
        #expect(first.lostRelease == nil && first.point == Vec2(50, 10))
        pointer.recordClick(down: true, at: Vec2(51, 10))
        let second = pointer.takeEdge(down: true)
        #expect(second.lostRelease == Vec2(50, 10) && second.point == Vec2(51, 10))
    }

    // MARK: - overlay/presence_tests.rs (10 tests)

    @Test("presence: a fade out keeps drawing without input until it ends")
    func presenceFadeOutKeepsDrawingUntilEnd() {
        let t0 = 100.0
        var p = OverlayPresence.shown(occluded: false)
        #expect(p.step(.hide(fadeSeconds: Self.fadeDuration, now: t0), release: .now) == [.hideWindow(fadeSeconds: Self.fadeDuration)])
        #expect(!p.isShown && p.isDrawing && p.isFading)
        #expect(p.deadline == t0 + Self.fadeDuration)
        #expect(p.step(.due(now: t0 + Self.fadeDuration / 2.0), release: .now).isEmpty)
        #expect(p.step(.due(now: t0 + Self.fadeDuration), release: .now) == [.stopDrawing, .hideWindow(fadeSeconds: 0), .releaseGpu])
        #expect(p == .hidden(releaseAt: nil))
    }

    @Test("presence: hiding at once stops drawing then releases by policy")
    func presenceHidingAtOnceStopsDrawingAndReleasesByPolicy() {
        let t0 = 100.0
        let hide = OverlayPresenceEvent.hide(fadeSeconds: 0, now: t0)
        var keep = OverlayPresence.shown(occluded: false)
        #expect(keep.step(hide, release: .keep) == [.stopDrawing, .hideWindow(fadeSeconds: 0)])
        #expect(keep == .hidden(releaseAt: nil))

        var later = OverlayPresence.shown(occluded: false)
        #expect(later.step(hide, release: .after(Self.afterDuration)) == [.stopDrawing, .hideWindow(fadeSeconds: 0)])
        #expect(later == .hidden(releaseAt: t0 + Self.afterDuration))
        #expect(later.step(.due(now: t0 + Self.afterDuration / 2.0), release: .after(Self.afterDuration)).isEmpty)
        #expect(later.step(.due(now: t0 + Self.afterDuration), release: .after(Self.afterDuration)) == [.releaseGpu])
        #expect(later.deadline == nil)
    }

    @Test("presence: showing cancels a fade and its end is stale")
    func presenceShowingCancelsFade() {
        let t0 = 100.0
        var p = OverlayPresence.shown(occluded: false)
        _ = p.step(.hide(fadeSeconds: Self.fadeDuration, now: t0), release: .now)
        #expect(p.step(.show, release: .now).isEmpty)
        #expect(p == .shown(occluded: false))
        #expect(p.step(.due(now: t0 + Self.fadeDuration * 2.0), release: .now).isEmpty)
        #expect(p.isShown)
    }

    @Test("presence: showing cancels a pending release and its time is stale")
    func presenceShowingCancelsPendingRelease() {
        let t0 = 100.0
        let release = OverlayGpuRelease.after(Self.afterDuration)
        var p = OverlayPresence.shown(occluded: false)
        _ = p.step(.hide(fadeSeconds: 0, now: t0), release: release)
        _ = p.step(.show, release: release)
        #expect(p.deadline == nil)
        let t1 = t0 + Self.afterDuration / 2.0
        _ = p.step(.hide(fadeSeconds: 0, now: t1), release: release)
        #expect(p.step(.due(now: t0 + Self.afterDuration), release: release).isEmpty)
        #expect(p.step(.due(now: t1 + Self.afterDuration), release: release) == [.releaseGpu])
    }

    @Test("presence: fading again restarts the fade")
    func presenceFadingAgainRestartsFade() {
        let t0 = 100.0
        var p = OverlayPresence.shown(occluded: false)
        _ = p.step(.hide(fadeSeconds: Self.fadeDuration, now: t0), release: .keep)
        let t1 = t0 + Self.fadeDuration / 2.0
        #expect(p.step(.hide(fadeSeconds: Self.fadeDuration * 2.0, now: t1), release: .keep) == [.hideWindow(fadeSeconds: Self.fadeDuration * 2.0)])
        #expect(p == .fadingOut(until: t1 + Self.fadeDuration * 2.0, length: Self.fadeDuration * 2.0, occluded: false))
        #expect(p.step(.due(now: t0 + Self.fadeDuration), release: .keep).isEmpty)
    }

    @Test("presence: hiding mid-fade without one ends it now")
    func presenceHidingMidFadeEndsNow() {
        let t0 = 100.0
        var p = OverlayPresence.shown(occluded: false)
        _ = p.step(.hide(fadeSeconds: Self.fadeDuration, now: t0), release: .after(Self.afterDuration))
        let t1 = t0 + Self.fadeDuration / 2.0
        #expect(p.step(.hide(fadeSeconds: 0, now: t1), release: .after(Self.afterDuration)) == [.stopDrawing, .hideWindow(fadeSeconds: 0)])
        #expect(p == .hidden(releaseAt: t1 + Self.afterDuration))
    }

    @Test("presence: hiding a hidden overlay leaves its release alone")
    func presenceHidingHiddenLeavesReleaseAlone() {
        let t0 = 100.0
        var p = OverlayPresence.hidden(releaseAt: t0 + Self.afterDuration)
        #expect(p.step(.hide(fadeSeconds: Self.fadeDuration, now: t0 + Self.afterDuration / 2.0), release: .after(Self.afterDuration)) == [.stopDrawing, .hideWindow(fadeSeconds: Self.fadeDuration)])
        #expect(p == .hidden(releaseAt: t0 + Self.afterDuration))

        var never = OverlayPresence.initial
        #expect(never.step(.hide(fadeSeconds: 0, now: t0), release: .now) == [.stopDrawing, .hideWindow(fadeSeconds: 0)])
    }

    @Test("presence: a fading panel never becomes covered but one that was stays so")
    func presenceFadingPanelNeverBecomesCovered() {
        let t0 = 100.0
        var p = OverlayPresence.shown(occluded: false)
        _ = p.step(.hide(fadeSeconds: Self.fadeDuration, now: t0), release: .keep)
        #expect(!p.setOccluded(true) && !p.isOccluded)

        var covered = OverlayPresence.shown(occluded: true)
        _ = covered.step(.hide(fadeSeconds: Self.fadeDuration, now: t0), release: .keep)
        #expect(covered.isOccluded)
        #expect(covered.setOccluded(false) && !covered.isOccluded)
    }

    @Test("presence: a hidden overlay keeps no occlusion and a show reads it again")
    func presenceHiddenKeepsNoOcclusion() {
        var p = OverlayPresence.initial
        let applied = p.setOccluded(true)
        #expect(applied)
        #expect(!p.isOccluded)

        var covered = OverlayPresence.shown(occluded: true)
        _ = covered.step(.hide(fadeSeconds: 0, now: 100.0), release: .keep)
        _ = covered.step(.show, release: .keep)
        #expect(covered == .shown(occluded: false))
    }

    @Test("presence: release follows the platform")
    func presenceReleaseFollowsPlatform() {
        #expect(OverlayGpuRelease.make(afterSeconds: nil, isMacOS: true) == .keep)
        #expect(OverlayGpuRelease.make(afterSeconds: nil, isMacOS: false) == .keep)
        #expect(OverlayGpuRelease.make(afterSeconds: 0, isMacOS: true) == .now)
        #expect(OverlayGpuRelease.make(afterSeconds: 0, isMacOS: false) == .now)
        #expect(OverlayGpuRelease.make(afterSeconds: Self.afterDuration, isMacOS: true) == .keep)
        #expect(OverlayGpuRelease.make(afterSeconds: Self.afterDuration, isMacOS: false) == .after(Self.afterDuration))
    }

    #if os(macOS)
    // MARK: - platform/macos/geometry_tests.rs (1 test)

    @Test("geometry: overlay appkit top row belongs to secondary display")
    @MainActor
    func geometryAppKitTopRowBelongsToSecondaryDisplay() {
        let secondary = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        #expect(RuneOverlayMacOSHost<Int>.containsAppKitPoint(secondary, point: NSPoint(x: -100, y: 1080)))
        #expect(!RuneOverlayMacOSHost<Int>.containsAppKitPoint(secondary, point: NSPoint(x: -100, y: 0)))
        #expect(!RuneOverlayMacOSHost<Int>.containsAppKitPoint(secondary, point: NSPoint(x: 0, y: 500)))
        let below = NSRect(x: -1920, y: -1080, width: 1920, height: 1080)
        #expect(RuneOverlayMacOSHost<Int>.containsAppKitPoint(below, point: NSPoint(x: -100, y: 0)))
    }

    // MARK: - platform/macos/surface_tests.rs (1 test)

    @Test("surface: a metal layer pins its contents to the window top left")
    @MainActor
    func surfaceMetalLayerPinsContentsTopLeft() {
        for flipped in [true, false] {
            let parent = CALayer()
            parent.isGeometryFlipped = flipped
            let layer = CAMetalLayer()
            parent.addSublayer(layer)
            MacOSMetalLayerSurface.pinContentsTopLeft(layer)
            #expect(layer.contentsGravity == (flipped ? .bottomLeft : .topLeft))
            #expect(layer.colorspace?.name == CGColorSpace.sRGB)
        }
    }
    #endif
}
