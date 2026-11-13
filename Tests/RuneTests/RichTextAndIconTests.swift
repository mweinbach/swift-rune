import Testing
@testable import Rune

@Suite("Rich Text, TextCase, FontEpoch, and Multi-Color SVG Icon Tests")
struct RichTextAndIconTests {

    @Test("fontEpoch bumps when FontFamiliesRegistry or TextSystem.setFamilies changes")
    func fontEpochAndFamilies() {
        let initial = fontEpoch()
        let ts = TextSystem()
        #expect(ts.currentFontEpoch == initial)

        // Setting same empty families does nothing
        #expect(ts.setFamilies(sans: "", mono: "") == false)
        #expect(fontEpoch() == initial)

        // Switching families bumps epoch
        #expect(ts.setFamilies(sans: "Helvetica Neue, Inter", mono: "Menlo") == true)
        let afterSet = fontEpoch()
        #expect(afterSet > initial)
        #expect(ts.families().sans == "Helvetica Neue, Inter")
        #expect(ts.families().mono == "Menlo")

        // Scoped withFontFamilies bumps on entry and restores on exit
        withFontFamilies(sans: "Avenir", mono: "Courier") {
            #expect(FontFamiliesRegistry.currentFamilies().sans == "Avenir")
            #expect(fontEpoch() > afterSet)
        }
        #expect(FontFamiliesRegistry.currentFamilies().sans == "Helvetica Neue, Inter")
        #expect(fontEpoch() > afterSet + 1)

        // Restore clean defaults
        _ = FontFamiliesRegistry.setFamilies(sans: "", mono: "")
    }

    @Test("TextCaseMapping preserves UTF-8 byte offsets across Unicode case expansions")
    func textCaseByteMapping() {
        // 'ß' (2 UTF-8 bytes at 1..<3) expands to "SS" (2 bytes), 'i' -> 'I'
        // Ported from crates/rune/src/text/case.rs:63-82
        let src = "aß b"
        let mapped = TextCaseMapping(source: src, textCase: .uppercase)
        #expect(mapped.displayed == "ASS B")
        #expect(mapped.displayedOffset(forSourceUTF8Offset: 1, up: false) == 1)
        #expect(mapped.displayedOffset(forSourceUTF8Offset: 3, up: false) == 3)
        #expect(mapped.displayedOffset(forSourceUTF8Offset: 2, up: false) == 1)
        #expect(mapped.displayedOffset(forSourceUTF8Offset: 2, up: true) == 3)
        #expect(mapped.displayedOffset(forSourceUTF8Offset: 5, up: false) == 5)
        #expect(mapped.displayedRange(forSourceUTF8Range: 1..<2) == 1..<3)
        #expect(mapped.displayedRange(forSourceUTF8Range: 1..<3) == 1..<3)
        #expect(mapped.displayedRange(forSourceUTF8Range: 4..<5) == 4..<5)

        #expect(mapped.sourceOffset(forDisplayedUTF8Offset: 2, up: false) == 1)
        #expect(mapped.sourceOffset(forDisplayedUTF8Offset: 2, up: true) == 3)
        #expect(mapped.sourceOffset(forDisplayedUTF8Offset: 4, up: false) == 4)
        #expect(mapped.sourceOffset(forDisplayedUTF8Offset: 5, up: false) == 5)

        // Greek uppercase -> lowercase
        let greek = "ΟΔΟΣ Ω"
        let lower = TextCaseMapping(source: greek, textCase: .lowercase)
        #expect(lower.displayed == "οδος ω")
        #expect(lower.displayedOffset(forSourceUTF8Offset: 8, up: false) == 8)
    }

    @Test("RichSpanFlattener splits and merges overlapping spans into contiguous TextSpans")
    func richSpanFlattening() {
        let text = "Hello Rune World"
        let spans = [
            RichSpan(0..<10).color(.srgb(1, 0, 0)).bold(),
            RichSpan(6..<16).bg(.srgb(0, 0, 1, 0.2)).underline(),
        ]
        let flat = RichSpanFlattener.flatten(spans, in: text, base: TextStyle())
        #expect(flat.map(\.text) == ["Hello ", "Rune", " World"])
        #expect(flat[0].weight == 700 && flat[0].underline == false)
        #expect(flat[1].weight == 700 && flat[1].underline == true && flat[1].background != nil)
        #expect(flat[2].weight == nil && flat[2].underline == true)
    }

