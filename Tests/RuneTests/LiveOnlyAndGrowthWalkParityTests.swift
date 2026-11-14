import Foundation
import Testing
@testable import Rune
@testable import RuneMotion

// MARK: - LiveOnly Full Parity Suite (`src/live_only_tests.rs` 13 + `tests/live_only.rs:167`)

@Suite("LiveOnly Full Parity Tests (live_only_tests.rs + declined gesture)")
struct LiveOnlyFullParityTests {
    private struct S {
        var count: UInt32 = 0
        var misuse: Bool
        var pan: Live<Vec2>
        var physical: Int = 0

        init(misuse: Bool) {
            self.misuse = misuse
            self.pan = Live<Vec2>(.zero)
        }

        mutating func nudge(_ tx: inout Tx) {
            let cur = pan.get()
            pan.set(Vec2(cur.x + 10, cur.y))
            if misuse { count += 1 }
            tx.liveOnly()
        }
    }

    private func makeApp(misuse: Bool) -> Runtime<S> {
        let rt = Runtime<S>(
            state: S(misuse: misuse),
            viewport: Vec2(200, 200),
            pixelScale: 1.0,
            onKey: { state, ev, tx in
                guard ev.key == .arrowRight else { return false }
                state.nudge(&tx)
                return true
            },
            view: { s, _ in
                el().size(200, 200)
                    .child(
                        el().key("camera").size(50, 50)
                            .liveOffset(s.pan.binding)
                            .onClick { st in st.count += 1 }
                    )
                    .child(text("\(s.count)").key("count"))
                    .child(
                        el().key("recorder").size(40, 40).focusable(true)
                            .onPhysicalInput { st, ev, tx in
                                guard case .key(_, _, let pressed, _) = ev, !pressed else {
                                    return false
                                }
                                st.physical += 1
                                st.nudge(&tx)
                                return true
                            }
                    )
                    .onKeyUp { st, _, tx in
                        st.nudge(&tx)
                        return true
                    }
            }
        )
        _ = rt.frame(at: 0.0)
        return rt
    }

    private func cameraX(_ rt: Runtime<S>) -> Float {
        rt.elements().first(where: { $0.key == "camera" })?.rect[0] ?? -1
    }

    private func clickCenter(_ rt: Runtime<S>, key: String, at now: Double) {
        let c = rt.find(key)!
        rt.pointerDown(at: c, at: now)
        rt.pointerUp(at: c, at: now)
    }

    @Test("live_only_tests.rs:55 - physical keys and their releases can be live-only")
    func physicalKeysAndReleasesCanBeLiveOnly() {
        let rt = makeApp(misuse: false)
        rt.checkLiveOnly(false)
        let before = rt.viewCommitCount
        _ = rt.physicalWithFallback(
            .key(key: .arrowRight, mods: .none, pressed: true, repeat: false),
            fallback: KeyEvent(key: .arrowRight),
            at: 1.0 / 120.0
        )
        _ = rt.frame(at: 1.0 / 120.0)
        _ = rt.physicalWithFallback(
            .key(key: .arrowRight, mods: .none, pressed: false, repeat: false),
            fallback: KeyEvent(key: .arrowRight),
            at: 2.0 / 120.0
        )
        _ = rt.frame(at: 2.0 / 120.0)
        _ = rt.frame(at: 3.0 / 120.0)
        #expect(rt.viewCommitCount == before)
        #expect(rt.liveOnlySkips == 2)
        #expect(cameraX(rt) == 20.0)

        // Declined Tab falls through to Rune's own focus handling and commits once.
        _ = rt.physicalWithFallback(
            .key(key: .tab, mods: .none, pressed: true, repeat: false),
            fallback: KeyEvent(key: .tab),
            at: 4.0 / 120.0
        )
        _ = rt.frame(at: 4.0 / 120.0)
        #expect(rt.viewCommitCount == before + 1)
    }

