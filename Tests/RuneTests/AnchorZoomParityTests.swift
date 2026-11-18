import Testing
import Foundation
@testable import Rune
import RuneMotion

@Suite("Anchor Zoom & Anchor Zoom Motion Parity Tests")
struct AnchorZoomParityTests {
    private enum Mode: Equatable {
        case inherit
        case ownScale
        case unscaled
    }

    private struct S {
        var zoom: Float = 1.0
        var top: Float = 100.0
        var mode: Mode = .inherit
        var presses: Int = 0
    }

    private func makeAnchorView(_ s: S) -> El<S> {
        let page: El<S> = col()
            .key("page")
            .size(800, 600)
            .scale(s.zoom)
            .origin(0, 0)
            .child(
                el()
                    .key("target")
                    .absolute(x: 100, y: s.top)
                    .size(80, 20)
            )

        var pop: El<S> = col()
            .key("pop")
            .w(120)
            .h(60)
            .p(10)
            .child(
                el()
                    .key("btn")
                    .size(100, 30)
                    .onClick { state in state.presses += 1 }
                    .child(
                        text("Rename")
                            .key("label")
                            .font(TextStyle(size: 13.0, weight: 400.0))
                    )
            )
            .anchored("target", side: .bottom, align: .start, gap: 5.0)

        switch s.mode {
        case .inherit:
            break
        case .ownScale:
            pop = pop.scale(s.zoom).origin(0, 0)
        case .unscaled:
            pop = pop.anchoredUnscaled()
        }

        return col().size(800, 600).children([page, pop])
    }

    private func settledRuntime(_ s: S) -> Runtime<S> {
        let rt = Runtime<S>(state: s, viewport: Vec2(800, 600), pixelScale: 2.0, systemDark: true) { state, _ in
            makeAnchorView(state)
        }
        _ = rt.frame(at: 0.0)
        for step in 1...120 {
            _ = rt.frame(at: Double(step) / 120.0)
        }
        return rt
    }

    private func rect<T>(_ rt: Runtime<T>, _ key: String) -> [Float] {
        rt.element(byKey: key)!.rect
    }

    private func expectRect(_ got: [Float], _ expected: [Float], _ context: String = "") {
        #expect(got.count == 4, "rect count for \(context)")
        for i in 0..<4 {
            #expect(abs(got[i] - expected[i]) < 0.01, "\(context)[\(i)] expected \(expected[i]), got \(got[i])")
        }
    }

    @Test("anchor_zoom_tests: at_zoom_one_the_overlay_sits_below_its_anchor_at_its_own_size")
    func atZoomOneTheOverlaySitsBelowItsAnchorAtItsOwnSize() {
        let rt = settledRuntime(S(zoom: 1.0, top: 100.0))
        expectRect(rect(rt, "target"), [100, 100, 80, 20], "target")
        expectRect(rect(rt, "pop"), [100, 125, 120, 60], "pop")
        expectRect(rect(rt, "btn"), [110, 135, 100, 30], "btn")
    }

    @Test("anchor_zoom_tests: at_zoom_one_point_six_the_overlay_draws_at_the_zoom_beside_the_drawn_anchor")
    func atZoomOnePointSixTheOverlayDrawsAtTheZoomBesideTheDrawnAnchor() {
        let rt = settledRuntime(S(zoom: 1.6, top: 100.0))
        expectRect(rect(rt, "target"), [160, 160, 128, 32], "target")
        // The gap zooms too: 5 points at 1.6 is 8.
        expectRect(rect(rt, "pop"), [160, 200, 192, 96], "pop")
        expectRect(rect(rt, "btn"), [176, 216, 160, 48], "btn")
        let label = rt.element(byKey: "label")!
        #expect(abs(label.scale - 1.6) < 0.001, "expected label scale 1.6, got \(label.scale)")
        #expect(!label.moving, "expected settled scale motion")
    }

