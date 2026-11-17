import Foundation
import Testing
@testable import Rune
import RuneMotion
import RuneRef

@Suite("PixelSnap Parity (pixel_snap.rs & pixel_snap_tests.rs)")
struct PixelSnapParityTests {
    private func snap(_ r: SIMD4<Float>, _ motion: SIMD4<Float> = .zero, _ rigid: SIMD2<Float> = .zero) -> SIMD4<Float> {
        PixelSnap.snap(r, motion: motion, rigid: rigid, parent: nil) { _, c in c }.0
    }

    private func fills(_ scene: RefScene) -> [SIMD4<Float>] {
        scene.primitives.compactMap { p in
            p.params.y == Float(PrimitiveKind.roundedRect.rawValue) && p.fill.w > 0 ? p.rect : nil
        }
    }

    private func edges(_ rects: [SIMD4<Float>]) -> [Float] {
        rects.flatMap { [$0.x, $0.y, $0.x + $0.z, $0.y + $0.w] }
    }

    private func whole(_ v: Float) -> Bool {
        v.truncatingRemainder(dividingBy: 1.0) == 0.0
    }

    private func coverage<State>(
        state: State,
        width: Int,
        height: Int,
        scale: Float = 2.0,
        view: @escaping Runtime<State>.ViewFn
    ) throws -> [UInt8] {
        let rt = Runtime(
            state: state,
            viewport: Vec2(Float(width), Float(height)),
            pixelScale: scale,
            view: view
        )
        var scene = rt.frame(at: 0.0)
        scene.clearColor = .zero
        let frame = try RuneRef.render(scene)
        var alpha: [UInt8] = []
        alpha.reserveCapacity(frame.width * frame.height)
        for i in stride(from: 3, to: frame.rgba.count, by: 4) {
            alpha.append(frame.rgba[i])
        }
        return alpha
    }

    @Test("shared_edges_round_alike")
    func sharedEdgesRoundAlike() {
        let a = snap(SIMD4<Float>(0, 10.3, 50, 30.5))
        let b = snap(SIMD4<Float>(0, 30.5, 50, 52.7))
        #expect(a[3] == b[1])
        #expect(a == SIMD4<Float>(0, 10, 50, 31))
    }

    @Test("keeps_a_pixel_and_thin_rects")
    func keepsAPixelAndThinRects() {
        let s = snap(SIMD4<Float>(0, 4.6, 9, 5.4))
        #expect(s[1] == 5.0 && s[3] == 6.0)
        let thin = snap(SIMD4<Float>(0, 4.6, 9, 4.9))
        #expect(thin[1] == 4.6 && thin[3] == 4.9)
    }

    @Test("motion_carries_the_resting_correction")
    func motionCarriesTheRestingCorrection() {
        let moving = snap(SIMD4<Float>(0, 15.55, 9, 25.55), SIMD4<Float>(0, 5.25, 0, 5.25))
        #expect(abs(moving[1] - 15.25) < 1e-4 && abs(moving[3] - 25.25) < 1e-4)
    }

    @Test("rigid_translation_snaps_as_one")
    func rigidTranslationSnapsAsOne() {
        for k in 0..<64 {
            let d = -Float(k) * 0.37
            let a = snap(SIMD4<Float>(0, 10.0 + d, 9, 20.0 + d), .zero, SIMD2<Float>(0, d))
            let b = snap(SIMD4<Float>(0, 22.2 + d, 9, 32.2 + d), .zero, SIMD2<Float>(0, d))
            #expect(b[1] - a[3] == 2.0)
            #expect(whole(a[1]))
        }
    }

    @Test("line_width Chromium snapping preserves sub-1px at 1px and floors above")
    func lineWidthSnapping() {
        #expect(PixelSnap.lineWidth(0) == 0)
        #expect(PixelSnap.lineWidth(0.5 * 1.25) == 1.0)
        #expect(PixelSnap.lineWidth(1.0 * 1.25) == 1.0)
        #expect(PixelSnap.lineWidth(1.0 * 1.5) == 1.0)
        #expect(PixelSnap.lineWidth(1.0 * 2.0) == 2.0)
        #expect(PixelSnap.lineWidth(2.99) == 3.0)
        #expect(PixelSnap.lineWidth(-1.5) == -1.0)
    }

    @Test("a_scaled_layer_eases_to_the_grid_from_its_last_move")
    func scaledLayerEasesToGrid() {
        let id = NodeId(1)
        let frameDt = 1.0 / 60.0
        var g = PixelSnap.Glides()
        func paint(_ t: Double, _ r: SIMD4<Float>) -> (PixelSnap.LayerPhase, Float) {
            g.beginFrame(t: t, size: SIMD2<Float>(800, 600))
            _ = g.layer(id: id, r: r, unscaled: r, rigid: .zero, cached: false)
            return (g.layers[id]!.phase, g.now[0].to)
        }
        let a = SIMD4<Float>(10.3, 10.3, 50.3, 50.3)
        let b = SIMD4<Float>(12.6, 10.3, 52.6, 50.3)
        let p0 = paint(0.0, a)
        #expect(p0.0 == .rest(since: -.infinity) && p0.1 == 1.0)
        let p1 = paint(frameDt, b)
        #expect(p1.0 == .moving(last: frameDt) && p1.1 == 0.0)
        #expect(g.layers[id]!.out0.rect == a && g.layers[id]!.out0.weight == 1.0)
        let p2 = paint(2.0 * frameDt, b)
        #expect(p2.0 == .rest(since: frameDt))
        #expect(p2.1 > 0.0 && p2.1 < 1.0)
        let p3 = paint(frameDt + 2.0 * PixelSnap.settleDuration, b)
        #expect(p3.1 == 1.0)
        #expect(g.layers[id]!.out0.weight == 0.0)
    }

    private func gapColumnView(_ on: Bool, _: inout Cx<Bool>) -> El<Bool> {
        let rows = (0..<6).map { _ in El<Bool>().size(20, 7.3).bg(.white) }
        return El<Bool>(direction: .column).gap(1.1).p(0.3).pixelSnap(on).children(rows)
    }

    @Test("rows_with_a_fractional_gap_have_hard_edges")
    func rowsWithFractionalGapHaveHardEdges() throws {
        for on in [true, false] {
            let a = try coverage(state: on, width: 24, height: 52, scale: 2.0, view: gapColumnView)
            let column = (0..<104).map { y in a[y * 48 + 10] }
            let soft = column.filter { $0 > 1 && $0 < 254 }.count
            if on {
                #expect(soft == 0)
                let starts = (1..<column.count).filter { column[$0 - 1] < 128 && column[$0] >= 128 }.count
                    + (column[0] >= 128 ? 1 : 0)
                #expect(starts == 6)
            } else {
                #expect(soft > 0)
            }
        }
    }

    @Test("layout_and_drawn_rects_stay_fractional")
    func layoutAndDrawnRectsStayFractional() {
        let rt = Runtime(state: true, viewport: Vec2(24, 52), pixelScale: 2.0, view: gapColumnView)
        let scene = rt.frame(at: 0.0)
        let rows = rt.elements().filter { abs($0.rect[3] - 7.3) < 0.02 }
        #expect(rows.count == 6)
        for (k, e) in rows.enumerated() {
            let y = 0.3 + Float(k) * 8.4
            #expect(abs(e.rect[1] - y) < 1.0 / 64.0)
        }
        for r in fills(scene) {
            #expect(whole(r.x) && whole(r.y) && whole(r.z) && whole(r.w))
        }
    }

    @Test("adjacent_boxes_meet_without_a_seam")
    func adjacentBoxesMeetWithoutASeam() throws {
        let a = try coverage(state: (), width: 40, height: 12, scale: 2.0) { _, _ in
            El<()>(direction: .row).p(0.35).children((0..<5).map { _ in El<()>().size(7.15, 10).bg(.white) })
        }
        let line = Array(a[(12 * 80)..<(13 * 80)])
        let lit = (0..<80).filter { line[$0] > 0 }
        #expect(!lit.isEmpty)
        let first = lit.first!, last = lit.last!
        #expect(line[first...last].allSatisfy { $0 == 255 })
        #expect(line.allSatisfy { $0 == 0 || $0 == 255 })
    }

