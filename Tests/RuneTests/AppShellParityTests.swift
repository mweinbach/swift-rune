import Foundation
import Testing
@testable import Rune

@Suite("App, AppHandle, AppSpec poll/setup, Compositor & Frame Clock Parity Tests")
struct AppShellParityTests {
    private struct CounterState {
        var count: Int = 0
        var polls: Int = 0
        var focusEvents: [Bool] = []
        var imeEvents: [Ime] = []
        var closeAllowed: Bool = true
        var quitCalled: Bool = false
        var reopenArgs: [Bool] = []
        var openedUrls: [String] = []
        var encodedFrames: [FrameEncoded] = []
    }

    private func makeTestApp() -> App<CounterState> {
        App<CounterState>(title: "TestApp", size: Vec2(320, 240), state: CounterState()) { s, _ in
            el().size(Float(10 + s.count), 20)
        }
    }

    // MARK: - AppHandle & AppShared Request Coalescing (app.rs unit tests)

    @Test("App defaults srgbBlend to true and FontSmoothing to systemDefault")
    func appDefaults() {
        let app = makeTestApp()
        #expect(app.srgbBlendEnabled == true)
        #expect(app.fontSmoothingMode == .systemDefault)
        let rt = app.makeRuntime()
        #expect(rt.srgbBlend == true)
        #expect(rt.windowTitle == "TestApp")

        let spec = AppSpec<CounterState>(state: CounterState()) { _, _ in el() }
        #expect(spec.srgbBlend == true)
    }

    @Test("AppHandle open, show, hide, focus, activate, close coalescing")
    func handleRequestCoalescing() {
        let shared = AppShared<CounterState>()
        let wakes = LockedCounter()
        shared.setWaker(Waker { wakes.inc() })
        let handle = AppHandle(shared: shared)

        // show after open stays open; show keeps minimize
        handle.open()
        handle.show()
        var drained = shared.drain()
        #expect(drained.window == .open)
        #expect(wakes.value == 2)

        handle.minimize()
        handle.show()
        drained = shared.drain()
        #expect(drained.window == .show)
        #expect(drained.activation == .minimize)

        // hide / close cancel minimize while preserving focus/activate, and hide replaces close
        handle.minimize()
        handle.hide()
        drained = shared.drain()
        #expect(drained.window == .hide)
        #expect(drained.activation == .none)

        handle.focus()
        handle.close()
        handle.hide()
        drained = shared.drain()
        #expect(drained.window == .hide)
        #expect(drained.activation == .focus)

        // focus keeps activate if already set; focus cancels minimize
        handle.minimize()
        handle.focus()
        drained = shared.drain()
        #expect(drained.activation == .focus)

        // minimize after focus: last wins
        handle.focus()
        handle.minimize()
        drained = shared.drain()
        #expect(drained.activation == .minimize)

        // activate upgrades focus and clears minimize
        handle.minimize()
        handle.activate()
        drained = shared.drain()
        #expect(drained.activation == .activate)

        // close preserves focus (and cancels minimize)
        handle.open()
        handle.focus()
        handle.close()
        drained = shared.drain()
        #expect(drained.window == .close)
        #expect(drained.activation == .focus)
    }

    @Test("AppShared position and place are last-wins without mutating window or activation")
    func trayShowAndPositionPreserved() {
        let shared = AppShared<CounterState>()
        let handle = AppHandle(shared: shared)

        handle.show()
        handle.setPosition(Vec2(120, 48))
        handle.update { s, _ in s.count += 1 }

        let drained = shared.drain()
        #expect(drained.window == .show)
        #expect(drained.position == Vec2(120, 48))
        #expect(drained.place == nil)
        #expect(drained.updates.count == 1)

        handle.setPosition(Vec2(10, 20))
        handle.place(PlaceRequest(position: Vec2(200, 300), size: Vec2(400, 500), activate: false))
        let drainedPlace = shared.drain()
        #expect(drainedPlace.window == .none)
        #expect(drainedPlace.position == nil)
        #expect(drainedPlace.place?.position == Vec2(200, 300))
        #expect(drainedPlace.place?.size == Vec2(400, 500))
        #expect(drainedPlace.activation == .none)

        handle.place(PlaceRequest(position: Vec2(1, 2)))
        handle.setPosition(Vec2(50, 60))
        let drainedPos = shared.drain()
        #expect(drainedPos.position == Vec2(50, 60))
        #expect(drainedPos.place == nil)
    }

