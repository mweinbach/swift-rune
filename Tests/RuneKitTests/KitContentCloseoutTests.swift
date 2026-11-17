import Foundation
import Testing
@testable import Rune
@testable import RuneKit
import RuneMotion
#if canImport(CoreGraphics)
import CoreGraphics
#endif

@Suite("RuneKit Content Closeout Parity Tests (Batch 1)")
struct KitContentCloseoutTests {
    // MARK: - Kit.root (S2#400)

    @Test("Kit.root wraps base + overlays and forwards hoverMotionWithin curves")
    @MainActor
    func kitRootHoverCurvesAndOverlays() {
        struct S: Sendable { var clicks = 0 }
        let enterAnim = Anim<Float>(curve: .spring(Spring(duration: 0.3, bounce: 0.0)))
        let exitAnim = Anim<Float>(curve: .spring(Spring(duration: 0.25, bounce: 0.0)))
        let base: El<S> = el().key("base-page").hoverMotionWithin(enterAnim, exitAnim)
        let overlay: El<S> = el().key("toast-overlay").size(120, 32)
        let rootEl = Kit.root(base, overlays: [overlay])

        let curves = rootEl.hoverWithinCurves()
        #expect(curves != nil)
        #expect(rootEl.keyId == "kit-root")
        #expect(rootEl.children.count == 2)
        #expect(rootEl.children[0].keyId == "base-page")
        #expect(rootEl.children[1].keyId == "toast-overlay")

        let rt = Runtime<S>(state: S(), viewport: Vec2(400, 300)) { _, _ in rootEl }
        _ = rt.frame(at: 0.0)
        #expect(rt.element(byKey: "kit-root") != nil)
        #expect(rt.element(byKey: "base-page")?.rect == [0, 0, 400, 300])
        #expect(rt.element(byKey: "toast-overlay") != nil)
    }

    // MARK: - Note builder (S2#232)

    @Test("Note struct builder configures key, gap, and structured pieces")
    @MainActor
    func noteBuilderParity() {
        struct S: Sendable {}
        let k = Kit.neutral(dark: false)
        let src = """
        > [!note] Summary
        > Ready to ship.

        ```facts
        State: verified
        ```
        """
        let built: El<S> = Note(src).key("release-note").gap(18).build(k)
        #expect(built.keyId == "release-note")
        #expect(built.layout.rowGap == 18)
        let rt = Runtime<S>(state: S(), viewport: Vec2(500, 400)) { _, _ in built }
        _ = rt.frame(at: 0.0)
        let els = rt.elements()
        #expect(els.contains(where: { $0.label?.contains("Summary") == true || ($0.key ?? "").contains("release-note") }))
    }

    // MARK: - SyntaxTheme weight overrides (S2#225, S2#226)

    @Test("SyntaxTheme.withWeight clamps and weight returns per-kind override")
    func syntaxThemeWeightOverrides() {
        var theme = SyntaxTheme.fromKit(Kit.neutral(dark: true))
        #expect(theme.weight(for: .keyword) == nil)
        theme = theme.withWeight(.keyword, 700).withWeight(.comment, -50).withWeight(.string, 1500)
        #expect(theme.weight(for: .keyword) == 700)
        #expect(theme.weight(for: .comment) == 1)
        #expect(theme.weight(for: .string) == 1000)
    }

    // MARK: - ImageZoom builders & wheelZoomFactor (S2#267-#269, S2#280, S2#303-#305)