    @Test("live_only_tests.rs:77 - physical release heard at rest can be live-only")
    func physicalReleaseHeardAtRestCanBeLiveOnly() {
        let rt = makeApp(misuse: false)
        rt.checkLiveOnly(false)
        clickCenter(rt, key: "recorder", at: 0.0)
        for i in 1...60 {
            _ = rt.frame(at: Double(i) / 120.0)
        }
        let before = rt.viewCommitCount
        let handled = rt.physicalWithFallback(
            .key(key: .shiftLeft, mods: .none, pressed: false, repeat: false),
            fallback: nil,
            at: 1.0
        )
        #expect(handled == true)
        #expect(!rt.needsCommit)
        _ = rt.frame(at: 1.0 + 1.0 / 120.0)
        #expect(rt.state.physical == 1)
        #expect(rt.viewCommitCount == before)
        #expect(cameraX(rt) == 10.0)
    }

    @Test("live_only_tests.rs:95 - debug builds warn when live-only changed what the view reads")
    func debugBuildsWarnWhenLiveOnlyChangedView() {
        let bad = makeApp(misuse: true)
        _ = bad.frame(at: 0.5)
        _ = bad.keyDown(KeyEvent(key: .arrowRight), at: 0.5)
        _ = bad.frame(at: 0.5 + 1.0 / 120.0)
        #expect(bad.liveOnlyWarnings.count == 1)
        #expect(bad.liveOnlyWarnings.first?.contains("onKey") == true)

        let good = makeApp(misuse: false)
        _ = good.frame(at: 0.5)
        let before = good.viewCommitCount
        for step in 1...10 {
            let t = 0.5 + Double(step) / 120.0
            _ = good.keyUp(KeyEvent(key: .arrowRight), at: t)
            _ = good.frame(at: t)
        }
        #expect(good.liveOnlyWarnings.isEmpty)
        #expect(good.viewCommitCount - before == 1)
        #expect(good.liveChecks == 1)
        #expect(good.liveOnlySkips == 9)
    }

    @Test("live_only_tests.rs:118 - debug check ignores a change another event made in the same frame")
    func checkIgnoresChangeAnotherEventMadeInSameFrame() {
        let rt = makeApp(misuse: false)
        _ = rt.frame(at: 0.5)
        _ = rt.keyUp(KeyEvent(key: .arrowRight), at: 0.5)
        clickCenter(rt, key: "camera", at: 0.5)
        _ = rt.frame(at: 0.5 + 1.0 / 120.0)
        #expect(rt.state.count == 1)
        #expect(rt.liveChecks == 1)
        #expect(rt.liveOnlyWarnings.isEmpty)
    }

    @Test("live_only_tests.rs:132 - declined element key does not hide an ancestor change")
    func declinedElementKeyDoesNotHideAncestorChange() {
        let rt = Runtime<UInt32>(state: 0, viewport: Vec2(200, 200), pixelScale: 1.0) { s, _ in
            el().size(200, 200)
                .onKey { st, _, _ in st += 1; return true }
                .child(
                    el().key("field").size(40, 40).focusable(true)
                        .onKey { _, _, tx in tx.liveOnly(); return false }
                )
                .child(text("\(s)").key("count"))
        }
        rt.checkLiveOnly(false)
        _ = rt.frame(at: 0.0)
        let c = rt.find("field")!
        rt.pointerDown(at: c, at: 0.01)
        rt.pointerUp(at: c, at: 0.01)
        _ = rt.frame(at: 0.01)
        let before = rt.viewCommitCount
        _ = rt.keyDown(KeyEvent(key: .arrowRight), at: 0.02)
        _ = rt.frame(at: 0.02)
        #expect(rt.state == 1)
        #expect(rt.viewCommitCount == before + 1)
    }

    @Test("live_only_tests.rs:152 - live-only does not cancel poll, update, or later event commits")
    func liveOnlyDoesNotCancelPollUpdateOrLaterCommits() {
        for source in 0..<3 {
            let rt = makeApp(misuse: false)
            rt.checkLiveOnly(false)
            if source == 0 {
                rt.poll = { st, _, _ in st.count += 1; return true }
            } else if source == 1 {
                rt.update(at: 0.0) { st, _ in st.count += 1 }
            }
            _ = rt.keyUp(KeyEvent(key: .arrowRight), at: 0.0)
            if source == 2 {
                clickCenter(rt, key: "camera", at: 0.0)
            }
            let before = rt.viewCommitCount
            _ = rt.frame(at: 0.01)
            #expect(rt.state.count == 1)
            #expect(rt.viewCommitCount > before)
            #expect(rt.element(byKey: "count")?.text == "1")
        }
    }

