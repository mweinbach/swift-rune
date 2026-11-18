import Foundation
import Testing
@testable import Rune

@Suite("Layout Rows Parity (runtime/tests/layout_rows.rs)")
struct LayoutRowsParityTests {
    @Test("duplicate_sibling_keys_keep_the_first_and_lay_out_without_a_panic")
    func duplicateSiblingKeysKeepFirstAndLayOut() {
        let rt = Runtime<Int>(
            state: 2,
            viewport: Vec2(100.0, 100.0),
            pixelScale: 1.0,
            systemDark: true
        ) { count, _ in
            var root: El<Int> = col()
            for i in 0..<count {
                root = root.child(el().key("row:R-94").size(10.0, 10.0 + Float(i)))
            }
            return root
        }
        var t = 0.0
        _ = rt.frame(at: t)
        let h: (String) -> Float? = { key in rt.element(byKey: key)?.rect[3] }
        #expect(h("row:R-94") == 10.0, "the first keeps the key")
        #expect(h("row:R-94#dup1") == 11.0, "the duplicate still draws")
        rt.update(at: t) { s, _ in s = 3 }
        t += 0.1
        _ = rt.frame(at: t)
        #expect(h("row:R-94#dup2") == 12.0)
    }

    @Test("duplicate_sibling_keys_tooling_reports_and_lays_out")
    func duplicateSiblingKeysToolingReportsAndLaysOut() {
        let rt = Runtime<Void>(
            state: (),
            viewport: Vec2(100.0, 100.0),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            col().wFull().hFull()
                .child(el().key("dup").size(10.0, 10.0))
                .child(el().key("dup").size(10.0, 10.0))
        }
        _ = rt.frame(at: 0.0)
        #expect(rt.keyWarnings.count == 1)
        #expect(rt.flatNodes.count == 3)
        #expect(rt.flatNodes[0].localSize.x == 100.0)
    }

    @Test("side_panel_wraps_once_and_releases_height_after_stable_width")
    func sidePanelWrapsOnceAndReleasesHeightAfterStableWidth() {
        struct PanelState {
            var sideWidth: Float
            var reduced: Bool
        }

        func buildView(_ s: PanelState, _ cx: inout Cx<PanelState>) -> El<PanelState> {
            cx.reducedMotion(s.reduced)
            return row().key("window").wFull().hFull()
                .child(
                    col().key("viewport").grow(1.0).shrink().hFull()
                        .scroll(ScrollSpec(stickBottom: true))
                        .clipFade(bottom: 18.0)
                        .child(
                            col().key("stack").wFull().growth(GrowthSpec.default)
                                .child(
                                    col().key("message").wFull()
                                        .child(text(String(repeating: "Wrap once at the landing width. ", count: 30)).wrap(.wrap).wFull())
                                )
                        )
                )
                .child(el().key("side-panel").w(s.sideWidth).hFull())
        }

        func run(fps: Int, reduced: Bool) -> [Float] {
            let rt = Runtime<PanelState>(
                state: PanelState(sideWidth: 0.0, reduced: reduced),
                viewport: Vec2(480.0, 700.0),
                pixelScale: 2.0,
                systemDark: true,
                view: buildView
            )
            var t = 0.0
            _ = rt.frame(at: t)
            let msgNode = rt.flatNodes.first(where: { $0.key == "message" })!
            let stackPath = rt.flatNodes.first(where: { $0.key == "stack" })!.path
            let msgGKey = "growth:\(msgNode.path)"
            let original = rt.growthRows[msgGKey]!.track.h

            rt.update(at: t) { s, _ in s.sideWidth = 160.0 }
            _ = rt.frame(at: t)
            let viewCalls = rt.viewCallCount
            let shapesBefore = rt.textSystem.measureMissCount
            let targetHeight: Float
            if reduced {
                targetHeight = rt.growthRows[msgGKey]!.track.h
                #expect(targetHeight > original)
            } else {
                targetHeight = rt.growthStacks[stackPath]?.pendingHeights[msgGKey] ?? rt.growthRows[msgGKey]!.track.target
                #expect(targetHeight > original)
                #expect(rt.growthRows[msgGKey]!.track.target == original)
            }

            var samples: [Float] = []
            for frame in 1...(fps * 2) {
                t += 1.0 / Double(fps)
                _ = rt.frame(at: t)
                #expect(rt.viewCallCount == viewCalls, "presentation must not re-run view during wrap release")
                #expect(rt.textSystem.measureMissCount == shapesBefore, "presentation must not re-shape wrapping")
                let curH = rt.growthRows[msgGKey]!.track.h
                if Double(frame) / Double(fps) < 0.12 && !reduced {
                    let isAnim = rt.isAnimating
                    #expect(curH == original, "frame \(frame)/\(fps): height stays at \(original), got \(curH)")
                    #expect(isAnim, "the hold must keep the shared clock awake")
                }
                if frame % (fps / 30) == 0 {
                    samples.append(curH)
                }
            }
            #expect(abs(rt.growthRows[msgGKey]!.track.h - targetHeight) < 0.05)

            // A second target during a hold restarts the stable-width interval.
            rt.update(at: t) { s, _ in s.sideWidth = 80.0 }
            _ = rt.frame(at: t)
            for _ in 0..<(fps / 10) {
                t += 1.0 / Double(fps)
                _ = rt.frame(at: t)
            }
            rt.update(at: t) { s, _ in s.sideWidth = 120.0 }
            _ = rt.frame(at: t)
            for _ in 0..<(fps / 10) {
                t += 1.0 / Double(fps)
                _ = rt.frame(at: t)
            }
            if !reduced {
                #expect(abs(rt.growthRows[msgGKey]!.track.h - targetHeight) < 0.05, "a changing width must restart the hold")
                #expect(rt.growthStacks[stackPath]?.pendingHeights.isEmpty == false)
            }
            // Settle/resume bypasses even an active hold completely.
            rt.settleAll()
            _ = rt.frame(at: t)
            let stacksEmpty = rt.growthStacks.values.allSatisfy { $0.pendingHeights.isEmpty }
            let stillAnim = rt.isAnimating
            #expect(stacksEmpty)
            #expect(!stillAnim)
            return samples
        }

        for reduced in [false, true] {
            let a = run(fps: 30, reduced: reduced)
            let b = run(fps: 120, reduced: reduced)
            #expect(a.count == b.count)
            for (sa, sb) in zip(a, b) {
                #expect(abs(sa - sb) < 0.05, "frame-rate dependent hold (reduced=\(reduced)): \(sa) vs \(sb)")
            }
        }
    }

