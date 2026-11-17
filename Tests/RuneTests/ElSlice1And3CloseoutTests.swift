import Foundation
import Testing
@testable import Rune

@Suite("El Slice 1 & 3 Closeout Parity Tests")
struct ElSlice1And3CloseoutTests {

    private func sampleRGBA(_ frame: Frame, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let idx = (y * frame.width + x) * 4
        return (frame.rgba[idx], frame.rgba[idx + 1], frame.rgba[idx + 2], frame.rgba[idx + 3])
    }

    private func findNode(_ node: AccessibilityNode, id: String) -> AccessibilityNode? {
        if node.id == id { return node }
        for child in node.children {
            if let hit = findNode(child, id: id) { return hit }
        }
        return nil
    }

    // MARK: - 1. src/el/a11y.rs Props on El (L59, L142, L147-149, L151-152, L158, L160-163, L168)

    @Test("Integer scrolling reuses retained mask draws and reproduces the fresh command stream")
    func retainedTranslatedLabelDraws() throws {
        func app() -> Runtime<Int> {
            let rt = Runtime<Int>(state: 0, viewport: Vec2(360, 220), pixelScale: 1) { version, _ in
                let rows: [El<Int>] = (0..<20).map { i in
                    text("row \(i) value \(version)").key("r\(i)").size(280, 24)
                }
                return col().key("scroll").size(360, 220).scroll(ScrollSpec(stickBottom: false)).children(rows)
            }
            rt.textSystem.smoothing = .off
            return rt
        }
        let retained = app(), fresh = app()
        var reused = false
        for step in 0..<9 {
            let t = Double(step) / 60
            if step == 5 {
                for rt in [retained, fresh] { rt.update(at: t) { value, tx in value = 1; tx.instant() } }
            }
            if step > 0 {
                for rt in [retained, fresh] { rt.wheel(WheelEvent(dy: -4), at: Vec2(10, 40), now: t) }
            }
            let previous = retained.labelDraws
            let before = retained.element(byKey: "r4")?.rect
            fresh.labelDraws.removeAll()
            let a = retained.renderFrame(at: t), b = fresh.renderFrame(at: t)
            #expect(a.instances == b.instances)
            #expect(a.marks == b.marks)
            #expect(retained.element(byKey: "r4")?.rect == fresh.element(byKey: "r4")?.rect)
            if let before, let after = retained.element(byKey: "r4")?.rect, before[1] != after[1],
               let id = retained.flatNodes.first(where: { $0.key == "r4" })?.nodeId,
               let prior = previous[id], let current = retained.labelDraws[id],
               prior.draws.withUnsafeBufferPointer({ old in
                   current.draws.withUnsafeBufferPointer { $0.baseAddress == old.baseAddress }
               }) { reused = true }
        }
        #expect(reused)
    }

    @Test("Deep native paint traversal shapes visible text on a Swift task stack")
    func deepNativePaintTraversal() {
        let rt = Runtime(state: (), viewport: Vec2(100, 100), pixelScale: 1) { _, _ -> El<Void> in
            var branch: El<Void> = text("inside").key("leaf").size(90, 25)
            for level in 0..<72 {
                branch = el().key("level-\(level)").size(100, 100).child(branch)
            }
            return branch
        }
        let result = rt.renderFrame(at: 0)
        #expect(rt.element(byKey: "leaf")?.visible == [0, 0, 90, 25])
        #expect(result.instances.contains { $0.params.y == KIND_GLYPH })
    }

    @Test("Unclipped virtual-row labels skip offscreen glyph draws and return when scrolled into view")
    func offscreenSingleLinePaint() {
        let rt = Runtime(state: false, viewport: Vec2(120, 90), pixelScale: 1) { moved, _ -> El<Bool> in
            let label: El<Bool> = text("glyphs").key("label").truncate().w(100).h(20)
            return el().size(120, 90).clip(true)
                .child(row().pin(top: moved ? 10 : 350, left: 0).size(120, 22).child(label))
        }
        let off = rt.renderFrame(at: 0)
        #expect(rt.element(byKey: "label")?.visible[3] == 0)
        #expect(!off.instances.contains { $0.params.y == KIND_GLYPH })
        rt.update(at: 0.1) { moved, tx in
            moved = true
            tx.instant()
        }
        let on = rt.renderFrame(at: 0.1)
        #expect(rt.element(byKey: "label")?.visible[3] ?? 0 > 0)
        #expect(on.instances.contains { $0.params.y == KIND_GLYPH })
    }

