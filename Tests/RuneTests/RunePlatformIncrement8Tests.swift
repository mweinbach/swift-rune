import Foundation
import Testing
@testable import Rune
@testable import RuneMotion
#if os(macOS)
import AppKit
#endif

@Suite("Platform Increment 8: WindowFrame, FrameMove, FitHeight, Menu & Platform Bridges")
struct RunePlatformIncrement8Tests {

    // MARK: - 1. window/frame.rs (8 upstream tests)

    @Test("window/frame: a_scale_change_keeps_the_logical_size")
    func scaleChangeKeepsLogicalSize() {
        #expect(WindowFrame.rescaled((1470, 1140), from: 1.5, to: 1.0) == (980, 760))
        #expect(WindowFrame.rescaled((980, 760), from: 1.0, to: 1.5) == (1470, 1140))
        #expect(WindowFrame.rescaled((1225, 950), from: 1.25, to: 1.75) == (1715, 1330))
        #expect(WindowFrame.rescaled(WindowFrame.rescaled((1225, 950), from: 1.25, to: 1.75), from: 1.75, to: 1.25) == (1225, 950))
        #expect(WindowFrame.rescaled((1001, 777), from: 1.0, to: 1.25) == (1251, 971))
    }

    @Test("window/frame: a_resize_keeps_the_top_edge_and_stays_on_screen")
    func resizeKeepsTopEdgeAndStaysOnScreen() {
        let screen: [Float] = [0.0, 33.0, 1728.0, 1084.0]
        let window: [Float] = [100.0, 200.0, 400.0, 432.0]
        #expect(WindowFrame.target(current: window, outer: (400.0, 632.0), center: false, visible: screen) == [100.0, 200.0, 400.0, 632.0])
        #expect(WindowFrame.target(current: window, outer: (400.0, 1000.0), center: false, visible: screen) == [100.0, 117.0, 400.0, 1000.0])
        #expect(WindowFrame.target(current: window, outer: (400.0, 2000.0), center: false, visible: screen) == [100.0, 33.0, 400.0, 2000.0])
    }

    @Test("window/frame: a_window_already_off_screen_is_not_pulled_back")
    func windowAlreadyOffScreenIsNotPulledBack() {
        let screen: [Float] = [0.0, 33.0, 1728.0, 1084.0]
        let window: [Float] = [-200.0, 900.0, 400.0, 400.0]
        #expect(WindowFrame.target(current: window, outer: (400.0, 300.0), center: false, visible: screen) == [-200.0, 900.0, 400.0, 300.0])
        #expect(WindowFrame.target(current: window, outer: (400.0, 600.0), center: false, visible: screen) == [-200.0, 700.0, 400.0, 600.0])
    }

    @Test("window/frame: centring_matches_appkit")
    func centringMatchesAppKit() {
        let screen: [Float] = [0.0, 33.0, 1728.0, 1084.0]
        #expect(WindowFrame.target(current: [0.0, 0.0, 400.0, 100.0], outer: (400.0, 332.0), center: true, visible: [0.0, 0.0, 1728.0, 1084.0]) == [664.0, 188.0, 400.0, 332.0])
        #expect(WindowFrame.target(current: [0.0, 0.0, 400.0, 100.0], outer: (300.0, 932.0), center: true, visible: [0.0, 0.0, 1728.0, 1084.0]) == [714.0, 38.0, 300.0, 932.0])
        #expect(WindowFrame.target(current: [5.0, 5.0, 800.0, 132.0], outer: nil, center: true, visible: screen) == [464.0, 33.0 + 238.0, 800.0, 132.0])
    }

    @Test("window/frame: the_spring_lands_on_the_target_and_retargets_with_its_speed")
    func springLandsOnTargetAndRetargetsWithSpeed() {
        let spring = Spring(duration: 0.3, bounce: 0.0)
        let anim = WindowFrameAnim(spring: spring, now: 1.0, from: [0.0, 0.0, 400.0, 400.0], velocity: [0, 0, 0, 0], to: [0.0, 0.0, 400.0, 600.0])
        let (mid, v) = anim.sample(at: 1.1)
        #expect(mid[3] > 400.0 && mid[3] < 600.0 && v[3] > 0.0)
        #expect(Array(mid[0..<3]) == [0.0, 0.0, 400.0])
        #expect(!anim.isDone(at: 1.1))
        #expect(anim.isDone(at: 2.0))
        #expect(anim.sample(at: 2.0).position == anim.to)

        let back = WindowFrameAnim.retarget(previous: anim, spring: spring, now: 1.1, from: [9, 9, 9, 9], to: [0.0, 0.0, 400.0, 400.0])
        #expect(back.sample(at: 1.1).position == mid)
        #expect(back.sample(at: 1.11).position[3] > mid[3])

        let jump = WindowFrameAnim.retarget(previous: anim, spring: nil, now: 1.1, from: [9, 9, 9, 9], to: [1, 1, 1, 1])
        #expect(jump.isDone(at: 1.1))
        #expect(jump.sample(at: 1.1).position == [1, 1, 1, 1])
    }