    @Test("live_only_tests.rs:172 - live values published by poll draw in that frame after a scroll callback")
    func liveValuesPublishedByPollDrawAfterScrollCallback() {
        let pan = Live<Vec2>(.zero)
        let rt = Runtime<Live<Vec2>>(state: pan, viewport: Vec2(200, 200), pixelScale: 1.0) { state, _ in
            el().size(200, 200)
                .child(
                    el().key("scroll").size(100, 100)
                        .scrollY()
                        .onScrollOffset { at in state.set(Vec2(at.offset.y, 0)) }
                        .child(el().size(100, 1000))
                )
                .child(
                    el().key("marker").absolute(x: 0, y: 0).size(10, 10).liveOffset(state.binding)
                )
        }
        _ = rt.frame(at: 0.0)
        rt.wheel(WheelEvent(dx: 0, dy: -20), at: Vec2(50, 50), now: 1.0 / 60.0)
        _ = rt.frame(at: 1.0 / 60.0)
        _ = rt.frame(at: 2.0 / 60.0)
        #expect(pan.get() == Vec2(20, 0))
        #expect(!rt.livePending)

        let commits = rt.viewCommitCount
        rt.poll = { (st: inout Live<Vec2>, _: Double, _: inout Tx) -> Bool in
            let cur = st.get()
            st.set(Vec2(cur.x + 5, 0))
            return false
        }
        for f in 1...4 {
            _ = rt.frame(at: Double(2 + f) / 60.0)
            #expect(pan.get().x == 20.0 + Float(f) * 5.0)
            #expect(rt.element(byKey: "marker")?.rect[0] == 20.0 + Float(f) * 5.0)
            #expect(rt.viewCommitCount == commits)
        }
    }

    @Test("live_only_tests.rs:202 - debug check does not blame live-only for layout feedback before a key")
    func debugCheckIgnoresLayoutFeedbackAndSameFrameCommit() {
        var didTriggerLayout = false
        let rt = Runtime<S>(
            state: S(misuse: false),
            viewport: Vec2(200, 200),
            pixelScale: 1.0,
            onKey: { state, ev, tx in
                guard ev.key == .arrowRight else { return false }
                state.nudge(&tx)
                return true
            },
            view: { s, _ in
                el().size(200, 200)
                    .child(
                        el().key("sensor").size(50, 50)
                            .onLayout { st, _ in
                                if !didTriggerLayout {
                                    didTriggerLayout = true
                                    st.count += 1
                                }
                            }
                    )
                    .child(text("\(s.count)").key("count"))
                    .onKeyUp { st, _, tx in
                        st.nudge(&tx)
                        return true
                    }
            }
        )
        _ = rt.frame(at: 0.0)
        // First frame queued an `onLayout` action (`hasPendingActions == true`); flush at 0.5 after a keyUp live-only + unhandled keyDown.
        _ = rt.keyUp(KeyEvent(key: .arrowRight), at: 0.5)
        _ = rt.keyDown(KeyEvent(key: .arrowLeft), at: 0.5)
        _ = rt.frame(at: 0.5 + 1.0 / 120.0)
        #expect(didTriggerLayout)
        #expect(rt.state.count == 1)
        #expect(rt.liveOnlyWarnings.isEmpty)
    }

