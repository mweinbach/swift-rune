import Foundation
import Testing
@testable import Rune
import RuneMotion

@Suite("El Slice: Picture Scale Parity (picture_scale.rs)")
struct ElSlicePictureScaleTests {

    @Test("Text inside static, live, and press scale draws at scaled size, crisp when still, and hits follow drawn rect")
    func textInsideScaleDrawsAtThatSize() {
        enum How {
            case `static`
            case live
            case press
        }
        struct State {
            var k: Float
            var how: How
            var pressed: Int = 0
        }

        let liveRef = Live<Float>(0.5)

        func makeRuntime(k: Float, how: How) -> Runtime<State> {
            let live = Live<Float>(k)
            return Runtime<State>(
                state: State(k: k, how: how),
                viewport: Vec2(300, 200),
                pixelScale: 2.0
            ) { s, _ in
                let label: El<State> = text("Hamburgefonstiv").key("label")
                var card: El<State> = el().key("card").size(200, 80).onClick { st, _ in st.pressed += 1 }.child(label)
                switch s.how {
                case .static: card = card.scale(s.k)
                case .live: card = card.liveScale((s.k == 0.5 ? live : liveRef).binding)
                case .press: card = card.pressScale(s.k)
                }
                return col().size(300, 200).child(card)
            }
        }

        func glyphBoundsAndCrisp(_ rt: Runtime<State>) -> (bounds: [Float], crisp: Bool) {
            let rf = rt.renderFrame(at: rt.currentTime)
            let gs = rf.instances.filter { $0.params.y == KIND_GLYPH }
            #expect(gs.count >= 10, "the label draws its glyphs")
            var minX = Float.greatestFiniteMagnitude
            var minY = Float.greatestFiniteMagnitude
            var maxX = -Float.greatestFiniteMagnitude
            var maxY = -Float.greatestFiniteMagnitude
            for q in gs {
                // Measure covered texels. CoreText and native line tiles can reserve different
                // transparent borders for the same glyph.
                let width = Int((q.uv.z > 0 ? q.uv.z : q.rect.z).rounded())
                let height = Int((q.uv.z > 0 ? q.uv.w : q.rect.w).rounded())
                let left = Int(q.uv.x.rounded()), top = Int(q.uv.y.rounded())
                guard width > 0, height > 0, left >= 0, top >= 0,
                      left + width <= rf.glyphs.width, top + height <= rf.glyphs.height else {
                    Issue.record("Glyph rectangle falls outside its atlas")
                    continue
                }
                let dx = q.rect.z / Float(width), dy = q.rect.w / Float(height)
                for y in 0..<height {
                    for x in 0..<width where rf.glyphs.texels[(top + y) * rf.glyphs.width + left + x] > 0 {
                        minX = min(minX, q.rect.x + Float(x) * dx)
                        minY = min(minY, q.rect.y + Float(y) * dy)
                        maxX = max(maxX, q.rect.x + Float(x + 1) * dx)
                        maxY = max(maxY, q.rect.y + Float(y + 1) * dy)
                    }
                }
            }
            #expect(minX < maxX && minY < maxY, "the label has visible ink")
            return ([minX, minY, maxX, maxY], gs.allSatisfy { $0.uv.z == 0.0 })
        }

        func run(_ k: Float, _ how: How) -> Runtime<State> {
            let rt = makeRuntime(k: k, how: how)
            _ = rt.frame(at: 0.0)
            _ = rt.frame(at: 1.0 / 120.0)
            return rt
        }

        let (rest, _) = glyphBoundsAndCrisp(run(1.0, .static))
        let w = rest[2] - rest[0]
        let h = rest[3] - rest[1]
        // Card center in device px at 2x scale: (200, 80).
        let c: [Float] = [200.0, 80.0]

        for how in [How.static, How.live] {
            let rt = run(0.5, how)
            let (half, crisp) = glyphBoundsAndCrisp(rt)
            let hw = half[2] - half[0]
            let hh = half[3] - half[1]
            let rw = hw / w
            let rh = hh / h
            #expect(abs(rw - 0.5) < 0.03 && abs(rh - 0.5) < 0.06, "glyphs draw at half size: \(hw)x\(hh) vs \(w)x\(h)")
            for axis in 0..<2 {
                let want = c[axis] + (rest[axis] - c[axis]) * 0.5
                #expect(abs(half[axis] - want) < 1.5, "about card center: \(half[axis]) vs \(want)")
            }
            #expect(crisp, "a still scale rasterizes crisp at the scaled size")
        }

        // Static scale keeps layout target unchanged; hits follow drawn rect [50..150 x 20..60].
        let rtStatic = run(0.5, .static)
        let card = rtStatic.elements().first(where: { $0.key == "card" })!
        #expect(card.target == [0, 0, 200, 80])
        #expect(abs(card.rect[0] - 50.0) < 0.05 && abs(card.rect[2] - 100.0) < 0.05)
        var t = rtStatic.currentTime
        for (x, expectedHits) in [(Float(20.0), 0), (Float(100.0), 1)] {
            rtStatic.pointerMove(to: Vec2(x, 40), at: t)
            rtStatic.pointerDown(at: Vec2(x, 40), at: t)
            t += 1.0 / 120.0
            rtStatic.pointerUp(at: Vec2(x, 40), at: t)
            _ = rtStatic.frame(at: t)
            #expect(rtStatic.state.pressed == expectedHits, "press at x=\(x)")
        }

        // Press scale shrinks text crisp while held, samples rest glyphs while springing back, then settles exact.
        let rtPress = run(0.9, .press)
        var tp = rtPress.currentTime
        rtPress.pointerMove(to: Vec2(100, 40), at: tp)
        rtPress.pointerDown(at: Vec2(100, 40), at: tp)
        for _ in 0..<30 {
            tp += 1.0 / 120.0
            _ = rtPress.frame(at: tp)
        }
        let (held, crispHeld) = glyphBoundsAndCrisp(rtPress)
        #expect(abs((held[2] - held[0]) / w - 0.9) < 0.02, "held text is 90%: \(held)")
        #expect(crispHeld, "held size rasterizes crisp")

        tp += 1.0 / 120.0
        rtPress.pointerUp(at: Vec2(100, 40), at: tp)
        _ = rtPress.frame(at: tp)
        // The release starts the spring at its held value. Sample after it has advanced.
        tp += 3.0 / 120.0
        _ = rtPress.frame(at: tp)
        let (moving, crispMoving) = glyphBoundsAndCrisp(rtPress)
        let mw = (moving[2] - moving[0]) / w
        #expect(mw > 0.9 && mw < 1.0, "springing back: \(mw)")
        let cardScale = rtPress.elements().first { $0.key == "card" }!.rect[2] / 200
        #expect(abs(mw - cardScale) < 0.02, "glyph width \(mw) follows card scale \(cardScale)")
        #expect(!crispMoving, "moving scale samples rest-size glyphs")

        for _ in 0..<120 {
            tp += 1.0 / 120.0
            _ = rtPress.frame(at: tp)
        }
        let settled = glyphBoundsAndCrisp(rtPress)
        #expect(settled.crisp)
        for i in 0..<4 {
            #expect(abs(settled.bounds[i] - rest[i]) < 0.5)
        }
    }