    @Test("Overscan culls guide and icon draws while retaining geometry, overflowing children, and input")
    func overscanBoxAndIconPaint() throws {
        struct State { var moved = false; var taps = 0 }
        let svg = SVGIcon(viewBox: 10, paths: ["M0 0 H10 V10 H0 Z"])
        let rt = Runtime(state: State(), viewport: Vec2(120, 100), pixelScale: 2) { state, _ -> El<State> in
            let rowY: Float = state.moved ? 15 : 140
            let guide: El<State> = el().key("guide").pin(top: 0, left: 0).size(1, 20).bg(.white).mark(2)
            let glyph: El<State> = icon(svg, size: 16).key("icon").pin(top: 2, left: 4).mark(3)
            let protruding: El<State> = el().key("overhang").pin(top: -100, left: 1).size(12, 12).bg(.white).mark(4)
            let row: El<State> = el().key("row").pin(top: rowY, left: 0).size(100, 24)
                .bg(.black).mark(1).onClick { (state: inout State) in state.taps += 1 }.children([guide, glyph, protruding])
            let oversize: El<State> = icon(svg, size: 64).key("oversize").pin(top: 107, left: 54).size(8, 8).mark(5)
            return el().size(120, 100).clip(true).children([row, oversize])
        }
        let off = rt.renderFrame(at: 0)
        #expect(rt.element(byKey: "guide")?.rect == [0, 140, 1, 20])
        #expect(rt.element(byKey: "icon")?.visible[3] == 0)
        #expect(!off.marks.contains(1) && !off.marks.contains(2) && !off.marks.contains(3))
        #expect(off.marks.contains(4) && off.marks.contains(5))
        rt.update(at: 0.1) { state, tx in state.moved = true; tx.instant() }
        let on = rt.renderFrame(at: 0.1)
        #expect(on.marks.contains(1) && on.marks.contains(2) && on.marks.contains(3))
        #expect(!on.marks.contains(4) && on.marks.contains(5))
        #expect(rt.element(byKey: "icon")?.visible[3] == 16)
        rt.pointerDown(at: Vec2(45, 25), at: 0.2)
        rt.pointerUp(at: Vec2(45, 25), at: 0.21)
        #expect(rt.state.taps == 1)
    }

    @Test("Offscreen clipped cells keep element geometry without submitting invisible draws")
    func clippedCellsKeepGeometry() {
        let rt = Runtime(state: false, viewport: Vec2(100, 100), pixelScale: 1) { move, _ -> El<Bool> in
            let cell: El<Bool> = el().key("clip").pin(top: move ? 20 : 250, left: 0)
                .size(90, 20).clip(true).child(el().key("ink").size(80, 16).bg(.white))
            return el().size(100, 100).clip(true).child(cell)
        }
        let off = rt.renderFrame(at: 0)
        #expect(rt.element(byKey: "ink")?.rect[1] == 250)
        #expect(rt.element(byKey: "ink")?.visible[3] == 0)
        #expect(!off.instances.contains { $0.params.y == KIND_RECT && $0.rect.z == 80 && $0.fill.w == 1 })
        rt.update(at: 0.1) { move, tx in
            move = true
            tx.instant()
        }
        let on = rt.renderFrame(at: 0.1)
        #expect(rt.element(byKey: "ink")?.rect[1] == 20)
        #expect(on.instances.contains { $0.params.y == KIND_RECT && $0.rect.z == 80 && $0.fill.w == 1 })
    }

