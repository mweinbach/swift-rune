import Foundation
import Testing
@testable import Rune
@testable import RuneMotion

@Suite("Motion Integration Parity Tests (drawOn, groupOpacity, loopSleep, pictureScale, springs, reviveSettle)")
struct MotionIntegrationParityTests {
    // MARK: - drawOn (`draw_on.rs`)

    @Test("drawOn: Transition.draw trims vector strokes across enter and exit and snaps under reducedMotion")
    func drawOnAnimatesAndRespectsReducedMotion() {
        let seg = Rune.Shape().line(Vec2(0, 10), Vec2(100, 10), width: 2, cap: .round, color: .white)
        let rt = Runtime<Bool>(state: false, viewport: Vec2(120, 40), pixelScale: 1.0) { show, _ in
            var root: El<Bool> = el().size(120, 40)
            if show {
                root = root.child(
                    canvas(seg).key("stroke").size(100, 20).transition(.draw)
                )
            }
            return root
        }
        _ = rt.frame(at: 0)
        #expect(rt.presented("stroke") == nil)

        // Mount: draw should start below 1.0 (shorter segment) and progress smoothly to 1.0
        rt.update(at: 0) { show, _ in show = true }
        let s0 = rt.renderFrame(at: 0.01)
        let mid = s0.instances.first(where: { $0.params.y == KIND_SEGMENT })
        #expect(mid != nil)
        if let mid {
            #expect(mid.radii.z < 99.0, "draw-on entrance trims stroke length: bx=\(mid.radii.z)")
        }
        for step in 1...60 {
            _ = rt.frame(at: Double(step) / 60.0)
        }
        #expect(!rt.isAnimating)
        let settled = rt.renderFrame(at: 1.5)
        let fullSeg = settled.instances.first(where: { $0.params.y == KIND_SEGMENT })
        #expect(fullSeg != nil)
        if let fullSeg {
            #expect(abs(fullSeg.radii.z - 100.0) < 0.5)
        }

        // Exit: draw reverses cleanly back down until unmounted
        rt.update(at: 1.5) { show, _ in show = false }
        let exScene = rt.renderFrame(at: 1.55)
        #expect(rt.isAnimating)
        #expect(rt.presented("stroke") != nil)
        #expect(exScene.instances.contains(where: { $0.params.y == KIND_SEGMENT }))
        for step in 1...80 {
            _ = rt.frame(at: 1.55 + Double(step) / 60.0)
        }
        #expect(rt.presented("stroke") == nil)

        // Reduced motion draws immediately at rest without animation
        let rm = Runtime<Bool>(state: false, viewport: Vec2(120, 40), pixelScale: 1.0, systemDark: true, reducedMotion: true) { show, _ in
            var root: El<Bool> = el().size(120, 40)
            if show {
                root = root.child(canvas(seg).key("stroke").size(100, 20).transition(.draw))
            }
            return root
        }
        _ = rm.frame(at: 0)
        rm.update(at: 0) { show, _ in show = true }
        _ = rm.frame(at: 1.0 / 60.0)
        #expect(!rm.isAnimating)
    }

    // MARK: - groupOpacity (`group_opacity.rs`)

    private struct GroupOpacityState {
        var restShown: Bool = false
        var mountSecond: Bool = false
        var reduced: Bool = false
    }

