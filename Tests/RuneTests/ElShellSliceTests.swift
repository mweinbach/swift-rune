import Testing
import Foundation
@testable import Rune
@testable import RuneMotion
@testable import RuneRef

private let cRed = Color(r: 1, g: 0, b: 0, a: 1)
private let cGreen = Color(r: 0, g: 1, b: 0, a: 1)
private let cBlue = Color(r: 0, g: 0, b: 1, a: 1)

@Suite("El Slice 1 (shell) Parity Tests: motion, pills, text, visuals")
struct ElShellSliceTests {
    // MARK: - el/motion.rs builders & partial items

    @Test("paintOrder reorders siblings in paint & hit-test within parent layer/clip scope")
    func paintOrderReordersSiblingsInPaintAndHitTest() throws {
        struct State {
            var hits: [String] = []
        }
        let rt = Runtime(state: State(), viewport: Vec2(200, 120), pixelScale: 1.0) { _, _ in
            row().size(120, 80).children([
                col().key("frontByPaintOrder")
                    .bg(cRed)
                    .paintOrder(10)
                    .size(60, 60)
                    .onClick { s, _ in s.hits.append("front") },
                col().key("backByDefault")
                    .bg(cBlue)
                    .size(60, 60)
                    .offset(-60, 0)
                    .onClick { s, _ in s.hits.append("back") },
            ])
        }
        _ = rt.frame(at: 0.0)
        // Lower paintOrder ("backByDefault", z=0) paints first; higher paintOrder ("frontByPaintOrder", z=10) paints second (top).
        let backIdx = try #require(rt.paintOrderPaths.firstIndex(where: { $0.contains("backByDefault") }))
        let frontIdx = try #require(rt.paintOrderPaths.firstIndex(where: { $0.contains("frontByPaintOrder") }))
        #expect(backIdx < frontIdx)

        // Click overlap center hits frontByPaintOrder first
        let fRect = try #require(rt.element(byKey: "frontByPaintOrder")?.rect)
        let cx = fRect[0] + fRect[2] * 0.5
        let cy = fRect[1] + fRect[3] * 0.5
        rt.pointerDown(at: Vec2(cx, cy), at: 0.1)
        rt.pointerUp(at: Vec2(cx, cy), at: 0.12)
        _ = rt.frame(at: 0.12)
        #expect(rt.state.hits == ["front"])
    }

    @Test("lead springs leading and trailing layout edges differently when moving")
    func leadSpringsLeadingAndTrailingEdges() throws {
        struct State { var wide: Bool = false }
        let fastLead = Spring(duration: 0.12, bounce: 0.0)
        let slowTrail = Spring(duration: 0.55, bounce: 0.0)
        let rt = Runtime(state: State(), viewport: Vec2(300, 100), pixelScale: 1.0) { s, _ in
            col().wFull().hFull().children([
                col().key("pill")
                    .bg(.white)
                    .h(24)
                    .w(s.wide ? 220 : 60)
                    .offset(s.wide ? 40 : 0, 0)
                    .lead(fastLead, slowTrail)
            ])
        }
        _ = rt.frame(at: 0.0)
        let first = try #require(rt.element(byKey: "pill")?.rect)
        #expect(abs(first[2] - 60) < 0.5)

        rt.update { s, _ in s.wide = true }
        _ = rt.frame(at: 0.01)
        _ = rt.frame(at: 0.08)
        let mid = try #require(rt.element(byKey: "pill")?.rect)
        #expect(mid[2] > 60 && mid[2] < 220)
        _ = rt.frame(at: 1.8)
        let settled = try #require(rt.element(byKey: "pill")?.rect)
        #expect(abs(settled[2] - 220) < 0.5)
    }