    @Test("hairline_border_is_one_crisp_pixel")
    func hairlineBorderIsOneCrispPixel() throws {
        let a = try coverage(state: (), width: 32, height: 32, scale: 2.0) { _, _ in
            El<()>().size(32, 32).child(
                El<()>().absolute(x: 3.3, y: 4.15).size(20.3, 12.45).border(0.5, .white)
            )
        }
        let column = (0..<64).map { y in a[y * 64 + 20] }
        #expect(column.allSatisfy { $0 <= 1 || $0 >= 254 })
        #expect(column.filter { $0 >= 254 }.count == 2)
    }

    @Test("an_opted_out_element_paints_its_exact_offset")
    func optedOutElementPaintsExactOffset() {
        for on in [true, false] {
            let rt = Runtime(state: on, viewport: Vec2(40, 40), pixelScale: 2.0) { on, _ in
                El<Bool>().size(40, 40).child(
                    El<Bool>().size(10, 10).offset(3.3, 2.15).pixelSnap(on).bg(.white)
                )
            }
            let r = fills(rt.frame(at: 0.0))[0]
            if on {
                #expect(r.x == 7.0 && r.y == 4.0)
            } else {
                #expect(abs(r.x - 6.6) < 1.0 / 32.0 && abs(r.y - 4.3) < 1.0 / 32.0)
            }
        }
    }

    @Test("a_moving_element_glides_and_lands_snapped")
    func movingElementGlidesAndLandsSnapped() {
        let rt = Runtime(state: false, viewport: Vec2(40, 40), pixelScale: 2.0) { down, _ in
            let y: Float = down ? 10.3 : 0.0
            return El<Bool>().size(40, 40).child(
                El<Bool>().size(10, 10).absolute(x: 1.15, y: 1.15).offset(0, y)
                    .animate(Spring(duration: 0.4, bounce: 0)).bg(.white)
            )
        }
        let f0 = rt.frame(at: 0.0)
        #expect(fills(f0)[0].y == 2.0)

        rt.update(at: 0.0) { state, _ in state = true }
        var ys: [Float] = []
        var t = 0.0
        for _ in 0..<120 {
            t += 1.0 / 120.0
            let sc = rt.frame(at: t)
            ys.append(fills(sc)[0].y)
        }
        #expect(ys.last == 23.0)
        #expect(ys[0] - 2.0 < 0.25)
        #expect(ys.contains { !whole($0) })
        let steps = zip(ys, ys.dropFirst()).map { $1 - $0 }
        let peak = steps.max() ?? 0
        let after = steps.firstIndex(of: peak) ?? 0
        for i in (after + 1)..<steps.count {
            #expect(steps[i] <= steps[i - 1] + 1.0 / 32.0 && steps[i] >= -1.0 / 32.0)
        }
    }

    @Test("text_keeps_its_place_against_its_fill")
    func textKeepsItsPlaceAgainstItsFill() {
        func place(y: Float) -> (Float, Float) {
            let rt = Runtime(state: y, viewport: Vec2(80, 40), pixelScale: 2.0) { y, _ in
                let label: El<Float> = text("Hg")
                return El<Float>().size(80, 40).child(
                    label.p(2.3).absolute(x: 4.0, y: y)
                        .bg(Color.white.mix(with: .black, t: 0.8))
                )
            }
            let sc = rt.frame(at: 0.0)
            let fill = fills(sc)[0]
            let glyphTop = sc.primitives
                .filter { $0.params.y == Float(PrimitiveKind.glyph.rawValue) }
                .map { $0.rect.y }
                .min() ?? .greatestFiniteMagnitude
            #expect(glyphTop < .greatestFiniteMagnitude, "draws glyphs")
            return (glyphTop, fill.y)
        }
        // The fill snaps to whole pixels. The text lays out from its box's exact place and rounds
        // once, as Blink paints a text fragment (#935), so it keeps its place against where its box
        // is rather than its snapped fill: half a point (a device pixel) further down, it draws one
        // pixel lower, at every phase; and between, it steps at most a pixel, never back.
        for k in 0..<10 {
            let y = 10.0 + Float(k) * 0.05
            let (glyph, top) = place(y: y)
            let (next, _) = place(y: y + 0.05)
            let (lower, _) = place(y: y + 0.5)
            #expect(whole(top), "\(top)")
            #expect(lower == glyph + 1.0, "y \(y): a device pixel lower draws a pixel lower")
            #expect(next == glyph || next == glyph + 1.0, "y \(y): \(glyph) then \(next)")
        }
    }

    @Test("Two text lines follow a gliding growth row in whole pixels (#1072)",
          arguments: [Float(1), 1.875], [false, true])
    func glidingGrowthRowKeepsBothLinesOnItsBox(scale: Float, native: Bool) throws {
        let rt = Runtime(state: true, viewport: Vec2(220, 240), pixelScale: scale) { open, _ in
            let line: El<Bool> = text("H").font(TextStyle(size: 13, weight: 400)).h(17.5).pt(3.3).color(.white)
            return col().size(220, 240).child(
                col().key("stack").wFull().growth(GrowthSpec())
                    .child(el().key("fold").wFull().h(open ? 72 : 24).foldGlide(Spring(duration: 0.3)))
                    .child(col().key("row").wFull().h(62).bg(.black).children([line, line]))
            )
        }

        func sample(at t: Double) throws -> (box: Float, offsets: SIMD2<Float>) {
            let box: Float?
            let glyphs: [Float]
            if native {
                let instances = rt.renderFrame(at: t).instances
                box = instances.first { $0.params.y == KIND_RECT && $0.fill.w > 0.99 }?.rect.y
                glyphs = instances.filter { $0.params.y == KIND_GLYPH }.map { $0.rect.y }
            } else {
                let primitives = rt.frame(at: t).primitives
                box = primitives.first { $0.kind == .roundedRect && $0.fill.w > 0.99 }?.rect.y
                glyphs = primitives.filter { $0.kind == .glyph }.map { $0.rect.y }
            }
            let top = try #require(box)
            try #require(glyphs.count == 2)
            return (top, SIMD2(glyphs[0] - top, glyphs[1] - top))
        }

        let initial = try sample(at: 0)
        rt.update(at: 0) { open, _ in open = false }
        var fractionalPositions = 0
        var worstOffsetDrift: Float = 0
        var worstSpacingDrift: Float = 0
        var worstPixelError: Float = 0
        let initialSpacing = initial.offsets.y - initial.offsets.x
        for frame in 1...85 {
            let drawn = try sample(at: Double(frame) / 120)
            let row = try #require(rt.element(byKey: "row"))
            let y = row.rect[1] * scale
            if abs(y - y.rounded()) > 0.1 { fractionalPositions += 1 }
            worstPixelError = max(worstPixelError, abs(drawn.box - drawn.box.rounded()))
            worstOffsetDrift = max(worstOffsetDrift, abs(drawn.offsets.x - initial.offsets.x),
                                   abs(drawn.offsets.y - initial.offsets.y))
            worstSpacingDrift = max(worstSpacingDrift, abs(drawn.offsets.y - drawn.offsets.x - initialSpacing))
        }
        #expect(fractionalPositions > 8)
        #expect(worstPixelError < 0.001)
        #expect(worstOffsetDrift < 0.001)
        #expect(worstSpacingDrift < 0.001)
        let settled = try sample(at: 1)
        #expect(initial.box - settled.box == 48 * scale)
        #expect(settled.offsets == initial.offsets)
    }