    @Test("measurement_cannot_change_presented_geometry_or_motion_policy")
    func measurementCannotChangePresentedGeometryOrMotionPolicy() {
        let rt = Runtime<Bool>(
            state: false,
            viewport: Vec2(300.0, 300.0),
            pixelScale: 2.0,
            systemDark: true
        ) { changed, cx in
            cx.reducedMotion(changed)
            return col().key("stack").wFull().growth(GrowthSpec.default)
                .child(el().key("row").wFull().h(changed ? 160.0 : 40.0))
        }
        _ = rt.frame(at: 0.0)
        let rowNode = rt.flatNodes.first(where: { $0.key == "row" })!
        let rowId = rowNode.nodeId
        let rowGKey = "growth:\(rowNode.path)"
        let before = rt.scene.presented(rowId)!.rect

        rt.state = true
        let measured = rt.measurePass(
            at: 0.0,
            cut: false,
            commitKind: .animate,
            commitMotion: nil,
            commitColorSpring: nil,
            commitCut: false,
            prevMountedIds: rt.nodeIndexById.keys,
            focusedCaret: nil,
            allowZoomSettle: false
        )!
        #expect(rt.scene.presented(rowId)!.rect == before)
        #expect(rt.scene.store.activeLen == 0)
        #expect(rt.growthRows[rowGKey]!.track.h == 40.0)
        #expect(!rt.reducedMotion && !rt.scene.reducedMotion)

        let result = rt.applyMeasurePass(
            measured,
            at: 0.0,
            cut: false,
            settlePass: 0,
            commitKind: .animate,
            commitMotion: nil,
            commitColorSpring: nil,
            commitFollowEdge: false,
            commitCut: false,
            prevMountedIds: rt.nodeIndexById.keys
        )
        #expect(result == .applied)
        #expect(rt.reducedMotion && rt.scene.reducedMotion)
        #expect(rt.growthRows[rowGKey]!.track.h == 160.0)
    }