    @Test("MotionIntent bitflags, combinations, tokenMotion, animatedChanges, sequence, and tracing metadata")
    func motionIntentAndMotionPartialBuilders() throws {
        let b: MotionIntent = .bounce
        #expect(b.contains(.overshoot))
        #expect(b.contains(.recoil))
        #expect(b.contains(.jiggle))
        #expect(!b.contains(.impulse))

        let k: MotionIntent = .kick
        #expect(k.contains(.bounce))
        #expect(k.contains(.impulse))

        let t: MotionIntent = .typing
        #expect(t.contains(.step))
        #expect(t.contains(.cut))
        #expect(MotionIntent.none.isEmpty)
        #expect(MotionIntent(rawValue: k.rawValue) == .kick)
        #expect(MotionIntent.overshoot.union(.cut).contains(.cut))

        struct State { var toggled = false }
        let seq = MotionSequence(frames: [
            Beat(at: 0.0, opacity: 1.0, scale: 1.0),
            Beat(at: 0.1, opacity: 0.4, scale: 0.9),
        ])
        let rt = Runtime(state: State(), viewport: Vec2(200, 100), pixelScale: 1.0) { s, _ in
            col().traceNamespace("shell", "motion").children([
                col().key("card")
                    .traceName("motion-card")
                    .bg(s.toggled ? cRed : cBlue)
                    .size(s.toggled ? 120 : 60, 40)
                    .tokenMotion(MotionTokens.SNAPPY)
                    .animatedChanges()
                    .sequence(seq)
            ])
        }
        _ = rt.frame(at: 0.0)
        #expect(try #require(rt.element(byKey: "card")?.rect[2]) == 60)

        rt.update { s, _ in s.toggled = true }
        _ = rt.frame(at: 0.05)
        let midW = try #require(rt.element(byKey: "card")?.rect[2])
        #expect(midW > 60 && midW < 120)
        _ = rt.frame(at: 1.2)
        let settledW = try #require(rt.element(byKey: "card")?.rect[2])
        #expect(abs(settledW - 120) < 0.5)
    }

    // MARK: - el/text.rs builders & partial items

    @Test("spanRadius customizes rounded RichSpan background chip corner radius")
    func spanRadiusAppliesToSpanBackgroundQuads() {
        let rt = Runtime(state: (), viewport: Vec2(260, 80), pixelScale: 2.0) { _, _ in
            col().gap(8).children([
                rich("Hello badge", [RichSpan(6..<11).bg(cBlue).color(.white)])
                    .key("sharp")
                    .spanRadius(1.5),
                rich("Hello badge", [RichSpan(6..<11).bg(cBlue).color(.white)])
                    .key("pillish")
                    .spanRadius(7.0),
            ])
        }
        let scene = rt.frame(at: 0.0)
        let bgPrims = scene.primitives.filter { prim in
            prim.params.y == Float(PrimitiveKind.roundedRect.rawValue) && prim.fill.z > 0.5 && prim.fill.w > 0.5
        }
        #expect(bgPrims.count >= 2)
        // pxScale == 2.0 -> 1.5*2 = 3.0 and 7.0*2 = 14.0
        #expect(bgPrims.contains { abs($0.radii.x - 3.0) < 0.25 })
        #expect(bgPrims.contains { abs($0.radii.x - 14.0) < 0.25 })

        let rf = rt.renderFrame(at: 0.0)
        let rfBg = rf.instances.filter { $0.params.y == KIND_RECT && $0.fill.z > 0.5 && $0.fill.w > 0.5 }
        #expect(rfBg.contains { abs($0.radii.x - 3.0) < 0.25 })
        #expect(rfBg.contains { abs($0.radii.x - 14.0) < 0.25 })
    }

    @Test("spanRings batch-applies inset border rings onto background-bearing spans")
    func spanRingsAppliesBatchRingsToBackgroundSpans() {
        let bgChip = Color(r: 0.2, g: 0.2, b: 0.2, a: 1)
        let rt = Runtime(state: (), viewport: Vec2(320, 80), pixelScale: 1.0) { _, _ in
            rich("alpha beta gamma", [
                RichSpan(0..<5).bg(bgChip),
                RichSpan(6..<10).bg(bgChip),
            ])
            .spanRings([
                (0..<5, cGreen, 2.0),
                (6..<10, cRed, 1.5),
                (11..<16, cBlue, 2.0), // ignored: no bg on 11..<16
            ])
        }
        let scene = rt.frame(at: 0.0)
        let rectKind = Float(PrimitiveKind.roundedRect.rawValue)
        let ringPrims = scene.primitives.filter { prim in
            prim.params.y == rectKind && prim.params.x > 0 && prim.border.w > 0.5
        }
        #expect(ringPrims.count == 2)
        let hasGreenRing = ringPrims.contains { prim in
            prim.border.y > 0.8 && prim.border.x < 0.1 && abs(prim.params.x - 2.0) < 0.05
        }
        let hasRedRing = ringPrims.contains { prim in
            prim.border.x > 0.8 && prim.border.y < 0.1 && abs(prim.params.x - 1.5) < 0.05
        }
        #expect(hasGreenRing)
        #expect(hasRedRing)

        let rf = rt.renderFrame(at: 0.0)
        let rfRings = rf.instances.filter { inst in
            inst.params.y == KIND_RECT && inst.params.x > 0 && inst.border.w > 0.5
        }
        #expect(rfRings.count == 2)
    }