    @Test("TextLink effectivePaint prioritizes pressed > hover > focused ?? hover")
    func textLinkAndHighlights() {
        let link = TextLink(0..<5, id: "docs", label: "Docs")
            .hover(LinkPaint().color(.srgb(0, 0.5, 1)).underline())
            .pressed(LinkPaint().color(.srgb(0, 0.2, 0.8)))
            .focused(LinkPaint().ring(.srgb(0.2, 0.6, 1), width: 1.5))

        let focusedOnly = link.effectivePaint(hovered: false, pressed: false, focused: true)
        #expect(focusedOnly.ring?.width == 1.5)
        #expect(focusedOnly.underline == nil)

        let hovered = link.effectivePaint(hovered: true, pressed: false, focused: true)
        #expect(hovered.underline == true)
        #expect(hovered.ring == nil)

        let pressed = link.effectivePaint(hovered: true, pressed: true, focused: true)
        #expect(pressed.color == .srgb(0, 0.2, 0.8))
        #expect(pressed.underline == nil)

        // When focused paint is nil, focused state falls back to hover paint
        let fallbackLink = TextLink(0..<5, id: "fallback")
            .hover(LinkPaint().color(.srgb(0.1, 0.4, 0.9)).underline())
        let fallbackFocused = fallbackLink.effectivePaint(hovered: false, pressed: false, focused: true)
        #expect(fallbackFocused.color == .srgb(0.1, 0.4, 0.9))
        #expect(fallbackFocused.underline == true)

        // TextHighlightPainter emits merged highlight quad
        let ts = TextSystem()
        let shaped = ts.shape(text: "Hello highlight", style: TextStyle(), maxWidth: nil, pixelScale: 2.0, emitGlyphs: false)
        let hl = TextHighlight(6..<15, bg: .srgb(1, 1, 0, 0.35), pad: 2.0, key: "match")
        let quads = TextHighlightPainter.quads(highlights: [hl], in: "Hello highlight", shaped: shaped, textSystem: ts, pixelScale: 2.0)
        #expect(quads.count >= 1)
        #expect(quads[0].cornerRadius == 8.0)
    }

    @Test("Multi-color SVGIcon rasterizes RGB colors, gradients, currentColor, and monochrome fallback")
    func multiColorSVGIcon() {
        let badge = SVGIcon(
            viewBox: 24,
            body: """
            <defs>
              <linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
                <stop offset="0%" stop-color="#ff0000"/>
                <stop offset="100%" stop-color="#0000ff"/>
              </linearGradient>
            </defs>
            <rect x="2" y="2" width="10" height="20" rx="2" fill="#00ff00"/>
            <circle cx="17" cy="12" r="5" fill="url(#g)"/>
            <path d="M4 12 L20 12" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>
            """
        )
        #expect(badge.isColorIcon == true)

        let rasterizer = ColorIconRasterizer()
        let img = rasterizer.rasterize(badge, pixelSize: 48, currentColor: .srgb(1, 1, 1))
        #expect(img != nil)
        #expect(img?.width == 48 && img?.height == 48)
        let rgba = img!.mips[0].rgba
        #expect(rgba.count == 48 * 48 * 4)
        // Left green rect pixel around (x=12, y=24) has non-zero green channel
        let idx = (24 * 48 + 12) * 4
        #expect(rgba[idx + 1] > 180)
        #expect(rgba[idx + 3] > 200)

        // Monochrome SVGIcon with XML body rasterizes cleanly into GlyphAtlas
        let monoXml = SVGIcon(viewBox: 24, body: "<rect x=\"4\" y=\"4\" width=\"16\" height=\"16\" rx=\"3\"/>")
        #expect(monoXml.isColorIcon == false)
        let entry = GlyphAtlas().rasterizeIcon(monoXml, pixelSize: 24)
        #expect(entry.uv.z > entry.uv.x)
    }