    @Test("window/frame: a_drag_mid_flight_keeps_the_new_origin_and_the_size_carries_on")
    func dragMidFlightKeepsNewOrigin() {
        let spring = Spring(duration: 0.3, bounce: 0.0)
        var anim = WindowFrameAnim(spring: spring, now: 0.0, from: [10.0, 20.0, 400.0, 400.0], velocity: [0, 0, 0, 0], to: [10.0, 20.0, 400.0, 600.0])
        let before = anim.sample(at: 0.1).position
        anim.shift(dx: 50.0, dy: -5.0)
        let after = anim.sample(at: 0.1).position
        #expect(after == [before[0] + 50.0, before[1] - 5.0, before[2], before[3]])
        #expect(anim.to == [60.0, 15.0, 400.0, 600.0])
    }

    @Test("window/frame: requested_sizes_stay_inside_the_window_limits")
    func requestedSizesStayInsideWindowLimits() {
        let clamped1 = WindowFrame.clampSize((300.0, 900.0), min: (420.0, 0.0), max: (800.0, 700.0))
        #expect(clamped1.0 == 420.0 && clamped1.1 == 700.0)
        let clamped2 = WindowFrame.clampSize((500.0, 100.0), min: (420.0, 200.0), max: nil)
        #expect(clamped2.0 == 500.0 && clamped2.1 == 200.0)
    }

    @Test("window/frame: later_sizes_win_and_centring_sticks")
    func laterSizesWinAndCentringSticks() {
        let a = WindowFrameRequest(size: (1.0, 2.0), animate: true, spring: nil, center: true)
        let b = WindowFrameRequest(size: (3.0, 4.0), animate: false, spring: nil, center: false)
        #expect(a.merged(with: b) == WindowFrameRequest(size: (3.0, 4.0), animate: false, spring: nil, center: true))
        let centered = b.merged(with: WindowFrameRequest(center: true))
        #expect(centered == WindowFrameRequest(size: (3.0, 4.0), animate: false, spring: nil, center: true))
    }

    // MARK: - 2. window/frame_move_tests.rs (4 upstream tests)

    private enum FrameStep {
        case animate
        case cancel
        case jump(Float, Float)
        case resized(Float, Float)
        case land
    }

    private struct FrameObserved: Equatable {
        var moving: Bool
        var asked: Bool
    }

    private struct ReferenceApart {
        var hasMove = false
        var jump: (Float, Float)? = nil

        mutating func step(_ step: FrameStep) -> FrameObserved {
            var asked = false
            switch step {
            case .animate:
                hasMove = true
            case .cancel:
                hasMove = false
            case .jump(let w, let h):
                jump = (w, h)
            case .resized(let vw, let vh):
                if let j = jump {
                    jump = nil
                    asked = abs(j.0 - vw) < 1.0 && abs(j.1 - vh) < 1.0
                }
            case .land:
                hasMove = false
            }
            return FrameObserved(moving: hasMove, asked: asked)
        }
    }

    private static let testJump: (Float, Float) = (300.0, 200.0)
    private static let testOtherJump: (Float, Float) = (420.0, 260.0)
    private static let testHis: (Float, Float) = (300.0, 200.0)
    private static let testNear: (Float, Float) = (300.9, 200.9)
    private static let testUser: (Float, Float) = (7.0, 7.0)

    private func sampleAnim() -> WindowFrameAnim {
        WindowFrameAnim(spring: nil, now: 0.0, from: [10, 20, 300, 200], velocity: [0, 0, 0, 0], to: [30, 40, 300, 200])
    }

    private func feed(_ slot: inout WindowFrameMove?, _ step: FrameStep) -> FrameObserved {
        let asked: Bool
        switch step {
        case .animate:
            slot = .moving(sampleAnim(), origin: (10.0, 20.0))
            asked = false
        case .cancel:
            slot = nil
            asked = false
        case .jump(let w, let h):
            slot = .jumped((w, h))
            asked = false
        case .resized(let vw, let vh):
            asked = WindowFrameMove.takeJump(&slot, viewport: (vw, vh))
        case .land:
            _ = WindowFrameMove.takeMoving(&slot)
            asked = false
        }
        return FrameObserved(moving: WindowFrameMove.isMoving(slot), asked: asked)
    }