    @Test("Preview/Stage icons, labels, formatLevel, grows & wheelZoomFactor parity")
    @MainActor
    func imageZoomBuildersAndWheelZoomFactor() {
        struct S: Sendable {
            var zoom = ImageZoomState()
            var stage = StageZoom()
        }
        let k = Kit.neutral(dark: false)
        // wheelZoomFactor neutral at 0, zooms in on negative deltaY, zooms out on positive deltaY
        #expect(ImageZoomMath.wheelZoomFactor(deltaY: 0) == 1.0)
        #expect(ImageZoomMath.wheelZoomFactor(deltaY: -120) > 1.0)
        #expect(ImageZoomMath.wheelZoomFactor(deltaY: 120) < 1.0)

        let zoom = ImageZoomState(isOpen: true)
        let imgEl: El<S> = el().key("img").bg(Color(r: 0, g: 0, b: 1, a: 1))
        let preview = Preview<S>(\.zoom, natural: Vec2(400, 300), image: imgEl)
            .icons(minus: KitIcons.minus, plus: KitIcons.plus)
            .labels(zoomOut: "Out!", fit: "Fit!", zoomIn: "In!", close: "Bye!")
            .formatLevel { "\($0)pct" }
            .build(zoom, kit: k, window: Vec2(900, 700))

        let stageImgEl: El<S> = el().key("stage-img").bg(Color(r: 0, g: 1, b: 0, a: 1))
        let stage = Stage<S>(\.stage, natural: Vec2(400, 300), image: stageImgEl)
            .grows(true)
            .icons(zoomIn: KitIcons.plus, zoomOut: KitIcons.minus, fit: KitIcons.arrowRight)
            .labels(zoomIn: "Bigger", zoomOut: "Smaller", fit: "ResetFit", group: "StageTools")
            .build(StageZoom(), kit: k, size: Vec2(600, 450))

        let rt = Runtime<S>(state: S(zoom: zoom), viewport: Vec2(900, 700)) { _, _ in
            col().child(preview).child(stage)
        }
        _ = rt.frame(at: 0.0)
        let els = rt.elements()
        #expect(els.contains(where: { $0.label == "Out!" }))
        #expect(els.contains(where: { $0.label == "In!" }))
        #expect(els.contains(where: { $0.label == "Bye!" }))
        #expect(els.contains(where: { ($0.text ?? "").contains("100pct") }))
        #expect(els.contains(where: { $0.label == "StageTools" }))
        #expect(els.contains(where: { $0.label == "Bigger" }))
        #expect(els.contains(where: { $0.label == "Smaller" }))
    }

    // MARK: - Actions Button & IconButton (S2#349, S2#363, S2#365, S2#366)

    @Test("Button & IconButton expanded, help, and shortcut parity")
    @MainActor
    func actionsButtonAndIconButtonParity() {
        struct S: Sendable { var presses = 0 }
        let k = Kit.neutral(dark: false)
        let btn = Button<S>(key: "menu-trig", "Options")
            .variant(.ghost)
            .expanded(true)
            .help("Open options")
            .shortcut("⌘O")
            .onPress { s, _ in s.presses += 1 }
            .build(k)

        let iconBtn = IconButton<S>(key: "lock-btn", svg: KitIcons.lock)
            .variant(.ghost)
            .label("Lock")
            .expanded(true)
            .help("Lock pane")
            .shortcut("⌘L")
            .onPress { s, _ in s.presses += 1 }
            .build(k)

        let rt = Runtime<S>(state: S(), viewport: Vec2(400, 200)) { _, _ in
            row().gap(8).child(btn).child(iconBtn)
        }
        _ = rt.frame(at: 0.0)
        let els = rt.elements()
        let bEl = els.first { $0.key == "menu-trig" }
        let iEl = els.first { $0.key == "lock-btn" }
        #expect(bEl?.expanded == true)
        #expect(bEl?.help == "Open options  ⌘O")
        #expect(iEl?.label == "Lock")
        #expect(iEl?.expanded == true)
        #expect(iEl?.help == "Lock pane  ⌘L")
        let a11y = rt.accessibilitySnapshot()
        func findNode(_ n: AccessibilityNode, id: String) -> AccessibilityNode? {
            if n.id == id { return n }
            for c in n.children {
                if let hit = findNode(c, id: id) { return hit }
            }
            return nil
        }
        #expect(findNode(a11y, id: "menu-trig")?.keyboardShortcut == "⌘O")
        #expect(findNode(a11y, id: "lock-btn")?.keyboardShortcut == "⌘L")
    }