    @Test("El.link hit tests link byte range only, preserves focus, emits ElementInfo, and handles secondary clicks")
    func elLinkClickPreservesFocusAndTransparentOutside() {
        struct State: Sendable {
            var clicked: [String] = []
            var secondary: [String] = []
        }

        let rt = Runtime(state: State(), viewport: Vec2(400, 200)) { _, _ in
            col().gap(8).children([
                text("Focus Target")
                    .focusable()
                    .key("anchor-btn"),
                text("Open docs now")
                    .key("stage-link")
                    .link(
                        TextLink(5..<9, id: "docs", label: "Documentation")
                            .hover(LinkPaint().color(.srgb(0, 0.5, 1)).underline())
                            .pressed(LinkPaint().bg(.srgb(0, 0.5, 1, 0.2)))
                            .help("Open docs")
                    )
                    .onLink { s, id, _ in s.clicked.append(id) }
                    .onLinkSecondary { s, id, _, _ in s.secondary.append(id) },
            ])
        }

        _ = rt.frame(at: 0.0)

        let infos = rt.elements()
        let parentInfo = infos.first(where: { $0.key == "stage-link" })
        let linkInfo = infos.first(where: { $0.key == "docs" })
        #expect(parentInfo != nil)
        #expect(parentInfo?.focusable == false)
        #expect(parentInfo?.focused == false)
        #expect(linkInfo != nil)
        #expect(linkInfo?.path.hasSuffix("#link-0") == true)
        #expect(linkInfo?.role == .link)
        #expect(linkInfo?.text == "docs")
        #expect(linkInfo?.label == "Documentation")
        #expect(linkInfo?.help == "Open docs")
        #expect(linkInfo?.focusable == true)

        guard let btnPt = rt.find("anchor-btn"), let docsPt = rt.find("docs"), let parent = parentInfo else {
            Issue.record("Missing expected elements")
            return
        }

        // Focus button via pointer click
        rt.pointerDown(at: btnPt, at: 0.1)
        rt.pointerUp(at: btnPt, at: 0.12)
        _ = rt.frame(at: 0.13)
        #expect(rt.elements().first(where: { $0.focused })?.key == "anchor-btn")

        // Pointer inside non-link portion of "Open docs now" ("Open ") is transparent
        let outsidePt = Vec2(parent.rect[0] + 4.0, docsPt.y)
        rt.pointerMove(to: outsidePt, at: 0.2)
        #expect(rt.currentCursor() == .default)
        rt.pointerDown(at: outsidePt, at: 0.21)
        rt.pointerUp(at: outsidePt, at: 0.22)
        _ = rt.frame(at: 0.23)
        #expect(rt.state.clicked.isEmpty)

        // Re-focus button, then hover + click link: must activate link AND keep anchor-btn focused
        rt.pointerDown(at: btnPt, at: 0.3)
        rt.pointerUp(at: btnPt, at: 0.31)
        _ = rt.frame(at: 0.32)
        #expect(rt.elements().first(where: { $0.focused })?.key == "anchor-btn")

        rt.pointerMove(to: docsPt, at: 0.4)
        #expect(rt.currentCursor() == .pointer)
        _ = rt.frame(at: 0.41)
        #expect(rt.elements().first(where: { $0.key == "docs" })?.hover == 1.0)

        rt.pointerDown(at: docsPt, at: 0.5)
        _ = rt.frame(at: 0.51)
        #expect(rt.elements().first(where: { $0.key == "docs" })?.press == 1.0)
        #expect(rt.elements().first(where: { $0.focused })?.key == "anchor-btn")

        rt.pointerUp(at: docsPt, at: 0.52)
        _ = rt.frame(at: 0.53)
        #expect(rt.state.clicked == ["docs"])
        #expect(rt.elements().first(where: { $0.focused })?.key == "anchor-btn")

        // Secondary click fires onLinkSecondary
        rt.pointerDown(at: docsPt, button: .secondary, at: 0.6)
        rt.pointerUp(at: docsPt, button: .secondary, at: 0.61)
        #expect(rt.state.secondary == ["docs"])
    }