    private func everySequence(_ alphabet: [FrameStep], maxLen: Int, _ body: ([FrameStep]) -> Void) {
        var seq: [FrameStep] = []
        func walk() {
            body(seq)
            if seq.count == maxLen { return }
            for s in alphabet {
                seq.append(s)
                walk()
                seq.removeLast()
            }
        }
        walk()
    }

    private func assertHoldsUp(_ seq: [FrameStep]) {
        var slot: WindowFrameMove? = nil
        var apart = ReferenceApart()
        for step in seq {
            let seen = feed(&slot, step)
            let expected = apart.step(step)
            #expect(seen == expected)
            #expect(!(apart.hasMove && apart.jump != nil))
            let left: WindowFrameMove? = apart.hasMove
                ? .moving(sampleAnim(), origin: (10.0, 20.0))
                : apart.jump.map { .jumped($0) }
            #expect(slot == left)
        }
    }

    @Test("window/frame_move_tests: every_order_of_jumps_spends_one_coupon")
    func everyOrderOfJumpsSpendsOneCoupon() {
        let alphabet: [FrameStep] = [
            .jump(Self.testJump.0, Self.testJump.1),
            .jump(Self.testOtherJump.0, Self.testOtherJump.1),
            .resized(Self.testHis.0, Self.testHis.1),
            .resized(Self.testNear.0, Self.testNear.1),
            .resized(Self.testUser.0, Self.testUser.1),
            .land,
        ]
        everySequence(alphabet, maxLen: 6, assertHoldsUp)
    }

    @Test("window/frame_move_tests: every_order_of_animations_leaves_the_same_frame_moving")
    func everyOrderOfAnimationsLeavesSameFrameMoving() {
        let alphabet: [FrameStep] = [
            .animate,
            .cancel,
            .resized(Self.testHis.0, Self.testHis.1),
            .land,
        ]
        everySequence(alphabet, maxLen: 7, assertHoldsUp)
    }

    @Test("window/frame_move_tests: a_jump_is_spent_by_the_resize_it_announced_once")
    func jumpIsSpentByResizeItAnnouncedOnce() {
        var slot: WindowFrameMove? = nil
        #expect(!feed(&slot, .resized(Self.testHis.0, Self.testHis.1)).asked)
        let requested = feed(&slot, .jump(Self.testJump.0, Self.testJump.1))
        #expect(!requested.moving)
        #expect(!feed(&slot, .resized(Self.testUser.0, Self.testUser.1)).asked)
        #expect(!feed(&slot, .resized(Self.testHis.0, Self.testHis.1)).asked)
        _ = feed(&slot, .jump(Self.testJump.0, Self.testJump.1))
        #expect(feed(&slot, .resized(Self.testHis.0, Self.testHis.1)).asked)
        #expect(!feed(&slot, .resized(Self.testHis.0, Self.testHis.1)).asked)
    }

    @Test("window/frame_move_tests: a_later_request_or_landing_keeps_the_rules")
    func laterRequestOrLandingKeepsRules() {
        var slot: WindowFrameMove? = nil
        _ = feed(&slot, .jump(Self.testJump.0, Self.testJump.1))
        _ = feed(&slot, .jump(Self.testOtherJump.0, Self.testOtherJump.1))
        #expect(!feed(&slot, .resized(Self.testHis.0, Self.testHis.1)).asked)
        _ = feed(&slot, .jump(Self.testJump.0, Self.testJump.1))
        _ = feed(&slot, .land)
        #expect(feed(&slot, .resized(Self.testHis.0, Self.testHis.1)).asked)
        #expect(feed(&slot, .animate).moving)
        _ = feed(&slot, .animate)
        #expect(feed(&slot, .resized(Self.testHis.0, Self.testHis.1)).moving)
        #expect(!feed(&slot, .land).moving)
    }

    // MARK: - 3. runtime/tests/window_wake.rs (resize / stepViewport / fitHeight)

