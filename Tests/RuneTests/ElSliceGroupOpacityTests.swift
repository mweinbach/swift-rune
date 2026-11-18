import Foundation
import Testing
@testable import Rune
import RuneMotion

@Suite("El Slice: Group Opacity Parity (group_opacity.rs)")
struct ElSliceGroupOpacityTests {

    @Test("Group opacity rests at 0, illuminates on pointer hover, and returns to rest on exit")
    func restOpacityThenHovered() {
        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(120, 80),
            pixelScale: 1.0
        ) { _, _ in
            el().size(64, 32).hoverGroup()
                .child(el().key("child").size(24, 24).bg(Color.white).groupOpacity(0.0, 1.0))
        }

        _ = rt.frame(at: 0.0)
        let restEl = rt.elements().first(where: { $0.key == "child" })
        #expect(restEl != nil)
        #expect((restEl?.opacity ?? 1.0) < 0.01)
        let rfRest = rt.renderFrame(at: 0.0)
        #expect(rfRest.instances.allSatisfy { $0.fill.w < 0.01 })

        rt.pointerMove(to: Vec2(12, 12), at: 0.05)
        _ = rt.frame(at: 0.05)
        _ = rt.frame(at: 1.0)
        let hovEl = rt.elements().first(where: { $0.key == "child" })
        #expect((hovEl?.opacity ?? 0.0) > 0.99)
        let rfHov = rt.renderFrame(at: 1.0)
        #expect(rfHov.instances.contains { $0.fill.w > 0.99 })