    @Test("Nested static, live, and press scales compose about each mapped center")
    func nestedScalesComposeAboutEachMappedCentre() {
        enum How {
            case press
            case `static`
            case productOfOne
            case threeLevels
        }
        struct State {
            var how: How
            var pressed: Int = 0
        }

        func edges(_ rt: Runtime<State>) -> [Float] {
            let r = rt.elements().first(where: { $0.key == "c" })!.rect
            return [r[0], r[1], r[0] + r[2], r[1] + r[3]]
        }

        func near(_ a: [Float], _ b: [Float]) -> Bool {
            zip(a, b).allSatisfy { abs($0 - $1) < 0.3 }
        }

        func run(_ how: How) -> Runtime<State> {
            let liveMid = Live<Float>(0.8)
            let rt = Runtime<State>(
                state: State(how: how),
                viewport: Vec2(400, 400),
                pixelScale: 2.0
            ) { s, _ in
                let leaf: El<State> = el().key("c").size(40, 40).onClick { st, _ in st.pressed += 1 }
                let inner: El<State>
                switch s.how {
                case .press:
                    inner = leaf.pressScale(0.96)
                case .static:
                    inner = leaf.scale(0.8)
                case .productOfOne:
                    inner = leaf.scale(2.0)
                case .threeLevels:
                    inner = el().key("mid").size(100, 100).itemsStart()
                        .liveScale(liveMid.binding)
                        .child(leaf.pressScale(0.9))
                }
                return col().size(400, 400).itemsStart()
                    .child(el().key("p").size(200, 200).itemsStart().scale(0.5).child(inner))
            }
            _ = rt.frame(at: 0.0)
            _ = rt.frame(at: 1.0 / 120.0)
            return rt
        }

        let cases: [(how: How, rest: [Float], held: [Float]?)] = [
            (.press, [50, 50, 70, 70], [50.4, 50.4, 69.6, 69.6]),
            (.static, [52, 52, 68, 68], nil),
            (.productOfOne, [40, 40, 80, 80], nil),
            (.threeLevels, [55, 55, 71, 71], [55.8, 55.8, 70.2, 70.2]),
        ]

        for entry in cases {
            let rt = run(entry.how)
            var t = rt.currentTime
            let restEdges = edges(rt)
            #expect(near(restEdges, entry.rest), "\(entry.how) at rest: \(restEdges) vs \(entry.rest)")

            // Outside drawn corner misses; inside drawn corner hits.
            for pt in [Vec2(entry.rest[0] - 1, entry.rest[1] - 1), Vec2(entry.rest[0] + 1, entry.rest[1] + 1)] {
                t += 1.0 / 120.0
                rt.pointerMove(to: pt, at: t)
                rt.pointerDown(at: pt, at: t)
                t += 1.0 / 120.0
                rt.pointerUp(at: pt, at: t)
                _ = rt.frame(at: t)
            }
            #expect(rt.state.pressed == 1, "\(entry.how): hits follow the drawn rect")

            guard let held = entry.held else { continue }
            let cx = (entry.rest[0] + entry.rest[2]) * 0.5
            let cy = (entry.rest[1] + entry.rest[3]) * 0.5
            t += 1.0 / 120.0
            rt.pointerMove(to: Vec2(cx, cy), at: t)
            rt.pointerDown(at: Vec2(cx, cy), at: t)
            for _ in 0..<30 {
                t += 1.0 / 120.0
                _ = rt.frame(at: t)
            }
            let heldEdges = edges(rt)
            #expect(near(heldEdges, held), "\(entry.how) held: \(heldEdges) vs \(held)")

            // Still hit at its resting corner while shrunk.
            t += 1.0 / 120.0
            rt.pointerUp(at: Vec2(entry.rest[2] - 0.2, entry.rest[3] - 0.2), at: t)
            _ = rt.frame(at: t)
            #expect(rt.state.pressed == 2, "\(entry.how): held press hits at resting rect")
        }
    }