    @Test("strike and strikes emit strikethrough quads with explicit, inherited span, or text colors")
    func strikeAndStrikesEmitCorrectQuads() {
        let rt = Runtime(state: (), viewport: Vec2(320, 80), pixelScale: 1.0) { _, _ in
            rich("alpha beta gamma", [RichSpan(6..<10).color(cGreen)])
                .color(cBlue)
                .strike(0..<5, cRed)          // explicit red
                .strikes([(6..<10, nil),      // inherits green from span
                          (11..<16, nil)])    // inherits blue default text color
        }
        let scene = rt.frame(at: 0.0)
        let strikeRects = scene.primitives.filter { prim in
            prim.params.y == Float(PrimitiveKind.roundedRect.rawValue) && prim.rect.w > 0.5 && prim.rect.w <= 3.0
        }
        #expect(strikeRects.count == 3)
        #expect(strikeRects.contains { $0.fill.x > 0.8 && $0.fill.y < 0.1 })
        #expect(strikeRects.contains { $0.fill.y > 0.8 && $0.fill.x < 0.1 })
        #expect(strikeRects.contains { $0.fill.z > 0.8 && $0.fill.x < 0.1 })

        let rf = rt.renderFrame(at: 0.0)
        let rfStrikes = rf.instances.filter { $0.params.y == KIND_RECT && $0.rect.w > 0.5 && $0.rect.w <= 3.0 }
        #expect(rfStrikes.count == 3)
    }

    @Test("decorations works on both static rich text and editable textInput")
    func decorationsWorksOnStaticAndTextInput() {
        struct State {
            var edit = TextEdit("hello world", multiline: false)
        }
        let rt = Runtime(state: State(), viewport: Vec2(300, 120), pixelScale: 1.0) { _, _ in
            col().gap(8).children([
                text("hello static").decorations([RichSpan(0..<5).bg(cRed)]),
                textInput(key: "inp", \State.edit).decorations([RichSpan(0..<5).bg(cGreen)]),
            ])
        }
        let scene = rt.frame(at: 0.0)
        let redChip = scene.primitives.contains {
            $0.params.y == Float(PrimitiveKind.roundedRect.rawValue) && $0.fill.x > 0.8 && $0.fill.w > 0.5
        }
        #expect(redChip)
        let inpEl = rt.renderNode(forKey: "inp")
        #expect((inpEl?.runtimeExtras["inputDecorations"] as? [RichSpan])?.count == 1)
    }

    @Test("wrapAnywhere and wraps break unbroken long tokens cleanly inside constrained width")
    func wrapAnywhereAndWraps() throws {
        let longURL = "https://example.com/a/very/long/unbroken/path/segment/for/wrapping"
        let wrappedEl: El<Void> = text(longURL).wrapAnywhere(true)
        let unwrappedEl: El<Void> = text(longURL).noWrap()
        let disabledEl: El<Void> = text(longURL).noWrap().wrapAnywhere(false)
        #expect(wrappedEl.wraps())
        #expect(!unwrappedEl.wraps())
        #expect(!disabledEl.wraps())

        let rt = Runtime(state: (), viewport: Vec2(120, 200), pixelScale: 1.0) { _, _ in
            col().w(110).children([
                text(longURL).key("t").font(TextStyle(size: 14)).wrapAnywhere()
            ])
        }
        _ = rt.frame(at: 0.0)
        let r = try #require(rt.element(byKey: "t")?.rect)
        #expect(r[2] <= 110.5)
        #expect(r[3] > 30.0)
    }