        rt.pointerMove(to: Vec2(100, 70), at: 1.05)
        _ = rt.frame(at: 1.05)
        _ = rt.frame(at: 2.5)
        let afterExit = rt.elements().first(where: { $0.key == "child" })
        #expect((afterExit?.opacity ?? 1.0) < 0.01)
    }

    /// Upstream 4e215eac (#726): every hover group lights while keyboard focus is on it or inside
    /// it (CSS `:is(:hover, :has(:focus-visible))`, `hover.rs::keyboard_within`), so all the
    /// controls it reveals show when Tab reaches one of them, not just the focused one.
    @Test("Keyboard focus inside a hover group lights the group's groupOpacity elements")
    func keyboardFocusWithinTriggersGroupOpacity() {
        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(120, 80),
            pixelScale: 1.0
        ) { _, _ in
            el().size(100, 40).hoverGroup()
                .child(
                    el().key("focused")
                        .size(24, 24)
                        .bg(Color.white)
                        .focusable(true)
                        .groupOpacity(0.0, 1.0)
                )
                .child(
                    el().key("sibling")
                        .size(24, 24)
                        .bg(Color.white)
                        .groupOpacity(0.0, 1.0)
                )
        }

        _ = rt.frame(at: 0.0)
        #expect((rt.elements().first(where: { $0.key == "focused" })?.opacity ?? 1.0) < 0.01)
        #expect((rt.elements().first(where: { $0.key == "sibling" })?.opacity ?? 1.0) < 0.01)

        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.02)
        _ = rt.frame(at: 0.02)
        #expect(rt.focusVisible)
        let focusedChild = rt.elements().first(where: { $0.key == "focused" })
        let siblingChild = rt.elements().first(where: { $0.key == "sibling" })
        #expect((focusedChild?.opacity ?? 0.0) > 0.99)
        #expect((siblingChild?.opacity ?? 0.0) > 0.99, "the group lights for keyboard focus inside it, revealing its sibling too")
        let rf = rt.renderFrame(at: 0.02)
        #expect(rf.instances.contains { $0.fill.w > 0.99 })
    }

    @Test("A row mounting before a hovered one draws its actions at rest without inheriting hover")
    func rowMountingBeforeHoveredOneDrawsActionsAtRest() {
        let rt = Runtime<Bool>(
            state: false,
            viewport: Vec2(200, 100),
            pixelScale: 1.0
        ) { prependNew, _ in
            func makeRow(_ k: String) -> El<Bool> {
                row().key(k).size(200, 20).hoverGroup()
                    .child(el().key("\(k)-act").size(10, 10).bg(Color.white).groupOpacity(0.0, 1.0))
            }
            var list: El<Bool> = col().size(200, 100)
            if prependNew {
                list = list.child(makeRow("new").absolute(x: 0, y: 60))
            }
            list = list.child(makeRow("old"))
            return list
        }

        func alpha(_ key: String) -> Float {
            rt.elements().first(where: { $0.key == key })?.opacity ?? -1.0
        }

        _ = rt.frame(at: 0.0)
        rt.pointerMove(to: Vec2(100, 10), at: 1.0 / 120.0)
        _ = rt.frame(at: 1.0 / 120.0)
        _ = rt.frame(at: 1.0)
        #expect(abs(alpha("old-act") - 1.0) < 0.01)

        rt.update(at: 1.0 + 1.0 / 120.0) { s, _ in s = true }
        for f in 0..<10 {
            let t = 1.0 + Double(f + 2) / 120.0
            _ = rt.frame(at: t)
            #expect(alpha("new-act") < 1e-4, "frame \(f): new row action should rest at 0")
            #expect(abs(alpha("old-act") - 1.0) < 1e-4, "frame \(f): old row action should stay at 1")
        }
    }

    @Test("A returning keyed group snaps to its new rest opacity during exit")
    func returningGroupSnapsToNewRestOpacity() throws {
        let rt = Runtime<(visible: Bool, rest: Float)>(
            state: (true, 0.2),
            viewport: Vec2(200, 100),
            pixelScale: 1.0
        ) { state, _ in
            var group: El<(visible: Bool, rest: Float)> = row().key("row").size(200, 40)
                .hoverGroup()
                .childExit(Transition.opacity.spring(Spring(duration: 0.5, bounce: 0)))
            if state.visible {
                group = group.child(el().key("action").size(10, 10).bg(.white).groupOpacity(state.rest, 1))
            }
            return group
        }

        _ = rt.frame(at: 0)
        let id = try #require(rt.flatNodes.first(where: { $0.key == "action" })?.nodeId)
        rt.update(at: 1) { state, _ in state.visible = false }
        _ = rt.frame(at: 1)
        let phase = try #require(rt.scene.phase(id))
        guard case .exiting = phase else {
            Issue.record("The action should still be exiting when it returns")
            return
        }

        rt.update(at: 1.01) { state, _ in state = (true, 0.8) }
        _ = rt.frame(at: 1.01)
        #expect(rt.flatNodes.first(where: { $0.key == "action" })?.nodeId == id)
        let rest = try #require(rt.scene.get(id, Props.GROUP_REST))
        #expect(abs(rest - 0.8) < 1e-5)
        #expect(!rt.scene.store.isAnimating(id, Props.GROUP_REST))
    }

    @Test("Adding or dropping groupOpacity fades smoothly rather than cutting")
    func addingOrDroppingGroupOpacityFades() {
        let rt = Runtime<Bool>(
            state: true,
            viewport: Vec2(200, 100),
            pixelScale: 1.0
        ) { on, _ in
            var act: El<Bool> = el().key("act").size(10, 10).bg(Color.white)
            if on {
                act = act.groupOpacity(0.0, 1.0)
            }
            return col().size(200, 100)
                .child(row().key("row").size(200, 40).hoverGroup().child(act))
        }

        func alpha() -> Float {
            rt.elements().first(where: { $0.key == "act" })?.opacity ?? -1.0
        }

        var clock = 0.0
        _ = rt.frame(at: clock)
        #expect(abs(alpha() - 0.0) < 1e-5)

        for (on, from, to) in [(false, Float(0.0), Float(1.0)), (true, Float(1.0), Float(0.0))] {
            rt.update(at: clock) { s, _ in s = on }
            var seen: [Float] = []
            for _ in 0..<120 {
                clock += 1.0 / 120.0
                _ = rt.frame(at: clock)
                seen.append(alpha())
            }
            #expect(abs(seen[0] - from) < 0.5, "first frame should not cut to \(to): \(seen[0])")
            for i in 1..<seen.count {
                #expect(abs(seen[i] - seen[i - 1]) < 0.2, "step \(i) fades smoothly: \(seen[i - 1]) -> \(seen[i])")
            }
            #expect(abs(seen[119] - to) < 1e-3, "settles at \(to): \(seen[119])")
        }
        #expect(!rt.isAnimating)
    }

    @Test("Newly mounted element with groupOpacity draws at rest on frame 0 and stays near 0")
    func initialMountWithGroupOpacityDrawsAtRestOnFrameZero() {
        let rt = Runtime<Bool>(
            state: false,
            viewport: Vec2(200, 100),
            pixelScale: 1.0
        ) { mountNew, _ in
            var r: El<Bool> = row().key("row").size(200, 40).hoverGroup()
                .child(el().key("act").size(10, 10).bg(Color.white).groupOpacity(1.0, 1.0))
            if mountNew {
                r = r.child(el().key("new").size(10, 10).bg(Color.white).groupOpacity(0.0, 1.0))
            }
            return col().size(200, 100).child(r)
        }

        _ = rt.frame(at: 0.0)
        let initialRf = rt.renderFrame(at: 0.0)
        #expect(initialRf.instances.allSatisfy { $0.fill.w > 0.99 })

        rt.update(at: 1.0 / 120.0) { s, _ in s = true }
        for f in 0..<30 {
            let t = Double(f + 1) / 120.0
            _ = rt.frame(at: t)
            let a = rt.elements().first(where: { $0.key == "new" })?.opacity ?? -1.0
            #expect(a >= 0.0 && a < (1.0 / 512.0), "frame \(f): newly mounted child resting at 0 draws \(a)")
        }
        #expect(!rt.isAnimating)
    }

    @Test("Dropping groupOpacity fades rest back to 1.0, removes Props.GROUP_REST, and snaps under Curve.instant")
    func droppingGroupOpacityFadesBackAndRemovesTrack() {
        let rt = Runtime<(grouped: Bool, instant: Bool)>(
            state: (true, false),
            viewport: Vec2(200, 100),
            pixelScale: 1.0
        ) { state, _ in
            var act: El<(grouped: Bool, instant: Bool)> = el().key("act").size(10, 10).bg(Color.white)
            if state.grouped {
                act = act.groupOpacity(0.0, 1.0)
            }
            if state.instant {
                act = act.opacityMotion(Curve.instant)
            }
            return col().size(200, 100)
                .child(row().key("row").size(200, 40).hoverGroup().child(act))
        }

        var clock = 0.0
        _ = rt.frame(at: clock)
        let actId = rt.flatNodes.first(where: { $0.key == "act" })!.nodeId
        #expect(rt.hasGroupRestTrack(actId))
        #expect((rt.elements().first(where: { $0.key == "act" })?.opacity ?? 1.0) < 0.01)

        rt.update(at: clock) { s, _ in s.grouped = false }
        clock += 1.0 / 120.0
        _ = rt.frame(at: clock)
        #expect(rt.flatNodes.first(where: { $0.nodeId == actId })?.el.groupOpacity == nil)
        #expect(rt.hasGroupRestTrack(actId))
        #expect(rt.isGroupFading(actId))

        for _ in 0..<120 {
            clock += 1.0 / 120.0
            _ = rt.frame(at: clock)
        }
        #expect(!rt.isAnimating)
        #expect(rt.flatNodes.first(where: { $0.nodeId == actId })?.el.groupOpacity == nil)
        #expect(!rt.hasGroupRestTrack(actId))
        #expect(!rt.isGroupFading(actId))
        #expect((rt.elements().first(where: { $0.key == "act" })?.opacity ?? 0.0) > 0.99)

        // With Anim(curve: .instant), dropping groupOpacity clears GROUP_REST & groupFadeIds in one frame.
        rt.update(at: clock) { s, _ in s = (true, true) }
        clock += 1.0 / 120.0
        _ = rt.frame(at: clock)
        #expect(rt.hasGroupRestTrack(actId))
        #expect((rt.elements().first(where: { $0.key == "act" })?.opacity ?? 1.0) < 0.01)

        rt.update(at: clock) { s, _ in s.grouped = false }
        clock += 1.0 / 120.0
        _ = rt.frame(at: clock)
        #expect(rt.flatNodes.first(where: { $0.nodeId == actId })?.el.groupOpacity == nil)
        #expect(!rt.hasGroupRestTrack(actId), "instant opacityMotion drops GROUP_REST immediately")
        #expect(!rt.isGroupFading(actId), "instant opacityMotion skips groupFadeIds")
        #expect((rt.elements().first(where: { $0.key == "act" })?.opacity ?? 0.0) > 0.99)
    }

    @Test("Dropping groupOpacity while hovered displays at full hovered opacity")
    func droppedGroupOpacityUnderHoverShowsAtFull() {
        let rt = Runtime<Bool>(
            state: true,
            viewport: Vec2(200, 100),
            pixelScale: 1.0
        ) { grouped, _ in
            var act: El<Bool> = el().key("act").size(20, 20).bg(Color.white)
                .opacityMotion(Curve.easeInOut(0.4))
            if grouped {
                act = act.groupOpacity(0.0, 1.0)
            }
            return row().key("row").size(200, 40).hoverGroup().child(act)
        }

        _ = rt.frame(at: 0.0)
        rt.pointerMove(to: Vec2(50, 20), at: 0.01)
        _ = rt.frame(at: 0.01)
        _ = rt.frame(at: 0.6)
        #expect((rt.elements().first(where: { $0.key == "act" })?.opacity ?? 0.0) > 0.99)

        rt.update(at: 0.61) { s, _ in s = false }
        _ = rt.frame(at: 0.62)
        let alphaWhileHovered = rt.elements().first(where: { $0.key == "act" })?.opacity ?? 0.0
        #expect(alphaWhileHovered > 0.99, "dropped groupOpacity fading to full under active hover shows full opacity: \(alphaWhileHovered)")
    }

    @Test("Shared hover group key illuminates sibling groupOpacity children")
    func sharedHoverKeyDrivesGroupOpacityAcrossSiblings() {
        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(160, 80),
            pixelScale: 1.0
        ) { _, _ in
            row().gap(10)
                .child(el().key("trigger").size(50, 40).hoverGroupShared("card"))
                .child(
                    el().key("target").size(50, 40).hoverGroupShared("card")
                        .child(el().key("revealed").size(20, 20).bg(Color.white).groupOpacity(0.0, 1.0))
                )
        }

        _ = rt.frame(at: 0.0)
        #expect((rt.elements().first(where: { $0.key == "revealed" })?.opacity ?? 1.0) < 0.01)

        rt.pointerMove(to: Vec2(20, 20), at: 0.05)
        _ = rt.frame(at: 0.05)
        _ = rt.frame(at: 1.0)
        #expect((rt.elements().first(where: { $0.key == "revealed" })?.opacity ?? 0.0) > 0.99)
    }

    @Test("Changing groupOpacity rest animates smoothly and snaps under tx.instant, opacityMotion(.instant), or reducedMotion")
    func restChangeAnimatesAndSnapsWhenInstantOrReduced() {
        let rt = Runtime<(rest: Float, instantMotion: Bool)>(
            state: (0.0, false),
            viewport: Vec2(200, 100),
            pixelScale: 1.0
        ) { state, _ in
            var act: El<(rest: Float, instantMotion: Bool)> = el().key("act")
                .size(10, 10)
                .bg(Color.white)
                .groupOpacity(state.rest, 1.0)
            if state.instantMotion {
                act = act.opacityMotion(Curve.instant)
            }
            return col().size(200, 100)
                .child(row().key("row").size(200, 40).hoverGroup().child(act))
        }

        var clock = 0.0
        _ = rt.frame(at: clock)
        #expect(abs((rt.elements().first(where: { $0.key == "act" })?.opacity ?? -1) - 0.0) < 1e-5)

        rt.update(at: clock) { s, _ in s.rest = 1.0 }
        var seen: [Float] = []
        for _ in 0..<120 {
            clock += 1.0 / 120.0
            _ = rt.frame(at: clock)
            seen.append(rt.elements().first(where: { $0.key == "act" })?.opacity ?? -1)
        }
        #expect(seen[0] < 0.5)
        for i in 1..<seen.count {
            #expect(seen[i] >= seen[i - 1] - 1e-4)
        }
        #expect(abs(seen[119] - 1.0) < 1e-3)
        #expect(!rt.isAnimating)

        rt.update(at: clock) { s, tx in
            tx.instant()
            s.rest = 0.0
        }
        clock += 1.0 / 120.0
        _ = rt.frame(at: clock)
        #expect(abs((rt.elements().first(where: { $0.key == "act" })?.opacity ?? -1) - 0.0) < 1e-5)
        #expect(!rt.isAnimating)

        rt.update(at: clock) { s, _ in
            s.instantMotion = true
            s.rest = 0.65
        }
        clock += 1.0 / 120.0
        _ = rt.frame(at: clock)
        #expect(abs((rt.elements().first(where: { $0.key == "act" })?.opacity ?? -1) - 0.65) < 1e-5)
        #expect(!rt.isAnimating)

        let rtReduced = Runtime<Float>(
            state: 1.0,
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            reducedMotion: true
        ) { rest, _ in
            col().size(200, 100)
                .child(row().key("row").size(200, 40).hoverGroup()
                    .child(el().key("act").size(10, 10).bg(Color.white).groupOpacity(rest, 1.0)))
        }
        _ = rtReduced.frame(at: 0.0)
        rtReduced.update(at: 1.0 / 120.0) { r, _ in r = 0.0 }
        _ = rtReduced.frame(at: 2.0 / 120.0)
        #expect(abs((rtReduced.elements().first(where: { $0.key == "act" })?.opacity ?? -1) - 0.0) < 1e-5)
        #expect(!rtReduced.isAnimating)
    }
}