    @Test("Changing static scale keeps the glyph atlas bounded and rasterizes crisp when settled")
    func glyphAtlasBoundsDuring1000FrameSweep() {
        let rt = Runtime<Float>(
            state: 1.0,
            viewport: Vec2(300, 200),
            pixelScale: 2.0
        ) { k, _ in
            col().size(300, 200)
                .child(
                    el().key("card").size(200, 80)
                        .scale(k)
                        .scaleMotion(Curve.instant)
                        .child(text("Hamburgefonstiv"))
                )
        }

        func isCrisp(_ rt: Runtime<Float>) -> Bool {
            let rf = rt.renderFrame(at: rt.currentTime)
            let gs = rf.instances.filter { $0.params.y == KIND_GLYPH }
            return !gs.isEmpty && gs.allSatisfy { $0.uv.z == 0.0 }
        }

        var t = 0.0
        _ = rt.frame(at: t)
        let restEntries = rt.textSystem.glyphAtlas.cachedEntryCount

        for i in 0..<1000 {
            let k = 0.5 + Float(i) * 0.0007
            rt.update(at: t) { s, _ in s = k }
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            #expect(i == 0 || !isCrisp(rt), "scale changing on step \(i) samples rest-size glyphs")
            if i % 100 == 99 {
                for _ in 0..<30 {
                    t += 1.0 / 120.0
                    _ = rt.frame(at: t)
                }
            }
        }

        let grown = rt.textSystem.glyphAtlas.cachedEntryCount - restEntries
        #expect(grown < 1000, "1,000 scales added \(grown) glyph entries")

        rt.update(at: t) { s, _ in s = 0.75 }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(!isCrisp(rt))
        for _ in 0..<30 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        #expect(isCrisp(rt), "once held still, text rasterizes crisp at the scaled size")
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(!rt.isAnimating, "and nothing keeps animating")
    }