    @Test("AppShared applyStateUpdates executes updates first so open/close/quit apply in same drain")
    func nestedUpdateDoesNotDeadlock() {
        let rt = makeTestApp().makeRuntime()
        let shared = AppShared<CounterState>()
        let wakes = LockedCounter()
        shared.setWaker(Waker { wakes.inc() })
        let handle = AppHandle(shared: shared)

        handle.update { s, _ in
            s.count += 1
            handle.open()
            handle.update { inner, _ in
                inner.count += 10
            }
        }
        let first = shared.applyStateUpdates(to: rt, at: 0.1)
        #expect(first.window == .open)
        #expect(rt.state.count == 1)
        let second = shared.applyStateUpdates(to: rt, at: 0.2)
        #expect(second.window == .none)
        #expect(second.updates.count == 1)
        #expect(rt.state.count == 11)
    }

    // MARK: - Zero-Rebuild `updateIf` & `poll(t)`

    @Test("Runtime updateIf and poll returning false deliver side-effects without triggering view rebuild")
    func updateIfAndPollFalseDoNotRebuild() {
        let app = makeTestApp()
            .poll { s, _, _ in
                s.polls += 1
                return false
            }
        let rt = app.makeRuntime()
        _ = rt.frame(at: 0.0)
        let commitsAfterInit = rt.viewCommitCount
        #expect(commitsAfterInit == 1)
        #expect(rt.state.polls == 1)
        #expect(!rt.isStale)

        // updateIf returning false with tx side effects (copy, wakeAfter, quit) still delivers
        // requests without staling or rebuilding the tree (`app.rs:1240-1251`)
        let changed = rt.updateIf(at: 0.1) { _, tx in
            tx.copyText("unchanged")
            tx.wakeAfter(0.5)
            return false
        }
        #expect(changed == false)
        #expect(!rt.isStale)
        #expect(rt.clipboard.text == "unchanged")
        #expect(rt.nextWakeDeadline == 0.6)

        _ = rt.frame(at: 0.1)
        #expect(rt.state.polls == 2)
        #expect(rt.viewCommitCount == commitsAfterInit)

        // tx.commit() explicitly forces rebuild even when returning false
        _ = rt.updateIf(at: 0.15) { _, tx in
            tx.commit()
            return false
        }
        #expect(rt.isStale)
        _ = rt.frame(at: 0.15)
        #expect(rt.viewCommitCount == commitsAfterInit + 1)

        // Mutating poll returning true DOES rebuild on the same frame
        rt.poll = { s, _, _ in
            s.polls += 1
            s.count = 42
            return true
        }
        _ = rt.frame(at: 0.2)
        #expect(rt.state.count == 42)
        #expect(rt.viewCommitCount == commitsAfterInit + 2)
    }

    @Test("Runtime dispatchFocus deduplicates and avoids staling when onFocus is unset")
    func focusDeduplication() {
        let plain = makeTestApp().makeRuntime()
        _ = plain.frame(at: 0.0)
        #expect(!plain.isStale)
        plain.dispatchFocus(false, at: 0.1)
        #expect(plain.windowFocused == false)
        #expect(!plain.isStale)

        let rt = makeTestApp()
            .onFocus { s, focused, _ in
                s.focusEvents.append(focused)
            }
            .makeRuntime()

        // Default windowFocused is true, so dispatching true is a no-op
        rt.dispatchFocus(true, at: 0.1)
        #expect(rt.state.focusEvents.isEmpty)

        rt.dispatchFocus(false, at: 0.2)
        rt.dispatchFocus(false, at: 0.3)
        rt.dispatchFocus(true, at: 0.4)
        #expect(rt.state.focusEvents == [false, true])
    }