    @Test("groupOpacity: rest level change animates, instant/reduced snaps, and new mount starts at rest")
    func groupOpacityRestAndMountBehavior() {
        let rt = Runtime<GroupOpacityState>(state: GroupOpacityState(), viewport: Vec2(200, 100)) { s, cx in
            cx.reducedMotion(s.reduced)
            let rest: Float = s.restShown ? 1.0 : 0.0
            var r: El<GroupOpacityState> = row().key("row").size(200, 40).hoverGroup()
                .child(el().key("act").size(10, 10).bg(.white).groupOpacity(rest, 1.0))
            if s.mountSecond {
                r = r.child(el().key("new").size(10, 10).bg(.white).groupOpacity(0.0, 1.0))
            }
            return col().size(200, 100).child(r)
        }
        _ = rt.frame(at: 0)
        #expect(rt.presented("act")?.opacity == 0.0)

        // Rest change animates smoothly to 1.0
        rt.update(at: 0) { s, _ in s.restShown = true }
        var seen: [Float] = []
        for i in 1...120 {
            _ = rt.frame(at: Double(i) / 120.0)
            seen.append(rt.presented("act")?.opacity ?? -1)
        }
        #expect(seen[0] < 0.5)
        for i in 1..<seen.count {
            #expect(seen[i] >= seen[i - 1] - 1e-4)
        }
        #expect(abs(seen[119] - 1.0) < 1e-3)
        #expect(!rt.isAnimating)

        // Newly mounted child draws at rest 0.0 from frame 0
        rt.update(at: 1.0) { s, _ in s.mountSecond = true }
        for i in 1...30 {
            _ = rt.frame(at: 1.0 + Double(i) / 120.0)
            let op = rt.presented("new")?.opacity ?? -1
            #expect(op >= 0.0 && op < 1.0 / 512.0, "frame \(i): expected rest 0, got \(op)")
        }

        // Instant & reduced motion snap immediately
        rt.update(at: 1.5) { s, tx in
            tx.instant()
            s.restShown = false
        }
        _ = rt.frame(at: 1.5 + 1.0 / 120.0)
        #expect(rt.presented("act")?.opacity == 0.0)

        let rm = Runtime<GroupOpacityState>(
            state: GroupOpacityState(restShown: true, mountSecond: false, reduced: true),
            viewport: Vec2(200, 100)
        ) { s, cx in
            cx.reducedMotion(s.reduced)
            let rest: Float = s.restShown ? 1.0 : 0.0
            return col().size(200, 100).child(
                row().key("row").size(200, 40).hoverGroup()
                    .child(el().key("act").size(10, 10).bg(.white).groupOpacity(rest, 1.0))
            )
        }
        _ = rm.frame(at: 0)
        rm.update(at: 0) { s, _ in s.restShown = false }
        _ = rm.frame(at: 1.0 / 120.0)
        #expect(rm.presented("act")?.opacity == 0.0)
    }

    @Test("groupOpacity: adding or dropping groupOpacity fades smoothly and obeys opacityMotion(.instant)")
    func groupOpacityAddingOrDroppingFades() {
        let rt = Runtime<Bool>(state: true, viewport: Vec2(200, 100)) { on, _ in
            let actBase: El<Bool> = el().key("act").size(10, 10).bg(.white)
            let act = on ? actBase.groupOpacity(0.0, 1.0) : actBase
            return col().size(200, 100).child(
                row().key("row").size(200, 40).hoverGroup().child(act)
            )
        }
        _ = rt.frame(at: 0)
        #expect(rt.presented("act")?.opacity == 0.0)

        // Dropping groupOpacity fades smoothly toward 1.0
        rt.update(at: 0) { on, _ in on = false }
        var fadeUp: [Float] = []
        for i in 1...120 {
            _ = rt.frame(at: Double(i) / 120.0)
            fadeUp.append(rt.presented("act")?.opacity ?? -1)
        }
        #expect(fadeUp[0] < 0.5)
        for i in 1..<fadeUp.count {
            #expect(fadeUp[i] >= fadeUp[i - 1] - 1e-4)
        }
        #expect(abs(fadeUp[119] - 1.0) < 1e-3)
        #expect(!rt.isAnimating)

        // Re-adding groupOpacity fades smoothly back to 0.0
        rt.update(at: 1.0) { on, _ in on = true }
        var fadeDown: [Float] = []
        for i in 1...120 {
            _ = rt.frame(at: 1.0 + Double(i) / 120.0)
            fadeDown.append(rt.presented("act")?.opacity ?? -1)
        }
        #expect(fadeDown[0] > 0.5)
        for i in 1..<fadeDown.count {
            #expect(fadeDown[i] <= fadeDown[i - 1] + 1e-4)
        }
        #expect(fadeDown[119] < 1e-3)
        #expect(!rt.isAnimating)

        // Dropping with opacityMotion(.instant) snaps immediately
        let instantRt = Runtime<Bool>(state: true, viewport: Vec2(200, 100)) { on, _ in
            let actBase: El<Bool> = el().key("act").size(10, 10).bg(.white)
            let act = on ? actBase.groupOpacity(0.0, 1.0) : actBase.opacityMotion(Anim<Float>.instant)
            return col().size(200, 100).child(
                row().key("row").size(200, 40).hoverGroup().child(act)
            )
        }
        _ = instantRt.frame(at: 0)
        instantRt.update(at: 0) { on, _ in on = false }
        _ = instantRt.frame(at: 1.0 / 120.0)
        #expect(instantRt.presented("act")?.opacity == 1.0)
    }