    @Test("Held pressScale keeps hover at resting edge and cancels on wheel scroll or fling")
    func pressScaleCapturesRestingBoxAndSurvivesScrollCancel() {
        struct State {
            var pressed: [Int] = []
        }
        let rt = Runtime<State>(
            state: State(),
            viewport: Vec2(200, 200),
            pixelScale: 2.0
        ) { _, _ in
            var list: El<State> = col().key("list").wFull()
            for i in 0..<10 {
                list = list.child(
                    el().key("b\(i)").size(200, 40)
                        .hover(Color.oklcha(1.0, 0.0, 0.0, 0.1))
                        .pressScale(0.96)
                        .onClick { st, _ in st.pressed.append(i) }
                )
            }
            return col().size(200, 200)
                .child(col().key("scroll").size(200, 200).scrollY().child(list))
        }

        var t = 0.0
        _ = rt.frame(at: t)
        let b0 = rt.flatNodes.first(where: { $0.key == "b0" })!
        let rowId = b0.nodeId

        // Hold right edge (which 0.96x center-shrunk row no longer covers): stays hovered and fires onPress.
        rt.pointerMove(to: Vec2(199, 20), at: t)
        rt.pointerDown(at: Vec2(199, 20), at: t)
        for _ in 0..<30 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        #expect(abs((rt.scene.get(rowId, Props.PRESS_SCALE) ?? 1.0) - 0.96) < 1e-4)
        let hoverVal = rt.liveStore.get(Runtime<State>.hoverTrackId(rowId), Runtime<State>.hoverProp) ?? 0.0
        #expect(abs(hoverVal - 1.0) < 1e-4, "held row keeps its hover highlight")

        t += 1.0 / 120.0
        rt.pointerUp(at: Vec2(199, 20), at: t)
        _ = rt.frame(at: t)
        #expect(rt.state.pressed == [0])

        // Scrolling under held press cancels it and fires no press on release.
        for _ in 0..<60 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        rt.pointerMove(to: Vec2(100, 20), at: t)
        rt.pointerDown(at: Vec2(100, 20), at: t)
        for _ in 0..<10 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        #expect((rt.scene.get(rowId, Props.PRESS_SCALE) ?? 1.0) < 0.97)
        rt.wheel(WheelEvent(dx: 0, dy: -120), at: Vec2(100, 100), now: t)
        for _ in 0..<60 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        #expect(abs((rt.scene.get(rowId, Props.PRESS_SCALE) ?? 0.0) - 1.0) < 1e-3)
        t += 1.0 / 120.0
        rt.pointerUp(at: Vec2(100, 20), at: t)
        _ = rt.frame(at: t)
        #expect(rt.state.pressed == [0], "wheel scroll cancels press")

        // Fling cancels press as well.
        t += 1.0 / 120.0
        rt.pointerMove(to: Vec2(100, 20), at: t)
        rt.pointerDown(at: Vec2(100, 20), at: t)
        rt.fling(vy: 600, at: Vec2(100, 100), now: t)
        t += 1.0 / 120.0
        rt.pointerUp(at: Vec2(100, 20), at: t)
        _ = rt.frame(at: t)
        #expect(rt.state.pressed == [0], "fling cancels press")
    }