    @Test("anchor_zoom_tests: at_zoom_one_point_six_it_flips_by_its_zoomed_size")
    func atZoomOnePointSixItFlipsByItsZoomedSize() {
        // At 1.0 the 60 point overlay fits below an anchor ending at 320.
        let rt1 = settledRuntime(S(zoom: 1.0, top: 300.0))
        #expect(abs(rect(rt1, "pop")[1] - 325.0) < 0.01)

        // At 1.6 the anchor ends at 512 and the 96 point overlay would end at 616, past 600,
        // so it flips above: 480 - 8 - 96 = 376.
        let rt16 = settledRuntime(S(zoom: 1.6, top: 300.0))
        expectRect(rect(rt16, "target"), [160, 480, 128, 32], "target")
        expectRect(rect(rt16, "pop"), [160, 376, 192, 96], "pop")
    }

    @Test("anchor_zoom_tests: at_zoom_one_point_six_a_button_in_the_overlay_hits_where_it_draws")
    func atZoomOnePointSixAButtonInTheOverlayHitsWhereItDraws() {
        let rt = settledRuntime(S(zoom: 1.6, top: 100.0))
        // Inside the zoomed button (176..336, 216..264), outside where it would sit unzoomed.
        let t = 121.0 / 120.0
        rt.pointerDown(at: Vec2(320, 255), at: t)
        rt.pointerUp(at: Vec2(320, 255), at: t)
        _ = rt.frame(at: t)
        #expect(rt.state.presses == 1)
        #expect(rt.elementAt(320, 255)?.key == "btn")
    }

    @Test("anchor_zoom_tests: an_overlay_that_scales_itself_is_not_zoomed_twice")
    func anOverlayThatScalesItselfIsNotZoomedTwice() {
        let rt = settledRuntime(S(zoom: 1.6, top: 100.0, mode: .ownScale))
        let pop = rect(rt, "pop")
        #expect(abs(pop[2] - 192.0) < 0.01 && abs(pop[3] - 96.0) < 0.01, "got \(pop)")
    }

    @Test("anchor_zoom_tests: an_unscaled_overlay_stays_at_window_scale_beside_the_drawn_anchor")
    func anUnscaledOverlayStaysAtWindowScaleBesideTheDrawnAnchor() {
        let rt = settledRuntime(S(zoom: 1.6, top: 100.0, mode: .unscaled))
        expectRect(rect(rt, "pop"), [160, 197, 120, 60], "pop")
    }

    @Test("anchor_zoom_tests: at_zoom_one_point_six_a_fitted_list_fits_the_room_it_draws_in")
    func atZoomOnePointSixAFittedListFitsTheRoomItDrawsIn() {
        let rt = Runtime<Float>(state: 1.6, viewport: Vec2(800, 600), pixelScale: 2.0, systemDark: true) { zoom, _ in
            let rowEls: [El<Float>] = (0..<40).map { i in el().key("row\(i)").w(100).h(20) }
            let rows: El<Float> = col().key("rows").children(rowEls)
            let list: El<Float> = col().key("scroll").shrink(1).minH(0).scroll(stickBottom: false).child(rows)
            let page: El<Float> = col()
                .size(800, 600)
                .scale(zoom)
                .origin(0, 0)
                .child(el().key("target").absolute(x: 100, y: 100).size(80, 20))
            return col()
                .size(800, 600)
                .children([
                    page,
                    col().key("menu").w(100).child(list).anchoredFit("target", side: .bottom, align: .start, gap: 5.0)
                ])
        }
        _ = rt.frame(at: 0.0)
        for step in 1...120 {
            _ = rt.frame(at: Double(step) / 120.0)
        }
        // The anchor draws down to 192 and the gap is 8, so 600 - 8 - 200 = 392 points are left.
        let r = rect(rt, "menu")
        #expect(abs(r[1] - 200.0) < 0.01, "expected menu y=200, got \(r)")
        #expect(r[3] <= 392.01 && r[3] > 390.0, "drawn within the room below: \(r)")
    }

    // MARK: - MotionGate (`src/runtime/anchor_zoom_motion_tests.rs`)

    private struct MotionState {
        var zoom: Float
        var open: Bool
    }