    @Test("Runtime lifecycle hooks: onIme, onClose, onQuit, onReopen, onOpenUrl, turnScope")
    func lifecycleAndTxHooks() {
        let scopeEntered = LockedCounter()
        let rt = makeTestApp()
            .turnScope { s, body in
                scopeEntered.inc()
                body(&s)
            }
            .onIme { s, ev, _ in
                s.imeEvents.append(ev)
                return true
            }
            .onClose { s, tx in
                if !s.closeAllowed { return false }
                tx.closeWindow()
                return true
            }
            .onQuit { s, _ in
                s.quitCalled = true
            }
            .onReopen { s, visible, _ in
                s.reopenArgs.append(visible)
                return true
            }
            .onOpenUrl { s, url, tx in
                s.openedUrls.append(url)
                tx.setWindowTitle("URL: \(url)")
            }
            .makeRuntime()

        #expect(rt.dispatchIme(.commit("こんにちは"), at: 0.1) == true)
        #expect(rt.state.imeEvents == [.commit("こんにちは")])

        rt.state.closeAllowed = false
        #expect(rt.dispatchClose(at: 0.2) == false)
        #expect(rt.closeWindowRequested == false)

        rt.state.closeAllowed = true
        #expect(rt.dispatchClose(at: 0.3) == true)
        #expect(rt.closeWindowRequested == true)

        rt.dispatchQuit(at: 0.4)
        #expect(rt.state.quitCalled == true)

        #expect(rt.dispatchReopen(hasVisibleWindows: false, at: 0.5) == true)
        #expect(rt.state.reopenArgs == [false])

        rt.dispatchOpenUrl("rune://open/doc", at: 0.6)
        #expect(rt.state.openedUrls == ["rune://open/doc"])
        #expect(rt.windowTitle == "URL: rune://open/doc")
        #expect(scopeEntered.value >= 5)

        // Tx shell toggles
        rt.update(at: 0.7) { _, tx in
            tx.setSrgbBlend(false)
            tx.setFontSmoothing(.off)
            tx.minimize()
            tx.wakeAfter(0.25)
        }
        #expect(rt.srgbBlend == false)
        #expect(rt.fontSmoothing == .off)
        #expect(rt.minimizeRequested == true)
        #expect(rt.nextWakeDeadline == 0.95)
        rt.clearShellRequests()
        #expect(rt.minimizeRequested == false)
        #expect(rt.nextWakeDeadline == nil)
    }

    // MARK: - Headless App + Compositor + setup(Waker) + AppSpec Parity

    private final class MockCompositor: Compositor {
        typealias State = CounterState
        var renderCalls: Int = 0
        var uiDraws: Int = 0
        var lastSrgbBlend: Bool?
        var isAnimating: Bool { false }
        var drawsOwnContent: Bool { false }

        func render(frame: CompositorFrame<CounterState>) {
            renderCalls += 1
            lastSrgbBlend = frame.srgbBlend
            frame.drawUI()
            uiDraws += frame.uiDrawCount
        }

        func summary() -> String? {
            "mock(renders=\(renderCalls))"
        }
    }

    @Test("HeadlessRunner executes App with setup(Waker), poll(t), Compositor, and FrameReports")
    func headlessAppWithCompositorAndReports() throws {
        var setupWakerSeen = false
        var encodedSeen: [FrameEncoded] = []
        var drawnSeen: [FrameEncoded] = []
        let comp = MockCompositor()

        let app = makeTestApp()
            .gpuBackend(.software)
            .setup { waker in
                setupWakerSeen = true
                waker.wake()
            }
            .poll { s, t, _ in
                s.polls += 1
                if t >= 0.0 && s.count == 0 {
                    s.count = 7
                    return true
                }
                return false
            }
            .compositor(comp)
            .onFrameEncoded { encoded in
                encodedSeen.append(encoded)
            }
            .onFrameDrawn { s, encoded, _ in
                drawnSeen.append(encoded)
                s.encodedFrames.append(encoded)
            }

        let out = try HeadlessRunner.run(app, args: ToolingArgs.parse(["--force-cpu"]))
        #expect(setupWakerSeen == true)
        #expect(comp.renderCalls == 1)
        #expect(comp.uiDraws == 1)
        #expect(comp.lastSrgbBlend == true)
        #expect(encodedSeen.count == 1)
        #expect(encodedSeen.first?.outcome == .drawn)
        #expect(encodedSeen.first?.compositorSummary == "mock(renders=1)")
        #expect(drawnSeen.count == 1)
        #expect(out.finalFrame.width == 640) // 320 * default pixelScale 2.0
        #expect(out.finalFrame.height == 480)
    }