    @Test("reveal(wordFade:) fades words gradually over time and supports streaming appends")
    func revealWordFadeGradualAndStreaming() {
        struct MountState {
            var show = false
            var body = "Alpha beta gamma delta"
        }
        let rt = Runtime(state: MountState(), viewport: Vec2(320, 120), pixelScale: 1.0) { s, _ in
            let kids: [El<MountState>] = s.show ? [
                text(s.body).key("stream").color(.white).reveal(wordFade: 0.20)
            ] : []
            return col().children(kids)
        }
        _ = rt.frame(at: 0.0)

        // Mount at t = 0.05 -> Phase is .entering; later words start staggered and fade in gradually
        rt.update { s, _ in s.show = true }
        let fStart = rt.frame(at: 0.05)
        let glyphsAtStart = fStart.primitives.filter { $0.params.y == Float(PrimitiveKind.glyph.rawValue) }
        #expect(glyphsAtStart.count < 18)
        #expect(rt.isAnimating)

        // Advance well past stagger + fade (0.20s + ~0.08s) -> all words fully opaque
        let fDone = rt.frame(at: 0.60)
        let glyphsWhenDone = fDone.primitives.filter { $0.params.y == Float(PrimitiveKind.glyph.rawValue) }
        #expect(glyphsWhenDone.count >= 18)
        #expect(glyphsWhenDone.allSatisfy { $0.fill.w > 0.98 })

        // Append more words while keeping earlier ones shown
        rt.update { s, _ in s.body.append(" epsilon zeta") }
        let fAppend = rt.frame(at: 0.61)
        let glyphsAfterAppend = fAppend.primitives.filter { $0.params.y == Float(PrimitiveKind.glyph.rawValue) }
        #expect(glyphsAfterAppend.count >= glyphsWhenDone.count && glyphsAfterAppend.count < 30)

        let fFinal = rt.frame(at: 1.50)
        let finalGlyphs = fFinal.primitives.filter { $0.params.y == Float(PrimitiveKind.glyph.rawValue) }
        #expect(finalGlyphs.count >= 28)
        #expect(!rt.isAnimating)
    }

    @Test("textHighlights, caret, selectionColor, justify, and placeholder behave in layout & render")
    func textPartialBuildersCoverage() throws {
        struct State {
            var edit = TextEdit("", multiline: false)
            var selEdit: TextEdit = {
                var e = TextEdit("select me", multiline: false)
                e.selectAll()
                return e
            }()
        }
        let hlBg = Color(r: 1, g: 0.8, b: 0, a: 0.9)
        let selCol = Color(r: 0.9, g: 0.1, b: 0.4, a: 0.8)
        let caretCol = Color(r: 0.1, g: 0.9, b: 0.2, a: 1.0)
        let grayCol = Color(r: 0.5, g: 0.5, b: 0.5, a: 1.0)
        let rt = Runtime(state: State(), viewport: Vec2(320, 180), pixelScale: 1.0) { _, _ in
            col().gap(8).children([
                text("highlight and justify target line with multiple words")
                    .key("hl")
                    .w(200)
                    .justify(true)
                    .textHighlights([TextHighlight(0..<9, bg: hlBg, fg: .black)]),
                textInput(key: "emptyInp", \State.edit)
                    .w(200)
                    .placeholder("Type here...", color: grayCol)
                    .caret(caretCol)
                    .selectionColor(selCol),
                textInput(key: "selInp", \State.selEdit)
                    .w(200)
                    .caret(caretCol)
                    .selectionColor(selCol),
            ])
        }
        rt.update { _, tx in tx.focus("selInp") }
        let scene = rt.frame(at: 0.0)
        let hlQuads = scene.primitives.filter {
            $0.params.y == Float(PrimitiveKind.roundedRect.rawValue) && $0.fill.x > 0.8 && $0.fill.y > 0.5 && $0.fill.z < 0.2
        }
        #expect(!hlQuads.isEmpty)

        let expectedSel = selCol.simd4(srgb: rt.srgbBlend)
        let selQuads = scene.primitives.filter {
            $0.params.y == Float(PrimitiveKind.roundedRect.rawValue)
                && abs($0.fill.x - expectedSel.x) < 0.02
                && abs($0.fill.y - expectedSel.y) < 0.02
                && abs($0.fill.z - expectedSel.z) < 0.02
                && abs($0.fill.w - expectedSel.w) < 0.02
        }
        let placeholderNode = rt.renderNode(forKey: "emptyInp")
        #expect(placeholderNode?.placeholder == "Type here...")
        #expect(rt.focusedKey == "selInp")
        #expect(rt.renderNode(forKey: "selInp")?.selectionColor == selCol)
        #expect(!selQuads.isEmpty)
        #expect(rt.element(byKey: "hl") != nil)
    }

    // MARK: - el/pills.rs & src/el/pills/tests.rs #6 and #8