    @Test("scrolled_rows_stay_crisp_and_keep_their_spacing")
    func scrolledRowsStayCrispAndKeepSpacing() {
        let rt = Runtime(state: (), viewport: Vec2(40, 60), pixelScale: 2.0) { _, _ in
            El<()>(direction: .column).size(40, 60).gap(1.1).scroll()
                .children((0..<20).map { i in El<()>().key("r\(i)").size(20, 7.3).bg(.white) })
        }
        let s0 = rt.frame(at: 0.0)
        func pitch(_ s: RefScene) -> [Float] {
            let fs = fills(s)
            return zip(fs, fs.dropFirst()).map { $1.y - $0.y }
        }
        let want = pitch(s0)
        var fractional = false
        var t = 0.0
        for _ in 0..<12 {
            t += 1.0 / 120.0
            rt.wheel(WheelEvent(dy: -0.37, precise: true), at: Vec2(20, 30), now: t)
            let sc = rt.frame(at: t)
            let r0 = rt.element(byKey: "r0")!.rect
            fractional = fractional || !whole(r0[1] * 2.0)
            let fs = fills(sc)
            #expect(fs.allSatisfy { whole($0.x) && whole($0.y) && whole($0.z) && whole($0.w) })
            #expect(pitch(sc) == want)
        }
        #expect(fractional)
    }