    @Test("runtime/window_wake: window_frame_requests_take_the_change_spring")
    func windowFrameRequestsTakeChangeSpring() {
        let rt = Runtime(state: (), viewport: Vec2(100, 100), pixelScale: 1.0) { _, _ in el() }
        func captureSpring(_ edit: (inout Tx) -> Void) -> Spring? {
            rt.update(at: 0.0) { _, tx in edit(&tx) }
            return rt.takeWindowFrameRequest()?.spring
        }
        #expect(captureSpring { $0.resizeWindow((1.0, 2.0)) } == MotionTokens.DEFAULT)
        #expect(captureSpring { $0.motion(MotionTokens.SNAP); $0.resizeWindow((1.0, 2.0)) } == MotionTokens.SNAP)
        #expect(captureSpring { $0.instant(); $0.resizeWindow((1.0, 2.0)) } == nil)
        #expect(captureSpring { $0.resizeWindowInstant((1.0, 2.0)) } == nil)
        rt.reducedMotion = true
        _ = rt.frame(at: 0.0)
        #expect(captureSpring { $0.resizeWindow((1.0, 2.0)) } == nil)
        rt.update(at: 0.0) { _, tx in
            tx.resizeWindow((1.0, 2.0))
            tx.centerWindow()
        }
        let req = rt.takeWindowFrameRequest()
        #expect(req?.size?.0 == 1.0 && req?.size?.1 == 2.0)
        #expect(req?.center == true)
    }

    @Test("runtime/window_wake: a_window_resize_step_keeps_springs_and_flights_going")
    func windowResizeStepKeepsSpringsAndFlightsGoing() {
        func buildRuntime(userResize: Bool) -> Runtime<Bool> {
            let rt = Runtime(state: false, viewport: Vec2(300, 400), pixelScale: 1.0) { (grown: Bool, _: inout Cx<Bool>) -> El<Bool> in
                let tile: El<Bool> = el().key("tile").matched("tile").size(40, 40).bg(.white)
                var left: El<Bool> = el().key("left").size(100, 60)
                var right: El<Bool> = el().key("right").size(100, 60).ml(150)
                if grown {
                    right = right.child(tile)
                } else {
                    left = left.child(tile)
                }
                return col().key("root").wFull().hFull()
                    .child(el().key("box").size(50, grown ? 150 : 50).bg(.white).animateLayout())
                    .child(left)
                    .child(right)
                    .child(spacer())
                    .child(el().key("bar").wFull().h(20).bg(.white))
            }
            _ = rt.frame(at: 0.0)
            rt.update(at: 0.0) { grown, tx in
                grown = true
                tx.resizeWindow((300.0, 600.0))
            }
            _ = rt.frame(at: 1.0 / 60.0)
            _ = rt.takeWindowFrameRequest()
            if userResize {
                rt.setViewport(Vec2(300, 450), pixelScale: 1.0)
            } else {
                rt.stepViewport(Vec2(300, 450), pixelScale: 1.0)
            }
            _ = rt.frame(at: 2.0 / 60.0)
            return rt
        }

        let stepped = buildRuntime(userResize: false)
        let boxH = stepped.element(byKey: "box")?.rect[3] ?? -1
        #expect(boxH > 50.0 && boxH < 150.0)
        let tile = stepped.element(byKey: "tile")
        #expect(tile?.moving == true)
        let tileX = tile?.rect[0] ?? -1
        #expect(tileX > 0.0 && tileX < 150.0)
        #expect(stepped.element(byKey: "bar")?.rect[1] == 430.0)

        let userResized = buildRuntime(userResize: true)
        #expect(userResized.element(byKey: "box")?.rect[3] == 150.0)
    }

    @Test("runtime/window_wake: a_window_that_fits_its_content_refits_after_a_user_resize")
    func windowThatFitsContentRefitsAfterUserResize() {
        let rt = Runtime(state: (), viewport: Vec2(300, 400), pixelScale: 1.0) { _, _ in
            col().key("root").wFull().child(el().size(100, 90))
        }
        rt.fitHeight = true
        let height = rt.contentHeight()
        #expect(height == 90.0)
        rt.setViewport(Vec2(300, height), pixelScale: 1.0)
        _ = rt.frame(at: 0.0)
        _ = rt.takeWindowFrameRequest()

        // While not resting, host window size changes must not queue a refit.
        rt.setViewport(Vec2(300, height + 40.0), pixelScale: 1.0)
        _ = rt.frame(at: 1.0 / 60.0)
        #expect(rt.takeWindowFrameRequest() == nil)

        // Once resting, a user resize queues a refit back to natural content height.
        rt.windowResting = true
        rt.setViewport(Vec2(300, height + 100.0), pixelScale: 1.0)
        _ = rt.frame(at: 1.0 / 60.0)
        let req = rt.takeWindowFrameRequest()
        #expect(req?.size?.0 == 300.0 && req?.size?.1 == height)
    }