    @Test("El.pills, InlineIcon.color, pill test #6 selection+copy, pill test #8 streaming & bad ranges")
    func pillsBuildersAndTests6And8() throws {
        let accent = Color(r: 0, g: 0.8, b: 1, a: 1)
        let icon = SVGIcon(viewBox: 16, paths: ["M2 8h12"])
        let coloredIcon = InlineIcon.glyph(icon).color(cRed)
        #expect(coloredIcon.color == cRed)

        let pilledStyleNode: El<Void> = text("ping @alice now").pills([(5..<11, PillStyle.default.color(accent))])
        #expect(pilledStyleNode.pillChips.count == 1)

        // Pill test #6: a_selection_and_copy_across_a_pill_give_its_label_text
        struct PillState {
            var body = "ask @reviewer to look"
            var pills: [Range<Int>] = [4..<13]
        }
        let rt6 = Runtime(state: PillState(), viewport: Vec2(400, 100), pixelScale: 1.0) { s, _ in
            col().p(8).children([
                text(s.body)
                    .key("t")
                    .selectable()
                    .pills(s.pills.map { PillChip($0, style: PillStyle.default) })
            ])
        }
        _ = rt6.frame(at: 0.0)
        let rect6 = try #require(rt6.element(byKey: "t")?.rect)
        let midY = rect6[1] + rect6[3] * 0.5
        rt6.pointerDown(at: Vec2(rect6[0] + 1, midY), at: 0.1)
        rt6.pointerMove(to: Vec2(rect6[0] + rect6[2] - 1, midY), at: 0.12)
        rt6.pointerUp(at: Vec2(rect6[0] + rect6[2] - 1, midY), at: 0.14)
        _ = rt6.frame(at: 0.14)

        #expect(rt6.selectedText() == "ask @reviewer to look")
        let selHandled = rt6.keyDown(KeyEvent(key: .command("c"), mods: Mods(cmd: true)), at: 0.16)
        _ = rt6.frame(at: 0.16)
        #expect(selHandled)
        #expect(rt6.clipboard.text == "ask @reviewer to look")

        // Pill test #8: pills_survive_streaming_appends_and_bad_ranges_are_ignored
        struct StreamState {
            var body = "ask @reviewer"
            var pills: [Range<Int>] = [4..<13]
        }
        let rt8 = Runtime(state: StreamState(), viewport: Vec2(400, 100), pixelScale: 1.0) { s, _ in
            col().children([
                text(s.body)
                    .key("t")
                    .pills(s.pills.map { PillChip($0, style: PillStyle.default) })
            ])
        }
        _ = rt8.frame(at: 0.0)
        var prevW = try #require(rt8.element(byKey: "t")?.rect[2])
        for more in [" to", " look at", " the é diff"] {
            rt8.update { s, _ in s.body.append(more) }
            _ = rt8.frame(at: 0.02)
            let n = try #require(rt8.renderNode(forKey: "t"))
            #expect(n.pillChips.count == 1)
            #expect(n.pillChips[0].range == 4..<13)
            let curW = try #require(rt8.element(byKey: "t")?.rect[2])
            #expect(curW >= prevW)
            prevW = curW
        }
        let eByte = rt8.state.body.utf8.distance(from: rt8.state.body.utf8.startIndex, to: rt8.state.body.firstIndex(of: "é")!.samePosition(in: rt8.state.body.utf8)!)
        rt8.update { s, _ in
            s.pills = [4..<13, (eByte + 1)..<(eByte + 2), 30..<400, 20..<20]
        }
        let fBad = rt8.frame(at: 0.04)
        // Only the one valid pill emits a pill background quad
        let pillQuadsBad = fBad.primitives.filter { $0.params.y == Float(PrimitiveKind.roundedRect.rawValue) }
        #expect(pillQuadsBad.count == 1)

        rt8.update { s, _ in s.body = String(s.body.prefix(8)) }
        let fShort = rt8.frame(at: 0.06)
        let pillQuadsShort = fShort.primitives.filter { $0.params.y == Float(PrimitiveKind.roundedRect.rawValue) }
        #expect(pillQuadsShort.isEmpty)
    }

    // MARK: - el/visuals.rs builders & partial items