    // MARK: - loopSleep (`loop_sleep.rs`)

    @Test("loopSleep: hiding window sleeps loops and showing wakes them; reducedMotion freezes at midpoint")
    func loopSleepHiddenWindowAndReducedMotion() {
        let rt = Runtime<Bool>(state: false, viewport: Vec2(100, 100)) { reduced, cx in
            cx.reducedMotion(reduced)
            return col().size(100, 100).child(
                el().key("pulse").size(40, 40).bg(.white).loopOpacity(low: 0.2, high: 0.8, period: 1.0)
            )
        }
        _ = rt.frame(at: 0)
        #expect(rt.isAnimating)

        rt.setLiveVisible(false)
        _ = rt.frame(at: 0.1)
        #expect(!rt.isAnimating, "hidden window pauses loop animation")

        rt.setLiveVisible(true)
        _ = rt.frame(at: 0.2)
        #expect(rt.isAnimating, "visible window wakes loops")

        // Reduced motion holds low opacity (phase 0.0) without animating
        rt.update(at: 0.2) { reduced, _ in reduced = true }
        _ = rt.frame(at: 0.25)
        #expect(!rt.isAnimating)
        let mid = rt.presented("pulse")?.opacity ?? -1
        #expect(abs(mid - 0.2) < 0.02)
    }

    // MARK: - pictureScale (`picture_scale.rs`)

    @Test("pictureScale: dynamic scaling avoids GlyphAtlas bloat and settled scaled text rasterizes crisply")
    func pictureScaleTextCrispnessAndBoundedAtlas() {
        let rt = Runtime<Float>(state: 1.0, viewport: Vec2(400, 200)) { sc, _ in
            el().key("box").size(120, 40).scale(sc).child(
                text("Crisp").key("lbl").font(TextStyle(size: 14, weight: 400))
            )
        }
        _ = rt.renderFrame(at: 0)
        let startCount = rt.textSystem.glyphAtlas.rasterized

        // 200 varying scales should NOT place 200 distinct scale tiers in GlyphAtlas
        for i in 1...200 {
            let s = 1.0 + Float(i) * 0.005
            rt.update(at: Double(i) * 0.01) { sc, tx in
                sc = s
                tx.instant()
            }
            _ = rt.renderFrame(at: Double(i) * 0.01)
        }
        let midDelta = rt.textSystem.glyphAtlas.rasterized - startCount
        #expect(midDelta < 40, "dynamic scales must sample rest size; placed \(midDelta) glyphs")

        // Settle at 3.0x: after one unchanged frame, crisp rasterization places crisp 3x glyphs
        let preSettlePlaced = rt.textSystem.glyphAtlas.rasterized
        _ = rt.renderFrame(at: 3.0)
        let postSettlePlaced = rt.textSystem.glyphAtlas.rasterized
        #expect(postSettlePlaced > preSettlePlaced, "settled scaled text rasterizes at pixelScale * scale")
    }