    @Test("pressScale shrinks children, bounces smoothly on release, responds to leave/re-enter, and turns off under reducedMotion")
    func pressedReleaseBouncesAndReducedMotionStaysStill() {
        let rt = Runtime<Int>(
            state: 0,
            viewport: Vec2(200, 200),
            pixelScale: 1.0
        ) { _, _ in
            col().size(200, 200)
                .child(
                    el().key("tile").size(100, 100).pressScale(0.96)
                        .onClick { st, _ in st += 1 }
                        .child(el().key("dot").size(10, 10))
                )
        }

        func info(_ runtime: Runtime<Int>, _ key: String) -> ElementInfo {
            runtime.elements().first(where: { $0.key == key })!
        }

        func settle(_ runtime: Runtime<Int>, clock: inout Double) {
            for _ in 0..<90 {
                clock += 1.0 / 120.0
                _ = runtime.frame(at: clock)
            }
        }

        var t = 0.0
        _ = rt.frame(at: t)
        let rest = info(rt, "tile")
        #expect(rest.scale == 1.0)

        rt.pointerMove(to: Vec2(99, 50), at: t)
        rt.pointerDown(at: Vec2(99, 50), at: t)
        settle(rt, clock: &t)

        let held = info(rt, "tile")
        #expect(abs(held.scale - 0.96) < 1e-4)
        #expect(held.target == rest.target)
        #expect(abs(held.rect[0] - 2.0) < 0.05 && abs(held.rect[2] - 96.0) < 0.05)
        #expect(abs(info(rt, "dot").scale - 0.96) < 1e-4, "children shrink with parent")

        // Leave resting box -> springs back to 1.0; re-enter -> shrinks from current scale.
        rt.pointerMove(to: Vec2(150, 50), at: t)
        settle(rt, clock: &t)
        #expect(abs(info(rt, "tile").scale - 1.0) < 1e-4)

        rt.pointerMove(to: Vec2(99, 50), at: t)
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        let returning = info(rt, "tile").scale
        #expect(returning < 1.0 && returning > 0.96)
        settle(rt, clock: &t)

        rt.pointerUp(at: Vec2(99, 50), at: t)
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        #expect(rt.state == 1)

        var last = info(rt, "tile").scale
        #expect(last > 0.96 && last < 1.0)
        var peak = last
        for _ in 0..<90 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            let s = info(rt, "tile").scale
            #expect(abs(s - last) < 0.01, "release step jumped: \(last) -> \(s)")
            peak = max(peak, s)
            last = s
        }
        #expect(abs(last - 1.0) < 1e-4)
        #expect(peak > 1.0)