    @Test("send_flight_follows_the_measured_bubble_while_earlier_rows_land")
    func sendFlightFollowsMeasuredBubbleWhileEarlierRowsLand() {
        struct FlightState {
            var draft: TextEdit
            var sent: Bool = false
            var height: Float = 80.0
        }

        let draft = TextEdit("héllo flight")
        let rt = Runtime<FlightState>(
            state: FlightState(draft: draft),
            viewport: Vec2(400.0, 300.0),
            pixelScale: 2.0,
            systemDark: true
        ) { s, _ in
            var rows: El<FlightState> = col().wFull().growth(GrowthSpec.default)
                .child(el().key("earlier").wFull().h(s.height))
            if s.sent {
                rows = rows.child(
                    col().key("bubble").wFull().py(8.0)
                        .child(text("héllo flight").key("destination").wrap(.wrap))
                )
            }
            return col().wFull().hFull()
                .child(
                    col().key("scroll").wFull().grow(1.0).shrink()
                        .scroll(ScrollSpec(stickBottom: true))
                        .child(rows)
                )
                .child(
                    textInput(key: "source", \FlightState.draft)
                        .font(TextStyle(size: 14.0, weight: 400.0))
                        .autofocus(true)
                        .wFull()
                        .h(60.0)
                        .onSubmit { s, _, tx in
                            s.sent = true
                            s.draft.clear()
                            tx.flyText("source", to: "destination")
                        }
                )
        }
        var t = 0.0
        _ = rt.frame(at: t)
        rt.update(at: t) { s, _ in s.height = 400.0 }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        _ = rt.keyDown(KeyEvent(key: .enter), at: t)
        t += 1.0 / 120.0
        _ = rt.frame(at: t)

        #expect(rt.activeTextFlights.count == 1)
        let captured = rt.activeTextFlights[0].state.source
        let draftText = rt.textSystem.shape(
            text: "héllo flight", style: TextStyle(size: 14.0, weight: 400.0),
            maxWidth: nil, pixelScale: 2.0, emitGlyphs: false
        )
        #expect(abs(captured.width - draftText.size.x) < 1, "the flight starts at the text width inside the 400-point composer")
        var previousTarget = rt.activeTextFlights[0].state.destination
        var retargets = 0
        for _ in 0..<240 {
            t += 1.0 / 120.0
            let rf = rt.frame(at: t)
            if let f = rt.activeTextFlights.first {
                #expect(f.state.presented == Snap.rect(f.state.presented, scale: rt.pixelScale))
                let glyphKind = Float(PrimitiveKind.glyph.rawValue)
                let hasVisibleGlyph = rf.primitives.contains { (q: Primitive) -> Bool in
                    guard q.params.y == glyphKind, q.uv.z > 0.0, q.fill.w > 0.1 else { return false }
                    let visW = min(q.rect.x + q.rect.z, q.clip.x + q.clip.z) - max(q.rect.x, q.clip.x)
                    let visH = min(q.rect.y + q.rect.w, q.clip.y + q.clip.w) - max(q.rect.y, q.clip.y)
                    return visW > 1.0 && visH > 1.0
                }
                #expect(hasVisibleGlyph, "the source/destination handoff never loses every visible glyph")
                let dstEl = rt.element(byKey: "destination")!
                #expect(abs(f.state.destination.y - dstEl.rect[1]) < 0.01, "destination is this frame's post-scroll geometry")
                if f.state.destination != previousTarget {
                    retargets += 1
                }
                previousTarget = f.state.destination
            }
        }
        #expect(retargets > 3, "earlier row growth actually moved the destination (retargets=\(retargets))")
        #expect(rt.activeTextFlights.isEmpty, "flight lands and releases the captured glyphs")
        let isStillAnim = rt.isAnimating
        #expect(!isStillAnim)
    }

