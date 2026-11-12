import Foundation
import Testing
@testable import RuneKit
@testable import Rune
@testable import RuneRef

@Suite("RuneKit Content Parity — Increment 1 (Kit, Glyphs, LineSelection, Notes, Syntax, Mermaid)")
struct KitContentParityTests {
    // MARK: - Kit tokens, hashing & neutral palette

    @Test("Kit neutral dark/light populate all semantic palette tokens without transparent placeholders")
    func neutralPaletteHasNoTransparentPlaceholders() {
        for dark in [false, true] {
            let k = Kit.neutral(dark: dark)
            #expect(k.c.submitFg != .transparent)
            #expect(k.c.submitIcon != .transparent)
            #expect(k.c.surfaceRaisedBase != .transparent)
            #expect(k.c.surfaceRaisedHover != .transparent)
            #expect(k.c.borderWeak != .transparent)
            #expect(k.c.borderHover != .transparent)
            #expect(k.c.borderActive != .transparent)
            #expect(k.c.borderDisabled != .transparent)
            #expect(k.c.textStrong != .transparent)
            #expect(k.c.textWeak != .transparent)
            #expect(k.c.textInvertStrong != .transparent)
            #expect(k.c.iconWeaker != .transparent)
            #expect(k.c.stdIcon != .transparent)
            #expect(k.c.stdIconInvert != .transparent)
            #expect(k.c.stdIconStrong != .transparent)
            #expect(k.c.stdText != .transparent)
            #expect(!k.elevation.elements.isEmpty)
            #expect(!k.elevation.md.isEmpty)
            #expect(k.ty.small.lineHeight == 12.0)
            #expect(k.ty.smallMedium.lineHeight == 12.0)
            #expect(k.glyph == Glyphs.default)
        }
    }

    @Test("equal_tokens_hash_equal (kit.rs)")
    func equalTokensHashEqual() {
        let a = Kit.neutral(dark: true)
        let b = Kit.neutral(dark: true)
        let light = Kit.neutral(dark: false)

        #expect(a.c.hashValue == b.c.hashValue)
        #expect(a.ty.hashValue == b.ty.hashValue)
        #expect(a.radius.hashValue == b.radius.hashValue)
        #expect(a.glyph.hashValue == b.glyph.hashValue)
        #expect(a.c.hashValue != light.c.hashValue)

        var negRadius = a.radius
        negRadius.xs = -0.0
        var posRadius = a.radius
        posRadius.xs = 0.0
        #expect(posRadius == negRadius)
        #expect(posRadius.hashValue == negRadius.hashValue)

        var diffRadius = a.radius
        diffRadius.md += 1.0
        #expect(a.radius.hashValue != diffRadius.hashValue)

        var diffTy = a.ty
        diffTy.ui = a.ty.ui.lh((a.ty.ui.lineHeight ?? 20.0) + 1.0)
        #expect(a.ty.hashValue != diffTy.hashValue)

        var zeroTrack = a.ty.ui
        zeroTrack.letterSpacing = 0.0
        var negZeroTrack = a.ty.ui
        negZeroTrack.letterSpacing = -0.0
        #expect(zeroTrack.hashValue == negZeroTrack.hashValue)
    }

    @Test("legacy_exhaustive_elevation_literal_compiles + withInput (tests/elevation_compat.rs)")
    func elevationCompatAndInput() {
        let ring = Shadow(x: 0, y: 0, blur: 0, spread: 0.5)
        var e = KitElevation()
        e.raised = [ring]
        e.floating = [ring]
        e.overlay = [ring]
        e.buttonNeutral = [ring]
        e.knob = [ring]
        #expect(e.raised.count == 1)
        #expect(e.effectiveInput() == e.buttonNeutral)

        let customInput = [Shadow(x: 0, y: 0, blur: 0, spread: 1.0, color: .white)]
        let updated = e.withInput(customInput)
        #expect(updated.effectiveInput() == customInput)
    }

    // MARK: - Kit.interactive & Kit.elevate (tests/interactive.rs)