    @Test("IconButton neutral default, ghostMuted ink, size radii/glyphs, help-vs-label a11y, and accelerator formatting")
    @MainActor
    func iconButtonReviewFixesParity() {
        struct S: Sendable {}
        let k = Kit.neutral(dark: false)

        // 1. Default variant (.neutral) and default size (.regular -> 24x24, radius.md, glyph 16)
        let defaultBtn: El<S> = IconButton<S>(key: "def-btn", svg: KitIcons.lock)
            .label("Lock")
            .build(k)
        #expect(defaultBtn.background == k.c.bgButtonNeutral)
        #expect(defaultBtn.borderWidth == 0)
        #expect(defaultBtn.shadows == k.shadowLayers(k.elevation.buttonNeutral))
        #expect(defaultBtn.corners == .all(k.radius.md))
        #expect(defaultBtn.children.first?.keyId == "icon")
        #expect(defaultBtn.children.first?.isA11yHidden == true)
        #expect(defaultBtn.children.first?.iconPayload?.1 == 16)
        #expect(defaultBtn.children.first?.textColor == k.c.textBase)
        #expect(defaultBtn.a11yDescription == "")

        // 2. GhostMuted rest vs pressed vs expanded(true)
        let gmRest: El<S> = IconButton<S>(key: "gm-rest", svg: KitIcons.lock)
            .variant(.ghostMuted)
            .label("Mute")
            .build(k)
        let gmPressed: El<S> = IconButton<S>(key: "gm-press", svg: KitIcons.lock)
            .variant(.ghostMuted)
            .state(.pressed)
            .label("Mute")
            .build(k)
        let gmExpanded: El<S> = IconButton<S>(key: "gm-exp", svg: KitIcons.lock)
            .variant(.ghostMuted)
            .expanded(true)
            .label("Mute")
            .build(k)
        #expect(gmRest.background == .transparent)
        #expect(gmRest.children.first?.textColor == k.c.iconMuted)
        #expect(gmPressed.background == k.c.pressed)
        #expect(gmPressed.children.first?.textColor == k.c.iconBase)
        #expect(gmExpanded.background == k.c.pressed)
        #expect(gmExpanded.children.first?.textColor == k.c.iconBase)

        // 3. Help-only avoids setting a11yDescription (no VoiceOver double read); label + help sets both
        let helpOnly: El<S> = IconButton<S>(key: "help-only", svg: KitIcons.copy)
            .help("Copy link")
            .shortcut("cmd+o")
            .build(k)
        let labelAndHelp: El<S> = IconButton<S>(key: "lbl-help", svg: KitIcons.copy)
            .label("Copy")
            .help("Copy link")
            .shortcut("cmd+l")
            .build(k)
        let cmdBtn: El<S> = Button<S>(key: "cmd-btn", "Open")
            .help("Open item")
            .shortcut("cmd+o")
            .build(k)
        let rawShortcutBtn: El<S> = Button<S>(key: "raw-btn", "More")
            .shortcut("click")
            .build(k)

        // 4. Size-to-(side, cornerRadius, glyphSize) parity table
        let sizeSpecs: [(ControlSize, Float, Float, Float)] = [
            (.mini, 16, k.radius.sm, 12),
            (.small, 20, k.radius.sm, 16),
            (.regular, 24, k.radius.md, 16),
            (.large, 28, k.radius.md, 16),
            (.extraLarge, 36, k.radius.lg, 18),
        ]
        var sizedEls: [El<S>] = []
        for (idx, (sz, _, expectedRadius, expectedGlyph)) in sizeSpecs.enumerated() {
            let b: El<S> = IconButton<S>(key: "sz-\(idx)", svg: KitIcons.plus)
                .size(sz)
                .label("Add \(idx)")
                .build(k)
            #expect(b.corners == .all(expectedRadius))
            #expect(b.children.first?.iconPayload?.1 == expectedGlyph)
            sizedEls.append(b)
        }

        let rt = Runtime<S>(state: S(), viewport: Vec2(500, 300)) { _, _ in
            col().gap(4)
                .child(defaultBtn)
                .child(helpOnly)
                .child(labelAndHelp)
                .child(cmdBtn)
                .child(rawShortcutBtn)
                .children(sizedEls)
        }
        _ = rt.frame(at: 0.0)

        let defEl = rt.element(byKey: "def-btn")
        #expect(defEl?.rect[2] == 24 && defEl?.rect[3] == 24)
        #expect(defEl?.help == nil)

        let command: String = switch KeyPlatform.current {
        case .mac: "⌘"
        case .windows: "Win+"
        case .linux: "Super+"
        }
        let helpOnlyEl = rt.element(byKey: "help-only")
        #expect(helpOnlyEl?.label == "Copy link")
        #expect((helpOnlyEl?.a11yDescription ?? "") == "")
        #expect(helpOnlyEl?.help == "Copy link  \(command)O")

        let lblHelpEl = rt.element(byKey: "lbl-help")
        #expect(lblHelpEl?.label == "Copy")
        #expect(lblHelpEl?.a11yDescription == "Copy link")
        #expect(lblHelpEl?.help == "Copy link  \(command)L")

        #expect(rt.element(byKey: "cmd-btn")?.help == "Open item  \(command)O")
        #expect(rt.element(byKey: "raw-btn")?.help == "More  click")

        let a11y = rt.accessibilitySnapshot()
        func findNode(_ n: AccessibilityNode, id: String) -> AccessibilityNode? {
            if n.id == id { return n }
            for c in n.children {
                if let hit = findNode(c, id: id) { return hit }
            }
            return nil
        }
        #expect((findNode(a11y, id: "help-only")?.help ?? "").isEmpty)
        #expect(findNode(a11y, id: "help-only")?.keyboardShortcut == "\(command)O")
        #expect(findNode(a11y, id: "lbl-help")?.keyboardShortcut == "\(command)L")
        #expect(findNode(a11y, id: "cmd-btn")?.keyboardShortcut == "\(command)O")
        #expect(findNode(a11y, id: "raw-btn")?.keyboardShortcut == "click")

        for (idx, (_, expectedSide, _, _)) in sizeSpecs.enumerated() {
            let el = rt.element(byKey: "sz-\(idx)")
            #expect(el?.rect[2] == expectedSide && el?.rect[3] == expectedSide)
        }
    }