    @Test("destination ink travels above the clip until the handoff", arguments: [false, true])
    func destinationInkTravelsAboveTheClip(native: Bool) {
        let rt = Runtime<Bool>(state: false, viewport: Vec2(240, 240), pixelScale: 1) { sent, _ in
            let source: El<Bool> = text(sent ? "" : "flight").key("source").color(.srgb(1, 0, 0))
            let destination: El<Bool> = text("flight").key("destination").color(.srgb(0, 0, 1))
            return el().size(240, 240)
                .child(col().absolute(x: 12, y: 20).size(100, 32).clip().child(source))
                .child(col().absolute(x: 12, y: 184).size(100, 32).clip().child(destination))
        }

        func visibleGlyphs(at time: Double) -> [(top: Float, blue: Bool)] {
            typealias Glyph = (rect: SIMD4<Float>, ink: SIMD4<Float>, clip: SIMD4<Float>)
            let glyphs: [Glyph]
            if native {
                glyphs = rt.renderFrame(at: time).instances.filter { $0.params.y == KIND_GLYPH }
                    .map { ($0.rect, $0.fill, $0.clip) }
            } else {
                glyphs = rt.frame(at: time).primitives.filter { $0.kind == .glyph }.map {
                    let c = $0.clip
                    return ($0.rect, $0.fill, SIMD4(c.x, c.y, c.x + c.z, c.y + c.w))
                }
            }
            return glyphs.compactMap { g in
                let width = min(g.rect.x + g.rect.z, g.clip.z) - max(g.rect.x, g.clip.x)
                let height = min(g.rect.y + g.rect.w, g.clip.w) - max(g.rect.y, g.clip.y)
                guard width > 1, height > 1, g.ink.w > 0.1 else { return nil }
                return (g.rect.y, g.ink.z > g.ink.x)
            }
        }

        _ = visibleGlyphs(at: 0)
        rt.update(at: 0) { sent, tx in
            sent = true
            tx.flyText("source", to: "destination")
        }
        var crossedGap = false
        for frame in 1...120 {
            let glyphs = visibleGlyphs(at: Double(frame) / 120)
            guard let flight = rt.activeTextFlights.first else { break }
            #expect(!glyphs.isEmpty)
            let top = flight.state.presented.y
            if (60...138).contains(top) {
                crossedGap = true
                let destinationInk = glyphs.filter(\.blue)
                #expect(!destinationInk.isEmpty)
                #expect(destinationInk.allSatisfy { abs($0.top - top) < 24 })
            }
        }
        #expect(crossedGap)
        #expect(rt.activeTextFlights.isEmpty)
        let landed = visibleGlyphs(at: 1.1).filter(\.blue)
        #expect(!landed.isEmpty)
        #expect(landed.allSatisfy { (184...216).contains($0.top) })
    }

    @Test("reduced_motion_rows_land_immediately_but_keep_the_presence_fade")
    func reducedMotionRowsLandImmediatelyButKeepPresenceFade() {
        let rt = Runtime<Bool>(
            state: false,
            viewport: Vec2(200.0, 300.0),
            pixelScale: 2.0,
            systemDark: true
        ) { show, cx in
            cx.reducedMotion(true)
            var stack: El<Bool> = col().wFull().growth(GrowthSpec.default)
            if show {
                stack = stack.child(el().key("row").size(200.0, 100.0))
            }
            return stack
        }
        var t = 0.0
        _ = rt.frame(at: t)
        let anim0 = rt.isAnimating
        #expect(!anim0)

        rt.update(at: t) { show, _ in show = true }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        let entered = rt.element(byKey: "row")!
        #expect(entered.rect[3] == 100.0, "reduced motion removes growth travel")
        #expect(entered.opacity > 0.0 && entered.opacity < 1.0, "new rows still fade in")

        t += 0.2
        _ = rt.frame(at: t)
        let animAfterEnter = rt.isAnimating
        #expect(!animAfterEnter)
        #expect(rt.element(byKey: "row")!.opacity == 1.0)

        rt.update(at: t) { show, _ in show = false }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        let exiting = rt.element(byKey: "row")!
        #expect(exiting.opacity > 0.0 && exiting.opacity < 1.0, "removed rows stay for their fade")

        for _ in 0..<60 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        let animAfterExit = rt.isAnimating
        #expect(!animAfterExit)
        #expect(rt.elements().allSatisfy { $0.key != "row" })
    }