    @Test("an_interactive_element_shows_hover_and_press + elevate_paints_the_layers_as_shadows")
    func interactiveAndElevateParity() {
        func buildView(_ state: Int, cx: inout Cx<Int>) -> El<Int> {
            let k = Kit.neutral(dark: true)
            let row = k.interactive(
                El<Int>()
                    .key("row")
                    .size(100, 28)
                    .onClick { n in n += 1 }
            )
            let card = k.elevate(
                El<Int>().key("card").size(100, 28),
                k.elevation.floating
            )
            return col().children([row, card]).size(200, 200)
        }

        let rt = Runtime<Int>(state: 0, viewport: Vec2(200, 200), view: buildView)
        rt.frame(at: 0.0)
        let rowInfo0 = rt.element(byKey: "row")!
        #expect(rowInfo0.hover == 0.0)
        #expect(rowInfo0.press == 0.0)

        var t = 0.0
        rt.pointerMove(to: Vec2(50, 14), at: t)
        for _ in 0..<30 {
            t += 1.0 / 60.0
            rt.frame(at: t)
        }
        let rowHovered = rt.element(byKey: "row")!
        #expect(rowHovered.hover > 0.9)

        rt.pointerDown(at: Vec2(50, 14), at: t)
        for _ in 0..<30 {
            t += 1.0 / 60.0
            rt.frame(at: t)
        }
        let rowPressed = rt.element(byKey: "row")!
        #expect(rowPressed.press > 0.9)

        rt.pointerUp(at: Vec2(50, 14), at: t)
        t += 1.0 / 60.0
        rt.frame(at: t)
        #expect(rt.state == 1)

        // Compare shadow primitive generation against plain un-elevated elements
        let k = Kit.neutral(dark: true)
        #expect(!k.elevation.floating.isEmpty)
        let plain = Runtime<Int>(state: 0, viewport: Vec2(200, 200)) { _, _ in
            col().children([
                El<Int>().size(100, 28),
                El<Int>().size(100, 28),
            ]).size(200, 200)
        }
        let plainScene = plain.frame(at: 0.0)
        let elevatedScene = rt.frame(at: 0.0)
        #expect(elevatedScene.primitives.count >= plainScene.primitives.count + k.elevation.floating.count)
    }

    // MARK: - Glyphs (tests/glyphs.rs)

    @Test("All 28 built-in glyphs rasterize with ink at 16pt, 20pt, and 32pt")
    func builtInGlyphsRasterizeWithInk() {
        #expect(KitIcons.allBuiltIn.count == 28)
        let ts = TextSystem()
        let atlas = ts.glyphAtlas
        for icon in KitIcons.allBuiltIn {
            for pt in [16, 20, 32] {
                let entry = atlas.rasterizeIcon(icon, pixelSize: pt)
                #expect(entry.pixelSize == SIMD2<Int>(pt, pt))
                #expect(entry.uv.z > entry.uv.x)
                #expect(entry.uv.w > entry.uv.y)
            }
            let entry32 = atlas.rasterizeIcon(icon, pixelSize: 32)
            let x0 = Int((entry32.uv.x * Float(atlas.atlas.width)).rounded())
            let y0 = Int((entry32.uv.y * Float(atlas.atlas.height)).rounded())
            var ink = 0
            for y in y0..<(y0 + 32) {
                for x in x0..<(x0 + 32) {
                    ink += Int(atlas.atlas.texels[y * atlas.atlas.width + x])
                }
            }
            #expect(ink > 100, "Icon \(icon.paths) failed to produce ink at 32px (ink=\(ink))")
        }
        #expect(KitIcons.caretRight.strokeWidth == nil)
        #expect(KitIcons.triangleDown.strokeWidth == nil)
        #expect(KitIcons.triangleRight.strokeWidth == nil)
        #expect(KitIcons.dash.strokeWidth == nil)
        #expect(KitIcons.starFilled.strokeWidth == nil)
        #expect(KitIcons.check.viewBox == 12)
        #expect(KitIcons.dash.viewBox == 20)
    }

    // MARK: - LineSelection (line_selection.rs)

