import Foundation
import Testing
@testable import Rune
import RuneMotion
import RuneRef

@Suite("El & Runtime Parity Closeout Tests")
struct ElCloseoutParityTests {
    private static let red = Color(r: 0.95, g: 0.15, b: 0.15, a: 1.0)
    private static let blue = Color(r: 0.1, g: 0.25, b: 0.95, a: 1.0)
    private static let green = Color(r: 0.1, g: 0.75, b: 0.35, a: 1.0)

    @Test("Shadow.coreAnimation sets blur == 2 * radius for positional and labeled overloads")
    func shadowCoreAnimationOverloads() {
        let col = Color(r: 0.1, g: 0.2, b: 0.3, a: 0.45)
        let s1 = Shadow.coreAnimation(2, -3, 6, col)
        let s2 = Shadow.coreAnimation(x: 2, y: -3, radius: 6, color: col)
        #expect(s1 == s2)
        #expect(s1.x == 2)
        #expect(s1.y == -3)
        #expect(s1.blur == 12)
        #expect(s1.spread == 0)
        #expect(s1.color == col)
    }

    @Test("richStyle, pillColors, pillIcon, pillStyle style rich textInput pills and paint pill quads & icons")
    func richStyleAndPillInputModifiers() {
        struct S {
            var edit: TextEdit
        }
        var initEdit = TextEdit("hello ")
        initEdit.isRichEnabled = true
        initEdit.insertPill(id: "user", label: "@alice")
        let starIcon = SVGIcon(paths: ["M12 2 L15 9 L22 9 L16 14 L18 21 L12 17 L6 21 L8 14 L2 9 L9 9 Z"])
        let rich = RichStyle(
            codeFg: Color(r: 0.9, g: 0.4, b: 0.2, a: 1.0),
            codeBg: Color(r: 0.15, g: 0.15, b: 0.2, a: 1.0),
            codeBlockBg: Color(r: 0.1, g: 0.1, b: 0.15, a: 1.0),
            link: Color(r: 0.2, g: 0.6, b: 1.0, a: 1.0),
            quoteBar: Color(r: 0.5, g: 0.5, b: 0.5, a: 1.0),
            marker: Color(r: 0.7, g: 0.7, b: 0.7, a: 1.0)
        )
        let customBg = Self.green
        let defaultBg = Self.blue
        let rt = Runtime<S>(state: S(edit: initEdit)) { _, _ in
            let input: El<S> = textInput(key: "richIn", \S.edit)
                .w(240)
                .richStyle(rich)
                .pillColors(defaultBg, .white)
                .pillIcon { id in id == "user" ? starIcon : nil }
                .pillStyle { id in
                    if id == "user" {
                        return PillStyle(background: customBg, color: .white, pad: 6, gap: 4, bold: true)
                    }
                    return .default
                }
            return col().w(300).h(120).child(input)
        }
        let scene = rt.frame(at: 0)
        let expBg = customBg.simd4(srgb: rt.srgbBlend)
        let pillRects = scene.primitives.filter {
            Int($0.params.y) == PrimitiveKind.roundedRect.rawValue &&
            abs($0.fill.x - expBg.x) < 0.02 &&
            abs($0.fill.y - expBg.y) < 0.02 &&
            abs($0.fill.z - expBg.z) < 0.02
        }
        let glyphPrims = scene.primitives.filter { Int($0.params.y) == PrimitiveKind.glyph.rawValue }
        #expect(!pillRects.isEmpty, "pillStyle custom background quad should render")
        #expect(glyphPrims.count >= "@alice".count + "hello".count + 1, "text + leading pill icon glyphs should render")
    }