    @Test("a_scale_settling_at_one_lands_snapped_without_a_jump")
    func scaleSettlingAtOneLandsSnapped() {
        let rt = Runtime(state: false, viewport: Vec2(60, 60), pixelScale: 2.0) { big, _ in
            let k: Float = big ? 1.0 : 0.8
            return El<Bool>().size(60, 60).child(
                El<Bool>().size(20.3, 20.3).absolute(x: 10.15, y: 10.15)
                    .scale(k).animate(Spring(duration: 0.4, bounce: 0)).bg(.white)
            )
        }
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.0) { state, _ in state = true }
        var frames: [SIMD4<Float>] = []
        var t = 0.0
        for _ in 0..<120 {
            t += 1.0 / 120.0
            frames.append(fills(rt.frame(at: t))[0])
        }
        let end = frames.last!
        #expect(whole(end.x) && whole(end.y) && whole(end.z) && whole(end.w))
        for k in 0..<2 {
            let steps = zip(frames, frames.dropFirst()).map { abs($1[k] - $0[k]) }
            let tail = Array(steps[(steps.count / 3)...])
            for i in 1..<tail.count {
                #expect(tail[i] <= tail[i - 1] + 1.0 / 32.0)
            }
        }
    }

    @Test("a_trailing_child_holds_its_place_against_a_widening_parent")
    func trailingChildHoldsPlaceAgainstWideningParent() {
        let rt = Runtime(state: false, viewport: Vec2(80, 20), pixelScale: 2.0) { wide, _ in
            let w: Float = wide ? 50.7 : 30.3
            return El<Bool>().size(80, 20).child(
                El<Bool>().size(w, 12).absolute(x: 3.15, y: 2.0)
                    .animateLayout(Spring(duration: 0.4, bounce: 0))
                    .bg(Color.white.mix(with: .black, t: 0.5))
                    .child(
                        El<Bool>().size(6, 6).absolute(x: w - 9.15, y: 3.0)
                            .rideTrailing().bg(.white)
                    )
            )
        }
        let s0 = rt.frame(at: 0.0)
        func gap(_ f: [SIMD4<Float>]) -> Float { (f[0].x + f[0].z) - (f[1].x + f[1].z) }
        var last = gap(fills(s0))
        rt.update(at: 0.0) { state, _ in state = true }
        var moved = false
        var t = 0.0
        for _ in 0..<120 {
            t += 1.0 / 120.0
            let f = fills(rt.frame(at: t))
            moved = moved || (f[0].z != 61.0 && f[0].z != 101.0)
            let cur = gap(f)
            #expect(abs(cur - last) < 0.25)
            last = cur
        }
        #expect(moved)
        let fEnd = fills(rt.frame(at: t))
        #expect(fEnd.allSatisfy { whole($0.x) && whole($0.y) && whole($0.z) && whole($0.w) })
    }

    private func canvasView(_ st: (Float, Bool), _: inout Cx<(Float, Bool)>) -> El<(Float, Bool)> {
        let boxes = (0..<4).map { i in
            El<(Float, Bool)>().size(17.3, 11.1)
                .absolute(x: 3.3 + Float(i) * 21.7, y: 5.45 + Float(i) * 9.2)
                .bg(.white)
        }
        return El<(Float, Bool)>().size(160, 120).child(
            El<(Float, Bool)>().size(100.3, 70.15).absolute(x: 20.15, y: 15.3)
                .scale(st.0).pixelSnap(st.1)
                .bg(Color.white.mix(with: .black, t: 0.5)).children(boxes)
        )
    }

    @Test("a_still_zoomed_canvas_draws_on_whole_pixels")
    func stillZoomedCanvasDrawsOnWholePixels() {
        for on in [true, false] {
            let rt = Runtime(state: (1.37, on), viewport: Vec2(160, 120), pixelScale: 2.0, view: canvasView)
            let e = edges(fills(rt.frame(at: 0.0)))
            #expect(e.count == 20)
            if on {
                #expect(e.allSatisfy { whole($0) })
            } else {
                #expect(e.contains { !whole($0) })
            }
        }
    }

    @Test("a_zoom_draws_exact_while_it_moves_and_eases_onto_the_grid")
    func zoomDrawsExactWhileMovingAndEasesOntoGrid() {
        let snapped = Runtime(state: (Float(1.2), true), viewport: Vec2(160, 120), pixelScale: 2.0, view: canvasView)
        let exact = Runtime(state: (Float(1.2), false), viewport: Vec2(160, 120), pixelScale: 2.0, view: canvasView)
        _ = snapped.frame(at: 0.0)
        _ = exact.frame(at: 0.0)

        var frames: [(edges: [Float], asks: Bool)] = []
        var t = 0.0
        for k in 1...80 {
            if k <= 30 {
                let z: Float = 1.2 + 0.17 * Float(k) / 30.0
                for rt in [snapped, exact] {
                    rt.update(at: t) { st, tx in
                        st.0 = z
                        tx.instant()
                    }
                }
            }
            t += 1.0 / 120.0
            _ = snapped.frame(at: t)
            let asks = snapped.isAnimating
            let exScene = exact.frame(at: t)
            let snScene = snapped.frame(at: t)
            let a = edges(fills(snScene))
            let b = edges(fills(exScene))
            if (8...30).contains(k) {
                #expect(zip(a, b).allSatisfy { abs($0 - $1) < 1.0 / 64.0 })
            }
            #expect(zip(a, b).allSatisfy { abs($0 - $1) <= 0.5 + 1.0 / 64.0 })
            frames.append((a, asks))
        }
        let end = frames.last!
        #expect(end.edges.allSatisfy { whole($0) })
        #expect(!end.asks)
        let landed = frames.firstIndex { $0.edges.allSatisfy(whole) }!
        #expect(landed <= 30 + 16)
        for i in 30..<landed {
            #expect(frames[i].asks)
        }
        for i in 30..<frames.count {
            let step = zip(frames[i - 1].edges, frames[i].edges).map { abs($0 - $1) }.max() ?? 0
            #expect(step < 0.07)
        }
    }

    @Test("a_scale_spring_glides_exact_and_lands_snapped")
    func scaleSpringGlidesExactAndLandsSnapped() {
        let rt = Runtime(state: false, viewport: Vec2(160, 120), pixelScale: 2.0) { big, _ in
            let k: Float = big ? 1.37 : 1.0
            return El<Bool>().size(160, 120).child(
                El<Bool>().size(60.3, 40.15).absolute(x: 40.15, y: 35.3)
                    .scale(k).animate(Spring(duration: 0.4, bounce: 0)).bg(.white)
                    .child(El<Bool>().size(17.3, 11.1).absolute(x: 13.3, y: 9.45).bg(.black))
            )
        }
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.0) { state, _ in state = true }
        var frames: [[Float]] = []
        var t = 0.0
        for _ in 0..<160 {
            t += 1.0 / 120.0
            frames.append(edges(fills(rt.frame(at: t))))
        }
        let end = frames.last!
        #expect(end.allSatisfy { whole($0) })
        let fractional = frames.filter { $0.contains { !whole($0) } }.count
        #expect(fractional > 20)
        for k in 0..<end.count {
            let steps = zip(frames, frames.dropFirst()).map { abs($1[k] - $0[k]) }
            let start = steps.count / 3
            for i in (start + 1)..<steps.count {
                #expect(steps[i] <= steps[i - 1] + 0.07)
            }
        }
    }

    @Test("outlines_on_a_layer_anchored_elsewhere_stay_on_the_art")
    func outlinesOnLayerAnchoredElsewhereStayOnArt() {
        struct Anchored {
            var zoom: Float
            var origin: Vec2
        }
        let spots: [(Float, Float)] = [(41.3, 29.45), (45.85, 31.2), (3.3, 5.45), (70.1, 48.35), (12.6, 50.9), (0.0, 0.0)]
        func view(_ st: Anchored, _: inout Cx<Anchored>) -> El<Anchored> {
            func boxes(dx: Float, dy: Float) -> [El<Anchored>] {
                spots.map { (x, y) in El<Anchored>().size(17.3, 11.1).absolute(x: x + dx, y: y + dy).bg(.white) }
            }
            let cx: Float = 20.15, cy: Float = 15.3, cw: Float = 100.3, ch: Float = 70.15
            var layer = El<Anchored>().size(cw, ch).absolute(x: cx, y: cy).scale(st.zoom).pixelSnap(true).children(boxes(dx: 0, dy: 0))
            layer.runtimeExtras["scaleOrigin"] = st.origin
            let pivotX = cx + cw * st.origin.x
            let pivotY = cy + ch * st.origin.y
            let offX = (pivotX - 80.0) * (1.0 - st.zoom)
            let offY = (pivotY - 60.0) * (1.0 - st.zoom)
            let overlay = El<Anchored>().size(160, 120).absolute(x: 0, y: 0)
                .scale(st.zoom).offset(offX, offY).pixelSnap(true).children(boxes(dx: cx, dy: cy))
            return El<Anchored>().size(160, 120).child(layer).child(overlay)
        }
        for origin in [Vec2(0.5, 0.5), Vec2(0, 0), Vec2(0.41, 0.62), Vec2(3.0, -2.0)] {
            let rt = Runtime(state: Anchored(zoom: 1.2, origin: origin), viewport: Vec2(160, 120), pixelScale: 2.0, view: view)
            _ = rt.frame(at: 0.0)
            var t = 0.0
            for k in 1...80 {
                if k <= 30 {
                    let z: Float = 1.2 + 0.17 * Float(k) / 30.0
                    rt.update(at: t) { st, tx in
                        st.zoom = z
                        tx.instant()
                    }
                }
                t += 1.0 / 120.0
                let e = edges(fills(rt.frame(at: t)))
                let half = e.count / 2
                let art = Array(e[0..<half])
                let outline = Array(e[half...])
                let worst = zip(art, outline).map { abs($0 - $1) }.max() ?? 0
                #expect(worst <= 1.0 / 32.0)
                if k == 80 {
                    #expect(e.allSatisfy { whole($0) })
                }
            }
        }
    }

    private func knobView(_ st: (Float, Float), _: inout Cx<(Float, Float)>) -> El<(Float, Float)> {
        let knob = El<(Float, Float)>().size(26, 16).absolute(x: 2, y: 2)
            .offset(0, st.1).animate(Spring(duration: 0.4, bounce: 0)).bg(.white)
        return El<(Float, Float)>().size(80, 60).child(
            El<(Float, Float)>().size(44, 20).absolute(x: 3, y: st.0).bg(.black).child(knob)
        )
    }

    private func knobGaps(_ f: [SIMD4<Float>]) -> (Float, Float) {
        let track = f[0], knob = f[1]
        return (knob.y - track.y, (track.y + track.w) - (knob.y + knob.w))
    }

    @Test("a_centred_knob_keeps_even_gaps_at_fractional_scales")
    func centredKnobKeepsEvenGapsAtFractionalScales() {
        for scale: Float in [1.25, 1.5, 1.75, 2.0] {
            var heights: Set<Int> = []
            for k in 0..<64 {
                let y = 10.0 + Float(k) / 16.0
                let rt = Runtime(state: (y, 0.0), viewport: Vec2(80, 60), pixelScale: scale, view: knobView)
                let f = fills(rt.frame(at: 0.0))
                let (above, below) = knobGaps(f)
                #expect(above == below)
                #expect(f.allSatisfy { whole($0.x) && whole($0.y) && whole($0.z) && whole($0.w) })
                heights.insert(Int(f[1].w))
            }
            #expect(heights.count == 1)
        }
    }

    @Test("a_centred_knob_draws_even_gaps_in_device_pixels_at_1_25x")
    func centredKnobDrawsEvenGapsInDevicePixelsAt1_25x() throws {
        let rt = Runtime(state: (Float(11.25), Float(0)), viewport: Vec2(80, 60), pixelScale: 1.25, view: knobView)
        var scene = rt.frame(at: 0.0)
        scene.clearColor = .zero
        let frame = try RuneRef.render(scene)
        let column = (0..<75).map { y in frame.pixel(x: 22, y: y) }
        let trackRows = (0..<75).filter { column[$0].w == 255 }
        let knobRows = (0..<75).filter { column[$0].x == 255 }
        #expect(column.allSatisfy { $0.w == 0 || $0.w == 255 })
        let above = knobRows.first! - trackRows.first!
        let below = trackRows.last! - knobRows.last!
        #expect(trackRows.count == 25 && above == 3 && below == 3)
    }

    @Test("an_unpainted_parent_leaves_a_centred_child_its_size")
    func unpaintedParentLeavesCentredChildItsSize() {
        for k in 0..<16 {
            let y = 10.0 + Float(k) / 16.0
            let rt = Runtime(state: y, viewport: Vec2(80, 60), pixelScale: 1.25) { y, _ in
                El<Float>().size(80, 60).child(
                    El<Float>().size(44, 22).absolute(x: 3, y: y).child(
                        El<Float>().size(44, 20).absolute(x: 0, y: 1).bg(.white)
                    )
                )
            }
            let f = fills(rt.frame(at: 0.0))
            #expect(f[0].w == 25.0)
        }
    }

    @Test("a_knob_glides_into_and_out_of_its_centred_rest")
    func knobGlidesIntoAndOutOfCentredRest() {
        let rt = Runtime(state: (Float(11.25), Float(0)), viewport: Vec2(80, 60), pixelScale: 1.25, view: knobView)
        _ = rt.frame(at: 0.0)
        var t = 0.0
        for offset: Float in [3.1, 0.0] {
            let before = fills(rt.frame(at: t))[1]
            rt.update(at: t) { st, _ in st.1 = offset }
            var bottoms = [before.y + before.w]
            for _ in 0..<120 {
                t += 1.0 / 120.0
                let k = fills(rt.frame(at: t))[1]
                bottoms.append(k.y + k.w)
            }
            let steps = zip(bottoms, bottoms.dropFirst()).map { abs($1 - $0) }
            #expect(steps[0] < 0.3)
            #expect(steps.suffix(20).allSatisfy { $0 < 0.1 })
            let f = fills(rt.frame(at: t))
            #expect(f.allSatisfy { whole($0.x) && whole($0.y) && whole($0.z) && whole($0.w) })
            if offset == 0.0 {
                let (above, below) = knobGaps(f)
                #expect(above == below)
            }
        }
    }

    @Test("a_knob_keeps_even_gaps_while_its_track_slides")
    func knobKeepsEvenGapsWhileTrackSlides() {
        let rt = Runtime(state: Float(0), viewport: Vec2(80, 60), pixelScale: 1.25) { slide, _ in
            let knob = El<Float>().size(26, 16).absolute(x: 2, y: 2).bg(.white)
            let track = El<Float>().size(44, 20).absolute(x: 3, y: 11.25)
                .offset(0, slide).animate(Spring(duration: 0.4, bounce: 0)).bg(.black).child(knob)
            return El<Float>().size(80, 60).child(track)
        }
        _ = rt.frame(at: 0.0)
        var t = 0.0
        for slide: Float in [7.3, 0.0] {
            rt.update(at: t) { st, _ in st = slide }
            var tops = [fills(rt.frame(at: t))[1].y]
            for _ in 0..<120 {
                t += 1.0 / 120.0
                let f = fills(rt.frame(at: t))
                let (above, below) = knobGaps(f)
                #expect(abs(above - below) < 1e-3)
                tops.append(f[1].y)
            }
            let steps = zip(tops, tops.dropFirst()).map { abs($1 - $0) }
            #expect(steps[0] < 0.3)
            #expect(steps.suffix(20).allSatisfy { $0 < 0.1 })
            let f = fills(rt.frame(at: t))
            #expect(f.allSatisfy { whole($0.x) && whole($0.y) && whole($0.z) && whole($0.w) })
        }
    }

    @Test("a_still_knob_eases_with_its_track_growing_around_it")
    func stillKnobEasesWithTrackGrowingAroundIt() {
        for retarget in [nil, 10] as [Int?] {
            let rt = Runtime(state: Float(20.0), viewport: Vec2(80, 60), pixelScale: 1.25) { h, _ in
                let knob = El<Float>().size(26, 16).absolute(x: 2, y: (h - 16) / 2)
                    .animateLayout(Spring(duration: 0.4, bounce: 0)).bg(.white)
                return El<Float>().size(80, 60).child(
                    El<Float>().size(44, h).absolute(x: 3, y: 11.25 - (h - 20) / 2)
                        .animateLayout(Spring(duration: 0.4, bounce: 0)).bg(.black).child(knob)
                )
            }
            var t = 0.0
            let start = fills(rt.frame(at: t))[1]
            rt.update(at: t) { st, _ in st = 20.8 }
            var knobs = [start]
            for i in 0..<120 {
                if retarget == i {
                    rt.update(at: t) { st, _ in st = 22.4 }
                }
                t += 1.0 / 120.0
                knobs.append(fills(rt.frame(at: t))[1])
            }
            for i in 1..<knobs.count {
                let a = knobs[i - 1], b = knobs[i]
                #expect(abs(a.y - b.y) < 0.3 && abs((a.y + a.w) - (b.y + b.w)) < 0.3)
            }
            let f = fills(rt.frame(at: t))
            let (above, below) = knobGaps(f)
            #expect(above == below && f.allSatisfy { whole($0.x) && whole($0.y) && whole($0.z) && whole($0.w) })
            let end = knobs.last!
            #expect(start.y != end.y || (start.y + start.w) != (end.y + end.w))
        }
    }

    // MARK: - Pixel Scale & Text Glide Parity (`pixel_scale.rs` & `text_glide.rs`)

    private func primitivesMatchWithColorTol(_ a: [Primitive], _ b: [Primitive], tol: Float = 1e-5) -> Bool {
        guard a.count == b.count else { return false }
        for (pa, pb) in zip(a, b) {
            if pa.rect != pb.rect || pa.radii != pb.radii || pa.params != pb.params || pa.uv != pb.uv
                || pa.clip != pb.clip || pa.fade != pb.fade || pa.fadeOrigin != pb.fadeOrigin || pa.turn != pb.turn {
                return false
            }
            for k in 0..<4 {
                if abs(pa.fill[k] - pb.fill[k]) > tol || abs(pa.border[k] - pb.border[k]) > tol {
                    return false
                }
            }
        }
        return true
    }

    @Test("pixel_scale_change_matches_instances_from_a_fresh_runtime")
    func pixelScaleChangeMatchesFreshRuntime() {
        func makeRt(scale: Float) -> Runtime<()> {
            Runtime(state: (), viewport: Vec2(240, 150), pixelScale: scale) { (_: (), _: inout Cx<()>) -> El<()> in
                col().wFull().hFull().child(
                    el().key("row").absolute(x: 0.123, y: 0.137).size(30.123, 20.137)
                        .bg(.white).hover(.black).onClick { _ in }
                )
            }
        }
        let rt = makeRt(scale: 1.0)
        _ = rt.frame(at: 0.0)
        for scale: Float in [2.0, 1.5, 1.0] {
            rt.setViewport(Vec2(240, 150), pixelScale: scale)
            let p1 = rt.frame(at: 0.0).primitives
            let fresh = makeRt(scale: scale)
            let p2 = fresh.frame(at: 0.0).primitives
            #expect(primitivesMatchWithColorTol(p1, p2), "settled hover rows resnap at scale \(scale)")
        }
    }

    private struct GlideCard {
        var at: SIMD2<Float>
        var spring: Float
    }

    private func makeGlideRuntime(at: SIMD2<Float> = .zero, spring: Float) -> Runtime<GlideCard> {
        Runtime(state: GlideCard(at: at, spring: spring), viewport: Vec2(240, 120), pixelScale: 2.0) { s, _ in
            let label: El<GlideCard> = text("Quiet harbor glides")
                .font(TextStyle(size: 13.0, weight: 500.0))
                .color(.white)
            let sp = Spring(duration: s.spring, bounce: 0.0)
            let root: El<GlideCard> = el()
            let card: El<GlideCard> = col()
            return root.size(240, 120).child(
                card.absolute(x: 20, y: 30).p(12).rounded(10)
                    .bg(Color.white.mix(with: .black, t: 0.8))
                    .border(1.0, Color.white.mix(with: .black, t: 0.6))
                    .offset(s.at.x, s.at.y)
                    .animate(sp)
                    .child(label)
            )
        }
    }

    private func glideCardAt(_ scene: RefScene) -> SIMD2<Float> {
        let r = scene.primitives.first { $0.params.y == Float(PrimitiveKind.roundedRect.rawValue) && $0.fill.w > 0 }!.rect
        return SIMD2<Float>(r.x, r.y)
    }

    private func glideInkAt(_ rt: Runtime<GlideCard>, scene: RefScene) -> SIMD2<Float> {
        let atlas = rt.textSystem.glyphAtlas.atlas
        var sum: Double = 0
        var at = SIMD2<Double>(0, 0)
        for p in scene.primitives where p.params.y == Float(PrimitiveKind.glyph.rawValue) {
            let u = Int((p.uv.x * Float(atlas.width)).rounded())
            let v = Int((p.uv.y * Float(atlas.height)).rounded())
            let w = Int(p.rect.z.rounded())
            let h = Int(p.rect.w.rounded())
            for y in 0..<h {
                for x in 0..<w {
                    let row = v + y
                    let col = u + x
                    guard row >= 0, row < atlas.height, col >= 0, col < atlas.width else { continue }
                    let c = Double(atlas.texels[row * atlas.width + col])
                    sum += c
                    at.x += c * (Double(p.rect.x) + Double(x) + 0.5)
                    at.y += c * (Double(p.rect.y) + Double(y) + 0.5)
                }
            }
        }
        #expect(sum > 0, "draws glyphs")
        return SIMD2<Float>(Float(at.x / sum), Float(at.y / sum))
    }

    private func runGlide(axis: Int, spring: Float, hz: Int) -> (spread: Float, travel: Float, masks: Int) {
        let rt = makeGlideRuntime(spring: spring)
        var t = 0.0
        _ = rt.frame(at: t)
        let startMasks = rt.textSystem.glyphAtlas.cachedEntryCount
        var lo: Float = .greatestFiniteMagnitude
        var hi: Float = -.greatestFiniteMagnitude
        var topLo: Float = .greatestFiniteMagnitude
        var topHi: Float = -.greatestFiniteMagnitude
        let steps = 5 * hz
        for k in 1...steps {
            let phase = Float(k) / Float(hz)
            let d = -2.5 * (0.5 - 0.5 * cos(Float.pi * 2.0 * phase / 5.0))
            rt.update(at: t) { st, _ in st.at[axis] = d }
            t += 1.0 / Double(hz)
            let scene = rt.frame(at: t)
            let ink = glideInkAt(rt, scene: scene)
            let card = glideCardAt(scene)
            let off = ink[axis] - card[axis]
            lo = min(lo, off)
            hi = max(hi, off)
            lo = min(lo, off)
            hi = max(hi, off)
            topLo = min(topLo, card[axis])
            topHi = max(topHi, card[axis])
        }
        return (hi - lo, topHi - topLo, rt.textSystem.glyphAtlas.cachedEntryCount - startMasks)
    }

    @Test("text_glides_with_its_box")
    func textGlidesWithItsBox() {
        var ticks: [(Float, Int, Int, Float)] = []
        for (spring, hz) in [(Float(0.08), 120), (Float(0.08), 60), (Float(0.3), 60), (Float(1.0), 120)] {
            for axis in [1, 0] {
                let (spread, travel, _) = runGlide(axis: axis, spring: spring, hz: hz)
                #expect(travel > 4.5, "card moves ~5 device px: \(travel)")
                if spread > 0.3 {
                    ticks.append((spring, hz, axis, spread))
                }
            }
        }
        #expect(ticks.isEmpty, "ink ticks against card: \(ticks)")
    }

    @Test("a_glide_keeps_the_atlas_bounded")
    func glideKeepsAtlasBounded() {
        let rt = makeGlideRuntime(spring: 0.3)
        let scene = rt.frame(at: 0.0)
        let glyphs = scene.primitives.filter { $0.params.y == Float(PrimitiveKind.glyph.rawValue) }.count
        let (_, _, masks) = runGlide(axis: 1, spring: 0.3, hz: 60)
        #expect(masks <= glyphs * Int(GlyphAtlas.glidePhases), "\(masks) new masks for \(glyphs) glyphs")
    }

    @Test("a_glide_lands_on_the_resting_frame")
    func glideLandsOnRestingFrame() {
        let rt = makeGlideRuntime(spring: 0.3)
        var t = 0.0
        _ = rt.frame(at: t)
        for k in 1...40 {
            rt.update(at: t) { st, _ in
                st.at = SIMD2<Float>(0.7 * Float(k) / 40.0, -1.3 * Float(k) / 40.0)
            }
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        for _ in 0..<120 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        let landed = rt.frame(at: t).primitives
        let still = makeGlideRuntime(at: SIMD2<Float>(0.7, -1.3), spring: 0.3)
        let stillPrims = still.frame(at: 0.0).primitives
        #expect(primitivesMatchWithColorTol(landed, stillPrims), "landed card draws identically to a still one")
    }

    // MARK: - One-Snap Concentric Placement & Large Heading Glide (one_snap.rs)

    private static let oneSnapRingIcon = SVGIcon(
        viewBox: 16.0,
        body: #"<circle cx="8" cy="8" r="6.5" stroke="currentColor" stroke-width="1.5" fill="none"/>"#
    )
    private static let oneSnapDiscIcon = SVGIcon(
        viewBox: 16.0,
        body: #"<circle cx="8" cy="8" r="4" fill="currentColor"/>"#
    )

    private static func circlePoints(cx: Float, cy: Float, r: Float) -> [Vec2] {
        (0..<64).map { k in
            let a = Float.pi * 2.0 * Float(k) / 64.0
            return Vec2(cx + r * cos(a), cy + r * sin(a))
        }
    }

    private static func discShape(r: Float, color: Color) -> Shape {
        Shape.new().fill(circlePoints(cx: 8.0, cy: 8.0, r: r), color: color)
    }

    /// Coverage-weighted `[cx, cy]` (device px) and total pixel area of `channel` in straight RGBA frame.
    private static func channelMoments(_ frame: Frame, channel: Int) -> (SIMD2<Float>, Float) {
        var sum = 0.0
        var sx = 0.0
        var sy = 0.0
        let w = frame.width
        let h = frame.height
        for y in 0..<h {
            for x in 0..<w {
                let idx = (y * w + x) * 4
                let a = Double(frame.rgba[idx + 3]) / 255.0
                let v: Double = channel == 3 ? a : (Double(frame.rgba[idx + channel]) / 255.0) * a
                if v > 0.0 {
                    sum += v
                    sx += v * (Double(x) + 0.5)
                    sy += v * (Double(y) + 0.5)
                }
            }
        }
        #expect(sum > 0.0, "channel \(channel) must have non-zero coverage")
        return (SIMD2<Float>(Float(sx / sum), Float(sy / sum)), Float(sum))
    }

    private static func isWholePixel(_ v: Float) -> Bool {
        abs(v - v.rounded()) < 1e-4
    }

    @Test("one_snap: concentric_icon_and_shape_share_centre_and_size_at_scaled_rest")
    func concentricIconAndShapeShareCentreAndSizeAtScaledRest() throws {
        struct ScaledCase {
            var at: SIMD2<Float>
            var zoom: Float
            var anchored: Bool
            var onlyIconDisc: Bool
        }
        func buildView(_ s: ScaledCase, _: inout Cx<ScaledCase>) -> El<ScaledCase> {
            let red = Color(r: 1, g: 0, b: 0, a: 1)
            let green = Color(r: 0, g: 1, b: 0, a: 1)
            let blue = Color(r: 0, g: 0, b: 1, a: 1)
            let badge: El<ScaledCase> = if s.onlyIconDisc {
                el().key("badge").size(16.0, 16.0)
                    .child(icon(Self.oneSnapDiscIcon, size: 16.0).color(red).absolute(x: 0.0, y: 0.0))
            } else {
                el().key("badge").size(16.0, 16.0).bg(blue)
                    .child(icon(Self.oneSnapRingIcon, size: 16.0).color(red).absolute(x: 0.0, y: 0.0))
                    .child(canvas(Self.discShape(r: 4.0, color: green)).size(16.0, 16.0).absolute(x: 0.0, y: 0.0))
            }
            if s.anchored {
                let page: El<ScaledCase> = col().key("page").size(120.0, 120.0)
                    .scale(s.zoom, s.zoom).origin(0.0, 0.0)
                    .child(el().key("anchor").absolute(x: 12.0 + s.at.x, y: 10.0 + s.at.y).size(24.0, 8.0))
                let pop: El<ScaledCase> = col().key("pop").p(6.0)
                    .bg(Color(r: 0, g: 0, b: 0.25, a: 1))
                    .child(badge)
                    .anchored("anchor", side: .bottom, align: .start, gap: 4.0)
                return col().size(160.0, 160.0).child(page).child(pop)
            } else {
                return col().size(160.0, 160.0).child(
                    col().key("scaled").size(100.0, 100.0)
                        .scale(s.zoom, s.zoom).origin(0.0, 0.0)
                        .child(badge.absolute(x: 14.0 + s.at.x, y: 14.0 + s.at.y))
                )
            }
        }

        let renderer = try MetalRenderer()
        let rectKind = Float(PrimitiveKind.roundedRect.rawValue)
        for anchored in [false, true] {
            var minIconArea = Float.greatestFiniteMagnitude
            var maxIconArea: Float = 0.0
            for iy in 0..<5 {
                for ix in 0..<5 {
                    let at = SIMD2<Float>(Float(ix) * 0.21, Float(iy) * 0.21)
                    let rt = Runtime<ScaledCase>(
                        state: ScaledCase(at: at, zoom: 1.6, anchored: anchored, onlyIconDisc: false),
                        viewport: Vec2(160.0, 160.0),
                        pixelScale: 2.0,
                        systemDark: true,
                        view: buildView
                    )
                    rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
                    _ = rt.frame(at: 0.0)
                    let scene = rt.frame(at: 1.0 / 120.0)

                    let fills = scene.primitives.filter { $0.params.y == rectKind && $0.fill.w > 0 }
                    #expect(!fills.isEmpty)
                    for prim in fills {
                        let r = prim.rect
                        #expect(
                            Self.isWholePixel(r.x) && Self.isWholePixel(r.y)
                                && Self.isWholePixel(r.z) && Self.isWholePixel(r.w),
                            "anchored=\(anchored) at=\(at): held 1.6x fill must snap to whole device px, got \(r)"
                        )
                    }

                    let frame = try renderer.renderOffscreen(scene)
                    let (cIcon, _) = Self.channelMoments(frame, channel: 0)
                    let (cShape, shapeDiscArea) = Self.channelMoments(frame, channel: 1)
                    let errX = abs(cIcon.x - cShape.x)
                    let errY = abs(cIcon.y - cShape.y)
                    #expect(
                        errX <= 0.125 && errY <= 0.125,
                        "anchored=\(anchored) at=\(at): icon centre \(cIcon) vs shape centre \(cShape)"
                    )

                    if iy == 2 {
                        let rtDisc = Runtime<ScaledCase>(
                            state: ScaledCase(at: at, zoom: 1.6, anchored: anchored, onlyIconDisc: true),
                            viewport: Vec2(160.0, 160.0),
                            pixelScale: 2.0,
                            systemDark: true,
                            view: buildView
                        )
                        rtDisc.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
                        _ = rtDisc.frame(at: 0.0)
                        let discScene = rtDisc.frame(at: 1.0 / 120.0)
                        let discFrame = try renderer.renderOffscreen(discScene)
                        let (_, iconDiscArea) = Self.channelMoments(discFrame, channel: 0)
                        minIconArea = min(minIconArea, iconDiscArea)
                        maxIconArea = max(maxIconArea, iconDiscArea)
                        let rel = abs(iconDiscArea - shapeDiscArea) / shapeDiscArea
                        #expect(
                            rel < 0.015,
                            "anchored=\(anchored) at=\(at): icon disc area \(iconDiscArea) vs shape \(shapeDiscArea) (rel=\(rel))"
                        )
                    }
                }
            }
            let spread = (maxIconArea - minIconArea) / minIconArea
            #expect(
                spread < 0.005,
                "anchored=\(anchored): icon disc area jumped across pixel phases: \(minIconArea)..\(maxIconArea)"
            )
        }
    }

    @Test("one_snap: concentric_icon_shape_and_fill_glide_together_during_motion")
    func concentricIconShapeAndFillGlideTogetherDuringMotion() throws {
        struct MovingCase {
            var at: SIMD2<Float>
            var zoom: Float
        }
        func buildView(_ s: MovingCase, _: inout Cx<MovingCase>) -> El<MovingCase> {
            let red = Color(r: 1, g: 0, b: 0, a: 1)
            let green = Color(r: 0, g: 1, b: 0, a: 1)
            let blue = Color(r: 0, g: 0, b: 1, a: 1)
            let sp = Spring(duration: 0.45, bounce: 0.0)
            let badge: El<MovingCase> = el().key("badge").size(16.0, 16.0).bg(blue)
                .offset(s.at.x, s.at.y).animate(sp)
                .child(icon(Self.oneSnapRingIcon, size: 16.0).color(red).absolute(x: 0.0, y: 0.0))
                .child(canvas(Self.discShape(r: 4.0, color: green)).size(16.0, 16.0).absolute(x: 0.0, y: 0.0))
            return col().size(120.0, 120.0).child(
                col().key("scaled").size(100.0, 100.0).scale(s.zoom, s.zoom).origin(0.0, 0.0)
                    .child(badge.absolute(x: 10.0, y: 10.0))
            )
        }

        let renderer = try MetalRenderer()
        for zoom: Float in [1.0, 1.6] {
            let rt = Runtime<MovingCase>(
                state: MovingCase(at: .zero, zoom: zoom),
                viewport: Vec2(120.0, 120.0),
                pixelScale: 2.0,
                systemDark: true,
                view: buildView
            )
            rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
            var t = 0.0
            _ = rt.frame(at: t)
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            rt.update(at: t) { st, _ in st.at = SIMD2<Float>(17.35, 13.65) }

            for f in 0..<90 {
                t += 1.0 / 120.0
                let scene = rt.frame(at: t)
                let frame = try renderer.renderOffscreen(scene)
                let (cIcon, _) = Self.channelMoments(frame, channel: 0)
                let (cShape, _) = Self.channelMoments(frame, channel: 1)
                let (cFill, _) = Self.channelMoments(frame, channel: 3)
                let dIS = max(abs(cIcon.x - cShape.x), abs(cIcon.y - cShape.y))
                let dIF = max(abs(cIcon.x - cFill.x), abs(cIcon.y - cFill.y))
                #expect(
                    dIS <= 0.125 && dIF <= 0.125,
                    "zoom=\(zoom) frame=\(f): d_is=\(dIS), d_if=\(dIF)"
                )
            }
        }
    }

    @Test("one_snap: swapping_canvas_shape_to_icon_keeps_centre_and_area_steady")
    func swappingCanvasShapeToIconKeepsCentreAndAreaSteady() throws {
        struct SwapCase {
            var swapped: Bool
            var discR: Float
        }
        func buildView(_ s: SwapCase, _: inout Cx<SwapCase>) -> El<SwapCase> {
            let red = Color(r: 1, g: 0, b: 0, a: 1)
            let blue = Color(r: 0, g: 0, b: 1, a: 1)
            let page: El<SwapCase> = col().key("page").size(120.0, 120.0)
                .scale(1.6, 1.6).origin(0.0, 0.0)
                .child(el().key("anchor").absolute(x: 12.2, y: 10.35).size(24.0, 8.0))
            let indicator: El<SwapCase> = if s.swapped {
                el().key("badge").size(16.0, 16.0)
                    .child(icon(Self.oneSnapRingIcon, size: 16.0).color(blue).absolute(x: 0.0, y: 0.0))
                    .child(icon(Self.oneSnapDiscIcon, size: 16.0).color(red).absolute(x: 0.0, y: 0.0))
            } else {
                el().key("badge").size(16.0, 16.0)
                    .child(icon(Self.oneSnapRingIcon, size: 16.0).color(blue).absolute(x: 0.0, y: 0.0))
                    .child(canvas(Self.discShape(r: s.discR, color: red)).size(16.0, 16.0).absolute(x: 0.0, y: 0.0))
            }
            let pop: El<SwapCase> = col().key("pop").p(6.15)
                .child(indicator)
                .anchored("anchor", side: .bottom, align: .start, gap: 4.1)
            return col().size(160.0, 160.0).child(page).child(pop)
        }

        let renderer = try MetalRenderer()
        let rt = Runtime<SwapCase>(
            state: SwapCase(swapped: false, discR: 2.8),
            viewport: Vec2(160.0, 160.0),
            pixelScale: 2.0,
            systemDark: true,
            view: buildView
        )
        rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        var t = 0.0
        _ = rt.frame(at: t)

        var centres: [SIMD2<Float>] = []
        var areas: [Float] = []
        for f in 0..<60 {
            let u = min(1.0, max(0.0, Float(f) / 30.0))
            let r: Float = 2.8 + (4.0 - 2.8) * (1.0 - pow(1.0 - u, 3.0))
            let swapped = f >= 36
            rt.update(at: t) { st, _ in
                st.discR = r
                st.swapped = swapped
            }
            t += 1.0 / 120.0
            let scene = rt.frame(at: t)
            let frame = try renderer.renderOffscreen(scene)
            let (c, area) = Self.channelMoments(frame, channel: 0)
            centres.append(c)
            areas.append(area)
        }

        let before = centres[35]
        let after = centres[36]
        let jumpX = abs(after.x - before.x)
        let jumpY = abs(after.y - before.y)
        let areaRel = abs(areas[36] - areas[35]) / areas[35]
        #expect(jumpX <= 0.125 && jumpY <= 0.125, "shape->icon swap jumped: \(before) -> \(after)")
        #expect(areaRel < 0.01, "shape->icon swap area changed by \(areaRel * 100)%")
        let c0 = centres[0]
        for (f, c) in centres.enumerated() {
            let dx = abs(c.x - c0.x)
            let dy = abs(c.y - c0.y)
            #expect(dx <= 0.125 && dy <= 0.125, "frame \(f): centre drifted from \(c0) to \(c)")
        }
    }

    @Test("one_snap: large_heading_glides_horizontally_within_a_phase")
    func largeHeadingGlidesHorizontallyWithinAPhase() {
        struct HeadingCard {
            var x: Float = 0.0
        }
        let rt = Runtime<HeadingCard>(
            state: HeadingCard(),
            viewport: Vec2(280.0, 100.0),
            pixelScale: 2.0,
            systemDark: true
        ) { s, _ in
            let sp = Spring(duration: 0.35, bounce: 0.0)
            let card: El<HeadingCard> = col()
                .absolute(x: 20.0, y: 20.0)
                .p(10.0)
                .bg(Color.white.mix(with: .black, t: 0.8))
                .offset(s.x, 0.0)
                .animate(sp)
                .child(text("Centered").font(TextStyle(size: 24.0, weight: 600.0)).color(.white))
            return el().size(280.0, 100.0).child(card)
        }

        func headingInkX(_ scene: RefScene) -> Float {
            let atlas = rt.textSystem.glyphAtlas.atlas
            var sum = 0.0
            var sx = 0.0
            let glyphKind = Float(PrimitiveKind.glyph.rawValue)
            for p in scene.primitives where p.params.y == glyphKind {
                let u = Int((p.uv.x * Float(atlas.width)).rounded())
                let v = Int((p.uv.y * Float(atlas.height)).rounded())
                let w = Int(p.rect.z.rounded())
                let h = Int(p.rect.w.rounded())
                for y in 0..<h {
                    for x in 0..<w {
                        let row = v + y
                        let col = u + x
                        guard row >= 0, row < atlas.height, col >= 0, col < atlas.width else { continue }
                        let c = Double(atlas.texels[row * atlas.width + col])
                        sum += c
                        sx += c * (Double(p.rect.x) + Double(x) + 0.5)
                    }
                }
            }
            #expect(sum > 0.0)
            return Float(sx / sum)
        }

        var t = 0.0
        let firstScene = rt.frame(at: t)
        let glyphs = firstScene.primitives.filter { $0.params.y == Float(PrimitiveKind.glyph.rawValue) }.count
        let masks0 = rt.textSystem.glyphAtlas.cachedEntryCount
        var lo = Float.greatestFiniteMagnitude
        var hi = -Float.greatestFiniteMagnitude
        for k in 1...180 {
            t = Double(k) / 60.0
            let d = 2.5 * (0.5 - 0.5 * cos(Float.pi * 2.0 * Float(t) / 3.0))
            rt.update(at: t) { st, _ in st.x = d }
            let scene = rt.frame(at: t)
            let cardX = glideCardAt(scene).x
            let off = headingInkX(scene) - cardX
            lo = min(lo, off)
            hi = max(hi, off)
        }
        let spread = hi - lo
        let added = rt.textSystem.glyphAtlas.cachedEntryCount - masks0
        #expect(spread <= 0.30, "48 ppem heading x-glide spread \(spread) px > 0.30 px")
        #expect(added <= glyphs * Int(GlyphAtlas.glidePhases), "\(added) masks for \(glyphs) glyphs")
    }

    @Test("paintContained (#885): box, icon, and shape snap relative to containment rounded origin at 1.875x")
    func paintContainedSnapsBoxIconAndShapeRelativeToContainOrigin() {
        // Commit #885 example: at 1.875x, a box at 44 pt (82.5 px) rounds to 83,
        // and a child 17 pt into it (31.875 px) rounds to 32 -> 83 + 32 = 115
        // (whereas uncontained 61 * 1.875 = 114.375 rounds to 114).
        let scale: Float = 1.875
        let red = Color(r: 1, g: 0, b: 0, a: 1)
        let triShape = Shape.new().fill([Vec2(0, 0), Vec2(10, 0), Vec2(5, 10)], color: .white)

        func buildScene(contained: Bool) -> RefScene {
            let panel: El<Bool> = el()
                .absolute(x: 0, y: 44)
                .size(100, 100)
                .children([
                    el().absolute(x: 0, y: 17).size(16, 16).bg(red),
                    icon(Self.oneSnapDiscIcon, size: 16).absolute(x: 24, y: 17).color(.white),
                    canvas(triShape).absolute(x: 48, y: 17).size(16, 16),
                ])
            let finalPanel = contained ? panel.paintContained(0, 44) : panel
            let rt = Runtime(
                state: false,
                viewport: Vec2(200, 200),
                pixelScale: scale
            ) { _, _ in
                el().size(200, 200).child(finalPanel)
            }
            return rt.frame(at: 0.0)
        }

        let uncontained = buildScene(contained: false)
        let contained = buildScene(contained: true)

        let boxUncontained = fills(uncontained).first!
        let boxContained = fills(contained).first!
        #expect(boxUncontained.y == 114.0)
        #expect(boxContained.y == 115.0)

        let glyphKind = Float(PrimitiveKind.glyph.rawValue)
        let iconUncontained = uncontained.primitives.first { $0.params.y == glyphKind }!
        let iconContained = contained.primitives.first { $0.params.y == glyphKind }!
        #expect(iconUncontained.rect.y == 114.0)
        #expect(iconContained.rect.y == 115.0)

        let triKind = Float(PrimitiveKind.triangle.rawValue)
        let triUncontainedTop = uncontained.primitives.filter { $0.params.y == triKind }.map(\.rect.y).min()!
        let triContainedTop = contained.primitives.filter { $0.params.y == triKind }.map(\.rect.y).min()!
        // `Shape.triangulate` adds a 1 px AA fringe around the vertex bounding box (`origin.y - 1`).
        #expect(triUncontainedTop == 113.0)
        #expect(triContainedTop == 114.0)
    }

    @Test("paintContained (#885): nested containment replaces outer containment origin")
    func paintContainedNestedReplacesOuterOrigin() {
        let scale: Float = 1.875
        let green = Color(r: 0, g: 1, b: 0, a: 1)
        // Outer containment at y = 44.0 (82.5 px -> 83); inner containment at y = 45.0 (84.375 px -> 84).
        // Child at y = 61.0: relative to 44 -> roundHalfUp(31.875) + 83 = 115;
        // relative to 45 -> roundHalfUp(30.0) + 84 = 114.
        let rt = Runtime(
            state: false,
            viewport: Vec2(200, 200),
            pixelScale: scale
        ) { _, _ in
            el().size(200, 200).paintContained(0, 44).child(
                el().size(200, 200).paintContained(Vec2(0, 45)).child(
                    el().absolute(x: 0, y: 61).size(16, 16).bg(green)
                )
            )
        }
        let scene = rt.frame(at: 0.0)
        let box = fills(scene).first!
        #expect(box.y == 114.0)
    }

    @Test("motionSnaps (#892): moving box and subtree snap every frame instead of gliding")
    func motionSnapsMovesOnWholeDevicePixelsEveryFrame() {
        struct MovingBox {
            var x: Float = 0.0
        }
        let blue = Color(r: 0, g: 0, b: 1, a: 1)

        func runFrames(motionSnaps: Bool) -> [[Float]] {
            let rt = Runtime<MovingBox>(
                state: MovingBox(),
                viewport: Vec2(200, 120),
                pixelScale: 2.0
            ) { s, _ in
                let child: El<MovingBox> = el()
                    .key("child")
                    .m(4)
                    .size(16, 16)
                    .bg(.white)
                let box: El<MovingBox> = el()
                    .key("mover")
                    .absolute(x: 10, y: 20)
                    .offset(s.x, 0)
                    .size(40, 24)
                    .bg(blue)
                    .animate(Spring(duration: 0.4, bounce: 0.0))
                    .child(child)
                return el().size(200, 120).child(motionSnaps ? box.motionSnaps() : box)
            }
            _ = rt.frame(at: 0.0)
            rt.update(at: 1.0 / 60.0) { s, _ in s.x = 20.0 }
            var sampledEdges: [[Float]] = []
            for k in 2...15 {
                let scene = rt.frame(at: Double(k) / 60.0)
                let rectEdges = edges(fills(scene))
                #expect(rectEdges.count == 8)
                sampledEdges.append(rectEdges)
            }
            return sampledEdges
        }

        let glidingFrames = runFrames(motionSnaps: false)
        let snappingFrames = runFrames(motionSnaps: true)

        // Default moving box glides at sub-pixel positions.
        let hasFractionalWhileGliding = glidingFrames.flatMap { $0 }.contains { !whole($0) }
        #expect(hasFractionalWhileGliding, "expected un-stepped moving box to glide at sub-pixel coordinates")

        // With `motionSnaps()`, both the moving box and its child snap to whole device pixels on every frame
        // while still animating forward across frames.
        for (idx, frameEdges) in snappingFrames.enumerated() {
            for edge in frameEdges {
                #expect(whole(edge), "frame \(idx): expected whole device pixel edge, got \(edge)")
            }
        }
        let firstX = snappingFrames.first![0]
        let lastX = snappingFrames.last![0]
        #expect(lastX > firstX, "expected motionSnaps box to advance while stepping whole pixels: \(firstX) -> \(lastX)")
    }
}