    @Test("HeadlessRunner drives Tx.resizeWindowInstant and steps Tx.resizeWindow on virtual clock")
    func headlessRunnerDrivesWindowFrameRequests() throws {
        let app = App(title: "ResizeTest", size: Vec2(200, 120), state: false) { (grown: Bool, _: inout Cx<Bool>) -> El<Bool> in
            let btn: El<Bool> = el().key("btn").size(80, 40).bg(.white).onClick { s, tx in
                s = true
                tx.resizeWindowInstant((360, 220))
            }
            return col().wFull().hFull()
                .child(btn)
                .child(el().key("status").wFull().h(grown ? 100 : 40))
        }
        let script = #"[{"t": 0.05, "key": "btn", "action": "click"}]"#
        let out = try HeadlessRunner.run(app, args: ToolingArgs.parse(["--script", script, "--at", "0.2"]))
        let decoded = try JSONSerialization.jsonObject(with: out.treeJSON) as? [String: Any]
        let vp = decoded?["viewport"] as? [Double]
        #expect(vp == [360.0, 220.0])
    }

    // MARK: - 4. Platform Capabilities, currentRuntimeId, AppHandle.setMenu/takeMenuErrors, Reopen, DragItem.isEmpty

    @Test("popupMenuSupported and DragItem.isEmpty match platform contract")
    func popupSupportedAndDragItemIsEmpty() {
        #if os(macOS) || os(Windows)
        #expect(popupMenuSupported() == true)
        #else
        #expect(popupMenuSupported() == false)
        #endif

        #expect(DragItem().isEmpty == true)
        #expect(DragItem().text("hi").isEmpty == false)
        #expect(DragItem().file(path: "/tmp/a.txt").isEmpty == false)
        #expect(DragItem().png(Data([0x89, 0x50])).isEmpty == false)
    }

    @Test("currentRuntimeId is scoped to Runtime turns and distinguishes runtimes")
    func currentRuntimeIdScopedPerRuntime() {
        #expect(currentRuntimeId() == nil)
        var seenInViewA: [UInt64] = []
        var seenInPollA: [UInt64] = []
        var seenInUpdateA: [UInt64] = []
        let rtA = Runtime(state: 0, viewport: Vec2(100, 100), pixelScale: 1.0) { _, _ in
            if let id = currentRuntimeId() { seenInViewA.append(id) }
            return el()
        }
        rtA.poll = { _, _, _ in
            if let id = currentRuntimeId() { seenInPollA.append(id) }
            return false
        }
        let rtB = Runtime(state: 0, viewport: Vec2(100, 100), pixelScale: 1.0) { _, _ in el() }
        #expect(rtA.runtimeId != rtB.runtimeId)

        _ = rtA.frame(at: 0.0)
        rtA.update(at: 0.1) { _, _ in
            if let id = currentRuntimeId() { seenInUpdateA.append(id) }
        }
        _ = rtA.contentHeight()
        #expect(currentRuntimeId() == nil)
        #expect(seenInViewA == [rtA.runtimeId, rtA.runtimeId])
        #expect(seenInPollA == [rtA.runtimeId])
        #expect(seenInUpdateA == [rtA.runtimeId])
    }

    @Test("AppHandle.setMenu validates state/items, bumps snapshot revision, and records takeMenuErrors")
    func appHandleSetMenuAndTakeMenuErrors() throws {
        let app = App(title: "MenuTest", state: 0) { _, _ in el() }
        let handle = app.sharedHandle

        #expect(throws: MenuError.notRunning) {
            try handle.setMenu([NativeMenuItem(id: "open", title: "Open") { _, _ in }])
        }