    @Test("shadow(y:blur:color:), outline, corners, borderSides, blurMotion, pressScale, clipSoft, clipCorners, hoverMotion, hoverWithinCurves")
    func visualsBuildersAndPartials() throws {
        let outlineColor = cGreen
        let boxFill = cRed
        let enterCurve = Anim<Float>(curve: .tween(duration: 0.15, easing: .easeOut))
        let exitCurve = Anim<Float>(curve: .tween(duration: 0.2, easing: .easeIn))
        let rt = Runtime(state: (), viewport: Vec2(320, 200), pixelScale: 2.0) { _, _ in
            col().gap(10).children([
                col().key("outlined")
                    .size(60, 40)
                    .bg(boxFill)
                    .corners(2, 4, 6, 8)
                    .borderSides(top: 1, right: 2, bottom: 3, left: 4, color: .white)
                    .shadow(y: 4, blur: 8, color: Color(r: 0, g: 0, b: 0, a: 0.5))
                    .outline(width: 2, offset: 3, color: outlineColor)
                    .blurMotion(MotionTokens.SNAPPY)
                    .pressScale(0.95)
                    .hoverMotion(MotionTokens.SNAPPY, MotionTokens.SMOOTH),
                col().key("softClip")
                    .size(40, 40)
                    .clip()
                    .clipSoft(4)
                    .clipCorners(Corners(2, 4, 6, 8))
                    .hoverMotionWithin(enterCurve, exitCurve),
            ])
        }
        let scene = rt.frame(at: 0.0)
        #expect(scene.primitives.contains { $0.params.y == Float(PrimitiveKind.dropShadow.rawValue) && abs($0.params.x - 16.0) < 0.5 })
        // Crisp outline quad outside 60x40@2x = 120x80 box: ow=4, off=6 -> g=10 -> w=140, h=100
        let outlinePrim = scene.primitives.first {
            $0.params.y == Float(PrimitiveKind.roundedRect.rawValue) && abs($0.rect.z - 140) < 0.5 && abs($0.rect.w - 100) < 0.5 && $0.border.y > 0.8
        }
        #expect(outlinePrim != nil)
        #expect(abs((outlinePrim?.params.x ?? 0) - 4.0) < 0.25)

        let rf = rt.renderFrame(at: 0.0)
        let rfOutline = rf.instances.first {
            $0.params.y == KIND_RECT && abs($0.rect.z - 140) < 0.5 && $0.border.y > 0.8
        }
        #expect(rfOutline != nil)

        let boxPrim = scene.primitives.first {
            $0.params.y == Float(PrimitiveKind.roundedRect.rawValue) && abs($0.rect.z - 120) < 0.5 && abs($0.rect.w - 80) < 0.5 && $0.fill.x > 0.8
        }
        #expect(boxPrim?.radii == SIMD4<Float>(4, 8, 12, 16))
        #expect((boxPrim?.border.x ?? 0) > 0.99 && (boxPrim?.border.w ?? 0) > 0.99)
        #expect(boxPrim?.params.x == -1.0)
        #expect(boxPrim?.uv == SIMD4<Float>(2, 4, 6, 8))

        let clipNode = try #require(rt.renderNode(forKey: "softClip"))
        #expect(clipNode.hoverWithinCurves() != nil)
        #expect(clipNode.clipFade == SIMD4<Float>(4, 4, 4, 4))
        #expect(clipNode.clipCorners == Corners(2, 4, 6, 8))
        let outlinedNode = try #require(rt.renderNode(forKey: "outlined"))
        #expect(outlinedNode.elOutline == Outline(width: 2, offset: 3, color: outlineColor))
        #expect(outlinedNode.corners == Corners(2, 4, 6, 8))
        #expect(outlinedNode.borderSides == Sides(top: 1, right: 2, bottom: 3, left: 4))
        #expect(outlinedNode.pressScaleFactor == 0.95)
        #expect(outlinedNode.hoverMotionSpec != nil)
        let blurNoneNode: El<Void> = col().blurMotion(.none)
        #expect(blurNoneNode.runtimeExtras.values.contains { ($0 as? Bool) == true })
        #expect(outlinedNode.runtimeExtras.values.contains { ($0 as? Bool) == false })
    }