    @Test("AppSpec.poll and AppSpec.setup wire cleanly in HeadlessRunner")
    func appSpecSetupAndPoll() throws {
        var didSetup = false
        var pollCount = 0
        let spec = AppSpec<Int>(size: Vec2(100, 80), state: 0) { count, _ in
            el().size(Float(count), 10)
        }
        .setup { _ in didSetup = true }
        .poll { s, _, _ in
            pollCount += 1
            s = 55
            return true
        }

        let out = try HeadlessRunner.run(spec, args: ToolingArgs.parse(["--force-cpu"]))
        let jsonStr = String(data: out.treeJSON, encoding: .utf8) ?? ""
        #expect(didSetup == true)
        #expect(pollCount >= 1)
        #expect(jsonStr.contains("55"))
    }

    // MARK: - FrameClock, SurfaceMeter & FrameReports

    @Test("FrameClock splits running catch-up from fresh 1/120s step and clamps MAX_GAP")
    func frameClockSplitting() {
        let fresh = FrameClockStep.split(gap: 2.0, running: false)
        #expect(fresh.catchUp == 0.0)
        #expect(abs(fresh.dt - FrameClock.resumeStep) < 1e-9)

        let late = FrameClockStep.split(gap: 0.049, running: true)
        #expect(abs(late.total - 0.049) < 1e-9)
        #expect(abs(late.dt - FrameClock.resumeStep) < 1e-9)

        let suspended = FrameClockStep.split(gap: 3.0, running: true)
        #expect(abs(suspended.total - FrameClock.maxGap) < 1e-9)

        let clock = FrameClock(start: 10.0)
        clock.hold(at: 10.010)
        clock.hold(at: 10.002) // must not rewind
        let next = clock.frameStep(at: 10.018, running: true)
        #expect(abs(next.total - 0.008) < 1e-9)
    }

    @Test("SurfaceMeter warns once after 2 consecutive >400Hz failed/unpaced seconds and allows 360Hz")
    func surfaceMeterSpinDetection() {
        // Port of `the_guard_warns_once_after_two_seconds_of_spinning` (`surface_stats.rs:364-397`)
        let meter = SurfaceMeter(name: "main", now: 0.0)
        meter.setPacing(.failed(-6661))
        for _ in 0..<5000 {
            meter.redraw(paced: true)
            meter.failed(.occluded)
        }
        #expect(meter.tick(now: 1.0) == nil)
        for _ in 0..<5000 {
            meter.redraw(paced: true)
            meter.failed(.occluded)
        }
        let warn = meter.tick(now: 2.0)
        #expect(warn != nil)
        #expect(warn?.contains("main") == true)
        #expect(warn?.contains("failed acquires/s") == true)
        #expect(warn?.contains("occluded") == true)
        #expect(warn?.contains("display link failed (-6661)") == true)
        for _ in 0..<5000 {
            meter.redraw(paced: true)
            meter.failed(.occluded)
        }
        #expect(meter.tick(now: 3.0) == nil) // warns once

        // Unpaced redraws > 400Hz spin; a calm 60Hz second in between resets the streak.
        let unpacedMeter = SurfaceMeter(name: "main", now: 0.0)
        for _ in 0..<1000 { unpacedMeter.redraw(paced: false); unpacedMeter.presented() }
        #expect(unpacedMeter.tick(now: 1.0) == nil)
        for _ in 0..<60 { unpacedMeter.redraw(paced: false); unpacedMeter.presented() }
        #expect(unpacedMeter.tick(now: 2.0) == nil)
        for _ in 0..<1000 { unpacedMeter.redraw(paced: false); unpacedMeter.presented() }
        #expect(unpacedMeter.tick(now: 3.0) == nil)
        for _ in 0..<1000 { unpacedMeter.redraw(paced: false); unpacedMeter.presented() }
        let unpacedWarn = unpacedMeter.tick(now: 4.0)
        #expect(unpacedWarn?.contains("redraws/s") == true)
        #expect(unpacedWarn?.contains("unpaced") == true)

        // A high-refresh 360Hz display never trips the guard.
        let highRefresh = SurfaceMeter(name: "main", now: 0.0)
        for sec in 1...5 {
            for _ in 0..<360 { highRefresh.redraw(paced: false) }
            #expect(highRefresh.tick(now: Double(sec)) == nil)
        }
    }