    @Test("el/a11y: busy, labelledBy/describedBy scoping, liveRegion, readOnly, sorted, positionInSet, shortcutHint, and level on El")
    func elA11yPropertiesAndScoping() throws {
        struct S {
            var busy = true
            var ascending: Bool? = true
            var liveStatus = "Saving..."
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(420, 320), pixelScale: 1.0) { s, _ in
            col().key("root").w(420).h(320)
                .child(
                    col().key("cardA")
                        .child(text("Account").key("title"))
                        .child(text("Controls your sign-in state").key("desc").a11yHidden())
                        .child(
                            el().key("toggleA")
                                .size(120, 30)
                                .role(.switchControl)
                                .labelledBy("title")
                                .describedBy("desc")
                                .busy(s.busy)
                                .readOnly(true)
                                .shortcutHint("Cmd+Shift+A")
                        )
                )
                .child(
                    col().key("cardB")
                        .child(text("Billing").key("title"))
                        .child(
                            el().key("toggleB")
                                .size(120, 30)
                                .role(.switchControl)
                                .label("Explicit Name")
                                .labelledBy("title")
                        )
                )
                .child(
                    text("Name Column")
                        .key("colHdr")
                        .role(.columnHeader)
                        .sorted(s.ascending)
                )
                .child(
                    el().key("treeItem")
                        .size(160, 24)
                        .role(.treeItem)
                        .label("src")
                        .level(2)
                        .positionInSet(3, size: 7)
                )
                .child(
                    text(s.liveStatus)
                        .key("statusText")
                        .liveRegion(.polite)
                )
                .child(
                    text("Alert Banner")
                        .key("alertText")
                        .liveRegion(.assertive)
                )
                .child(
                    text("Section Heading")
                        .key("secHead")
                        .headingLevel(3)
                )
        }

        _ = rt.frame(at: 0.0)
        let snap1 = rt.accessibilitySnapshot()

        let tA = try #require(findNode(snap1, id: "toggleA"))
        #expect(tA.label == "Account")
        #expect(tA.help == "Controls your sign-in state")
        #expect(tA.isBusy == true)
        #expect(tA.isReadOnly == true)
        #expect(tA.keyboardShortcut == "Cmd+Shift+A")

        let tB = try #require(findNode(snap1, id: "toggleB"))
        #expect(tB.label == "Explicit Name", "El.label wins over El.labelledBy")

        let colHdr = try #require(findNode(snap1, id: "colHdr"))
        #expect(colHdr.sortAscending == true)

        let treeItem = try #require(findNode(snap1, id: "treeItem"))
        #expect(treeItem.role == .treeItem, "El.level preserves existing role")
        #expect(treeItem.level == 1, "AccessibilityNode stores 0-based level")
        #expect(treeItem.positionInSet == 2, "AccessibilityNode stores 0-based position")
        #expect(treeItem.sizeOfSet == 7)
        #expect(rt.element(byKey: "treeItem")?.level == 2, "ElementInfo preserves 1-based level")

        let head = try #require(findNode(snap1, id: "secHead"))
        #expect(head.role == .heading)
        #expect(head.level == 2)

        let dump1 = AccessibilityDump.dictionary(from: snap1)
        let dumpJson = AccessibilityDump.jsonString(from: snap1)
        #expect(dumpJson.contains("\"sort\" : \"ascending\"") || dumpJson.contains("\"sort\":\"ascending\""))
        #expect(dumpJson.contains("\"shortcut\" : \"Cmd+Shift+A\"") || dumpJson.contains("\"shortcut\":\"Cmd+Shift+A\""))
        #expect(dumpJson.contains("\"position\" : 3") || dumpJson.contains("\"position\":3"))
        #expect(dumpJson.contains("\"setSize\" : 7") || dumpJson.contains("\"setSize\":7"))
        #expect(dumpJson.contains("\"level\" : 2") || dumpJson.contains("\"level\":2"))
        #expect(dumpJson.contains("\"read-only\""))
        #expect(dumpJson.contains("\"live-polite\""))
        #expect(dumpJson.contains("\"live-assertive\""))
        _ = dump1

        // Also verify AccessibilityTreeBuilder.project resolves labelledBy / describedBy / busy directly
        let cardEl: El<S> = col().key("wrap").size(200, 80)
            .child(text("Direct Title").key("dt"))
            .child(text("Direct Desc").key("dd"))
            .child(el().key("ctrl").size(80, 24).labelledBy("dt").describedBy("dd").busy(true).liveRegion(.assertive))
        func toInput(_ node: El<S>) -> LayoutInputNode {
            LayoutInputNode(style: node.layout, children: node.children.map(toInput))
        }
        let cardLayout = LayoutEngine.compute(root: toInput(cardEl), viewport: Vec2(200, 80))
        let built = try #require(AccessibilityTreeBuilder.project(element: cardEl, layout: cardLayout))
        let builtCtrl = try #require(findNode(built, id: "ctrl"))
        #expect(builtCtrl.label == "Direct Title")
        #expect(builtCtrl.help == "Direct Desc")
        #expect(builtCtrl.isBusy == true)
        #expect(builtCtrl.liveRegion == LiveRegionPoliteness.assertive)

        // AccessibilityTreeState detects isBusy / sort changes + liveAnnouncements emits polite status updates
        let tracker = AccessibilityTreeState()
        _ = tracker.diff(root: snap1, windowTitle: "Test")
        rt.update(at: 0.1) { st, tx in
            st.busy = false
            st.ascending = false
            st.liveStatus = "Saved"
            tx.instant()
        }
        _ = rt.frame(at: 0.1)
        let snap2 = rt.accessibilitySnapshot()
        let update = tracker.diff(root: snap2, windowTitle: "Test")
        #expect(update?.updatedNodes.contains(where: { $0.id == "toggleA" }) == true)
        #expect(findNode(snap2, id: "toggleA")?.isBusy == false)
        #expect(findNode(snap2, id: "colHdr")?.sortAscending == false)

        let anns = AccessibilityTreeBuilder.liveAnnouncements(previous: snap1, current: snap2)
        #expect(anns.contains(where: { $0.politeness == .polite && $0.text.contains("Saved") }))
    }