    @Test("dim applies only to existing children without paint-time propagation; layerOpacity opens one layer for subtrees")
    func dimVsLayerOpacitySemantics() throws {
        let rt = Runtime(state: (), viewport: Vec2(280, 120), pixelScale: 1.0) { _, _ in
            row().gap(10).children([
                col().key("dimGroup").children([
                    col().key("dimChildA").bg(cRed).size(40, 40),
                    col().key("dimChildB").bg(cRed).size(20, 20).offset(5, -10),
                ]).dim(0.4),
                col().key("dimBeforeChildren").bg(cBlue).size(20, 20).dim(0.4).children([
                    col().key("childAddedAfterDim").bg(cGreen).size(15, 15),
                ]),
                col().key("layerGroup").layerOpacity(0.4).children([
                    col().key("layerChildA").bg(cBlue).size(40, 40),
                    col().key("layerChildB").bg(cGreen).size(20, 20).offset(-30, 10),
                ]),
            ])
        }
        let scene = rt.frame(at: 0.0)
        let rf = rt.renderFrame(at: 0.0)

        let layers = scene.primitives.filter { $0.params.y == Float(PrimitiveKind.layerBegin.rawValue) }
        #expect(layers.count == 1)
        #expect(abs((layers.first?.params.x ?? 0) - 0.4) < 0.02)

        // Children built before .dim(0.4) get 0.4 once (not 0.16 from double application).
        let redBoxes = scene.primitives.filter { $0.params.y == Float(PrimitiveKind.roundedRect.rawValue) && $0.fill.x > 0.8 }
        #expect(redBoxes.count == 2)
        #expect(redBoxes.allSatisfy { abs($0.fill.w - 0.4) < 0.02 })

        // Verify both RenderFrame and Scene: blue boxes are the dimmed parent (0.4) and layered child (1.0),
        // green boxes are the child added after .dim(0.4) (1.0, no paint-time propagation) and layered child (1.0).
        let blueBoxes = scene.primitives.filter { $0.params.y == Float(PrimitiveKind.roundedRect.rawValue) && $0.fill.z > 0.8 }
        #expect(blueBoxes.count == 2)
        #expect(blueBoxes.contains { abs($0.fill.w - 0.4) < 0.02 })
        #expect(blueBoxes.contains { abs($0.fill.w - 1.0) < 0.02 })

        let greenBoxes = scene.primitives.filter { $0.params.y == Float(PrimitiveKind.roundedRect.rawValue) && $0.fill.y > 0.8 }
        #expect(greenBoxes.count == 2)
        #expect(greenBoxes.allSatisfy { abs($0.fill.w - 1.0) < 0.02 })

        let rfRedBoxes = rf.instances.filter { $0.params.y == KIND_RECT && $0.fill.x > 0.35 && $0.fill.y < 0.05 && $0.fill.z < 0.05 }
        #expect(rfRedBoxes.count == 2)
        #expect(rfRedBoxes.allSatisfy { abs($0.fill.w - 0.4) < 0.02 })

        let rfGreenBoxes = rf.instances.filter { $0.params.y == KIND_RECT && $0.fill.y > 0.8 && $0.fill.x < 0.05 && $0.fill.z < 0.05 }
        #expect(rfGreenBoxes.count == 2)
        #expect(rfGreenBoxes.allSatisfy { abs($0.fill.w - 1.0) < 0.02 })

        let rfLayers = rf.instances.filter { $0.params.y == KIND_LAYER }
        #expect(rfLayers.count == 1)
    }

    @Test("mark tags render instances and propagates to descendants unless overridden")
    func markTagsInstancesAndOverrides() {
        let rt = Runtime(state: (), viewport: Vec2(200, 120), pixelScale: 1.0) { _, _ in
            col().mark(0xABCD).children([
                col().key("a").bg(cRed).size(30, 30),
                col().key("b").mark(0x1234).bg(cGreen).size(30, 30),
            ])
        }
        let rf = rt.renderFrame(at: 0.0)
        #expect(rf.marks.count == rf.instances.count)
        #expect(rf.marks.contains(0xABCD))
        #expect(rf.marks.contains(0x1234))
    }

    @Test("timeScale scales subtree springs and word reveal clocks independently and freezes at 0.0")
    func timeScaleScalesSubtreeClocks() throws {
        struct State {
            var expanded = false
            var reveal = false
        }
        let rt = Runtime(state: State(), viewport: Vec2(260, 140), pixelScale: 1.0) { s, _ in
            let revealKids: [El<State>] = s.reveal ? [
                text("One Two Three").key("frozenReveal").color(.white).timeScale(0.0).reveal(wordFade: 0.1)
            ] : []
            return col().gap(8).children([
                col().key("normal").bg(.white).h(20).w(s.expanded ? 120 : 20).animateLayout(MotionTokens.SNAPPY),
                col().key("half").timeScale(0.25).bg(.white).h(20).w(s.expanded ? 120 : 20).animateLayout(MotionTokens.SNAPPY),
                col().key("frozen").timeScale(0.0).bg(.white).h(20).w(s.expanded ? 120 : 20).animateLayout(MotionTokens.SNAPPY),
                col().children(revealKids),
            ])
        }
        _ = rt.frame(at: 0.0)
        rt.update { s, _ in
            s.expanded = true
            s.reveal = true
        }
        _ = rt.frame(at: 0.01)
        let fLater = rt.frame(at: 0.15)
        let wNorm = try #require(rt.element(byKey: "normal")?.rect[2])
        let wHalf = try #require(rt.element(byKey: "half")?.rect[2])
        let wFrozen = try #require(rt.element(byKey: "frozen")?.rect[2])

        #expect(wFrozen < wHalf)
        #expect(wHalf < wNorm)
        let frozenGlyphs = fLater.primitives.filter { $0.params.y == Float(PrimitiveKind.glyph.rawValue) && $0.fill.w > 0.1 }
        #expect(frozenGlyphs.isEmpty)
    }