    @Test("FrameReports coalesces high-frequency drawn reports and delivers onFrameEncoded immediately")
    func frameReportsCoalescing() {
        var encodedCount = 0
        var drawnTimestamps: [Double] = []
        let reports = FrameReports<CounterState>(
            onFrameEncoded: { _ in encodedCount += 1 },
            onFrameDrawn: { _, _, _ in drawnTimestamps.append(1.0) },
            drawnInterval: 0.1
        )
        var s = CounterState()
        var tx = Tx()
        reports.record(FrameEncoded(outcome: .drawn, drawCount: 1))
        #expect(reports.flush(state: &s, tx: &tx, at: 0.0) == true)
        reports.record(FrameEncoded(outcome: .drawn, drawCount: 1))
        reports.record(FrameEncoded(outcome: .drawn, drawCount: 1))
        #expect(encodedCount == 3)
        #expect(reports.droppedCount == 1)
        #expect(reports.flush(state: &s, tx: &tx, at: 0.05) == false) // throttled
        #expect(reports.flush(state: &s, tx: &tx, at: 0.15) == true)
        #expect(drawnTimestamps.count == 2)
    }

    @Test("AppHandle reports host-published windowError (`app.rs:1079`)")
    func handlesReportWindowAndWindowError() {
        let app = makeTestApp()
        let handle = app.handle()
        #expect(handle.isVisible == false)
        #expect(handle.windowError == nil)

        app.sharedHandle.shared.setVisible(true)
        app.sharedHandle.shared.setWindowError("no GPU adapter")
        #expect(handle.isVisible == true)
        #expect(handle.windowError == "no GPU adapter")

        app.sharedHandle.shared.setWindowError(nil)
        #expect(handle.windowError == nil)
    }

    @Test("minimize reaches shell from handlers, updates, and handles with last-wins cancel rules (`app.rs:1139,1157`)")
    func minimizeReachesShellAndFocusCancelPolicy() {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(100, 100)) { _, _ in el() }
        rt.onFocus = { _, focused, tx in
            if !focused { tx.minimize() }
        }
        rt.dispatchFocus(true, at: 0.0)
        #expect(!rt.minimizeState.latched)
        rt.dispatchFocus(false, at: 0.01)
        #expect(rt.minimizeState.field && !rt.quitRequested)
        rt.ignoreMinimize("a test")
        #expect(!rt.minimizeState.latched)
        rt.update(at: 0.02) { _, tx in tx.minimize() }
        #expect(rt.minimizeState.field)