        let rtReduced = Runtime<Int>(
            state: 0,
            viewport: Vec2(200, 200),
            pixelScale: 1.0,
            reducedMotion: true
        ) { _, _ in
            col().size(200, 200)
                .child(el().key("tile").size(100, 100).pressScale(0.96).child(el().key("dot").size(10, 10)))
        }
        var tr = 0.0
        _ = rtReduced.frame(at: tr)
        rtReduced.pointerMove(to: Vec2(50, 50), at: tr)
        rtReduced.pointerDown(at: Vec2(50, 50), at: tr)
        settle(rtReduced, clock: &tr)
        #expect(info(rtReduced, "tile").scale == 1.0)
    }

    @Test("Picture with one side set sizes the other from its image without animating")
    func pictureWithOneSideSizesOtherFromImage() {
        func makeRuntime(_ px: Pixels) -> Runtime<Pixels> {
            Runtime<Pixels>(
                state: px,
                viewport: Vec2(240, 600),
                pixelScale: 1.0
            ) { p, _ in
                col().w(240).itemsStart()
                    .child(el().key("w").w(120).pixels(p))
                    .child(el().key("h").h(30).pixelsFit(p, .fit))
                    .child(el().key("full").wFull().pixelsFit(p, .fill))
                    .child(el().key("box").size(100, 100).pixelsFit(p, .fit))
                    .child(el().key("neither").pixels(p))
                    .child(el().key("explicit").w(120).aspectRatio(4.0).pixels(p))
                    .child(el().key("plain").h(25).aspectRatio(2.0))
            }
        }

        func sizeOf(_ rt: Runtime<Pixels>, _ key: String) -> [Float] {
            let e = rt.elements().first(where: { $0.key == key })!
            return [e.target[2], e.target[3]]
        }

        let px = Pixels()
        let rt = makeRuntime(px)
        _ = rt.frame(at: 0.0)
        #expect(sizeOf(rt, "w") == [120, 0])
        #expect(sizeOf(rt, "explicit") == [120, 30])
        #expect(sizeOf(rt, "plain") == [50, 25])

        px.set(width: 4, height: 2, rgba: [UInt8](repeating: 255, count: 4 * 4 * 2))
        _ = rt.frame(at: 1.0 / 120.0)
        #expect(sizeOf(rt, "w") == [120, 60])
        #expect(sizeOf(rt, "h") == [60, 30])
        #expect(sizeOf(rt, "full") == [240, 120])
        #expect(sizeOf(rt, "box") == [100, 100])
        #expect(sizeOf(rt, "neither") == [0, 0])
        #expect(sizeOf(rt, "explicit") == [120, 30])
        let anyMoving = rt.elements().contains(where: { $0.moving })
        #expect(!anyMoving)

        px.set(width: 2, height: 4, rgba: [UInt8](repeating: 255, count: 4 * 2 * 4))
        _ = rt.frame(at: 2.0 / 120.0)
        #expect(sizeOf(rt, "w") == [120, 240])
        let commits = rt.commitCount
        for step in 3...6 {
            _ = rt.frame(at: Double(step) / 120.0)
        }
        #expect(rt.commitCount == commits, "unchanged image costs no commits")
        // A stream can publish a different resolution at the same aspect.
        px.set(width: 4, height: 8, rgba: [UInt8](repeating: 255, count: 4 * 4 * 8))
        _ = rt.frame(at: 7.0 / 120.0)
        #expect(rt.commitCount == commits)

        // Decode landing alongside explicit invalidate on same frame lands snapped at its new size.
        let px2 = Pixels()
        let rt2 = makeRuntime(px2)
        _ = rt2.frame(at: 0.0)
        px2.set(width: 4, height: 2, rgba: [UInt8](repeating: 255, count: 4 * 4 * 2))
        rt2.invalidate(at: 1.0 / 120.0)
        _ = rt2.frame(at: 1.0 / 120.0)
        let wEl = rt2.elements().first(where: { $0.key == "w" })!
        #expect(wEl.rect[3] == 60.0 && wEl.target[3] == 60.0)
        #expect(!wEl.moving)
        let box = rt2.elements().first(where: { $0.key == "box" })!
        #expect(box.moving && box.rect[1] < box.target[1])
    }

    @Test("Pictures derive the automatic side after point and percentage limits resolve")
    func constrainedPictureUsesItsClampedSide() throws {
        let pixels = Pixels()
        pixels.set(width: 44, height: 10, rgba: .init(repeating: 255, count: 44 * 10 * 4))
        let rt = Runtime(state: pixels, viewport: Vec2(696, 600), pixelScale: 2) { p, _ in
            col().wFull().itemsStart()
                .child(el().key("percent-max").wFull().maxW(176).pixels(p))
                .child(el().key("fixed-max").w(696).maxW(176).pixels(p))
                .child(el().key("percent-min").wFrac(0.1).minW(176).pixels(p))
                .child(el().key("fixed-min").w(60).minW(176).pixels(p))
                .child(el().key("vertical").hFull().maxH(40).pixels(p))
                .child(el().key("explicit").w(696).maxW(176).aspectRatio(2).pixels(p))
                .child(el().key("padded-width").wFull().maxW(176).p(8).pixels(p))
                .child(el().key("padded-height").hFull().maxH(40).p(8).pixels(p))
        }
        _ = rt.frame(at: 0)
        let infos = rt.elements()
        for (index, key) in ["percent-max", "fixed-max", "percent-min", "fixed-min", "vertical"].enumerated() {
            let box = try #require(infos.first { $0.key == key })
            #expect(box.target == [0, Float(index) * 40, 176, 40])
        }
        let explicit = try #require(infos.first { $0.key == "explicit" })
        #expect(explicit.target == [0, 200, 176, 88])
        let paddedWidth = try #require(infos.first { $0.key == "padded-width" })
        let paddedHeight = try #require(infos.first { $0.key == "padded-height" })
        #expect(paddedWidth.target == [0, 288, 176, 56])
        #expect(paddedHeight.target == [0, 344, 192, 40])

        pixels.set(width: 22, height: 10, rgba: .init(repeating: 255, count: 22 * 10 * 4))
        _ = rt.frame(at: 1.0 / 120)
        let updated = try #require(rt.elements().first { $0.key == "percent-max" })
        #expect(updated.target == [0, 0, 176, 80])
    }

    @Test("Editable and plain text use the same intrinsic width in mixed-height rows")
    func intrinsicFieldMeasuresLikeItsText() throws {
        struct Fields {
            var filled = TextEdit("xx")
            var empty = TextEdit("")
        }
        for scale: Float in [1, 2] {
            let rt = Runtime(state: Fields(), viewport: Vec2(696, 600), pixelScale: scale) { _, _ in
                let small = TextStyle(size: 14, lineHeight: 20)
                let large = TextStyle(size: 22, lineHeight: 30)
                let line: El<Fields> = row().itemsEnd()
                    .child(text("xx").font(small).key("plain"))
                    .child(textInput(key: "filled", \.filled).font(small).singleLine())
                    .child(text(" ").font(small).key("space"))
                    .child(textInput(key: "empty", \.empty).font(small).singleLine())
                    .child(text("xx").font(large).key("large"))
                    .child(text("xx\nxx").font(small).key("multiline"))
                return col().wFull().itemsStart().child(line)
            }
            _ = rt.frame(at: 0)
            let nodes = rt.elements()
            func rect(_ key: String) throws -> [Float] {
                try #require(nodes.first { $0.key == key }).target
            }
            let plain = try rect("plain"), filled = try rect("filled")
            let space = try rect("space"), empty = try rect("empty")
            #expect(filled[2] == plain[2])
            #expect(empty[2] == space[2])
            #expect(filled[1] == 20 && empty[1] == 20)
            #expect(try rect("large")[1] == 10)
            #expect(try rect("multiline")[3] == 40)
        }
    }

    @Test("Picture set mid-frame keeps livePending armed and wakes another frame to size it")
    func pictureSetMidFrameWakesAnotherFrameToSizeIt() {
        final class WakeBox: @unchecked Sendable {
            var count = 0
        }
        let wakes = WakeBox()
        let px = Pixels()
        let rt = Runtime<Pixels>(
            state: px,
            viewport: Vec2(240, 600),
            pixelScale: 1.0
        ) { p, _ in
            col().w(240).itemsStart().child(el().key("w").w(120).pixels(p))
        }
        rt.setLiveWaker { wakes.count += 1 }

        func height() -> Float {
            rt.elements().first(where: { $0.key == "w" })!.target[3]
        }

        _ = rt.frame(at: 0.0)
        #expect(height() == 0.0)

        rt.invalidate(at: 1.0 / 120.0)
        RuntimeMidFrameHook.$current.withValue({
            px.set(width: 4, height: 2, rgba: [UInt8](repeating: 255, count: 4 * 4 * 2))
        }) {
            _ = rt.frame(at: 1.0 / 120.0)
        }
        let animating = rt.isAnimating
        #expect(!animating)
        #expect(wakes.count == 1)
        #expect(rt.livePending, "mid-frame set's wake outlives the frame it landed in")

        _ = rt.frame(at: 2.0 / 120.0)
        #expect(height() == 60.0)
        #expect(!rt.livePending)
    }

    @Test("Picture removed outright unsubscribes in the frame that removes it")
    func pictureRemovedOutrightStopsWakingInFrameThatRemovesIt() {
        final class WakeBox: @unchecked Sendable {
            var count = 0
        }
        let wakes = WakeBox()
        let px = Pixels()
        let rt = Runtime<(px: Pixels, show: Bool)>(
            state: (px, true),
            viewport: Vec2(8, 8),
            pixelScale: 1.0
        ) { s, _ in
            let root: El<(px: Pixels, show: Bool)> = el().size(8, 8)
            return s.show ? root.child(el().key("pic").size(4, 4).pixels(s.px)) : root
        }
        rt.setLiveWaker { wakes.count += 1 }

        _ = rt.frame(at: 0.0)
        rt.update(at: 0.0) { s, tx in
            s.show = false
            tx.settle()
        }
        let beforeWakes = wakes.count
        RuntimeMidFrameHook.$current.withValue({
            px.set(width: 1, height: 1, rgba: [255, 255, 255, 255])
        }) {
            _ = rt.frame(at: 1.0 / 120.0)
        }
        #expect(wakes.count == beforeWakes, "unmounted before mid-frame set")
        #expect(!rt.livePending)
    }

    @Test("Exiting direct Pixels and Pixels nested inside an exiting element both wake until exit ends")
    func exitingPixelsKeepsLiveSubscription() {
        final class WakeBox: @unchecked Sendable {
            var count = 0
        }
        let wakes = WakeBox()
        let direct = Pixels()
        let child = Pixels()

        let rt = Runtime<(direct: Pixels, child: Pixels, show: Bool)>(
            state: (direct, child, true),
            viewport: Vec2(20, 20),
            pixelScale: 1.0
        ) { s, _ in
            let root: El<(direct: Pixels, child: Pixels, show: Bool)> = el().size(20, 20)
            guard s.show else { return root }
            return root
                .child(el().key("direct").size(4, 4).pixels(s.direct).transition(.opacity))
                .child(
                    el().key("card").size(8, 8).transition(.opacity)
                        .child(el().key("child").size(4, 4).pixels(s.child))
                )
        }
        rt.setLiveWaker { wakes.count += 1 }

        var t = 0.0
        _ = rt.frame(at: t)
        rt.update(at: t) { s, _ in s.show = false }
        _ = rt.frame(at: t)
        #expect(rt.isAnimating, "exit runs")

        direct.set(width: 1, height: 1, rgba: [1, 1, 1, 1])
        #expect(wakes.count == 1, "exiting direct picture wakes")

        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        child.set(width: 1, height: 1, rgba: [1, 1, 1, 1])
        #expect(wakes.count == 2, "picture inside an exiting element wakes")

        for _ in 0..<240 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            if !rt.isAnimating { break }
        }
        #expect(!rt.elements().contains(where: { $0.key == "child" }), "exit ended")

        direct.set(width: 1, height: 1, rgba: [2, 2, 2, 2])
        child.set(width: 1, height: 1, rgba: [2, 2, 2, 2])
        #expect(wakes.count == 2, "gone pictures stay asleep")
        #expect(!rt.livePending)
    }
}