    @Test("frozen timeScale(0.0) word reveal does not request frames, mid-reveal timeScale shift preserves progress, and reducedMotion caps wordFade to 0.15s")
    func revealFrozenShiftAndReducedMotionSemantics() throws {
        // 1. Frozen timeScale(0.0) word reveal alone requests no frames (isAnimating == false, AnimSource.reveal == 0).
        let frozenRt = Runtime(state: (), viewport: Vec2(240, 80), pixelScale: 1.0) { _, _ in
            col().children([
                text("Frozen reveal words").key("frz").color(.white).timeScale(0.0).reveal(wordFade: 0.25)
            ])
        }
        _ = frozenRt.frame(at: 0.0)
        _ = frozenRt.frame(at: 0.05)
        #expect(!frozenRt.isAnimating)
        #expect((frozenRt.animSources & AnimSource.reveal) == 0)

        // 2. Changing El.timeScale mid-reveal onto an already-running 0.5x clock shifts active reveal timestamps instead of jumping backward.
        struct ShiftState {
            var show = false
            var slowReveal = false
        }
        let shiftRt = Runtime(state: ShiftState(), viewport: Vec2(280, 100), pixelScale: 1.0) { s, _ in
            var kids: [El<ShiftState>] = [
                col().key("halfAnchor").timeScale(0.5).size(10, 10).bg(.white)
            ]
            if s.show {
                let t: El<ShiftState> = text("Shift words cleanly").key("shiftText").color(.white).reveal(wordFade: 0.40)
                kids.append(s.slowReveal ? t.timeScale(0.5) : t)
            }
            return col().children(kids)
        }
        _ = shiftRt.frame(at: 0.0)
        _ = shiftRt.frame(at: 0.20)
        shiftRt.update { s, _ in s.show = true }
        let fBeforeShift = shiftRt.frame(at: 0.28) // elapsed = 0.08s at 1.0x -> ~0.488 ease-out alpha on first word
        let beforeAlphas = fBeforeShift.primitives
            .filter { $0.params.y == Float(PrimitiveKind.glyph.rawValue) }
            .map(\.fill.w)
        let maxBefore = try #require(beforeAlphas.max())
        #expect(maxBefore > 0.30 && maxBefore < 0.70)

        shiftRt.update { s, _ in s.slowReveal = true }
        let fAfterShift = shiftRt.frame(at: 0.30) // 0.02s wall = +0.01s at 0.5x -> ~0.535 alpha
        let afterAlphas = fAfterShift.primitives
            .filter { $0.params.y == Float(PrimitiveKind.glyph.rawValue) }
            .map(\.fill.w)
        let maxAfter = try #require(afterAlphas.max())
        #expect(maxAfter > maxBefore)

        // 3. reducedMotion overrides wordFade (0.80s -> 0.15s) with zero stagger so all words finish by t + 0.16s.
        struct RMState { var show = false }
        let rmRt = Runtime(state: RMState(), viewport: Vec2(280, 80), pixelScale: 1.0) { s, _ in
            let kids: [El<RMState>] = s.show ? [
                text("Alpha beta gamma").key("rm").color(.white).reveal(wordFade: 0.80)
            ] : []
            return col().children(kids)
        }
        rmRt.reducedMotion = true
        _ = rmRt.frame(at: 0.0)
        _ = rmRt.frame(at: 0.10)
        rmRt.update { s, _ in s.show = true }
        let fMidRM = rmRt.frame(at: 0.13) // 0.03s / 0.15s = 0.20 -> ~0.488 ease-out alpha on all words
        let midGlyphs = fMidRM.primitives.filter { $0.params.y == Float(PrimitiveKind.glyph.rawValue) }
        #expect(midGlyphs.count >= 12)
        #expect(midGlyphs.allSatisfy { $0.fill.w > 0.30 && $0.fill.w < 0.65 })
        #expect(rmRt.isAnimating)

        let fDoneRM = rmRt.frame(at: 0.27) // 0.17s elapsed > 0.15s override (well under 0.80s)
        let doneGlyphs = fDoneRM.primitives.filter { $0.params.y == Float(PrimitiveKind.glyph.rawValue) }
        #expect(doneGlyphs.allSatisfy { $0.fill.w > 0.98 })
        #expect(!rmRt.isAnimating)
    }
}

private extension Runtime {
    func renderNode(forKey key: String) -> El<State>? {
        flatNodes.first(where: { $0.key == key })?.el
    }
}