    @Test("streaming_fill_and_width_rewrap_land_on_completion")
    func streamingFillAndWidthRewrapLandOnCompletion() {
        struct StreamState {
            var text: String
            var streaming: Bool
        }

        let rt = Runtime<StreamState>(
            state: StreamState(text: "one", streaming: true),
            viewport: Vec2(180.0, 500.0),
            pixelScale: 2.0,
            systemDark: true
        ) { s, _ in
            var txt: El<StreamState> = text(s.text).wrapText().wFull()
            txt.runtimeExtras["shell.revealWordFade"] = Float(0.18)
            return col().wFull().growth(GrowthSpec.default).child(
                col().key("row").wFull().streaming(s.streaming).child(txt)
            )
        }

        func rowEntry() -> Runtime<StreamState>.RuntimeGrowthEntry {
            rt.growthRows.first { $0.key.contains("@row") }!.value
        }

        var t = 0.0
        _ = rt.frame(at: t)
        rt.update(at: t) { s, _ in
            s.text = "one two three four five six seven eight nine ten eleven"
        }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        let full = rowEntry().naturalHeight
        #expect(rowEntry().track.target < full, "new line is held back while filling")

        for _ in 0..<240 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        #expect(!rt.isAnimating, "partial line at rest must stop ticking")
        let oldH = rowEntry().track.h

        rt.setViewport(Vec2(600.0, 500.0), pixelScale: 2.0)
        rt.update(at: t) { s, _ in
            s.text += " twelve"
        }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(rowEntry().track.target == oldH, "rewrap waits for stable width")

        for _ in 0..<15 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        #expect(rowEntry().track.target < oldH, "width change may shrink a streaming row")
        #expect(rowEntry().track.h > rowEntry().track.target, "rewrapped height eases instead of snapping")

        rt.update(at: t) { s, _ in
            s.text = "one two"
        }
        _ = rt.frame(at: t)
        #expect(rowEntry().track.target < rowEntry().track.h, "streaming may still shrink inside the 400 ms rewrap window")

        for _ in 0..<120 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        let landed = rowEntry().track.h
        rt.update(at: t) { s, _ in
            s.text = "o"
        }
        _ = rt.frame(at: t)
        #expect(rowEntry().track.target == landed, "streaming cannot shrink after the rewrap window")

        rt.update(at: t) { s, _ in
            s.streaming = false
        }
        for _ in 0..<240 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        #expect(!rt.isAnimating)
        let rowNode = rt.flatNodes.first { $0.key == "row" }!
        #expect(rowEntry().track.h == rowNode.targetRect.height)
    }

    @Test("retained_layout_matches_fresh_tree_across_edits")
    func retainedLayoutMatchesFreshTreeAcrossEdits() {
        func buildSeedView(_ seed: Int, _: inout Cx<Int>) -> El<Int> {
            var root: El<Int> = col().key("root").wFull()
            for k in 0..<8 {
                let i = (k + seed) % 8
                if (i + seed) % 5 == 0 { continue }
                let body = String(repeating: "some words ", count: (i + seed) % 10 + 1)
                let child: El<Int> = ((i + seed) % 7 == 0) ? el().h(31.0) : text(body).wrap(.wrap)
                root = root.child(child.key("row-\(i)").wFull().px(Float(seed % 3)))
            }
            return root
        }

        let cached = Runtime<Int>(
            state: 0,
            viewport: Vec2(320.0, 600.0),
            pixelScale: 2.0,
            systemDark: true,
            view: buildSeedView
        )
        for seed in 0..<40 {
            let size = Vec2(240.0 + Float(seed % 4) * 30.0, 600.0)
            let scale: Float = (seed % 3 == 0) ? 1.0 : 2.0
            cached.state = seed
            cached.invalidate(at: 0.0)
            cached.setViewport(size, pixelScale: scale)
            cached.settleAll()
            _ = cached.frame(at: 0.0)

            let fresh = Runtime<Int>(
                state: seed,
                viewport: size,
                pixelScale: scale,
                systemDark: true,
                view: buildSeedView
            )
            _ = fresh.frame(at: 0.0)

            let rects: (Runtime<Int>) -> [(String, [Float])] = { r in
                r.elements().filter { $0.opacity > 0.0 }.map { ($0.path, $0.target) }
            }
            let a = rects(cached)
            let b = rects(fresh)
            #expect(a.count == b.count, "edit \(seed): count \(a.count) vs \(b.count)")
            for ((pa, ta), (pb, tb)) in zip(a, b) {
                #expect(pa == pb, "edit \(seed): path \(pa) vs \(pb)")
                #expect(ta == tb, "edit \(seed) @ \(pa): target \(ta) vs \(tb)")
            }
        }
    }
}