    @Test("live_only_tests.rs:216 - retained exit pruning does not change viewPrint")
    func retainedExitPruningDoesNotChangeViewPrint() {
        var visible = true
        let rt = Runtime<Int>(state: 0, viewport: Vec2(200, 200), pixelScale: 1.0) { _, _ in
            el().size(200, 200)
                .child(el().key("steady").size(40, 40))
                .child(visible ? el().key("temp").size(40, 40).transition(.opacity) : nil)
        }
        _ = rt.frame(at: 0.0)
        let before = rt.viewPrint()
        visible = false
        rt.update(at: 0.01) { s, _ in s += 1 }
        _ = rt.frame(at: 0.01)
        let exiting = rt.viewPrint()
        #expect(before.firstDifference(against: exiting) != nil)
        _ = rt.frame(at: 10.0)
        #expect(exiting.firstDifference(against: rt.viewPrint()) == nil)
    }

    @Test("live_only_tests.rs:228 - liveOnly keeps clipboard, scroll, and wake requests")
    func liveOnlyKeepsClipboardScrollAndWakeRequests() {
        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(200, 200),
            pixelScale: 1.0,
            onKey: { _, _, tx in
                tx.liveOnly()
                tx.copyText("copied")
                tx.scrollToY("scroll", 300.0)
                tx.wakeAfter(1.0)
                return true
            },
            view: { _, _ in
                el().child(
                    el().key("scroll").size(100, 100)
                        .scrollY()
                        .child(el().size(100, 1000))
                )
            }
        )
        rt.checkLiveOnly(false)
        _ = rt.frame(at: 0.0)
        let before = rt.viewCommitCount
        _ = rt.keyDown(KeyEvent(key: .arrowRight), at: 0.0)
        _ = rt.frame(at: 0.0)
        #expect(rt.viewCommitCount == before)
        #expect(rt.clipboard.text == "copied")
        #expect(rt.scrollOffsets.values.first?.y == 300.0)
        _ = rt.frame(at: 1.0 / 20.0)
        #expect(rt.nextWakeDeadline == 1.0)
    }

    @Test("live_only_tests.rs:252 - local points follow scroll offsets and element scale")
    func localPointsFollowScrollOffsetsAndScale() {
        var lastMove: PointerPress?
        let rt = Runtime<Int>(state: 0, viewport: Vec2(400, 400), pixelScale: 2.0) { _, _ in
            el().size(400, 400).child(
                el().key("scroll").absolute(x: 100, y: 100).size(200, 200).scale(1.5).scrollY()
                    .child(
                        col().size(200, 1000)
                            .child(el().size(200, 120))
                            .child(
                                el().key("target").size(50, 50)
                                    .onPointerMove { _, press, _ in lastMove = press }
                            )
                    )
            )
        }
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.0) { _, tx in tx.scrollToY("scroll", 100.0) }
        _ = rt.frame(at: 0.0)
        let r = rt.element(byKey: "target")!.rect
        let wx = r[0] + 15.0
        let wy = r[1] + 30.0
        rt.pointerMove(to: Vec2(wx, wy), at: 0.01)
        _ = rt.frame(at: 0.01)
        #expect(lastMove != nil)
        #expect(abs((lastMove?.local.x ?? -1) - 10.0) < 0.05)
        #expect(abs((lastMove?.local.y ?? -1) - 20.0) < 0.05)
        #expect(abs((lastMove?.window.x ?? -1) - wx) < 0.05)
        #expect(abs((lastMove?.window.y ?? -1) - wy) < 0.05)
    }

    @Test("live_only_tests.rs:271 - live transform refreshes hover paint without a handler")
    func liveTransformRefreshesHoverPaintWithoutHandler() {
        let offset = Live<Vec2>(Vec2(100, 0))
        let rt = Runtime<Live<Vec2>>(state: offset, viewport: Vec2(200, 200), pixelScale: 1.0) { s, _ in
            el().size(200, 200)
                .child(el().key("moving").size(40, 40).liveOffset(s.binding).hover(.white))
        }
        _ = rt.frame(at: 0.0)
        rt.pointerMove(to: Vec2(20, 20), at: 0.0)
        _ = rt.frame(at: 0.0)
        offset.set(.zero)
        _ = rt.frame(at: 0.01)
        _ = rt.frame(at: 0.01 + 1.0 / 120.0)
        #expect(rt.isAnimating || (rt.element(byKey: "moving")?.hover ?? 0) > 0.001)
    }

    @Test("live_only_tests.rs:285 - commit records CommitWhy for the frame log")
    func commitRecordsWhyForFrameLog() {
        for (source, want) in [(0, CommitWhy.poll), (1, CommitWhy.input)] {
            let rt = makeApp(misuse: false)
            rt.checkLiveOnly(false)
            _ = rt.frame(at: 0.0)
            rt.commitWhy = 0
            _ = rt.keyUp(KeyEvent(key: .arrowRight), at: 0.0)
            _ = rt.frame(at: 0.0)
            #expect(rt.commitWhy == 0)
            if source == 0 {
                rt.poll = { st, _, _ in st.count += 1; return true }
            } else {
                clickCenter(rt, key: "camera", at: 0.01)
            }
            _ = rt.frame(at: 0.01)
            #expect((rt.commitWhy & want) == want)
        }
    }

    @Test("tests/live_only.rs:167 - declined magnify/rotate event takes back its liveOnly")
    func declinedGestureTakesBackLiveOnly() {
        let rtMag = Runtime<UInt32>(state: 0, viewport: Vec2(100, 100), pixelScale: 1.0) { _, _ in
            el().size(100, 100)
                .child(el().key("inner").size(100, 100).onMagnify { _, _, tx in tx.liveOnly(); return false })
                .onMagnify { st, _, _ in st += 1; return true }
        }
        rtMag.checkLiveOnly(false)
        _ = rtMag.frame(at: 0.0)
        let beforeMag = rtMag.viewCommitCount
        #expect(rtMag.magnify(MagnifyEvent(delta: 0.5), at: Vec2(50, 50), now: 1.0 / 120.0))
        _ = rtMag.frame(at: 1.0 / 120.0)
        #expect(rtMag.state == 1)
        #expect(rtMag.viewCommitCount - beforeMag == 1)
        #expect(rtMag.liveOnlyEvents == 0)

        let rtRot = Runtime<UInt32>(state: 0, viewport: Vec2(100, 100), pixelScale: 1.0) { _, _ in
            el().size(100, 100)
                .child(el().key("inner").size(100, 100).onRotate { _, _, tx in tx.liveOnly(); return false })
                .onRotate { st, _, _ in st += 1; return true }
        }
        rtRot.checkLiveOnly(false)
        _ = rtRot.frame(at: 0.0)
        let beforeRot = rtRot.viewCommitCount
        #expect(rtRot.rotate(RotateEvent(degrees: 15.0), at: Vec2(50, 50), now: 1.0 / 120.0))
        _ = rtRot.frame(at: 1.0 / 120.0)
        #expect(rtRot.state == 1)
        #expect(rtRot.viewCommitCount - beforeRot == 1)
        #expect(rtRot.liveOnlyEvents == 0)
    }
}