    @Test("el/a11y: disabled prevents focus across chained onClick, blurs focused element, and unselectable blocks HTML page selection")
    func disabledFocusAndUnselectableHTML() throws {
        struct S {
            var disableSecond = false
            var focusLostCount = 0
            var clicks = 0
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 120), pixelScale: 1.0) { s, _ in
            col().w(300).h(120)
                .child(
                    el().key("alwaysDisabled").size(100, 30)
                        .disabled(true)
                        .onClick { st, _ in st.clicks += 1 }
                )
                .child(
                    el().key("dynamicBtn").size(100, 30)
                        .focusable()
                        .disabled(s.disableSecond)
                        .onPhysicalInput { st, ev, _ in
                            if case .focusLost = ev { st.focusLostCount += 1 }
                            return false
                        }
                        .onClick { st, _ in st.clicks += 1 }
                )
        }
        _ = rt.frame(at: 0.0)
        // disabled(true).onClick must remain non-focusable and non-actionable in a11y
        #expect(rt.element(byKey: "alwaysDisabled")?.focusable == false)
        let snap1 = rt.accessibilitySnapshot()
        let disabledNode = try #require(findNode(snap1, id: "alwaysDisabled"))
        #expect(disabledNode.isDisabled == true)
        #expect(disabledNode.isFocusable == false)
        #expect(!disabledNode.actions.contains(.focus))
        #expect(!disabledNode.actions.contains(.press))