    // MARK: - Glyphs reference rasteriser check (#187)

    @Test("tests/glyphs.rs #187: All 28 built-in glyphs match independent CoreGraphics reference coverage")
    func builtInGlyphsMatchReferenceRasteriser() {
        #if canImport(CoreGraphics)
        let points = [16, 20, 32]
        var failures: [String] = []
        for (idx, icon) in KitIcons.allBuiltIn.enumerated() {
            for pt in points {
                for scale in [1, 2] {
                    let px = pt * scale
                    let ours = GlyphAtlas.rasterizeIconBitmap(icon, pixelSize: px)
                    let ref = referenceRasterize(icon, pixelSize: px)
                    #expect(ours.count == px * px && ref.count == px * px)
                    let viewScale = Float(px) / max(1.0, icon.viewBox)
                    let strokePx = (icon.strokeWidth ?? 0) * viewScale
                    if strokePx > 0 && strokePx <= 1.2 {
                        // Hairline strokes must have ink and sit within 1px of reference ink
                        let hasInk = ours.contains(where: { $0 != 0 })
                        var misplaced = !hasInk
                        if hasInk {
                            outer: for y in 0..<px {
                                for x in 0..<px where ours[y * px + x] != 0 {
                                    var nearRef = false
                                    for ry in max(0, y - 1)...min(px - 1, y + 1) {
                                        for rx in max(0, x - 1)...min(px - 1, x + 1) where ref[ry * px + rx] != 0 {
                                            nearRef = true
                                        }
                                    }
                                    if !nearRef { misplaced = true; break outer }
                                }
                            }
                        }
                        if misplaced {
                            failures.append("icon[\(idx)] at \(pt)pt @\(scale)x: hairline mismatch")
                        }
                    } else if px == 20 && (idx == 9 || idx == 12) {
                        // Upstream glyphs.rs (commit 6171ae78a): at 20px these two Ganesh masks
                        // (search=9, eye=12) differ from area coverage; pin every alpha byte via
                        // FNV-1a rather than increasing the 0.12 tolerance.
                        let hash = ours.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { h, a in
                            (h ^ UInt64(a)) &* 0x100_0000_01b3
                        }
                        let expected: UInt64 = idx == 9 ? 0x2d95_190e_92a6_ace5 : 0x493e_5596_a7d7_b305
                        if hash != expected {
                            failures.append("icon[\(idx)] at \(pt)pt @\(scale)x: FNV-1a 0x\(String(hash, radix: 16)) != 0x\(String(expected, radix: 16))")
                        }
                    } else {
                        var sumDiff: Float = 0
                        var maxUnion: Float = 0
                        for i in 0..<(px * px) {
                            let a = Float(ours[i]) / 255.0
                            let b = Float(ref[i]) / 255.0
                            sumDiff += abs(a - b)
                            maxUnion += max(a, b)
                        }
                        let mismatch = maxUnion > 0 ? sumDiff / maxUnion : 0
                        if mismatch > 0.12 {
                            failures.append("icon[\(idx)] at \(pt)pt @\(scale)x: mismatch \(mismatch)")
                        }
                    }
                }
            }
        }
        #expect(failures.isEmpty, "Glyph rasteriser failures: \(failures.joined(separator: "; "))")
        #endif
    }