// MARK: - Growth State-Machine Walk Parity (`src/growth/walk.rs:386`)

@Suite("Growth Walk Parity Tests (growth/walk.rs)")
struct GrowthWalkParityTests {
    private struct Dev {
        var h: Float = 0
        var v: Float = 0
        var target: Float = 0
        var age: Float = 0
        var mask: Float = 0
        var streaming: Bool = false
        var whole: Bool = false
        var duration: Float = 0
        var span: Float = 0
        var glide: Spring? = nil
        var feather: Float? = nil
        var limit: Float = .infinity
        var stage: Float? = nil
        var slide: (Float, Float)? = nil
        var riding: Bool = false
        var restore: Float = 0
        var give: Float? = nil
        var paced: Bool = false
        var rate: Float = 0
        var ended: Float = 0
        var shut: Bool = false

        static func settled(_ h: Float) -> Dev {
            Dev(h: h, v: 0, target: h)
        }

        var moving: Bool { !atRest(target - h) || mask > 0.01 }

        func atRest(_ remaining: Float) -> Bool {
            let (dist, speed): (Float, Float) = (duration > 0.0 || target == 0.0)
                ? (1.0 / 128.0, 0.5)
                : (1.0 / 16.0, 1.5)
            return abs(remaining) <= dist && abs(v) <= speed
        }