        let snapURL = FileManager.default.temporaryDirectory.appendingPathComponent("rune-menu-snap-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: snapURL) }

        // Startup menu validation records errors automatically for takeMenuErrors (`native_menu/mod.rs:425-427`).
        let invalidStartup = App(title: "InvalidStartupMenu", state: 0) { _, _ in el() }
            .menuItem(NativeMenuItem(id: "dup", title: "First") { _, _ in })
            .menuItem(NativeMenuItem(id: "dup", title: "Second") { _, _ in })
        let invalidHandle = invalidStartup.sharedHandle
        _ = try HeadlessRunner.run(invalidStartup, args: ToolingArgs.parse(["--snap", snapURL.path]))
        let startupErrors = invalidHandle.takeMenuErrors()
        #expect(startupErrors.count == 1)
        if case .invalid = startupErrors.first {} else {
            Issue.record("Expected deferred MenuError.invalid in takeMenuErrors, got \(startupErrors)")
        }
        #expect(invalidHandle.takeMenuErrors().isEmpty)

        // Running via HeadlessRunner enables AppMenuBridge during the run.
        var caughtValidationError: MenuError? = nil
        var seenSnapshotRevision: UInt64 = 0
        var seenMenuCount = 0
        let wired = app.setup { _ in
            do {
                try handle.setMenu([NativeMenuItem<Int>(id: "bad", title: "") { _, _ in }])
            } catch let err as MenuError {
                caughtValidationError = err
            } catch {}

            try? handle.setMenu([
                NativeMenuItem<Int>(id: "a", title: "First", keyEquivalent: "Cmd+1") { s, _ in s += 1 },
                NativeMenuItem<Int>(id: "b", title: "Second", keyEquivalent: "Cmd+2") { s, _ in s += 2 },
            ])
            let snap = AppMenuBridge.snapshot(for: handle.shared)
            seenSnapshotRevision = snap.revision
            seenMenuCount = snap.items.count
        }

        _ = try HeadlessRunner.run(wired, args: ToolingArgs.parse(["--snap", snapURL.path]))
        if case .invalid = caughtValidationError {} else {
            Issue.record("Expected MenuError.invalid for empty title, got \(String(describing: caughtValidationError))")
        }
        #expect(seenSnapshotRevision >= 1)
        #expect(seenMenuCount == 2)
        #expect(handle.takeMenuErrors().isEmpty)

        // Stopped again once run finishes.
        #expect(throws: MenuError.notRunning) {
            try handle.setMenu([])
        }
    }

    @Test("platform/reopen.rs: DesktopReopen target selection, appKitHandles, stamp, and ReopenHandler")
    func reopenCandidateAndHandlerParity() {
        func win(_ visible: Bool, hiddenAt: UInt64? = nil, minimized: Bool = false, main: Bool = false, reopenable: Bool = true) -> DesktopReopenCandidate {
            DesktopReopenCandidate(reopenable: reopenable, visible: visible, minimized: minimized, hiddenAt: hiddenAt, main: main)
        }

        let hiddenOrder = [win(false, hiddenAt: 1, main: true), win(false, hiddenAt: 3), win(false, hiddenAt: 2)]
        #expect(!DesktopReopen.hasVisible(hiddenOrder))
        #expect(DesktopReopen.target(hiddenOrder) == 1)

        let visiblePresent = [win(true), win(false, hiddenAt: 5)]
        #expect(DesktopReopen.hasVisible(visiblePresent))
        #expect(DesktopReopen.target(visiblePresent) == nil)

        let minimizedFirst = [win(false, hiddenAt: 9), win(false, minimized: true)]
        #expect(DesktopReopen.target(minimizedFirst) == 1)

        let mainFallback = [win(false), win(false, main: true)]
        #expect(DesktopReopen.target(mainFallback) == 1)

        let panelAndClosed = [win(true, hiddenAt: 7, reopenable: false), win(false, hiddenAt: 8, main: true, reopenable: false)]
        #expect(!DesktopReopen.hasVisible(panelAndClosed))
        #expect(DesktopReopen.target(panelAndClosed) == nil)
        #expect(DesktopReopen.target(panelAndClosed + [win(false, hiddenAt: 1)]) == 2)

        #expect(DesktopReopen.appKitHandles(sent: true, appKitSeesVisible: true) == true)
        #expect(DesktopReopen.appKitHandles(sent: true, appKitSeesVisible: false) == false)
        #expect(DesktopReopen.appKitHandles(sent: false, appKitSeesVisible: false) == true)
        let s1 = DesktopReopen.stamp()
        let s2 = DesktopReopen.stamp()
        #expect(s2 > s1)

        final class Counter: @unchecked Sendable { var count = 0 }
        let c = Counter()
        let handler = ReopenHandler()
        handler.onReopen { c.count += 1 }
        handler.onReopen { c.count += 2 }
        handler.trigger()
        #expect(c.count == 3)
    }

    #if os(macOS)
    @Test("MacOSToolTipOwner syncs Runtime.helpRegionsList() onto NSView without thrashing")
    @MainActor
    func macOSToolTipOwnerSyncsHelpRegions() {
        _ = NSApplication.shared
        var flip = false
        let rt = Runtime(state: (), viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in
            el().key("root").size(200, 100).child(
                el().key("btn").size(80, 30).help(flip ? "Updated tip" : "Initial tip")
            )
        }
        rt.nativeHelp = true
        _ = rt.frame(at: 0.0)
        let regions1 = rt.helpRegionsList()
        #expect(regions1.count == 1)
        #expect(regions1[0].1 == "Initial tip")

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let owner = MacOSToolTipOwner()
        owner.sync(regions: regions1, on: view)
        let resolved1 = owner.view(
            view,
            stringForToolTip: 0,
            point: NSPoint(x: 10, y: 10),
            userData: UnsafeMutableRawPointer(bitPattern: 1)
        )
        #expect(resolved1 == "Initial tip")
        #expect(owner.view(view, stringForToolTip: 0, point: .zero, userData: nil) == "")

        // Re-syncing identical regions keeps tooltip token 1 stable; changing replaces with token 2.
        owner.sync(regions: regions1, on: view)
        #expect(owner.view(view, stringForToolTip: 0, point: NSPoint(x: 10, y: 10), userData: UnsafeMutableRawPointer(bitPattern: 1)) == "Initial tip")
        flip = true
        rt.markNeedsCommit()
        _ = rt.frame(at: 0.1)
        let regions2 = rt.helpRegionsList()
        owner.sync(regions: regions2, on: view)
        #expect(owner.view(view, stringForToolTip: 0, point: NSPoint(x: 10, y: 10), userData: UnsafeMutableRawPointer(bitPattern: 1)) == "")
        let resolved2 = owner.view(
            view,
            stringForToolTip: 0,
            point: NSPoint(x: 10, y: 10),
            userData: UnsafeMutableRawPointer(bitPattern: 2)
        )
        #expect(resolved2 == "Updated tip")
    }

    @Test("MacOSWindowFrameDriver applies instant resize and steps spring animation")
    @MainActor
    func macOSWindowFrameDriverAppliesAndSteps() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let driver = MacOSWindowFrameDriver()
        var recordedViewports: [Vec2] = []

        driver.applyRequest(
            WindowFrameRequest(size: (420, 280), animate: false, spring: nil, center: false),
            window: window,
            now: 0.0,
            minSize: (200, 150),
            maxSize: (800, 600),
            scale: 2.0
        ) { vp, _ in
            recordedViewports.append(vp)
        }
        #expect(!driver.isMoving)
        #expect(recordedViewports.last == Vec2(420, 280))
        #expect(driver.takeJumpIfMatching(viewport: Vec2(420, 280)))
        #expect(!driver.takeJumpIfMatching(viewport: Vec2(420, 280)))

        driver.applyRequest(
            WindowFrameRequest(size: (500, 340), animate: true, spring: Spring(duration: 0.3, bounce: 0.0), center: false),
            window: window,
            now: 0.0,
            minSize: (200, 150),
            maxSize: (800, 600),
            scale: 2.0
        ) { _, _ in }
        #expect(driver.isMoving)

        let stillMoving = driver.step(window: window, now: 0.1, scale: 2.0) { vp, _ in
            recordedViewports.append(vp)
        }
        #expect(stillMoving)
        #expect((recordedViewports.last?.x ?? 0) > 420 && (recordedViewports.last?.x ?? 0) < 500)

        let settled = driver.step(window: window, now: 2.0, scale: 2.0) { vp, _ in
            recordedViewports.append(vp)
        }
        #expect(!settled)
        #expect(!driver.isMoving)
        #expect(recordedViewports.last == Vec2(500, 340))

        // 1. Centering from an arbitrary position sets origin = current (does not self-cancel on first step),
        //    and resting: true defers the first move frame (`stepping.rs:183,231-235`).
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        let startOrigin = window.frame.origin
        driver.applyRequest(
            WindowFrameRequest(size: (460, 300), animate: true, spring: Spring(duration: 0.3, bounce: 0.0), center: true),
            window: window,
            now: 0.0,
            minSize: (200, 150),
            maxSize: (800, 600),
            scale: 2.0
        ) { _, _ in }
        #expect(driver.isMoving)
        #expect(driver.step(window: window, now: 0.02, scale: 2.0, resting: true) { _, _ in })
        #expect(window.frame.origin == startOrigin)

        #expect(driver.step(window: window, now: 0.1, scale: 2.0, resting: false) { _, _ in })
        #expect(window.frame.origin != startOrigin)

        // 2. centerWindow() (size == nil, animate == false) while moving continues on the active spring (`stepping.rs:172-177`).
        window.setFrameOrigin(NSPoint(x: 20, y: 20))
        driver.applyRequest(
            WindowFrameRequest(size: nil, animate: false, spring: nil, center: true),
            window: window,
            now: 0.12,
            minSize: (200, 150),
            maxSize: (800, 600),
            scale: 2.0
        ) { _, _ in }
        #expect(driver.isMoving)

        // 3. landFrame snaps a mid-flight move immediately to anim.to (`stepping.rs:260-267`).
        driver.landFrame(window: window)
        #expect(!driver.isMoving)
        #expect(Int(window.contentRect(forFrameRect: window.frame).width.rounded()) == 460)
        #expect(Int(window.contentRect(forFrameRect: window.frame).height.rounded()) == 300)
    }
    #endif

    // MARK: - 5. FitWindowState & Headless fitHeight Hold/Clamp (`window_requests_tests.rs`)

    @Test("runtime/window_requests: FitWindowState ask, outside resize, and hold lifecycle")
    func fitWindowStateUnitParity() {
        var fit = FitWindowState()
        let ask1 = fit.ask(height: 300, current: 300)
        #expect(!ask1)
        let ask2 = fit.ask(height: 420, current: 300)
        #expect(ask2)
        let ask3 = fit.ask(height: 420, current: 300)
        #expect(!ask3)
        let ask4 = fit.ask(height: 300, current: 360)
        #expect(ask4)

        var fit2 = FitWindowState()
        let f2Ask1 = fit2.ask(height: 420, current: 300)
        #expect(f2Ask1)
        let f2Resized1 = fit2.resized(to: 420.3, current: 300)
        #expect(!f2Resized1)
        let f2Resized2 = fit2.resized(to: 500, current: 420)
        #expect(f2Resized2)
        let f2Ask2 = fit2.ask(height: 420, current: 500)
        #expect(f2Ask2)
        var fresh = FitWindowState()
        let freshResized = fresh.resized(to: 300, current: 300)
        #expect(!freshResized)

        var holdFit = FitWindowState()
        let initHolds = holdFit.frameHolds()
        let initTaken = holdFit.takeHeld()
        #expect(!initHolds && !initTaken)
        holdFit.hold = .asked
        let askedHolds = holdFit.frameHolds()
        #expect(askedHolds)
        let taken1 = holdFit.takeHeld()
        #expect(taken1)
        let taken2 = holdFit.takeHeld()
        #expect(!taken2)

        holdFit.hold = .asked
        let askedHolds2 = holdFit.frameHolds()
        #expect(askedHolds2)
        let nextHolds = holdFit.frameHolds()
        #expect(!nextHolds)
        let nextTaken = holdFit.takeHeld()
        #expect(!nextTaken)
    }

    @Test("AppWindowSpec forwards fitContentHeight, menuItems, and appShared to TypedHostedWindowEntry")
    func appWindowSpecForwardsMenuAndFitHeight() {
        let app = App(title: "HostedProps", size: Vec2(320, 400), state: 0) { _, _ in
            el().size(100, 140)
        }
        .fitContentHeight(true)
        .menuItem(NativeMenuItem(id: "dup", title: "First") { _, _ in })
        .menuItem(NativeMenuItem(id: "dup", title: "Second") { _, _ in })

        let spec = AppWindowSpec(app: app)
        #expect(spec.fitContentHeight == true)
        #expect(spec.menuItems.count == 2)
        #expect(spec.appShared != nil)

        let entry = spec.boxed().makeHostEntry()
        entry.markMenusRunning(true)
        let startupErrors = app.sharedHandle.takeMenuErrors()
        #expect(startupErrors.count == 1)
        entry.markMenusRunning(false)

        let rtObj = entry.createRuntime(pixelScale: 1.0, systemDark: false, reducedMotion: false, waker: Waker())
        #expect(entry.runtimeViewport(runtimeObj: rtObj) == Vec2(320, 140))
    }

    @Test("HeadlessRunner clamps initial fitContentHeight and holds motion for one frame during fit resize")
    func headlessFitHeightClampAndHold() throws {
        let app = App(title: "FitHeightTest", size: Vec2(320, 400), state: false) { grown, _ in
            let btn = el().key("grow").size(100, 40).onClick { s, _ in s = true }
            return col().wFull().child(btn).child(el().key("body").wFull().h(grown ? 240 : 120))
        }
        .fitContentHeight(true)
        .windowOptions(WindowOptions(minSize: Vec2(200, 100), maxSize: Vec2(600, 220)))

        // Initial contentHeight = 40 + 120 = 160 (within [100, 220]) -> clamps viewport before frame 0.
        let out0 = try HeadlessRunner.run(app, args: ToolingArgs.parse([]))
        let json0 = try JSONSerialization.jsonObject(with: out0.treeJSON) as? [String: Any]
        #expect((json0?["viewport"] as? [Double]) == [320.0, 160.0])

        // Clicking "grow" asks for 280, clamped by maxSize.y = 220.
        let script = #"[{"t": 0.05, "key": "grow", "action": "click"}]"#
        let out1 = try HeadlessRunner.run(app, args: ToolingArgs.parse(["--script", script, "--at", "0.6"]))
        let json1 = try JSONSerialization.jsonObject(with: out1.treeJSON) as? [String: Any]
        #expect((json1?["viewport"] as? [Double]) == [320.0, 220.0])
    }
}