    private func makeMotionView(_ s: MotionState) -> El<MotionState> {
        let page: El<MotionState> = col()
            .key("page")
            .size(300, 200)
            .scale(s.zoom)
            .origin(0, 0)
            .child(
                el()
                    .key("target")
                    .absolute(x: 100, y: 100)
                    .size(80, 20)
                    .bg(Color.white)
            )
        let root: El<MotionState> = col().size(800, 600).child(page)
        guard s.open else { return root }
        let pop: El<MotionState> = col()
            .key("pop")
            .w(120)
            .p(10)
            .bg(Color.white)
            .child(
                text("Rename")
                    .key("label")
                    .font(TextStyle(size: 13.0, weight: 400.0))
            )
            .transition(Transition.scale(0.95).combined(with: .opacity))
            .anchored("target", side: .bottom, align: .start, gap: 5.0)
        return root.child(pop)
    }

    private func runCell(start: MotionState, what: String, change: @escaping (inout MotionState) -> Void) -> MotionGateRecording {
        let rt = Runtime<MotionState>(state: start, viewport: Vec2(800, 600), pixelScale: 2.0, systemDark: true) { state, _ in
            makeMotionView(state)
        }
        let r = MotionGateRun(rt, hz: 120.0)
        r.idle(1.0)
        r.step()
        r.actUpdate(what) { state, _ in change(&state) }
        r.play(1.2)
        r.quiet()
        r.play(0.3)
        return r.rec
    }

    @Test("anchor_zoom_motion_tests: anchored_zoom_motion_gate")
    func anchoredZoomMotionGate() {
        let cells: [(String, MotionGateRecording)] = [
            ("anchored-zoom/zoom-while-open", runCell(start: MotionState(zoom: 1.0, open: true), what: "zoom to 1.6") { $0.zoom = 1.6 }),
            ("anchored-zoom/unzoom-while-open", runCell(start: MotionState(zoom: 1.6, open: true), what: "zoom to 1.0") { $0.zoom = 1.0 }),
            ("anchored-zoom/enter-zoomed", runCell(start: MotionState(zoom: 1.6, open: false), what: "open") { $0.open = true }),
            ("anchored-zoom/exit-zoomed", runCell(start: MotionState(zoom: 1.6, open: true), what: "close") { $0.open = false }),
        ]
        var failures: [String] = []
        for (name, rec) in cells {
            let findings = motionGateCheck(rec)
            if !findings.isEmpty {
                failures.append("\(name): \(findings)")
            }
        }
        #expect(failures.isEmpty, "MotionGate findings: \(failures.joined(separator: "\n"))")
    }

    @Test("anchor.rs: live scale binding sets hasScaleTrack and opts out of inherited anchor zoom")
    func liveScaleTrackOptsOutOfInheritedAnchorZoom() {
        let liveScale = Live<Float>(1.0)
        let rt = Runtime<Float>(state: 1.6, viewport: Vec2(800, 600), pixelScale: 2.0, systemDark: true) { zoom, _ in
            let page: El<Float> = col()
                .key("page")
                .size(800, 600)
                .scale(zoom)
                .origin(0, 0)
                .child(el().key("target").absolute(x: 100, y: 100).size(80, 20))
            let pop: El<Float> = col()
                .key("pop")
                .size(120, 60)
                .liveScale(liveScale.binding)
                .anchored("target", side: .bottom, align: .start, gap: 5.0)
            return col().size(800, 600).children([page, pop])
        }
        _ = rt.frame(at: 0.0)
        for step in 1...10 {
            _ = rt.frame(at: Double(step) / 60.0)
        }
        expectRect(rect(rt, "target"), [160, 160, 128, 32], "target")
        // Overlay has a live scale binding (`hasScaleTrack == true`), so it must not inherit 1.6x zoom.
        expectRect(rect(rt, "pop"), [160, 197, 120, 60], "pop")
    }