        func lift() -> Float {
            guard let (a, b) = slide else { return 0 }
            return max(0, a + b * h)
        }

        func shuttingFold() -> Bool {
            glide != nil && h > target + 0.01
        }

        mutating func retarget(_ newTarget: Float) {
            guard abs(newTarget - target) > 1e-4 else { return }
            let l = lift()
            if !moving { age = 0 }
            if streaming { rate += max(0, newTarget - target) / 0.5 }
            target = newTarget
            span = abs(newTarget - h)
            stage = nil
            give = nil
            shut = glide != nil && newTarget < h
            if glide != nil {
                if newTarget < h && h > limit {
                    h = max(limit, newTarget)
                } else if newTarget > h && newTarget > limit {
                    stage = max(limit, h)
                }
                span = abs(newTarget - h)
            }
            let d = newTarget - h
            slide = (l > 1.0 / 64.0 && abs(d) > 1.0 / 64.0) ? (l * newTarget / d, -l / d) : nil
            riding = false
        }

        mutating func hideAbove(_ above: Float) -> Float {
            let pinned = lift() + h
            let cut = max(0, min(above, h - target))
            h -= cut
            span = abs(target - h)
            slide = (pinned, -1.0)
            riding = true
            return cut
        }

        mutating func rideUp(_ rise: Float) {
            let from = lift()
            let curH = h
            let s = min(target, curH + max(0, rise))
            let d = s - curH
            let end = target - s
            let b: Float = d > 1.0 / 64.0 ? (end - from) / d : 0.0
            slide = (d > 1.0 / 64.0 ? from - b * curH : end, b)
            riding = false
            stage = s
            span = d
        }

        mutating func setKind(streaming: Bool, whole: Bool, fold: (FoldGlide, Float)?) {
            self.streaming = streaming
            self.paced = self.paced || streaming
            self.whole = whole
            let fg = streaming ? nil : fold
            if fg == nil {
                stage = nil
                shut = false
            }
            glide = fg?.0.spring
            feather = fg?.0.feather
            limit = fg?.1 ?? .infinity
        }

        mutating func climb(_ rem: Float, carryingTail: Bool) {
            let dt: Float = 1.0 / 240.0
            ended = streaming ? 0 : ended + dt
            let landing = min(1.0, ended / 0.15)
            let w = min(40.0, max(2.5 + (18.0 - 2.5) * landing, rate / 4.0))
            let a = min(6000.0, max(-6000.0, w * w * rem - 2.0 * w * v))
            var cap: Float = rem > 240.0 ? 16.0 * 60.0 : 11.5 * 60.0
            if carryingTail { cap = min(cap, 7.5 * 60.0) }
            let nextV = min(cap.isFinite ? min(cap, sqrtf(2.0 * 6000.0 * rem)) : sqrtf(2.0 * 6000.0 * rem), max(8.0 * landing, v + a * dt))
            if nextV * dt >= rem {
                h = target
                v = 0
            } else {
                h += nextV * dt
                v = nextV
            }
            age += dt
        }