    @Test("LineSelectionState handles Shift precedence, missing rows, and keepStart anchor")
    func lineSelectionParity() {
        let rows: [Int: UInt32] = [1: 0, 2: 1, 3: 2, 4: 3, 5: 4]
        var state = LineSelectionState<Int>.idle(selected: .line(3))

        // Shift-click on the SAME selected line extends/selects via Shift branch (not unselecting)
        _ = state.step(
            .press(at: 3, column: .numbers, shift: true),
            rowOf: { rows[$0] }
        )
        #expect(state.selected == LineRange(start: 3, end: 3))
        if case .unselecting = state {
            Issue.record("Shift-press on selected line must enter .selecting, not .unselecting")
        }

        // Release keeps selection; now extend downward to 5 (3..5), then Shift-click 1 (above start -> anchor switches to 5)
        state = .idle(selected: LineRange(start: 3, end: 5))
        _ = state.step(
            .press(at: 1, column: .numbers, shift: true),
            rowOf: { rows[$0] }
        )
        #expect(state.selected == LineRange(start: 5, end: 1))

        // Shift-click on unrendered row (rowOf returns nil) ignores press and stays .idle
        state = .idle(selected: LineRange(start: 2, end: 4))
        _ = state.step(
            .press(at: 99, column: .numbers, shift: true),
            rowOf: { rows[$0] }
        )
        #expect(state == .idle(selected: LineRange(start: 2, end: 4)))
    }

    // MARK: - Notes (notes_tests.rs)

    @Test("NoteParser handles tabs, repeated '- ' prefixes, and all 7 piece kinds")
    func noteParserParity() {
        let tabSample = """
        Lead summary line.

        \t> [!note]
        \t> Attention callout paragraph.

        ```facts
        \t- Latency: {verified} 11.9 ms
        \t- - Mode: `Rgba16Float`
        ```

        ```compare
        Before: Software rasterized overlay loop.
        After: Single-pass GPU uber-quad exposure.
        ```

        ```steps
        - - {built} Shared shutter pass · verified
        - {proposed} Live preview window
        ```

        ```size
        app +120 −30 · tests +45 −0 · 4 files
        ```

        ```rust title="shutter.rs" {2-3}
        fn add_sample(c: Vec4, w: f32) -> Vec4 {
        +   c * w
        }
        ```
        """
        let pieces = NoteParser.parse(tabSample)
        #expect(pieces.count == 7)
        if case .facts(let rows) = pieces[2] {
            #expect(rows.count == 2)
            #expect(rows[0].label == "Latency")
            #expect(rows[1].label == "Mode")
        } else {
            Issue.record("Expected .facts")
        }
        if case .steps(let steps) = pieces[4] {
            #expect(steps.count == 2)
            #expect(steps[0].status == "built")
            #expect(steps[0].title == "Shared shutter pass")
            #expect(steps[0].note == "verified")
        } else {
            Issue.record("Expected .steps")
        }
    }

    // MARK: - Syntax & KitMermaid (syntax/paths.rs, mermaid.rs)

    @Test("Syntax.langForPath handles trailing slash and unknown paths")
    func syntaxLangForPathEdgeCases() {
        #expect(Syntax.langForPath("dir/") == nil)
        #expect(Syntax.langForPath("dir\\") == nil)
        #expect(Syntax.langForPath("") == nil)
        #expect(Syntax.langForPath("src/lib.rs") == "rust")
        #expect(Syntax.langForPath("a/b/Makefile") == "makefile")
    }

    @Test("KitMermaid suffix-only kindLabel and style defaults")
    func mermaidKindAndDefaults() {
        #expect(KitMermaid.kindLabel("stateDiagram-v2\nA --> B") == "State diagram")
        #expect(KitMermaid.kindLabel("xychart-beta\nx-axis [a, b]") == "XY chart")
        #expect(KitMermaid.kindLabel("C4Context\nPerson(a, \"A\")") == "C4 diagram")

        let k = Kit.neutral(dark: true)
        let theme = k.mermaidTheme()
        #expect(theme.maxWidth == 680)
        #expect(theme.minScale == 0.6)
        #expect(theme.surface == k.c.bgBase)
        #expect(theme.nodeFill == k.c.layer01)
        #expect(theme.noteFill == k.c.warning.bg)
    }
}