    @Test("singleLine keeps overflowing input on one line and scrolls caret into view", arguments: [false, true])
    func singleLineInputKeepsHeightAndScrollsCaret(native: Bool) throws {
        struct S {
            var edit = TextEdit(String(repeating: "abcdefghij", count: 8))
        }
        let rt = Runtime<S>(state: S()) { _, _ in
            col().w(400).h(200).child(
                row().key("row").child(
                    textInput(key: "single", \S.edit).singleLine(true).w(100)
                )
            )
        }
        func paint(_ time: Double) {
            if native { _ = rt.renderFrame(at: time) } else { _ = rt.frame(at: time) }
        }
        paint(0)
        let field = try #require(rt.element(byKey: "single"))
        let x = field.rect[0], right = x + field.rect[2]
        #expect(field.rect[3] < 36, "singleLine should keep 1-line height even with 80 chars in 100pt width")

        rt.pointerDown(at: Vec2(x + 10, field.rect[1] + 8), at: 0.05)
        rt.pointerUp(at: Vec2(x + 10, field.rect[1] + 8), at: 0.06)
        _ = rt.keyDown(KeyEvent(key: .end), at: 0.07)
        paint(0.08)
        let endCaret = try #require(rt.element(byKey: "single")?.caret)
        #expect(rt.state.edit.selectedUTF8Range == 80..<80)
        #expect((rt.inputScroll[field.path] ?? 0) > 50)
        #expect(endCaret[0] >= x && endCaret[0] <= right)

        _ = rt.keyDown(KeyEvent(key: .home), at: 0.09)
        paint(0.10)
        let startCaret = try #require(rt.element(byKey: "single")?.caret)
        #expect(rt.state.edit.selectedUTF8Range == 0..<0)
        #expect((rt.inputScroll[field.path] ?? 0) == 0)
        #expect(startCaret[0] >= x && startCaret[0] < endCaret[0])
    }

    @Test("animateEditLayout opts textInput edits into animated layout instead of instant snap")
    func animateEditLayoutVsInstantDefault() {
        struct S {
            var edit = TextEdit("hi")
        }
        func runTyping(_ animate: Bool) -> (sibY0: Float, sibY1: Float, animating: Bool) {
            let rt = Runtime<S>(state: S()) { _, _ in
                let inp: El<S> = animate
                    ? textInput(key: "in", \S.edit).animateEditLayout(true).w(120).animateLayout(Spring(duration: 0.4, bounce: 0))
                    : textInput(key: "in", \S.edit).w(120).animateLayout(Spring(duration: 0.4, bounce: 0))
                let sib: El<S> = el().key("sib").w(40).h(20).bg(Self.red).animateLayout(Spring(duration: 0.4, bounce: 0))
                return col().w(300).h(200).child(
                    col().gap(8).children([inp, sib])
                )
            }
            _ = rt.frame(at: 0)
            let y0 = rt.element(byKey: "sib")?.rect[1] ?? 0
            rt.pointerDown(at: Vec2(20, 10), at: 0.02)
            rt.pointerUp(at: Vec2(20, 10), at: 0.03)
            var t = 0.04
            for ch in String(repeating: "wrap ", count: 14) {
                _ = rt.keyDown(KeyEvent(key: .text(String(ch))), at: t)
                t += 0.001
            }
            _ = rt.frame(at: 0.06)
            let y1 = rt.element(byKey: "sib")?.rect[1] ?? 0
            return (y0, y1, rt.isAnimating)
        }

        let plain = runTyping(false)
        #expect(plain.sibY1 > plain.sibY0, "wrapped input shifts sibling down")
        #expect(!plain.animating, "without animateEditLayout, textInput edit uses instant commit")

        let anim = runTyping(true)
        #expect(anim.animating, "animateEditLayout keeps spring layout transition active across text edit")
    }

    @Test("iconOneColor rasterizes color icon monochrome and iconRotation turns glyph without rotating box")
    func iconOneColorAndIconRotation() {
        let twoTone = SVGIcon(
            viewBox: 24,
            body: "<rect x='2' y='2' width='9' height='20' fill='#ff0000'/><rect x='13' y='2' width='9' height='20' fill='#00ff00'/>"
        )
        struct S {
            var rot: Float = 0.0
            var mono = false
        }
        let rt = Runtime<S>(state: S()) { s, _ in
            let icBase: El<S> = icon(twoTone, size: 24)
            let ic = icBase
                .key("ic")
                .w(24).h(24)
                .color(Self.blue)
                .iconRotation(s.rot)
                .animate(Spring(duration: 0.3, bounce: 0))
            return col().w(100).h(100).child(s.mono ? ic.iconOneColor(true) : ic)
        }
        let fColor = rt.frame(at: 0)
        let img0 = fColor.primitives.first { Int($0.params.y) == PrimitiveKind.image.rawValue }
        #expect(img0 != nil, "multi-color SVG rasterizes as color image primitive")
        #expect(img0?.turn == 0)

        rt.update(at: 0.1) { s, _ in
            s.rot = .pi / 2
            s.mono = true
        }
        _ = rt.frame(at: 0.1)
        let fMid = rt.frame(at: 0.25)
        let fEnd = rt.frame(at: 1.0)
        let imgMid = fMid.primitives.first { Int($0.params.y) == PrimitiveKind.image.rawValue }
        let imgEnd = fEnd.primitives.first { Int($0.params.y) == PrimitiveKind.image.rawValue }
        let boxRect = rt.element(byKey: "ic")?.rect ?? [0, 0, 0, 0]
        #expect(boxRect[2] == 24 && boxRect[3] == 24)
        #expect((imgMid?.turn ?? 0) > 0.1 && (imgMid?.turn ?? 99) < .pi / 2, "Props.ICON_TURN animates icon rotation smoothly")
        #expect(abs((imgEnd?.turn ?? 0) - (.pi / 2)) < 0.01)
    }