        mutating func step(spring: Spring, edge: StreamEdge, carryingTail: Bool) {
            let dt: Float = 1.0 / 240.0
            let sp = spring.withDuration(max(spring.duration, duration) * max(edge.duration, 0.05))
            let aim = stage ?? target
            let rem = aim - h
            if stage != nil && abs(rem) < 1.0 {
                restore += lift()
                slide = nil
                h = target
                v = 0
                stage = nil
            } else if atRest(rem) {
                h = target
                v = 0
            } else if paced && rem > 0 {
                climb(rem, carryingTail: carryingTail)
            } else if !streaming, let own = glide {
                let (x, nv) = own.sample(from: h, velocity: v, target: aim, at: dt)
                let landed = (rem >= 0 && x >= aim) || (rem <= 0 && x <= aim)
                h = landed ? aim : x
                v = landed ? 0 : nv
                age += dt
            } else if whole {
                let scaled = sp.withDuration(sp.duration * Float.maximum(sqrtf(span / 300.0), 1.0))
                let (x, nv) = scaled.sample(from: h, velocity: v, target: target, at: dt)
                let landed = (rem >= 0 && x >= target) || (rem <= 0 && x <= target)
                h = landed ? target : x
                v = landed ? 0 : nv
                age += dt
            } else {
                let (x, _) = sp.sample(from: h, velocity: v, target: target, at: dt)
                var cap: Float = abs(rem) > 240.0 ? 16.0 * 60.0 : 11.5 * 60.0
                if carryingTail { cap = min(cap, 7.5 * 60.0) }
                cap = min(cap, 1.875 * 60.0 * expf(28.2 * age))
                if streaming && rem > 0 && rem < 36.0 {
                    cap = min(cap, (0.085 * rem + 0.65 * min(rem / 4.0, 1.0)) * 60.0 * edge.catchUp)
                }
                let braking = sqrtf(2.0 * 1800.0 * abs(rem))
                cap = max(cap, min(abs(v) - 1800.0 * dt, braking))
                cap = min(cap, 14.0 * abs(rem) + 3.0)
                var d = x - h
                let lim = cap * dt
                d = min(lim, max(-lim, d))
                let landed = (rem >= 0 && d >= rem) || (rem <= 0 && d <= rem)
                if landed { d = rem }
                h += d
                v = landed ? 0 : d / dt
                age += dt
            }
            let left = max(0, target - h)
            let mAim: Float = left > 0.25 ? min(edge.maskMax, max(edge.floor, 1.5 * left)) : 0
            if glide != nil && !streaming {
                let leftAbs = abs(target - h)
                let riding = self.riding
                let fAim: Float = (leftAbs > 0.25 && !riding) ? min(feather ?? edge.maskMax, 1.5 * leftAbs) : 0
                mask = fAim > mask ? min(mAim == mAim ? fAim : fAim, mask + 600.0 * dt) : fAim
            } else if mAim > mask {
                mask = min(mAim, mask + (5.0 * 60.0) * dt)
            } else {
                mask = max(mAim, mask - edge.shrink * dt)
            }
            rate *= expf(-dt / 0.5)
            if !moving {
                if !shut {
                    slide = nil
                    riding = false
                }
                if !streaming {
                    paced = false
                    rate = 0
                    ended = 0
                }
            }
        }
    }

    private enum Ev {
        case kind(streaming: Bool, whole: Bool, fold: (FoldGlide, Float)?)
        case retarget(Float)
        case hideAbove(Float)
        case rideUp(Float)
        case step(carryingTail: Bool)
    }

    private func mismatch(_ t: GrowTrack, _ d: Dev) -> String? {
        if t.h.bitPattern != d.h.bitPattern { return "h \(t.h) vs \(d.h)" }
        if t.v.bitPattern != d.v.bitPattern { return "v \(t.v) vs \(d.v)" }
        if t.target.bitPattern != d.target.bitPattern { return "target \(t.target) vs \(d.target)" }
        if t.age.bitPattern != d.age.bitPattern { return "age \(t.age) vs \(d.age)" }
        if t.mask.bitPattern != d.mask.bitPattern { return "mask \(t.mask) vs \(d.mask)" }
        if t.span.bitPattern != d.span.bitPattern { return "span \(t.span) vs \(d.span)" }
        if t.restore.bitPattern != d.restore.bitPattern { return "restore \(t.restore) vs \(d.restore)" }
        if t.rate.bitPattern != d.rate.bitPattern { return "rate \(t.rate) vs \(d.rate)" }
        if t.currentLift().bitPattern != d.lift().bitPattern { return "lift \(t.currentLift()) vs \(d.lift())" }
        if t.streaming != d.streaming { return "streaming" }
        if t.give?.bitPattern != d.give?.bitPattern { return "give" }
        if t.isShut != d.shut { return "shut" }
        if t.isShuttingFold != d.shuttingFold() { return "shuttingFold" }
        if t.glide != d.glide { return "glide" }
        if t.feather != d.feather { return "feather" }
        if t.whole != d.whole { return "whole" }
        if t.isStaged != (d.stage != nil) { return "staged" }
        if t.isPaced != d.paced { return "paced" }
        if t.isRiding != d.riding { return "riding" }
        if t.isLiftedAtAll != (d.slide != nil) { return "liftedAtAll" }
        return nil
    }