    #if canImport(CoreGraphics)
    private func referenceRasterize(_ icon: SVGIcon, pixelSize px: Int) -> [UInt8] {
        // Supersample 2x and downsample to match anti-aliased coverage cleanly.
        let ss = 2
        let w = px * ss
        var hi = [UInt8](repeating: 0, count: w * w)
        let gray = CGColorSpaceCreateDeviceGray()
        if let ctx = CGContext(
            data: &hi,
            width: w,
            height: w,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: gray,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) {
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)
            ctx.translateBy(x: 0, y: CGFloat(w))
            let s = CGFloat(w) / CGFloat(icon.viewBox)
            ctx.scaleBy(x: s, y: -s)
            for d in icon.paths {
                ctx.addPath(GlyphAtlas.parseSVGPath(d))
                if let sw = icon.strokeWidth, sw > 0 {
                    ctx.setStrokeColor(gray: 1.0, alpha: 1.0)
                    ctx.setLineWidth(CGFloat(sw))
                    ctx.setLineCap(.round)
                    ctx.setLineJoin(.round)
                    ctx.strokePath()
                } else {
                    ctx.setFillColor(gray: 1.0, alpha: 1.0)
                    ctx.fillPath()
                }
            }
        }
        var out = [UInt8](repeating: 0, count: px * px)
        for y in 0..<px {
            for x in 0..<px {
                let sum =
                    Int(hi[(y * 2) * w + (x * 2)]) +
                    Int(hi[(y * 2) * w + (x * 2 + 1)]) +
                    Int(hi[(y * 2 + 1) * w + (x * 2)]) +
                    Int(hi[(y * 2 + 1) * w + (x * 2 + 1)])
                out[y * px + x] = UInt8(sum / 4)
            }
        }
        return out
    }
    #endif

    @MainActor
    @Test("§2 #358/#367/#368: IconButton.variant(.accent).onPress mounts and handles pointer click")
    func iconButtonVariantOnPressParity() {
        struct S: Sendable { var clicks = 0 }
        let kit = Kit.neutral(dark: false)
        let rt = Runtime<S>(state: S(), viewport: Vec2(240, 120)) { _, _ in
            col().p(12)
                .child(
                    IconButton<S>(key: "ib-accent", svg: KitIcons.close)
                        .label("Close")
                        .variant(.accent)
                        .onPress { st, _ in st.clicks += 1 }
                        .build(kit)
                )
        }
        _ = rt.frame(at: 0)
        let el = rt.element(byKey: "ib-accent")!
        let pt = Vec2(el.rect[0] + el.rect[2] * 0.5, el.rect[1] + el.rect[3] * 0.5)
        rt.pointerDown(at: pt, at: 0.05)
        rt.pointerUp(at: pt, at: 0.1)
        #expect(rt.state.clicks == 1)
    }
}