    @Test("anchor.rs: anchor own scale is excluded from ancestors-only inherited zoom")
    func anchorOwnScaleExcludedFromAncestorsOnlyZoom() {
        let rt = Runtime<Void>(state: (), viewport: Vec2(800, 600), pixelScale: 2.0, systemDark: true) { _, _ in
            let page: El<Void> = col()
                .key("page")
                .size(800, 600)
                .child(
                    el()
                        .key("target")
                        .absolute(x: 100, y: 100)
                        .size(80, 20)
                        .scale(2.0)
                        .origin(0, 0)
                )
            let pop: El<Void> = col()
                .key("pop")
                .size(120, 60)
                .anchored("target", side: .bottom, align: .start, gap: 5.0)
            return col().size(800, 600).children([page, pop])
        }
        _ = rt.frame(at: 0.0)
        for step in 1...10 {
            _ = rt.frame(at: Double(step) / 60.0)
        }
        expectRect(rect(rt, "target"), [100, 100, 160, 40], "target")
        // Anchor node has own scale 2.0, but its parent ("page") is unscaled -> overlay stays 1.0x.
        expectRect(rect(rt, "pop"), [100, 145, 120, 60], "pop")
    }

    @Test("Scale snapshots preserve missing nodes and paint order when exits share a path")
    func scaleSnapshotIdentities() {
        let old = NodeId(1), current = NodeId(2)
        let unit = Vec2(1, 1), zoom = Vec2(1.5, 2)
        var indexed = PresentedScales(count: 2, byPath: ["old": 0, "current": 1],
                                      byId: [old: 0, current: 1], hasExits: false)
        indexed.record(at: 0, path: "old", id: old, scale: unit, motion: .still)
        #expect(indexed["old"] == unit)
        #expect(indexed.motion(for: old) == .still)
        #expect(indexed["current"] == nil)
        #expect(indexed.motion(for: current) == nil)
        let previous = indexed
        indexed.record(at: 1, path: "current", id: current, scale: zoom, motion: .live)
        #expect(previous.motion(for: current) == nil)
        #expect(indexed["current"] == zoom)

        var exiting = PresentedScales(count: 1, byPath: ["same": 0], byId: [current: 0], hasExits: true)
        exiting.record(at: 0, path: "same", id: current, scale: unit, motion: .still)
        exiting.record(at: 0, path: "same", id: old, scale: zoom, motion: .moving)
        #expect(exiting["same"] == zoom)
        #expect(exiting.motion(for: current) == .still)
        #expect(exiting.motion(for: old) == .moving)
    }

    @Test("anchor.rs & build.rs: anchored overlay inherits anchor scaleMotion while moving and settles crisp at zoom", arguments: [false, true])
    func anchoredOverlayInheritsScaleMotionAndSettlesCrisp(native: Bool) {
        let rt = Runtime<MotionState>(
            state: MotionState(zoom: 1.0, open: true),
            viewport: Vec2(800, 600),
            pixelScale: 2.0,
            systemDark: true
        ) { state, _ in
            makeMotionView(state)
        }
        func paint(_ now: Double) {
            if native { _ = rt.renderFrame(at: now) }
            else { _ = rt.frame(at: now) }
        }
        paint(0.0)
        for step in 1...10 {
            paint(Double(step) / 60.0)
        }
        let popId = rt.flatNodes.first(where: { $0.key == "pop" })!.nodeId
        #expect(rt.presentedScales.motion(for: popId) == .still)
        #expect(abs((rt.elSliceRenderState.scaleSettles[popId]?.stillScale ?? 0) - 1.0) < 0.01)

        // Start spring zoom from 1.0 -> 1.6 on anchor's parent ("page")
        rt.update(at: 0.2) { state, _ in state.zoom = 1.6 }
        paint(0.25)
        #expect(rt.presentedScales.motion(for: popId) == .moving)
        #expect(abs((rt.elSliceRenderState.scaleSettles[popId]?.stillScale ?? 0) - 1.0) < 0.01)

        // Advance until scale spring finishes and settles
        var t = 0.25
        for _ in 0..<180 {
            t += 1.0 / 60.0
            paint(t)
        }
        #expect(rt.presentedScales.motion(for: popId) == .still)
        #expect(abs((rt.elSliceRenderState.scaleSettles[popId]?.stillScale ?? 0) - 1.6) < 0.02)
    }
}