    @Test("growth/walk.rs:386 - sequence walk matches literal Dev reference")
    func everySequenceOfEventsMatchesDev() {
        let foldSpring = Spring(duration: 0.18, bounce: 0.0)
        let alphabet: [Ev] = [
            .kind(streaming: false, whole: false, fold: nil),
            .kind(streaming: true, whole: false, fold: nil),
            .kind(streaming: false, whole: true, fold: nil),
            .kind(streaming: false, whole: false, fold: (FoldGlide(spring: foldSpring, feather: nil), 900.0)),
            .kind(streaming: false, whole: false, fold: (FoldGlide(spring: foldSpring, feather: 20.0), 400.0)),
            .retarget(120.0),
            .retarget(640.0),
            .hideAbove(12.0),
            .rideUp(90.0),
            .step(carryingTail: false),
            .step(carryingTail: true),
        ]
        var visited = 0
        var firstFailure: String?
        func explore(_ t: GrowTrack, _ d: Dev, left: Int) {
            if left == 0 || firstFailure != nil { return }
            for e in alphabet {
                var nt = t
                var nd = d
                switch e {
                case let .kind(streaming, whole, fold):
                    nt.setKind(streaming: streaming, whole: whole, glide: fold)
                    nd.setKind(streaming: streaming, whole: whole, fold: fold)
                case let .retarget(to):
                    nt.retarget(to)
                    nd.retarget(to)
                case let .hideAbove(above):
                    let cutA = nt.hideAbove(above)
                    let cutB = nd.hideAbove(above)
                    if cutA.bitPattern != cutB.bitPattern {
                        firstFailure = "hideAbove cut \(cutA) vs \(cutB)"
                        return
                    }
                case let .rideUp(rise):
                    nt.rideUp(rise)
                    nd.rideUp(rise)
                case let .step(carryingTail):
                    nt.step(spring: Growth.spring, edge: .feather, carryingTail: carryingTail)
                    nd.step(spring: Growth.spring, edge: .feather, carryingTail: carryingTail)
                }
                visited += 1
                if let err = mismatch(nt, nd) {
                    firstFailure = err
                    return
                }
                explore(nt, nd, left: left - 1)
                if firstFailure != nil { return }
            }
        }
        // Depth 6 tests all 11^6 * 2 = 3,543,122 transitions against Dev bit-exact (matching growth/walk.rs DEPTH = 6).
        for from: Float in [0.0, 640.0] {
            explore(GrowTrack.settled(from), Dev.settled(from), left: 6)
        }
        #expect(visited > 0)
        #expect(firstFailure == nil, "first divergence: \(firstFailure ?? "")")
    }

    @Test("growth.rs:818 - fold reopened by what it was cut by still feathers (r266)")
    func foldReopenedByWhatItWasCutByStillFeathers() {
        let foldSpring = Spring(duration: 0.18, bounce: 0.0)
        func cut() -> GrowTrack {
            var t = GrowTrack.settled(640.0)
            t.setKind(streaming: false, whole: false, glide: (FoldGlide(spring: foldSpring, feather: nil), 900.0))
            t.retarget(120.0)
            _ = t.hideAbove(12.0)
            return t
        }

        // Riding: contents aren't cut by the edge, so nothing to soften.
        var riding = cut()
        #expect(riding.isRiding)
        riding.step(spring: Growth.spring, edge: .feather, carryingTail: false)
        #expect(riding.mask == 0.0)

        // Reopened by exactly what it was cut by: the same 12 pt, on its edge by arithmetic.
        var t = cut()
        t.retarget(640.0)
        #expect(t.lift == .easing(a: 640.0, b: -1.0))
        #expect(t.currentLift() == 12.0)
        t.step(spring: Growth.spring, edge: .feather, carryingTail: false)
        #expect(t.mask > 2.4)
    }
}