    @Test("pictureScale: pressScale resting hit, edge pointerMove release/re-enter, scroll/fling cancel, and release bounce")
    func pressScaleLifecycle() {
        struct S { var pressed: Int = 0; var reduced: Bool = false }
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 200)) { s, cx in
            cx.reducedMotion(s.reduced)
            return col().size(200, 200).child(
                el().key("tile").size(100, 100).pressScale(0.96)
                    .onClick { st, _ in st.pressed += 1 }
                    .child(el().key("dot").size(10, 10))
            )
        }
        func tileScale(_ r: Runtime<S>, key: String = "tile") -> Float {
            r.elements().first(where: { $0.key == key })?.scale ?? -1
        }
        func settle(_ r: Runtime<S>, base: inout Double) {
            for _ in 0..<90 {
                base += 1.0 / 120.0
                _ = r.frame(at: base)
            }
        }

        var t = 0.0
        _ = rt.frame(at: t)
        #expect(tileScale(rt) == 1.0)

        // Press near right edge (x=99): stays pressed even after shrinking to width 96!
        rt.pointerMove(to: Vec2(99, 50), at: t)
        rt.pointerDown(at: Vec2(99, 50), at: t)
        settle(rt, base: &t)
        #expect(abs(tileScale(rt) - 0.96) < 1e-3)
        #expect(abs(tileScale(rt, key: "dot") - 0.96) < 1e-3)

        // Moving outside resting rect while held springs back to 1.0
        rt.pointerMove(to: Vec2(150, 50), at: t)
        settle(rt, base: &t)
        #expect(abs(tileScale(rt) - 1.0) < 1e-3)

        // Re-entering resting rect shrinks again; releasing inside resting rect fires onClick and bounces > 1.0!
        rt.pointerMove(to: Vec2(99, 50), at: t)
        settle(rt, base: &t)
        #expect(abs(tileScale(rt) - 0.96) < 1e-3)
        rt.pointerUp(at: Vec2(99, 50), at: t)
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(rt.state.pressed == 1)
        var peak = tileScale(rt)
        for _ in 0..<90 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            peak = max(peak, tileScale(rt))
        }
        #expect(peak > 1.0, "release bounces slightly past 1.0: \(peak)")
        #expect(abs(tileScale(rt) - 1.0) < 1e-3)

        // Scroll wheel and fling inside scroll container cancel active press
        let scrollRt = Runtime<Int>(state: 0, viewport: Vec2(200, 120)) { _, _ in
            col().key("sc").size(200, 120).scrollY().child(
                col().size(200, 400).child(
                    el().key("row0").size(200, 40).pressScale(0.95).onClick { st, _ in st += 1 }
                )
            )
        }
        _ = scrollRt.frame(at: 0)
        scrollRt.pointerMove(to: Vec2(100, 20), at: 0)
        scrollRt.pointerDown(at: Vec2(100, 20), at: 0)
        for i in 1...10 { _ = scrollRt.frame(at: Double(i) / 120.0) }
        scrollRt.wheel(WheelEvent(dy: -60), at: Vec2(100, 20), now: 0.1)
        for i in 13...70 { _ = scrollRt.frame(at: Double(i) / 120.0) }
        scrollRt.pointerUp(at: Vec2(100, 20), at: 0.6)
        _ = scrollRt.frame(at: 0.65)
        #expect(scrollRt.state == 0, "scroll cancels active press")

        scrollRt.pointerMove(to: Vec2(100, 20), at: 0.7)
        scrollRt.pointerDown(at: Vec2(100, 20), at: 0.7)
        scrollRt.fling(vy: 600, at: Vec2(100, 20), now: 0.71)
        scrollRt.pointerUp(at: Vec2(100, 20), at: 0.72)
        _ = scrollRt.frame(at: 0.75)
        #expect(scrollRt.state == 0, "fling cancels active press")

        // Reduced motion disables pressScale
        rt.update(at: t) { s, tx in
            s.reduced = true
            tx.settle()
        }
        _ = rt.frame(at: t)
        rt.pointerMove(to: Vec2(50, 50), at: t)
        rt.pointerDown(at: Vec2(50, 50), at: t)
        settle(rt, base: &t)
        #expect(tileScale(rt) == 1.0)
    }

    @Test("pictureScale: Pixels single-side sizing, exiting Pixels wake, and unmounted Pixels stay silent")
    func pixelsSingleSideAndWakeLifecycle() {
        let px = Pixels()
        let rt = Runtime<Pixels>(state: px, viewport: Vec2(240, 400)) { p, _ in
            col().w(240).itemsStart()
                .child(pixels(p).key("w").w(120))
                .child(pixels(p, fit: .fit).key("h").h(30))
        }
        _ = rt.frame(at: 0)
        #expect(rt.elements().first(where: { $0.key == "w" })?.target[3] == 0)

        px.set(width: 4, height: 2, rgba: [UInt8](repeating: 255, count: 4 * 2 * 4))
        _ = rt.frame(at: 1.0 / 120.0)
        let wTarget = rt.elements().first(where: { $0.key == "w" })?.target
        let hTarget = rt.elements().first(where: { $0.key == "h" })?.target
        #expect(wTarget?[2] == 120 && wTarget?[3] == 60)
        #expect(hTarget?[2] == 60 && hTarget?[3] == 30)

        // Exiting Pixels wakes while exiting, stops waking after exit completes
        final class Counter: @unchecked Sendable { var count = 0 }
        let wakes = Counter()
        let direct = Pixels()
        let child = Pixels()
        let exitRt = Runtime<Bool>(state: true, viewport: Vec2(40, 40)) { show, _ in
            var root: El<Bool> = el().size(40, 40)
            if show {
                root = root
                    .child(pixels(direct).key("direct").size(4, 4).transition(.opacity))
                    .child(el().key("card").size(8, 8).transition(.opacity).child(pixels(child).key("child").size(4, 4)))
            }
            return root
        }
        exitRt.setLiveWaker(Waker { wakes.count += 1 })
        _ = exitRt.frame(at: 0)
        exitRt.update(at: 0) { show, _ in show = false }
        _ = exitRt.frame(at: 0)
        #expect(exitRt.isAnimating)
        direct.set(width: 1, height: 1, rgba: [1, 1, 1, 255])
        #expect(wakes.count == 1)
        _ = exitRt.frame(at: 1.0 / 120.0)
        child.set(width: 1, height: 1, rgba: [1, 1, 1, 255])
        #expect(wakes.count == 2)
        for i in 2...240 {
            _ = exitRt.frame(at: Double(i) / 120.0)
            if !exitRt.isAnimating { break }
        }
        #expect(exitRt.presented("child") == nil)
        direct.set(width: 1, height: 1, rgba: [2, 2, 2, 255])
        child.set(width: 1, height: 1, rgba: [2, 2, 2, 255])
        #expect(wakes.count == 2, "unmounted Pixels stop waking")
    }

    // MARK: - springs.rs (`timeScale`, `presented`, `duplicate matched`, `zero-opacity exit`) & `reviveSettle`

    private struct TimeScaleLab {
        var outside: Float = 1
        var inside: Float = 1
        var badge: Bool = true
        var outer: Float = 1
        var inner: Float = 0
    }

    @Test("springs: timeScale freezes/scales subtrees, exiting nodes drop self timeScale, and zero-opacity skips exit")
    func springsTimeScaleAndZeroOpacityExit() {
        let rt = Runtime<TimeScaleLab>(state: TimeScaleLab(outer: 1.0, inner: 0.0), viewport: Vec2(200, 200)) { s, _ in
            let dot = { (k: String, op: Float) -> El<TimeScaleLab> in
                el().key(k).size(20, 20).bg(.white).opacity(op).opacityMotion(MotionTokens.SETTLE)
            }
            var inner: El<TimeScaleLab> = col().key("inner").timeScale(s.inner).child(dot("inside", s.inside))
            if s.badge {
                inner = inner.child(el().key("badge").size(20, 20).bg(.white).transition(.opacity))
            }
            return col().key("root").size(200, 200)
                .child(dot("outside", s.outside))
                .child(col().key("outer").timeScale(s.outer).child(inner))
        }
        _ = rt.frame(at: 0)

        // Frozen inner asks for no frames when only inner changes
        rt.update(at: 0) { s, _ in s.inside = 0 }
        for i in 1...5 {
            _ = rt.frame(at: Double(i) / 60.0)
            #expect(!rt.isAnimating, "frozen subtree requests no frames")
        }
        #expect(rt.presented("inside")?.opacity == 1.0)

        // Resuming runs inner, and nested timeScales multiply (0.5 * 0.5 = 0.25)
        rt.update(at: 0.1) { s, _ in s.inner = 1.0 }
        _ = rt.frame(at: 0.1 + 1.0 / 60.0)
        #expect(rt.isAnimating)
        #expect((rt.presented("inside")?.opacity ?? 1.0) < 1.0)

        // Exiting badge inside frozen inner waits until inner resumes, then finishes
        let rtEx = Runtime<TimeScaleLab>(state: TimeScaleLab(outer: 1.0, inner: 0.0), viewport: Vec2(200, 200)) { s, _ in
            let dot = { (k: String, op: Float) -> El<TimeScaleLab> in
                el().key(k).size(20, 20).bg(.white).opacity(op).opacityMotion(MotionTokens.SETTLE)
            }
            var inner: El<TimeScaleLab> = col().key("inner").timeScale(s.inner).child(dot("inside", s.inside))
            if s.badge {
                inner = inner.child(el().key("badge").size(20, 20).bg(.white).transition(.opacity))
            }
            return col().key("root").size(200, 200).child(col().key("outer").timeScale(s.outer).child(inner))
        }
        _ = rtEx.frame(at: 0)
        rtEx.update(at: 0) { s, _ in s.badge = false }
        for i in 1...60 { _ = rtEx.frame(at: Double(i) / 60.0) }
        #expect(!rtEx.isAnimating)
        #expect(rtEx.presented("badge")?.opacity == 1.0)
        rtEx.update(at: 1.0) { s, _ in s.inner = 1.0 }
        for i in 1...120 { _ = rtEx.frame(at: 1.0 + Double(i) / 60.0) }
        #expect(!rtEx.isAnimating)
        #expect(rtEx.presented("badge") == nil)

        // Removing zero-opacity element or child under hidden parent skips exit
        let skipRt = Runtime<(Bool, Float, Bool)>(state: (true, 0.0, true), viewport: Vec2(200, 200)) { s, _ in
            var group: El<(Bool, Float, Bool)> = col().key("group").size(100, 100)
                .opacity(s.2 ? 0.0 : 1.0)
                .opacityMotion(Anim<Float>.instant)
            if s.0 {
                group = group.child(el().key("dot").size(10, 10).bg(.white).transition(.opacity))
            }
            var root: El<(Bool, Float, Bool)> = col().key("root").size(200, 200).child(group)
            if s.0 {
                root = root.child(el().key("glow").size(50, 50).bg(.white).opacity(s.1).transition(.opacity))
            }
            return root
        }
        _ = skipRt.frame(at: 0)
        skipRt.update(at: 0) { s, _ in s.0 = false }
        _ = skipRt.frame(at: 1.0 / 60.0)
        #expect(skipRt.presented("glow") == nil)
        #expect(skipRt.presented("dot") == nil)
        #expect(!skipRt.isAnimating)

        // Same-commit parent instant hide ends dot exit
        skipRt.update(at: 0.1) { s, _ in s = (true, 1.0, false) }
        for i in 1...30 { _ = skipRt.frame(at: 0.1 + Double(i) / 60.0) }
        skipRt.update(at: 0.7) { s, _ in s = (false, 1.0, true) }
        _ = skipRt.frame(at: 0.7 + 1.0 / 60.0)
        #expect(skipRt.presented("dot") == nil)
    }

    @Test("springs & reviveSettle: duplicate matched id warns, exiting flags vs find vs presented, and tx.settle revival")
    func matchedWarningsPresentedAndReviveSettle() {
        let dupRt = Runtime<Int>(state: 0, viewport: Vec2(100, 100)) { _, _ in
            col()
                .child(el().key("a").flightId("tile").size(10, 10))
                .child(el().key("b").flightId("tile").size(10, 10))
        }
        _ = dupRt.frame(at: 0)
        #expect(dupRt.keyWarnings.count == 1)
        #expect(dupRt.keyWarnings[0].contains("duplicate matched id \"tile\""))

        // Exiting elements have exiting=true, find returns nil, presented stays readable, tx.settle revives cleanly
        let rt = Runtime<Bool>(state: true, viewport: Vec2(200, 100)) { show, _ in
            var root: El<Bool> = col().key("root").size(200, 100)
            if show {
                root = root.child(
                    el().key("card").size(100, 60).transition(.blur(sigma: 4.0))
                        .child(el().key("label").size(20, 20))
                )
            }
            return root
        }
        _ = rt.frame(at: 0)
        #expect(rt.find("card") != nil && rt.find("label") != nil)
        rt.update(at: 0) { show, _ in show = false }
        _ = rt.frame(at: 0.05)
        let cardInfo = rt.elements().first(where: { $0.key == "card" })
        #expect(cardInfo?.exiting == true && cardInfo?.inert == true)
        #expect(rt.find("card") == nil)
        #expect(rt.presented("card") != nil)

        // Revive mid-exit with tx.settle() lands immediately at opacity 1.0
        rt.update(at: 0.1) { show, tx in
            show = true
            tx.settle()
        }
        _ = rt.frame(at: 0.1 + 1.0 / 60.0)
        #expect(rt.presented("card")?.opacity == 1.0)
        #expect(rt.find("card") != nil)
        #expect(!rt.isAnimating)
    }
}