        // Focus dynamicBtn via Tab (alwaysDisabled must be skipped)
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.01)
        _ = rt.frame(at: 0.02)
        #expect(rt.focusedKey == "dynamicBtn")

        // Transition dynamicBtn to disabled(true) -> blurs & delivers focusLost
        rt.update(at: 0.03) { st, tx in
            st.disableSecond = true
            tx.instant()
        }
        _ = rt.frame(at: 0.04)
        #expect(rt.focusedKey == nil)
        #expect(rt.state.focusLostCount == 1)

        // El.unselectable() keeps subtree out of HTML page-mode selection while sibling stays selectable
        let spec = AppSpec<Int>(
            size: Vec2(300, 100),
            state: 0,
            view: { _, _ in
                col().wFull().hFull()
                    .child(text("Selectable Body").key("body"))
                    .child(
                        col().key("wordmark").unselectable()
                            .child(text("RUNE"))
                            .child(text("Copyable").selectable())
                    )
            }
        )
        let exported = try ToolingHTML.renderHTML(spec: spec, widths: [300], height: 100, document: true)
        #expect(exported.html.contains("RUNE"))
        #expect(exported.html.contains("user-select:none"))
        #expect(exported.html.contains("user-select:text"))
    }

    // MARK: - 2. tests/batch_c.rs:135, :155, :182 (L94, L607, L608, L609)

    @Test("batch_c.rs:135 fade_truncation_keeps_full_text_and_only_fades_overflowing_glyphs")
    func fadeTruncationKeepsFullTextAndOnlyFadesOverflowingGlyphs() throws {
        for scale: Float in [1.0, 2.0] {
            let rt = Runtime<Float>(state: 60.0, viewport: Vec2(600, 100), pixelScale: scale) { w, _ in
                row().child(
                    text("this is much too long")
                        .key("label")
                        .w(w)
                        .font(TextStyle(size: 14, weight: 400))
                        .truncateFade()
                )
            }
            let rf1 = rt.renderFrame(at: 0.0)
            #expect(rt.element(byKey: "label")?.text == "this is much too long")

            let glyphs = rf1.instances.filter { $0.params.y == KIND_GLYPH }
            #expect(!glyphs.isEmpty)
            let expectedFadePx = 1.5 * 14.0 * scale
            for g in glyphs {
                #expect(abs(g.clip.z - 60.0 * scale) < 1.0)
                let (w4, _) = unpackFade(g.fade)
                #expect(abs(w4.z - expectedFadePx) < 0.25, "1.5 em by default at scale \(scale)")
            }

            rt.update(at: 0.1) { s, tx in
                s = 500.0
                tx.settle()
            }
            let rf2 = rt.renderFrame(at: 0.1)
            #expect(rf2.instances.allSatisfy { unpackFade($0.fade).width == .zero })
        }
    }

    @Test("batch_c.rs:155 fade_truncation_overflow_is_independent_of_element_and_display_scale")
    func fadeTruncationOverflowIndependentOfElementAndDisplayScale() {
        let label = "clock 0123456789"
        let ts = TextSystem()
        let style = TextStyle(size: 14, weight: 400)
        for displayScale: Float in [1.0, 2.0] {
            let fullWidth = ts.measure(label, style: style, maxWidth: nil, pixelScale: displayScale).x
            for elementScale: Float in [0.5, 1.0, 2.0] {
                for (fraction, overflowing): (Float, Bool) in [(0.75, true), (1.25, false)] {
                    let liveScale = Live<Float>(elementScale)
                    let rt = Runtime<Float>(state: fullWidth * fraction, viewport: Vec2(600, 300), pixelScale: displayScale) { width, _ in
                        row().p(80).child(
                            text(label)
                                .w(width)
                                .font(style)
                                .liveScale(liveScale.binding)
                                .truncateFade()
                        )
                    }
                    let rf = rt.renderFrame(at: 0.0)
                    let fades = rf.instances
                        .filter { $0.params.y == KIND_GLYPH }
                        .map { unpackFade($0.fade).width.z }
                    #expect(!fades.isEmpty)
                    let expected = overflowing ? (1.5 * 14.0 * displayScale * elementScale) : 0.0
                    #expect(
                        fades.allSatisfy { abs($0 - expected) < 0.25 },
                        "display=\(displayScale) element=\(elementScale) overflowing=\(overflowing): got \(fades) expected \(expected)"
                    )
                }
            }
        }
    }

    @Test("batch_c.rs:182 fade_truncation_width_is_settable")
    func fadeTruncationWidthIsSettable() {
        for scale: Float in [1.0, 2.0] {
            for (width, em, expected): (Float, Float, Float) in [(60.0, 3.0, 42.0), (60.0, 0.5, 7.0)] {
                let rt = Runtime<(Float, Float)>(state: (width, em), viewport: Vec2(600, 100), pixelScale: scale) { s, _ in
                    row().child(
                        text("this is much too long")
                            .w(s.0)
                            .font(TextStyle(size: 14, weight: 400))
                            .truncateFadeWidth(s.1)
                    )
                }
                let rf = rt.renderFrame(at: 0.0)
                let fades = rf.instances
                    .filter { $0.params.y == KIND_GLYPH }
                    .map { unpackFade($0.fade).width.z }
                #expect(!fades.isEmpty)
                #expect(
                    fades.allSatisfy { abs($0 - expected * scale) < 0.25 },
                    "width \(width), \(em) em at \(scale)x: got \(fades)"
                )
            }
        }
    }

    // MARK: - 3. tests/clip.rs:171 (L1278, L1776)

    @Test("clip.rs:171 nested_row_text_keeps_full_alpha_in_the_middle_of_a_faded_list")
    func nestedRowTextKeepsFullAlphaInMiddleOfFadedList() throws {
        let renderer = try OffscreenGPURenderer()
        func fadedRows(_ faded: Bool) -> El<Bool> {
            func rowEl() -> El<Bool> {
                col().size(120, 20).clipFade(right: 8)
                    .child(text("MMMMMMMMMMMMMM").color(.white))
            }
            return col().size(120, 100).clipFade(top: faded ? 16 : 0, bottom: faded ? 16 : 0)
                .children([rowEl(), el().h(20), rowEl(), el().h(20), rowEl()])
        }

        for scale: Float in [1.0, 2.0] {
            let w = Int(120.0 * scale)
            let renderCase: (Bool, Bool) throws -> [UInt8] = { faded, zeroFadeBug in
                let rt = Runtime<Bool>(state: faded, viewport: Vec2(120, 100), pixelScale: scale) { s, _ in
                    fadedRows(s)
                }
                rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
                var rf = rt.renderFrame(at: 0.0)
                if zeroFadeBug {
                    for i in rf.instances.indices {
                        rf.instances[i].fade.z = 0
                    }
                }
                return try renderer.renderOffscreen(rf).rgba
            }

            let plain = try renderCase(false, false)
            let faded = try renderCase(true, false)
            let broken = try renderCase(true, true)

            let midStart = Int(40.0 * scale) * w * 4
            let midEnd = Int(60.0 * scale) * w * 4
            #expect(Array(plain[midStart..<midEnd]) == Array(faded[midStart..<midEnd]))

            func sumAlpha(_ slice: ArraySlice<UInt8>) -> UInt64 {
                var s: UInt64 = 0
                var idx = slice.startIndex + 3
                while idx < slice.endIndex {
                    s += UInt64(slice[idx])
                    idx += 4
                }
                return s
            }
            let midAlpha = sumAlpha(faded[midStart..<midEnd])
            #expect(midAlpha > 0)
            #expect(sumAlpha(broken[midStart..<midEnd]) < midAlpha / 2)

            let topEnd = Int(20.0 * scale) * w * 4
            #expect(sumAlpha(faded[0..<topEnd]) < sumAlpha(plain[0..<topEnd]))
        }
    }

    // MARK: - 4. tests/dim_browser.rs:55 & :81 (L1279, L1778, L1779)

    @Test("dim_browser.rs:55 a_dimmed_button_fades_as_css_opacity_does")
    func dimmedButtonFadesAsCssOpacityDoes() throws {
        let renderer = try OffscreenGPURenderer()
        let W: Float = 120
        let H: Float = 140

        func byteColor(_ v: UInt8) -> Color {
            let c = RefShader.srgbToLinear(Float(v) / 255.0)
            return Color(r: c, g: c, b: c, a: 1.0)
        }
        func mix(_ fg: Float, _ bg: Float, _ a: Float) -> Float {
            a * fg + (1.0 - a) * bg
        }
        func buttonView(page: UInt8, dim: Float, sheen: Bool) -> El<()> {
            var b: El<()> = el()
            b = b
                .size(100, 100)
                .rounded(8)
                .bg(byteColor(0x24))
                .shadow(y: 1.0, blur: 1.5, color: Color.black.alpha(0.2))
                .shadow(y: -0.5, blur: 0.0, color: Color.white.alpha(0.3))
            if sheen {
                b = b.gradient(Color.white.alpha(0.2), Color.white.alpha(0.0))
            }
            let pageBox: El<()> = el().size(W, H).bg(byteColor(page)).p(10).child(b.dim(dim))
            return pageBox
        }
        func renderOffscreen(page: UInt8, dim: Float, sheen: Bool, srgb: Bool) throws -> Frame {
            let rt = Runtime<()>(state: (), viewport: Vec2(W, H), pixelScale: 1.0) { _, _ in
                buttonView(page: page, dim: dim, sheen: sheen)
            }
            rt.setSrgbBlend(srgb, at: 0.0)
            rt.clearColor = .black
            let rf = rt.renderFrame(at: 0.0)
            return try renderer.renderOffscreen(rf)
        }

        for (pageByte, pageFloat): (UInt8, Float) in [(0xff, 255.0), (0x16, 22.0)] {
            for srgb in [true, false] {
                let frame = try renderOffscreen(page: pageByte, dim: 0.4, sheen: false, srgb: srgb)
                let got = Float(sampleRGBA(frame, x: 60, y: 60).r)
                let expected: Float = srgb
                    ? mix(36.0, pageFloat, 0.4)
                    : RefShader.linearToSRGB(
                        mix(RefShader.srgbToLinear(36.0 / 255.0), RefShader.srgbToLinear(pageFloat / 255.0), 0.4)
                    ) * 255.0
                #expect(abs(got - expected) <= 1.0, "page \(pageFloat), sRGB=\(srgb): \(got) vs \(expected)")
            }
        }

        let sheened = try renderOffscreen(page: 0xff, dim: 0.4, sheen: true, srgb: true)
        for y in [30, 60, 90] {
            let t = (Float(y) + 0.5 - 10.0) / 100.0
            let want = mix(mix(255.0, 36.0, 0.2 * (1.0 - t)), 255.0, 0.4)
            let got = Float(sampleRGBA(sheened, x: 60, y: y).r)
            #expect(abs(got - want) <= 1.5, "row \(y): \(got) vs \(want)")
        }
    }

    @Test("dim_browser.rs:81 a_shadow_paints_its_authored_alpha")
    func shadowPaintsAuthoredAlpha() throws {
        let renderer = try OffscreenGPURenderer()
        let W: Float = 120
        let H: Float = 140

        func renderCard(opaquePage: Bool) throws -> Frame {
            let rt = Runtime<()>(state: (), viewport: Vec2(W, H), pixelScale: 1.0) { _, _ in
                let card: El<()> = el().size(100, 60).bg(.white)
                    .shadow(y: 40.0, blur: 4.0, color: Color.black.alpha(31.0 / 255.0))
                var root: El<()> = el().size(W, H).p(10).child(card)
                if opaquePage { root = root.bg(.white) }
                return root
            }
            rt.setSrgbBlend(true, at: 0.0)
            rt.clearColor = opaquePage ? .white : Color(r: 0, g: 0, b: 0, a: 0)
            let rf = rt.renderFrame(at: 0.0)
            return try renderer.renderOffscreen(rf)
        }

        let overWindow = sampleRGBA(try renderCard(opaquePage: false), x: 60, y: 85)
        #expect(overWindow.r == 0 && overWindow.g == 0 && overWindow.b == 0)
        #expect(abs(Int(overWindow.a) - 31) <= 1, "expected ~31 alpha over transparent window, got \(overWindow)")

        let overPage = Float(sampleRGBA(try renderCard(opaquePage: true), x: 60, y: 85).r)
        let expected: Float = 255.0 * (1.0 - 31.0 / 255.0)
        #expect(abs(overPage - expected) <= 1.0, "expected \(expected) over white, got \(overPage)")
    }

    // MARK: - 5. src/runtime/tests/springs.rs:4 (L1691)

    @Test("springs.rs:4 dissolve_prepass_only_runs_for_trees_with_dissolve_nodes")
    func dissolvePrepassOnlyRunsForTreesWithDissolveNodes() {
        let rt = Runtime<Bool>(state: false, viewport: Vec2(64, 32), pixelScale: 1.0) { enabled, _ in
            let root: El<Bool> = el().size(64, 32).child(
                el().size(32, 32).opacity(0.5).bg(.white)
            )
            return enabled ? root.dissolve() : root
        }
        for enabled in [false, true, false] {
            rt.update(at: 0.0) { s, tx in
                s = enabled
                tx.instant()
            }
            _ = rt.renderFrame(at: 0.0)
            #expect(rt.hasDissolve == enabled)
            #expect(rt.dissolveScratch.isEmpty == !enabled)
            if enabled {
                #expect(rt.dissolveScratch.first == true)
            }

            _ = rt.frame(at: 0.0)
            #expect(rt.hasDissolve == enabled)
            #expect(rt.dissolveScratch.isEmpty == !enabled)
            if enabled {
                #expect(rt.dissolveScratch.first == true)
            }
        }
    }
}