    @Test("Multi-link text steps Tab/Shift-Tab sequentially and activates on Return/Space")
    func elLinkMultiLinkKeyboardTabAndActivation() {
        struct State: Sendable {
            var activated: [String] = []
        }

        let rt = Runtime(state: State(), viewport: Vec2(400, 200)) { _, _ in
            col().gap(8).children([
                text("one and two")
                    .link(TextLink(0..<3, id: "first"))
                    .link(TextLink(8..<11, id: "second"))
                    .onLink { s, id, _ in s.activated.append(id) },
                text("After")
                    .focusable()
                    .key("after-btn"),
            ])
        }

        rt.tabVisitsControls = true
        _ = rt.frame(at: 0.0)

        let tab = KeyEvent(key: .tab)
        let shiftTab = KeyEvent(key: .tab, mods: Mods(shift: true))
        let ret = KeyEvent(key: .enter)
        let space = KeyEvent(key: .space)

        #expect(rt.keyDown(tab, at: 0.1))
        _ = rt.frame(at: 0.11)
        #expect(rt.elements().first(where: { $0.focused })?.key == "first")
        #expect(rt.elements().first(where: { $0.focused })?.focusVisible == true)

        #expect(rt.keyDown(tab, at: 0.2))
        _ = rt.frame(at: 0.21)
        #expect(rt.elements().first(where: { $0.focused })?.key == "second")

        #expect(rt.keyDown(ret, at: 0.3))
        #expect(rt.keyDown(space, at: 0.35))
        #expect(rt.state.activated == ["second", "second"])

        #expect(rt.keyDown(tab, at: 0.4))
        _ = rt.frame(at: 0.41)
        #expect(rt.elements().first(where: { $0.focused })?.key == "after-btn")

        #expect(rt.keyDown(shiftTab, at: 0.5))
        _ = rt.frame(at: 0.51)
        #expect(rt.elements().first(where: { $0.focused })?.key == "second")

        #expect(rt.keyDown(shiftTab, at: 0.6))
        _ = rt.frame(at: 0.61)
        #expect(rt.elements().first(where: { $0.focused })?.key == "first")
    }

    @Test("Secure text and textInput ignore El.link and PlaygroundElLift preserves text links")
    func elLinkSecureIgnoredAndPlaygroundLifted() {
        struct ChildState: Sendable {
            var edit = TextEdit("hello")
            var clicks = 0
        }
        final class ChildBox {
            var value = ChildState()
        }
        struct ParentState {
            var box = ChildBox()
        }

        let rt = Runtime(state: ParentState(), viewport: Vec2(400, 200)) { parent, _ in
            let box = parent.box
            let childEl: El<ChildState> = col().gap(8).children([
                text("Open docs")
                    .key("lifted-link")
                    .link(TextLink(5..<9, id: "docs"))
                    .onLink { s, _, _ in s.clicks += 1 },
                text("secret docs")
                    .secure()
                    .key("secure-link")
                    .link(TextLink(7..<11, id: "sec")),
                textInput(key: "input-link", \ChildState.edit)
                    .link(TextLink(0..<5, id: "inp")),
            ])
            return childEl.liftHandlers(
                isValid: { true },
                get: { box.value },
                set: { box.value = $0 }
            )
        }
        _ = rt.frame(at: 0.0)

        let infos = rt.elements()
        #expect(infos.contains(where: { $0.key == "docs" && $0.role == .link }))
        #expect(!infos.contains(where: { $0.key == "sec" }))
        #expect(!infos.contains(where: { $0.key == "inp" }))

        if let pt = rt.find("docs") {
            rt.pointerDown(at: pt, at: 0.1)
            rt.pointerUp(at: pt, at: 0.12)
            #expect(rt.state.box.value.clicks == 1)
        } else {
            Issue.record("Missing lifted link 'docs'")
        }
    }