    @Test("hoverGroupFocus lights groupColor under keyboard focus")
    func hoverGroupFocusActivatesOnFocus() {
        struct S { var dummy = 0 }
        let normal = Self.blue
        let lit = Self.red
        let rt = Runtime<S>(state: S()) { _, _ in
            let label: El<S> = text("Badge").key("badge").color(normal).groupColor(lit)
            let grp: El<S> = row().key("grp").hoverGroupFocus().focusable(true).w(120).h(40).child(label)
            return col().w(200).h(100).child(grp)
        }
        let f0 = rt.frame(at: 0)
        let col0 = f0.primitives.first { Int($0.params.y) == PrimitiveKind.glyph.rawValue }?.fill
        #expect(abs((col0?.z ?? 0) - normal.b) < 0.05)

        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.1)
        let f1 = rt.frame(at: 0.12)
        let col1 = f1.primitives.first { Int($0.params.y) == PrimitiveKind.glyph.rawValue }?.fill
        #expect(abs((col1?.x ?? 0) - lit.r) < 0.05, "keyboard focus on hoverGroupFocus lights child groupColor")
    }

    @Test("raise paints subtree above siblings and wins hitTest while keeping parent clip and tree order")
    func raisePaintAndHitPriority() {
        struct S { var hits: [String] = [] }
        let topRed = Self.red
        let sibBlue = Self.blue
        let rt = Runtime<S>(state: S()) { _, _ in
            let raised: El<S> = el().key("raised").raise(true).w(80).h(80).bg(topRed).onClick { st, _ in st.hits.append("raised") }
            let host: El<S> = el().key("host").w(100).h(100).clip().child(raised)
            let sib: El<S> = el().key("sibling").z(50).w(100).h(100).offset(0, -100).bg(sibBlue).onClick { st, _ in st.hits.append("sibling") }
            return col().w(200).h(200).children([host, sib])
        }
        let scene = rt.frame(at: 0)
        let expRed = topRed.simd4(srgb: rt.srgbBlend)
        let expBlue = sibBlue.simd4(srgb: rt.srgbBlend)
        let redIdx = scene.primitives.lastIndex {
            Int($0.params.y) == PrimitiveKind.roundedRect.rawValue &&
            abs($0.fill.x - expRed.x) < 0.02 &&
            abs($0.fill.z - expRed.z) < 0.02
        }
        let blueIdx = scene.primitives.lastIndex {
            Int($0.params.y) == PrimitiveKind.roundedRect.rawValue &&
            abs($0.fill.z - expBlue.z) < 0.02 &&
            abs($0.fill.x - expBlue.x) < 0.02
        }
        #expect(redIdx != nil && blueIdx != nil && redIdx! > blueIdx!, "raised element paints after later z-ordered sibling")
        if let redPrim = redIdx.map({ scene.primitives[$0] }) {
            let clipMax = 100.0 * rt.pixelScale + 0.5
            #expect(redPrim.clip.z <= clipMax && redPrim.clip.w <= clipMax, "raised child keeps ancestor clip")
        }
        let hit = rt.hitTestElement(at: Vec2(40, 40))
        #expect(hit?.key == "raised", "raised element wins hitTest over overlapping z=50 sibling")
        let keys = rt.elements().compactMap(\.key)
        if let rTreeIdx = keys.firstIndex(of: "raised"), let sTreeIdx = keys.firstIndex(of: "sibling") {
            #expect(rTreeIdx < sTreeIdx, "ElementInfo retains authored DOM/tree order")
        } else {
            Issue.record("expected raised and sibling in elements()")
        }
    }

    @Test("widthLeads springs X faster and holdLandingWidth snaps child text width while parent glides")
    func widthLeadsAndHoldLandingWidth() {
        struct S { var wide = false }
        let rtLead = Runtime<S>(state: S()) { s, _ in
            let box: El<S> = el().key("box")
                .w(s.wide ? 200 : 100)
                .h(s.wide ? 200 : 100)
                .widthLeads(true)
                .animateLayout(Spring(duration: 0.6, bounce: 0))
                .bg(Self.blue)
            return col().w(300).h(200).child(box)
        }
        _ = rtLead.frame(at: 0)
        rtLead.update(at: 0.02) { s, _ in s.wide = true }
        let fMid = rtLead.frame(at: 0.25)
        let midBox = fMid.primitives.first { Int($0.params.y) == PrimitiveKind.roundedRect.rawValue && $0.fill.w > 0.5 }?.rect
        #expect(midBox != nil)
        if let r = midBox {
            #expect(r.z > r.w + 2.0, "widthLeads makes X advance ahead of Y mid-transition")
        }

        struct WrapState {
            var narrow = false
        }
        let rtHold = Runtime<WrapState>(state: WrapState()) { s, _ in
            let body: El<WrapState> = text("one two three four five six seven eight").key("body").wrap(.wrap).wFull().shrink(1).minW(0)
            let card: El<WrapState> = row().key("card")
                .w(s.narrow ? 80 : 260)
                .holdLandingWidth(true)
                .animateLayout(Spring(duration: 0.6, bounce: 0))
                .child(body)
            return col().w(300).h(200).child(card)
        }
        _ = rtHold.frame(at: 0)
        let hWide = rtHold.element(byKey: "body")?.rect[3] ?? 0
        rtHold.update(at: 0.05) { s, _ in s.narrow = true }
        let fJump = rtHold.frame(at: 0.06)
        let hJump = rtHold.element(byKey: "body")?.rect[3] ?? 0
        let fSettled = rtHold.frame(at: 1.5)
        let hEnd = rtHold.element(byKey: "body")?.rect[3] ?? 0
        #expect(hEnd > hWide)
        #expect(abs(hJump - hEnd) < 0.5, "holdLandingWidth snaps child subtree straight to landing wrap width/height")
        _ = fJump
        _ = fSettled
    }

    @Test("offsetMotion, opacityMotion, scaleMotion, rotateMotion customize curves and snap geometry under reducedMotion")
    func perPropertyMotionAndReducedMotion() {
        struct S { var active = false }
        func makeRuntime(reducedMotion: Bool) -> Runtime<S> {
            Runtime<S>(state: S(), reducedMotion: reducedMotion) { s, _ in
                let card: El<S> = el().key("card")
                    .w(80).h(40)
                    .bg(Self.red)
                    .offset(s.active ? 120 : 0, 0)
                    .opacity(s.active ? 0.1 : 1.0)
                    .scale(s.active ? 1.5 : 1.0)
                    .rotate(s.active ? 0.6 : 0.0)
                    .offsetMotion(Anim(curve: .linear(0.8)))
                    .opacityMotion(Anim(curve: .linear(0.8)))
                    .scaleMotion(Anim(curve: .linear(0.8)))
                    .rotateMotion(Anim(curve: .linear(0.8)))
                return col().w(300).h(300).child(card)
            }
        }

        let rtNormal = makeRuntime(reducedMotion: false)
        _ = rtNormal.frame(at: 0)
        rtNormal.update(at: 0.0) { s, _ in s.active = true }
        let fNormalMid = rtNormal.frame(at: 0.4)
        let cardNorm = fNormalMid.primitives.first { Int($0.params.y) == PrimitiveKind.roundedRect.rawValue }
        #expect(cardNorm != nil)
        if let p = cardNorm {
            #expect(p.rect.x > 10 && p.rect.x < 115, "offsetMotion interpolates X along 0.8s curve")
            #expect(p.fill.w > 0.2 && p.fill.w < 0.9, "opacityMotion interpolates alpha along 0.8s curve")
            #expect(p.turn > 0.1 && p.turn < 0.55, "rotateMotion interpolates angle along 0.8s curve")
        }

        let rtRM = makeRuntime(reducedMotion: true)
        _ = rtRM.frame(at: 0)
        rtRM.update(at: 0.0) { s, _ in s.active = true }
        _ = rtRM.frame(at: 0.001)
        let fRmMid = rtRM.frame(at: 0.09)
        let cardRm = fRmMid.primitives.first { Int($0.params.y) == PrimitiveKind.roundedRect.rawValue }
        #expect(cardRm != nil)
        if let p = cardRm {
            #expect(abs(p.turn - 0.6) < 0.05, "reducedMotion snaps rotateMotion spatial transform")
            #expect(p.fill.w > 0.15 && p.fill.w < 0.95, "reducedMotion still cross-fades opacityMotion")
        }
        let fRmEnd = rtRM.frame(at: 0.4)
        let cardRmEnd = fRmEnd.primitives.first { Int($0.params.y) == PrimitiveKind.roundedRect.rawValue }
        #expect(abs((cardRmEnd?.fill.w ?? 0) - 0.1) < 0.02)
    }

    @Test("textCase transforms rendered glyphs including byte expansion while keeping ElementInfo.text authored; spanRing only borders bg spans")
    func textCaseAndSpanRings() {
        struct S { var dummy = 0 }
        let ringColor = Self.red
        let rt = Runtime<S>(state: S()) { _, _ in
            let cased: El<S> = text("Straße").key("caseText").textCase(.uppercase).size(16)
            let ringed: El<S> = rich([
                TextSpan("chip", background: Color(r: 0.2, g: 0.2, b: 0.3, a: 1.0)),
                TextSpan(" plain")
            ])
            .key("ringText")
            .spanRing(0..<3, ringColor, width: 2.0)
            .spanRing(5..<9, ringColor, width: 2.0)
            return col().w(300).h(200).children([cased.alignSelf(.start), ringed])
        }
        let scene = rt.frame(at: 0)
        #expect(rt.element(byKey: "caseText")?.text == "Straße", "ElementInfo.text stays authored")
        let caseRect = rt.element(byKey: "caseText")?.rect ?? [0, 0, 0, 0]
        let upperWidth = rt.textSystem.measure("STRASSE", style: TextStyle(size: 16), maxWidth: nil, pixelScale: rt.pixelScale).x
        #expect(abs(caseRect[2] - upperWidth) < 1.5, "textCase(.uppercase) measures expanded glyphs (STRASSE)")

        let expRing = ringColor.simd4(srgb: rt.srgbBlend)
        let ringPrims = scene.primitives.filter { prim in
            let isRect = Int(prim.params.y) == PrimitiveKind.roundedRect.rawValue
            let matchesBorder = abs(prim.border.x - expRing.x) < 0.02 && prim.border.w > 0.5
            return isRect && matchesBorder && prim.params.x > 0
        }
        #expect(ringPrims.count == 1, "spanRing only paints on bg-bearing range 0..<3, ignoring non-bg 5..<9")
    }

    @Test("exactLines keeps fractional height while roundedLines ceils to whole device pixels")
    func exactVsRoundedLines() {
        struct S { var dummy = 0 }
        let rt = Runtime<S>(state: S()) { _, _ in
            let ex: El<S> = text("Line one").key("exact").size(13).lineHeight(1.15).exactLines()
            let rd: El<S> = text("Line one").key("rounded").size(13).lineHeight(1.15).roundedLines()
            return col().w(300).h(200).children([ex, rd])
        }
        _ = rt.frame(at: 0)
        let hExact = rt.element(byKey: "exact")?.rect[3] ?? 0
        let hRounded = rt.element(byKey: "rounded")?.rect[3] ?? 0
        let hRoundedPx = hRounded * rt.pixelScale
        #expect(hExact > 0 && hRounded >= hExact)
        #expect(abs(hRoundedPx - ceilf(hRoundedPx)) < 0.001, "roundedLines aligns to whole device pixels")
    }

    @Test("truncateMiddle, truncateHead, maxLines, truncateFade, truncateFadeWidth and helpWhenTruncated")
    func truncationModesAndHelpWhenTruncated() {
        struct S { var dummy = 0 }
        let longLine = "Users/mweinbach/Projects/swift-rune-worktrees/el/Sources/Rune/Runtime.swift"
        let multiPara = "Alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau"

        let rt = Runtime<S>(state: S()) { _, _ in
            let e1: El<S> = text(longLine).key("mid").w(140).truncateMiddle().helpWhenTruncated("Mid Tip")
            let e2: El<S> = text(longLine).key("head").w(140).truncateHead()
            let e3: El<S> = text("hi").key("short").w(140).truncateMiddle().helpWhenTruncated("Short Tip")
            let e4: El<S> = text(multiPara).key("max2").w(110).maxLines(2)
            let e5: El<S> = text(longLine).key("fade").w(140).truncateFadeWidth(2.0)
            let e6: El<S> = text("ok").key("fitFade").w(140).truncateFade()
            let rtlLong = "مرحبا بكم في اختبار التلاشي الطويل جداً للنصوص العربية المتدفقة"
            let e7: El<S> = text(rtlLong).key("rtlFade").w(140).truncateFadeWidth(2.0)
            return col().w(400).h(300).children([e1, e2, e3, e4, e5, e6, e7])
        }
        let scene = rt.frame(at: 0)
        let rf = rt.renderFrame(at: 0)
        let twoLineRef = rt.textSystem.measure(multiPara, style: TextStyle(wrap: .wrap, maxLines: 2), maxWidth: 110, pixelScale: 1.0)
        let fullRef = rt.textSystem.measure(multiPara, style: TextStyle(wrap: .wrap, maxLines: 0), maxWidth: 110, pixelScale: 1.0)
        let max2Rect = rt.element(byKey: "max2")?.rect ?? [0, 0, 0, 0]
        #expect(abs(max2Rect[3] - twoLineRef.y) < 1.0)
        #expect(max2Rect[3] < fullRef.y - 4.0)

        let midRect = rt.element(byKey: "mid")?.rect ?? [0, 0, 0, 0]
        let shortRect = rt.element(byKey: "short")?.rect ?? [0, 0, 0, 0]
        let fadeRect = rt.element(byKey: "fade")?.rect ?? [0, 0, 0, 0]
        let rtlFadeRect = rt.element(byKey: "rtlFade")?.rect ?? [0, 0, 0, 0]

        let pxScale = rt.pixelScale
        let fadeGlyphs = scene.primitives.filter {
            Int($0.params.y) == PrimitiveKind.glyph.rawValue &&
            $0.rect.y >= fadeRect[1] * pxScale - 2 && $0.rect.y <= (fadeRect[1] + fadeRect[3]) * pxScale + 2 &&
            $0.fade.z != 0
        }
        #expect(!fadeGlyphs.isEmpty, "overflowing truncateFade attaches alpha fade ramp to glyphs")
        if let g0 = fadeGlyphs.first {
            // RefScene Metal shader encodes fade as (dir.x, dir.y, 1 / fadeW, 0) with edge fadeOrigin.
            #expect(g0.fade.x == -1.0 && g0.fade.y == 0.0)
            #expect(g0.fade.z > 0.0 && g0.fade.z < 0.25)
            #expect(abs(g0.fadeOrigin.x - (fadeRect[0] + fadeRect[2]) * pxScale) <= 1.5)
        }
        let rtlFadeGlyphs = scene.primitives.filter {
            Int($0.params.y) == PrimitiveKind.glyph.rawValue &&
            $0.rect.y >= rtlFadeRect[1] * pxScale - 2 && $0.rect.y <= (rtlFadeRect[1] + rtlFadeRect[3]) * pxScale + 2 &&
            $0.fade.z != 0
        }
        #expect(!rtlFadeGlyphs.isEmpty, "RTL text inside LTR container uses paragraph bidi direction for truncateFade")
        if let r0 = rtlFadeGlyphs.first {
            #expect(r0.fade.x == 1.0 && r0.fade.y == 0.0)
            #expect(abs(r0.fadeOrigin.x - rtlFadeRect[0] * pxScale) <= 1.5)
        }
        let rfLtrFade = rf.instances.filter {
            $0.params.y == KIND_GLYPH &&
            $0.rect.y >= fadeRect[1] * pxScale - 2 && $0.rect.y <= (fadeRect[1] + fadeRect[3]) * pxScale + 2 &&
            unpackFade($0.fade).width.z > 0
        }
        let rfRtlFade = rf.instances.filter {
            $0.params.y == KIND_GLYPH &&
            $0.rect.y >= rtlFadeRect[1] * pxScale - 2 && $0.rect.y <= (rtlFadeRect[1] + rtlFadeRect[3]) * pxScale + 2 &&
            unpackFade($0.fade).width.x > 0
        }
        #expect(!rfLtrFade.isEmpty)
        #expect(!rfRtlFade.isEmpty)

        rt.pointerMove(to: Vec2(midRect[0] + 10, midRect[1] + 8), at: 0.1)
        _ = rt.frame(at: 0.1)
        _ = rt.frame(at: 0.1 + rt.helpDelay + 0.02)
        #expect(rt.helpTooltip()?.text == "Mid Tip")

        rt.pointerMove(to: Vec2(shortRect[0] + 10, shortRect[1] + 8), at: 1.0)
        _ = rt.frame(at: 1.0)
        _ = rt.frame(at: 1.0 + rt.helpDelay + 0.02)
        #expect(rt.helpTooltip() == nil, "helpWhenTruncated suppresses tooltip when text fits")
        #expect(rt.element(byKey: "head") != nil)
    }

    @Test("TextRun and El.advanceIn slice per-grapheme widths preserving run kerning")
    func textRunAndAdvanceInSlices() {
        let ts = TextSystem()
        let style = TextStyle(size: 16)
        let run = TextRun("AVATAR")
        var offsets: [Int] = []
        var offset = 0
        for g in run.text {
            offsets.append(offset)
            offset += String(g).utf8.count
        }

        struct S { var dummy = 0 }
        let rt = Runtime<S>(state: S()) { _, _ in
            let cells: [El<S>] = offsets.map { off in
                text("").key("c\(off)").advanceIn(run, at: off).font(style)
            }
            return row().w(200).h(50).children(cells)
        }
        let full = ts.measure("AVATAR", style: style, maxWidth: nil, pixelScale: rt.pixelScale)
        #expect(full.x > 0)
        let advances: [Float] = offsets.map { off in
            ts.measureRunSlice(run, at: off, style: style, pixelScale: rt.pixelScale)?.x ?? 0
        }
        #expect(advances.count == 6)

        let scene = rt.frame(at: 0)
        let glyphs = scene.primitives.filter { Int($0.params.y) == PrimitiveKind.glyph.rawValue }
        #expect(glyphs.count == 6, "advanceIn cells emit one glyph per grapheme slice")
        for (i, off) in offsets.enumerated() {
            let w = rt.element(byKey: "c\(off)")?.rect[2] ?? -1
            #expect(abs(w - advances[i]) < 0.05)
        }
    }

    @Test("multiline textInput selection highlights all covered lines including middle lines")
    func multilineTextInputSelectionHighlightsAllLines() {
        struct S {
            var edit: TextEdit
        }
        var initEdit = TextEdit("alpha line\nbeta middle\ngamma end", multiline: true)
        initEdit.selectAll()
        let selColor = Self.red.alpha(0.35)
        let rt = Runtime<S>(state: S(edit: initEdit)) { _, _ in
            let field: El<S> = textInput(key: "ml-sel", \S.edit)
                .focusable(true)
                .selectionStyle(SelectionStyle(highlight: selColor))
                .w(240)
                .h(120)
            return col().w(260).h(140).child(field)
        }
        _ = rt.frame(at: 0)
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.02)
        let scene = rt.frame(at: 0.03)
        let expSel = selColor.simd4(srgb: rt.srgbBlend)
        let selRects: [Primitive] = scene.primitives.filter { prim in
            let isRect = Int(prim.params.y) == PrimitiveKind.roundedRect.rawValue
            let dr = abs(prim.fill.x - expSel.x)
            let dg = abs(prim.fill.y - expSel.y)
            let db = abs(prim.fill.z - expSel.z)
            let da = abs(prim.fill.w - expSel.w)
            return isRect && dr < 0.02 && dg < 0.02 && db < 0.02 && da < 0.05
        }
        #expect(selRects.count >= 3, "3-line selection should highlight first, middle, and last lines")
        let distinctRows = Set(selRects.map { Int($0.rect.y.rounded()) })
        #expect(distinctRows.count >= 3, "selection rects should cover all 3 distinct line Y bands")
    }
}