        let app = makeTestApp()
        let h = app.handle()
        func drained(_ calls: () -> Void) -> (AppWindowRequest, AppActivation) {
            calls()
            let r = app.sharedHandle.shared.drain()
            return (r.window, r.activation)
        }
        #expect(drained { h.focus(); h.minimize() } == (.none, .minimize))
        #expect(drained { h.minimize(); h.focus() } == (.none, .focus))
        #expect(drained { h.show(); h.minimize() } == (.show, .minimize))
        #expect(drained { h.minimize(); h.show() } == (.show, .minimize))
        #expect(drained { h.minimize(); h.hide() } == (.hide, .none))
        #expect(drained { h.minimize(); h.close() } == (.close, .none))
        #expect(drained { h.minimize(); h.open() } == (.open, .none))
        #expect(drained { h.focus(); h.open() } == (.open, .focus))
        #expect(drained { h.focus(); h.hide() } == (.hide, .focus))
        #expect(drained { h.minimize(); h.show(); h.focus() } == (.show, .focus))
    }

    @Test("hidden window drains inbox, arms timer from update without frames, and hidden timer polls without build (`app.rs:1270,1307,1324`)")
    func hiddenWindowDrainsInboxArmsTimerAndPollsWithoutBuild() {
        // 1. a_hidden_window_drains_its_inbox_on_wake_and_shows_it_when_reopened
        struct LockState {
            var pendingValue: Int?
            var locked: Int = 0
        }
        let rtInbox = Runtime<LockState>(state: LockState(), viewport: Vec2(200, 200)) { s, _ in
            row().child(el().key("box").size(Float(10 + s.locked), 10))
        }
        rtInbox.poll = { s, _, tx in
            guard let v = s.pendingValue else { return false }
            s.pendingValue = nil
            s.locked = v
            tx.wakeAfter(60.0)
            return true
        }
        _ = rtInbox.frame(at: 0.0)
        #expect(rtInbox.element(byKey: "box")?.rect[2] == 10.0)

        rtInbox.updateIf(at: 0.0) { s, _ in s.pendingValue = 30; return false }
        #expect(rtInbox.pollHidden(at: 0.0) == true)
        #expect(rtInbox.pollHidden(at: 0.0) == true) // needsCommit remains latched until next frame
        #expect(rtInbox.state.locked == 30)
        #expect(rtInbox.element(byKey: "box")?.rect[2] == 10.0)
        #expect(rtInbox.nextWakeDeadline != nil)

        rtInbox.settleAll()
        _ = rtInbox.frame(at: 1.0 / 60.0)
        #expect(rtInbox.element(byKey: "box")?.rect[2] == 40.0)

        // 2. an_update_arriving_without_frames_arms_its_timer
        let rtTimer = Runtime<Int>(state: 0, viewport: Vec2(100, 100)) { _, _ in el() }
        rtTimer.poll = { polls, _, _ in polls += 1; return false }
        _ = rtTimer.frame(at: 0.0)
        #expect(rtTimer.nextWakeDeadline == nil)
        rtTimer.update(at: 0.0) { _, tx in tx.wakeAfter(5.0) }
        _ = rtTimer.pollHidden(at: 0.0)
        let deadline = rtTimer.nextWakeDeadline
        #expect(deadline != nil && deadline! >= 4.9 && deadline! <= 5.5)
        _ = rtTimer.frame(at: 0.0)
        #expect(rtTimer.nextWakeDeadline == deadline)

        // 3. a_hidden_timer_polls_without_building_the_view
        for withPoll in [true, false] {
            let rtHidden = Runtime<Int>(state: 0, viewport: Vec2(100, 100)) { _, _ in el() }
            if withPoll {
                rtHidden.poll = { polls, _, _ in polls += 1; return true }
            }
            _ = rtHidden.frame(at: 0.0)
            let commits = rtHidden.viewCommitCount
            rtHidden.updateIf(at: 0.0) { _, tx in tx.wakeAfter(0.01); return false }
            #expect(rtHidden.hiddenWake(at: 0.0) == withPoll)
            #expect(rtHidden.nextWakeDeadline != nil)
            #expect(rtHidden.hiddenWake(at: 1.0) == withPoll)
            #expect(rtHidden.nextWakeDeadline == nil)
            #expect(rtHidden.viewCommitCount == commits)
            if withPoll {
                #expect(rtHidden.needsCommit)
                _ = rtHidden.frame(at: 1.0)
                #expect(rtHidden.viewCommitCount == commits + 1)
            }
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int = 0
    func inc() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