    @Test("Link focus draws no default ring, updates focusedKey, respects FKA/focusable(false), press drag-off, and selection drag")
    func elLinkReviewFixesAndFocusParity() {
        struct State: Sendable {
            var clicks = 0
            var selClicks = 0
        }

        let rt = Runtime(state: State(), viewport: Vec2(400, 240)) { _, _ in
            col().gap(8).children([
                text("see the docs")
                    .key("para")
                    .link(TextLink(8..<12, id: "docs"))
                    .onLink { s, _, _ in s.clicks += 1 },
                text("nonfocusable link")
                    .key("nf")
                    .link(TextLink(0..<12, id: "nf-link"))
                    .focusable(false),
                text("select across docs")
                    .key("sel-para")
                    .selectable()
                    .link(TextLink(14..<18, id: "sel-docs"))
                    .onLink { s, _, _ in s.selClicks += 1 },
            ])
        }

        // Before tabVisitsControls/FKA: Tab does not visit link, forceFocusRings does not force focusVisible on unfocused link
        rt.cxSettings.fullKeyboardAccess = false
        rt.cxSettings.viewDefaults.forceFocusRings = true
        let initialScene = rt.frame(at: 0.0)
        _ = initialScene
        let docsInfoInitial = rt.elements().first(where: { $0.key == "docs" })
        #expect(docsInfoInitial?.label == "docs")
        #expect(docsInfoInitial?.focusable == true)
        #expect(docsInfoInitial?.focusVisible == false)
        let nfInfo = rt.elements().first(where: { $0.key == "nf-link" })
        #expect(nfInfo?.focusable == false)

        let tab = KeyEvent(key: .tab)
        #expect(rt.keyDown(tab, at: 0.05) == false)

        // Enable tabVisitsControls: Tab focuses "docs" (not "nf-link"), sets focusedKey == "docs", draws underline and 0 default rings
        rt.tabVisitsControls = true
        #expect(rt.keyDown(tab, at: 0.1))
        let focusedScene = rt.frame(at: 0.11)
        #expect(rt.focusedKey == "docs")
        let focusedInfo = rt.elements().first(where: { $0.focused })
        #expect(focusedInfo?.key == "docs")
        #expect(focusedInfo?.focusVisible == true)

        let ringCount = focusedScene.primitives.filter { prim in
            prim.params.y == 0 && prim.fill.w == 0 && prim.border.w > 0
        }.count
        #expect(ringCount == 0)

        let underlineCount = focusedScene.primitives.filter { prim in
            prim.params.y == 0 && prim.fill.w > 0 && prim.border.w == 0 && prim.rect.w <= 3.0 && prim.rect.z > 5.0
        }.count
        #expect(underlineCount >= 1)

        // Pressing on "docs" and dragging off clears press == 0.0; dragging back restores press == 1.0
        guard let docsPt = rt.find("docs"), let selPara = rt.elements().first(where: { $0.key == "sel-para" }),
              let selDocsPt = rt.find("sel-docs") else {
            Issue.record("Missing expected link positions")
            return
        }
        rt.pointerMove(to: docsPt, at: 0.2)
        rt.pointerDown(at: docsPt, at: 0.21)
        _ = rt.frame(at: 0.22)
        #expect(rt.elements().first(where: { $0.key == "docs" })?.press == 1.0)

        let offPt = Vec2(docsPt.x, docsPt.y + 80.0)
        rt.pointerMove(to: offPt, at: 0.23)
        _ = rt.frame(at: 0.24)
        #expect(rt.elements().first(where: { $0.key == "docs" })?.press == 0.0)

        rt.pointerUp(at: offPt, at: 0.25)
        #expect(rt.state.clicks == 0)

        // Text-selection drag across selectable text ending on link must NOT fire onLink
        let dragStart = Vec2(selPara.rect[0] + 4.0, selDocsPt.y)
        rt.pointerDown(at: dragStart, at: 0.3)
        rt.pointerMove(to: selDocsPt, at: 0.32)
        rt.pointerUp(at: selDocsPt, at: 0.34)
        #expect(rt.state.selClicks == 0)
    }
}
