import Foundation
import Testing
@testable import Rune
import RuneMotion
import RuneRef

@Suite("Slice 3: Truncate Fade, Truncate Elision, Live Check, and Paint Tracks Parity Tests")
struct Slice3TruncateLivePaintTests {
    @Test("end truncation replaces a previous cut and leaves an editable field alone")
    func truncateResetsCutAndPreservesField() {
        struct Model { var edit: TextEdit }
        let label: El<Model> = text("A long label").truncateHead().truncateFade().truncate()
        #expect(label.textStyle.elide == .end)
        #expect(label.textStyle.wrap == .ellipsis)
        #expect(!label.isTruncateFadeEnabled)
        #expect(label.layout.flexShrink == 1)
        #expect(label.layout.minWidth == .points(0))

        let field = textInput(key: "field", \Model.edit)
        let unchanged = field.truncate()
        #expect(unchanged.textStyle == field.textStyle)
        #expect(unchanged.layout.flexShrink == field.layout.flexShrink)
        #expect(unchanged.layout.minWidth == field.layout.minWidth)
    }

    private static let red = Color(r: 0.9, g: 0.1, b: 0.1, a: 1.0)
    private static let blue = Color(r: 0.1, g: 0.2, b: 0.9, a: 1.0)
    private static let green = Color(r: 0.1, g: 0.75, b: 0.3, a: 1.0)
    private static let yellow = Color(r: 0.95, g: 0.8, b: 0.1, a: 1.0)

    private static func hasFadePrimitive(in scene: RefScene) -> Bool {
        scene.primitives.contains { prim in
            prim.fade != .zero
        }
    }

    private static func glyphFadePrimitives(in scene: RefScene) -> [Primitive] {
        scene.primitives.filter { prim in
            (prim.kind == .glyph || prim.kind == .layerBegin) && prim.fade != .zero
        }
    }

    private static func elementByKey(_ rt: Runtime<some Any>, _ key: String) -> ElementInfo? {
        rt.elements().first { $0.key == key }
    }

    // MARK: - 1. runtime/truncate_fade_tests.rs (3 tests)

    @Test("1.1 truncate_fade: a label that fits never fades wherever it lands across scales and zoom")
    func truncateFadeNoFadeWhileAnimatingLayoutWidth() {
        struct S {
            var zoom: Float
            var offset: Float
            var label: String
            var room: Float
        }
        func makeView(_ state: S) -> El<S> {
            el()
                .size(400 / state.zoom, 60 / state.zoom)
                .scale(state.zoom)
                .child(
                    row()
                        .w(400 / state.zoom)
                        .child(el().size(state.offset, 1))
                        .child(
                            el()
                                .maxW(state.room)
                                .child(
                                    text(state.label)
                                        .key("label")
                                        .font(TextStyle(size: 13, weight: 500))
                                        .truncateFade()
                                        .shrink()
                                )
                        )
                )
        }

        var faded: [String] = []
        for scale: Float in [1.0, 2.0] {
            for zoom: Float in [1.0, 1.1, 1.25, 1.3, 1.5, 1.6] {
                for label in ["Skill, Shell", "Read, Grep", "Shell"] {
                    for k in 0..<40 {
                        let offset = 30.0 + Float(k) * 0.137
                        let rt = Runtime<S>(
                            state: S(zoom: zoom, offset: offset, label: label, room: 300),
                            viewport: Vec2(400, 60),
                            pixelScale: scale,
                            systemDark: true
                        ) { s, _ in
                            makeView(s)
                        }
                        let scene = rt.frame(at: 0.0)
                        let f = Self.glyphFadePrimitives(in: scene)
                            .map { $0.fade.z > 0 ? (1.0 / $0.fade.z) : 0 }
                            .max() ?? 0
                        if f > 0 {
                            faded.append("\(scale)x zoom \(zoom) '\(label)' after \(offset): fades \(f) px")
                        }
                    }
                }
            }
        }
        #expect(faded.isEmpty, "\(faded.count) labels with room faded: \(faded.prefix(5))")
    }

    @Test("1.2 truncate_fade: a label cut short still fades across scales and zoom")
    func truncateFadeFadesWhenTextOverflowsLaidOutBox() {
        struct S {
            var zoom: Float
            var offset: Float
            var label: String
            var room: Float
        }
        for scale: Float in [1.0, 2.0] {
            for zoom: Float in [1.0, 1.3] {
                let rt = Runtime<S>(
                    state: S(zoom: zoom, offset: 30, label: "Skill, Shell", room: 40),
                    viewport: Vec2(400, 60),
                    pixelScale: scale,
                    systemDark: true
                ) { s, _ in
                    el()
                        .size(400 / s.zoom, 60 / s.zoom)
                        .scale(s.zoom)
                        .child(
                            row()
                                .w(400 / s.zoom)
                                .child(el().size(s.offset, 1))
                                .child(
                                    el()
                                        .maxW(s.room)
                                        .child(
                                            text(s.label)
                                                .key("label")
                                                .font(TextStyle(size: 13, weight: 500))
                                                .truncateFade()
                                                .shrink()
                                        )
                                )
                        )
                }
                let scene = rt.frame(at: 0.0)
                let faded = Self.glyphFadePrimitives(in: scene)
                #expect(!faded.isEmpty, "Cut-short label must fade at \(scale)x, zoom \(zoom)")
                #expect(faded.contains { $0.fade.x == -1.0 && $0.fade.y == 0.0 && $0.fade.z > 0.0 })
            }
        }
    }

    @Test("1.3 truncate_fade: a label that fits its layout never fades while its box grows to it")
    func truncateFadeNoFadeWhenTextFitsInsideAnimatedBox() {
        struct S {
            var label = "Read"
        }
        for scale: Float in [1.0, 2.0] {
            let rt = Runtime<S>(
                state: S(),
                viewport: Vec2(400, 40),
                pixelScale: scale,
                systemDark: true
            ) { state, _ in
                row()
                    .size(400, 40)
                    .child(
                        text(state.label)
                            .key("label")
                            .font(TextStyle(size: 13, weight: 500))
                            .truncateFade()
                            .shrink()
                            .animateLayout(Spring(duration: 0.3, bounce: 0.0))
                    )
            }

            var clock = 0.0
            for _ in 0..<60 {
                clock += 1.0 / 60.0
                _ = rt.frame(at: clock)
            }
            rt.update { s, _ in
                s.label = "Read, Shell"
            }
            var grew = false
            for f in 0..<60 {
                clock += 1.0 / 120.0
                let scene = rt.frame(at: clock)
                let label = Self.elementByKey(rt, "label")!
                grew = grew || (label.rect[2] + 1.0 < label.target[2])
                #expect(Self.glyphFadePrimitives(in: scene).isEmpty, "\(scale)x frame \(f): drawn \(label.rect), target \(label.target)")
                let glyphs = scene.primitives.filter { $0.kind == .glyph }
                if !glyphs.isEmpty {
                    let minRight = glyphs.map { ($0.clip.x + $0.clip.z) - ($0.rect.x + $0.rect.z) }.min()!
                    // Swift rasterizes glyphs with a 2px transparent quad pad (`Text.swift`) plus up to 0.5px glide shift.
                    #expect(minRight >= -2.5, "\(scale)x frame \(f): glyph ends \(-minRight) px past clip")
                }
            }
            #expect(grew, "\(scale)x: box should spring wider over frames")
        }
    }

    // MARK: - 2. runtime/truncate_tests.rs (8 tests)

    @Test("2.1 truncate: single-line end, head, middle ellipsis and grapheme cluster safety")
    func truncateSingleLineEndHeadMiddleAndGraphemeClusterSafety() {
        let ts = TextSystem()
        let baseStyle = TextStyle(size: 14, lineHeight: 20, wrap: .ellipsis, elide: .end)
        let text = "Alpha Bravo Charlie Delta Echo"

        let endShaped = ts.shape(text: text, style: baseStyle, maxWidth: 90, pixelScale: 1.0, emitGlyphs: false)
        #expect(endShaped.wasTruncated)
        #expect(endShaped.drawnText.hasSuffix("…"))
        #expect(endShaped.elided?.tail == text.utf8.count)
        #expect((endShaped.elided?.head ?? 0) > 0)

        var headStyle = baseStyle
        headStyle.elide = .head
        let headShaped = ts.shape(text: text, style: headStyle, maxWidth: 90, pixelScale: 1.0, emitGlyphs: false)
        #expect(headShaped.wasTruncated)
        #expect(headShaped.drawnText.hasPrefix("…"))
        #expect(headShaped.elided?.head == 0)
        #expect((headShaped.elided?.tail ?? text.utf8.count) < text.utf8.count)

        var midStyle = baseStyle
        midStyle.elide = .middle
        let midShaped = ts.shape(text: text, style: midStyle, maxWidth: 90, pixelScale: 1.0, emitGlyphs: false)
        #expect(midShaped.wasTruncated)
        #expect(midShaped.drawnText.contains("…"))
        #expect(!midShaped.drawnText.hasPrefix("…"))
        #expect(!midShaped.drawnText.hasSuffix("…"))
        #expect((midShaped.elided?.head ?? 0) > 0)
        #expect((midShaped.elided?.tail ?? text.utf8.count) < text.utf8.count)

        for keep: TextKeep in [.cached, .owned, .secret] {
            let keyed = ts.layoutKeyed(text: text, style: midStyle, maxWidth: 90, pixelScale: 1,
                                       emitGlyphs: true, keep: keep).shaped
            #expect(keyed.elided == midShaped.elided)
            #expect(keyed.drawnText == midShaped.drawnText)
            #expect(keyed.size == ts.measure(text, style: midStyle, maxWidth: 90, pixelScale: 1, keep: keep))
        }

        // Combining mark attached to space (" \u{0301}") must never be split onto a bare combining accent.
        let graphemeText = "a \u{0301}b \u{0301}c \u{0301}d \u{0301}e"
        for mode in [TextElide.end, .head, .middle] {
            var st = baseStyle
            st.elide = mode
            for width: Float in [18, 26, 36, 48] {
                let shaped = ts.shape(text: graphemeText, style: st, maxWidth: width, pixelScale: 1.0, emitGlyphs: false)
                if let e = shaped.elided {
                    let hIdx = graphemeText.utf8.index(graphemeText.utf8.startIndex, offsetBy: e.head)
                    let tIdx = graphemeText.utf8.index(graphemeText.utf8.startIndex, offsetBy: e.tail)
                    #expect(hIdx.samePosition(in: graphemeText) != nil)
                    #expect(tIdx.samePosition(in: graphemeText) != nil)
                    // Kept drawn string must never begin or immediately follow "…" with a bare combining mark.
                    #expect(!shaped.drawnText.contains("…\u{0301}"))
                }
            }
        }

        // Resize refit (`middle_truncation_keeps_both_ends_and_refits_on_resize`): 200 -> 320 -> 900 -> 200.
        let samplePath = "~/Projects/rune/crates/rune-kit/src/components/settings/appearance_panel.rs"
        struct PathS {}
        let rt = Runtime<PathS>(
            state: PathS(),
            viewport: Vec2(200, 40),
            pixelScale: 2.0,
            systemDark: true
        ) { _, _ -> El<PathS> in
            col().wFull().child(
                Rune.text(samplePath)
                    .key("t")
                    .font(TextStyle(size: 13, weight: 400, lineHeight: 16))
                    .truncateMiddle()
                    .selectable()
            )
        }
        _ = rt.frame(at: 0.0)
        let el0 = Self.elementByKey(rt, "t")!
        let shown0 = el0.drawnText ?? ""
        #expect(el0.elision != nil)
        #expect(shown0.hasPrefix("~/Projects") && shown0.hasSuffix("panel.rs") && shown0.contains("…"))
        #expect(el0.text == samplePath)

        rt.setViewport(Vec2(320, 40), pixelScale: 2.0)
        _ = rt.frame(at: 0.1)
        let el1 = Self.elementByKey(rt, "t")!
        #expect((el1.drawnText ?? "").count > shown0.count)

        rt.setViewport(Vec2(900, 40), pixelScale: 2.0)
        _ = rt.frame(at: 0.2)
        let el2 = Self.elementByKey(rt, "t")!
        #expect(el2.drawnText == samplePath && el2.elision == nil)

        rt.setViewport(Vec2(200, 40), pixelScale: 2.0)
        _ = rt.frame(at: 0.3)
        let el3 = Self.elementByKey(rt, "t")!
        #expect(el3.drawnText == shown0)
    }

    @Test("2.2 truncate: TextElision splices content, maps drawn offsets, and drops cut ranges")
    func truncateElisionContentDrawnAndRangeMapping() {
        let src = "0123456789ABCDEF"
        let e = TextElision(head: 4, tail: 12)
        #expect(e.drawnString(from: src) == "0123…CDEF")
        #expect(e.drawnLength(contentBytes: src.utf8.count) == "0123…CDEF".utf8.count)
        #expect(e.drawnOffset(forContent: 3, end: true) == 3)
        #expect(e.drawnOffset(forContent: 14, end: true) == 4 + 3 + 2)
        #expect(e.mark(1, 3, isLink: false) == (1..<3))
        #expect(e.mark(5, 10, isLink: false).isEmpty)
        #expect(e.mark(13, 16, isLink: false) == ((4 + 3 + 1)..<(4 + 3 + 4)))
        #expect(e.mark(0, 16, isLink: false) == (0..<e.drawnLength(contentBytes: 16)))
        #expect(e.contentOffset(forDrawn: 1) == 1)
        #expect(e.contentOffset(forDrawn: 4 + 3 + 2) == 14)
        #expect(e.selectionRange(1..<14) == (1..<(4 + 3 + 2)))

        // The cut starts and ends at span boundaries, so the inserted glyph uses the base style.
        let spans = [TextSpan("0123", color: Self.red), TextSpan("456789AB", color: Self.blue), TextSpan("CDEF", color: Self.green)]
        let drawn = e.drawnString(from: src)
        let visible = e.mapSpans(spans, originalLength: src.utf8.count, drawn: drawn)
        #expect(visible.map(\.text) == ["0123", "…", "CDEF"])
        #expect(visible.map(\.color) == [Self.red, nil, Self.green])
        let all = TextElision(head: 0, tail: src.utf8.count)
        #expect(all.mapSpans(spans, originalLength: src.utf8.count, drawn: "…") == [TextSpan("…")])
    }

    @Test("2.3 truncate: elision and shape caches reuse entries and prune stale elisions on commit")
    func truncateElisionAndShapeCachesReuseAndPrune() {
        struct S {
            var txt: String
        }
        let longText = "This is a deliberately very long line for elision cache testing"
        let rt = Runtime<S>(
            state: S(txt: longText),
            viewport: Vec2(200, 80),
            pixelScale: 1.0,
            systemDark: true
        ) { state, _ in
            text(state.txt).key("label").w(90).ellipsis()
        }

        _ = rt.frame(at: 0.0)
        #expect(rt.textSystem.cachedElisionCount == 1)
        let shapesAfterFrame1 = rt.textSystem.shapeCount

        _ = rt.frame(at: 0.016)
        #expect(rt.textSystem.cachedElisionCount == 1)
        #expect(rt.textSystem.shapeCount == shapesAfterFrame1)

        // Switching to short non-overflowing text prunes the unused elision entry on commit.
        rt.update { s, tx in
            s.txt = "Short"
        }
        _ = rt.frame(at: 0.032)
        #expect(rt.textSystem.cachedElisionCount == 0)

        // Direct TextSystem shape cache reuses shaped result across identical calls.
        let ts = TextSystem()
        let style = TextStyle(size: 14, lineHeight: 20, wrap: .ellipsis, elide: .middle)
        _ = ts.shape(text: longText, style: style, maxWidth: 80, pixelScale: 1.0, emitGlyphs: true)
        let afterFirst = ts.shapeCount
        _ = ts.shape(text: longText, style: style, maxWidth: 80, pixelScale: 1.0, emitGlyphs: true)
        #expect(ts.shapeCount == afterFirst)
        #expect(ts.cachedElisionCount == 1)
    }

    @Test("2.4 truncate: secure input bypasses elision cache and hides plaintext")
    func truncateSecureInputBypassesElisionCache() {
        struct S {
            var secret = "super-secret-password-string-that-overflows-narrow-field"
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 80),
            pixelScale: 1.0,
            systemDark: true
        ) { state, _ in
            text(state.secret).key("pw").w(80).secure().ellipsis()
        }

        _ = rt.frame(at: 0.0)
        #expect(rt.textSystem.cachedElisionCount == 0)
        let info = Self.elementByKey(rt, "pw")
        #expect(info?.text == nil)
        #expect(info?.drawnText == nil)
        #expect(info?.secure == true)
    }

    @Test("2.5 truncate: links inside cut middle emit zero hitboxes while visible links remain clickable")
    func truncateLinksInCutMiddleHaveZeroHitboxesWhileVisibleLinksWork() {
        struct S {
            var clicked: [String] = []
        }
        let full = "Start here [middle-cut-link-inside-elided-region-long-text] EndLink"
        let midStart = full.utf8.count / 4
        let midEnd = (full.utf8.count * 3) / 4
        let tailStart = full.utf8.count - "EndLink".utf8.count
        let tailEnd = full.utf8.count

        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(300, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            text(full)
                .key("linked")
                .w(110)
                .truncateMiddle()
                .link(TextLink(midStart..<midEnd, id: "cut"))
                .link(TextLink(tailStart..<tailEnd, id: "end"))
                .onLink { s, id in
                    s.clicked.append(id)
                }
        }

        _ = rt.frame(at: 0.0)
        let info = Self.elementByKey(rt, "linked")!
        #expect(info.elision != nil)
        let boxes = rt.linkBoxesByPath[info.path] ?? []
        #expect(!boxes.contains { $0.link.id == "cut" }, "Link completely inside cut middle must have zero hitboxes")
        let endBox = boxes.first { $0.link.id == "end" }
        #expect(endBox != nil, "Tail link outside cut region must produce a hitbox")

        if let b = endBox?.windowUnion {
            let pt = Vec2(b.x + b.z * 0.5, b.y + b.w * 0.5)
            rt.pointerDown(at: pt, at: 0.05)
            rt.pointerUp(at: pt, at: 0.06)
            _ = rt.frame(at: 0.07)
            #expect(rt.state.clicked == ["end"])
        }
    }

    @Test("2.6 truncate: cut highlights, spans, and pills omit elided gap and keep visible segments")
    func truncateHighlightsSpansAndPillsOmitCutRegion() {
        struct S {}
        let prefix = "Alpha "
        let cut = "middle_cut_region_that_will_be_elided_out_completely"
        let suffix = " Omega"
        let full = prefix + cut + suffix
        let prefixRange = 0..<prefix.utf8.count
        let cutRange = prefix.utf8.count..<(prefix.utf8.count + cut.utf8.count)
        let suffixRange = (prefix.utf8.count + cut.utf8.count)..<full.utf8.count

        // Verify span + pill slicing directly via TextSystem with middle elision.
        let ts = TextSystem()
        let style = TextStyle(size: 14, lineHeight: 20, wrap: .ellipsis, elide: .middle)
        let spans = [
            TextSpan(prefix, color: Self.red),
            TextSpan(cut, color: Self.green, background: Self.yellow),
            TextSpan(suffix, color: Self.blue, background: Self.red),
        ]
        let cutPill = PillChip(cutRange, style: .default)
        let headPill = PillChip(0..<3, style: .default)
        let shaped = ts.shape(text: "", spans: spans, pills: [headPill, cutPill], style: style, maxWidth: 110, pixelScale: 1.0, emitGlyphs: false)
        #expect(shaped.wasTruncated)
        #expect(shaped.elided != nil)
        #expect(shaped.pillChips.count == 1, "Cut pill must be omitted while kept head pill remains")
        #expect(shaped.pillChips.first?.pillIndex == 0)

        // Verify Runtime TextHighlightPainter omits cut highlight and keeps visible suffix highlight.
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(300, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            text(full)
                .key("hl-elide")
                .w(110)
                .size(14)
                .truncateMiddle()
                .textHighlights([
                    TextHighlight(cutRange, bg: Self.yellow, key: "cut"),
                    TextHighlight(suffixRange, bg: Self.green, key: "kept"),
                ])
        }
        let scene = rt.frame(at: 0.0)
        let info = Self.elementByKey(rt, "hl-elide")!
        #expect(info.elision != nil)
        #expect(info.elision!.mark(cutRange.lowerBound, cutRange.upperBound, isLink: false).isEmpty)
        let drawnSuffix = info.elision!.mark(suffixRange.lowerBound, suffixRange.upperBound, isLink: false)
        #expect(!drawnSuffix.isEmpty)
        let yellowRects = scene.primitives.filter { prim in
            prim.kind == .roundedRect && prim.fill.x > 0.7 && prim.fill.y > 0.5 && prim.fill.z < 0.2
        }
        #expect(yellowRects.isEmpty, "Highlight inside cut middle must produce zero background quads")
        #expect(prefixRange.count > 0)
    }

    @Test("2.7 truncate: drag selection and Select All on truncated text copy full authored text")
    func truncateDragSelectionAndSelectAllCopyAuthoredText() {
        struct S {}
        let full = "Header part that is kept — Middle elided text — Footer kept"
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(400, 120),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            col()
                .size(400, 120)
                .selectionGroup()
                .child(
                    text(full)
                        .key("sel")
                        .w(130)
                        .truncateMiddle()
                        .selectable()
                )
        }

        _ = rt.frame(at: 0.0)
        let info = Self.elementByKey(rt, "sel")!
        #expect(info.elision != nil)
        #expect(info.text == full)
        #expect(info.drawnText != full)

        // Click + drag across the entire box selects full authored text including cut middle.
        let r = info.rect
        let yMid = r[1] + r[3] * 0.5
        let xLeft = r[0] + 0.5
        let xRight = r[0] + r[2] - 0.5
        rt.pointerMove(to: Vec2(xLeft, yMid), at: 0.04)
        rt.pointerDown(at: Vec2(xLeft, yMid), at: 0.05)
        _ = rt.frame(at: 0.06)
        rt.pointerMove(to: Vec2(xRight, yMid), at: 0.07)
        _ = rt.frame(at: 0.08)
        rt.pointerUp(at: Vec2(xRight, yMid), at: 0.09)
        _ = rt.frame(at: 0.1)
        let dragged = rt.selectedText() ?? ""
        #expect(dragged == full, "Dragging across '…' must select full authored text: got '\(dragged)'")

        // Select All includes complete authored text while keeping selection geometry within drawn box.
        _ = rt.keyDown(KeyEvent(key: .command("a"), mods: RuneTestKey.primaryMods()), at: 0.15)
        _ = rt.frame(at: 0.16)
        #expect(rt.selectedText() == full)
    }

    @Test("2.8 truncate: non-overflowing ellipsis text does not truncate or cache elision")
    func truncateNonOverflowingEllipsisDoesNotTruncateOrCacheElision() {
        struct S {}
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(300, 80),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            text("Short")
                .key("short")
                .w(200)
                .ellipsis()
        }

        _ = rt.frame(at: 0.0)
        let info = Self.elementByKey(rt, "short")!
        #expect(info.text == "Short")
        #expect(info.drawnText == "Short")
        #expect(info.elision == nil)
        #expect(rt.textSystem.cachedElisionCount == 0)
    }

    // MARK: - 3. runtime/live_check_tests.rs (8 upstream tests + coverage checks)

    @Test("3.1 live_check: hover rows at rest with hoverGroup and groupColor never flag a view change")
    func liveCheckWarnsAndIncrementsCounterOnLiveOnlyStateMutation() {
        enum Side { case old, new }
        struct Rows {
            var copy: Side = .new
            var hovered: [Int] = []
            var changes = 0
            var selections = 0
        }
        let rowH: Float = 20
        func sideFor(_ i: Int) -> Side { (i % 4 == 3) ? .old : .new }
        func rowY(_ i: Int) -> Float { Float(i + 1) * rowH + rowH * 0.5 }

        let rt = Runtime<Rows>(
            state: Rows(),
            viewport: Vec2(400, 600),
            pixelScale: 2.0,
            systemDark: true
        ) { s, _ -> El<Rows> in
            let rowEls: [El<Rows>] = (0..<24).map { (i: Int) -> El<Rows> in
                let side = sideFor(i)
                let copy = s.copy == side
                var t: El<Rows> = text("let value_\(i) = compute(\(i));").key("text")
                if copy {
                    t = t.selectable(true)
                    t.selectionColor = .white
                }
                let code = col()
                    .key("code")
                    .grow(1)
                    .minH(rowH)
                    .child(t)
                    .onHoverChange { st, inside, tx in
                        if inside {
                            st.hovered.append(i)
                        } else {
                            st.hovered.removeAll { $0 == i }
                        }
                        if inside && st.copy != side {
                            st.copy = side
                            st.changes += 1
                        } else {
                            tx.liveOnly()
                        }
                    }
                return row()
                    .key("r\(i)")
                    .wFull()
                    .minH(rowH)
                    .bg(copy ? Color.black : Color.transparent)
                    .hover(Color.white.alpha(0.06))
                    .hoverGroup()
                    .child(
                        el()
                            .key("gutter")
                            .size(40, rowH)
                            .child(text("\(i)").key("n").groupColor(.white))
                    )
                    .child(code)
            }
            return col()
                .sizeFull()
                .scrollY()
                .child(text("\(s.selections) selections").key("selections"))
                .child(
                    col()
                        .key("rows")
                        .wFull()
                        .selectionGroup(true)
                        .children(rowEls)
                        .onSelectionChange { st, _, _ in
                            st.selections += 1
                        }
                )
        }

        var clock = 0.0
        for _ in 0..<60 {
            clock += 1.0 / 60.0
            _ = rt.frame(at: clock)
        }
        for (n, i) in [0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14].enumerated() {
            clock += (n < 6) ? 0.3 : (1.0 / 60.0)
            _ = rt.frame(at: clock)
            rt.pointerMove(to: Vec2(200, rowY(i)), at: clock)
            for _ in 0..<3 {
                clock += 1.0 / 60.0
                _ = rt.frame(at: clock)
            }
        }
        #expect(rt.liveChecks >= 6)
        #expect(rt.state.changes == 0)
        #expect(rt.liveOnlyWarnings.isEmpty, "Unexpected hover warnings: \(rt.liveOnlyWarnings.joined(separator: "; "))")
    }

    @Test("3.2 live_check: checkLiveOnly(false) suppresses check commits and warnings")
    func liveCheckDisabledSuppressesChecksAndWarnings() {
        struct S {
            var count = 0
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { state, _ in
            text("Count: \(state.count)")
                .key("btn")
                .size(160, 40)
                .onPointerMove { s, _, tx in
                    s.count += 1
                    tx.liveOnly()
                }
        }
        rt.checkLiveOnly(false)
        _ = rt.frame(at: 0.0)
        rt.pointerMove(to: Vec2(40, 20), at: 0.1)
        _ = rt.frame(at: 0.11)

        #expect(rt.liveOnlyEvents >= 1)
        #expect(rt.liveChecks == 0)
        #expect(rt.liveOnlyWarnings.isEmpty)
    }

    @Test("3.3 live_check: leave and enter in same frame ignores leave check when enter commits")
    func liveCheckLeaveAndEnterInOneFrameIgnoresLeaveWhenEnterCommits() {
        struct S {
            var active = "none"
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(240, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { state, _ in
            row()
                .size(240, 100)
                .child(
                    text("A (\(state.active))")
                        .key("boxA")
                        .size(100, 80)
                        .onHoverChange { _, inside, tx in
                            if !inside {
                                tx.liveOnly()
                            }
                        }
                )
                .child(
                    text("B (\(state.active))")
                        .key("boxB")
                        .size(100, 80)
                        .onHoverChange { s, inside, _ in
                            if inside {
                                s.active = "B"
                            }
                        }
                )
        }

        _ = rt.frame(at: 0.0)
        // Enter boxA cleanly first.
        rt.pointerMove(to: Vec2(50, 40), at: 0.05)
        _ = rt.frame(at: 0.06)

        // Advance >2s so live-only check interval triggers on boxA leave, while simultaneously entering boxB.
        rt.pointerMove(to: Vec2(150, 40), at: 3.0)
        _ = rt.frame(at: 3.01)

        #expect(rt.state.active == "B")
        #expect(rt.liveOnlyWarnings.isEmpty, "Non-liveOnly enter commit must clear pending liveOnly check")
    }

    @Test("3.4 live_check: grown viewport preserves virtual overscan during check commit")
    func liveCheckGrownViewportDoesNotMakeVirtualOverscanAViewChange() {
        struct S {}
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 120),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            col()
                .sizeFull()
                .onPointerMove { _, _, tx in tx.liveOnly() }
                .child(
                    col()
                        .key("vlist")
                        .wFull()
                        .grow(1)
                        .scrollY()
                        .virtualRows(50, 30, key: { _, i in "row-\(i)" }) { _, i in
                            text("Row \(i)").key("row-\(i)").wFull().h(30)
                        }
                )
        }

        _ = rt.frame(at: 0.0)
        rt.setViewport(Vec2(200, 320))
        _ = rt.frame(at: 0.02)
        rt.pointerMove(to: Vec2(50, 50), at: 3.0)
        _ = rt.frame(at: 3.01)

        #expect(rt.liveOnlyWarnings.isEmpty, "Growing viewport during liveOnly check commit must freeze virtual overscan")
    }

    @Test("3.5 live_check: dragging text selection never reports a false view change")
    func liveCheckDraggingTextSelectionNeverReportsViewChange() {
        struct S {}
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(300, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            col()
                .size(300, 100)
                .child(
                    text("Selectable paragraph for dragging check")
                        .key("sel")
                        .w(260)
                        .selectable()
                        .onPointerMove { _, _, tx in tx.liveOnly() }
                )
        }

        _ = rt.frame(at: 0.0)
        let r = Self.elementByKey(rt, "sel")!.rect
        let y = r[1] + r[3] * 0.5
        rt.pointerDown(at: Vec2(r[0] + 6, y), at: 0.1)
        rt.pointerMove(to: Vec2(r[0] + 90, y), at: 3.0)
        _ = rt.frame(at: 3.01)
        rt.pointerUp(at: Vec2(r[0] + 90, y), at: 3.05)
        _ = rt.frame(at: 3.06)

        #expect(!(rt.selectedText() ?? "").isEmpty)
        #expect(rt.liveOnlyWarnings.isEmpty)
    }

    @Test("3.6 live_check: onSelectionChange handler after checked liveOnly event clears pending check")
    func liveCheckSelectionHandlerAfterCheckedEventNeverReportsFalseDiff() {
        struct S {
            var lastLen = 0
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(300, 120),
            pixelScale: 1.0,
            systemDark: true
        ) { state, _ in
            col()
                .size(300, 120)
                .child(
                    text("Status len: \(state.lastLen)")
                        .key("status")
                        .h(24)
                        .onPointerMove { _, _, tx in tx.liveOnly() }
                )
                .child(
                    text("Select some characters here cleanly")
                        .key("body")
                        .w(260)
                        .selectable()
                        .onSelectionChange { s, change, _ in
                            s.lastLen = (change.selection?.text ?? "").count
                        }
                )
        }

        _ = rt.frame(at: 0.0)
        let statusR = Self.elementByKey(rt, "status")!.rect
        let bodyR = Self.elementByKey(rt, "body")!.rect

        // Trigger checked liveOnly event on status, then select on body in the same frame!
        rt.pointerMove(to: Vec2(statusR[0] + 10, statusR[1] + 10), at: 3.0)
        let y = bodyR[1] + bodyR[3] * 0.5
        rt.pointerDown(at: Vec2(bodyR[0] + 4, y), at: 3.005)
        rt.pointerMove(to: Vec2(bodyR[0] + 120, y), at: 3.01)
        rt.pointerUp(at: Vec2(bodyR[0] + 120, y), at: 3.015)
        _ = rt.frame(at: 3.02)

        #expect(rt.state.lastLen > 0)
        #expect(rt.liveOnlyWarnings.isEmpty, "Committing onSelectionChange after checked liveOnly must not warn: \(rt.liveOnlyWarnings)")
    }

    @Test("3.7 live_check: live values on fill, border, and text never warn as view changes")
    func liveCheckLiveValuesOnFillBorderAndTextNeverWarn() {
        struct S {
            var fill = Live<Color>(Color(r: 0.2, g: 0.3, b: 0.4, a: 1.0))
            var border = Live<Color>(Color(r: 0.5, g: 0.5, b: 0.6, a: 1.0))
            var textCol = Live<Color>(Color(r: 0.9, g: 0.9, b: 0.9, a: 1.0))
            var text = LiveText("Initial")
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(240, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { state, _ in
            col()
                .key("card")
                .size(200, 60)
                .border(2, .white)
                .liveFill(Binding(live: state.fill))
                .liveBorder(Binding(live: state.border))
                .liveTextColor(Binding(live: state.textCol))
                .child(liveText(state.text).key("lt"))
                .onPointerMove { s, _, tx in
                    s.fill.set(Self.blue)
                    s.border.set(Self.green)
                    s.textCol.set(Self.red)
                    s.text.set("Updated via live")
                    tx.liveOnly()
                }
        }

        _ = rt.frame(at: 0.0)
        rt.pointerMove(to: Vec2(40, 20), at: 3.0)
        _ = rt.frame(at: 3.01)
        rt.pointerMove(to: Vec2(45, 22), at: 6.0)
        _ = rt.frame(at: 6.01)

        #expect(rt.liveOnlyWarnings.isEmpty, "Live fill/border/text updates must not warn: \(rt.liveOnlyWarnings)")
    }

    @Test("live-only comparisons redact secure text and report text colour separately")
    func liveCheckSecureTextAndColour() throws {
        struct Value {
            var label = "private-label-a"
            var revealed = false
            var colour = Color.rgba8(64, 128, 192, 255)
        }
        let runtime = Runtime<Value>(state: Value(), viewport: Vec2(200, 40), pixelScale: 1.0) { value, _ in
            text(value.label).secure().revealed(value.revealed).color(value.colour).size(200, 40)
        }
        _ = runtime.frame(at: 0)
        var before = runtime.viewPrint()
        runtime.update(at: 0.1) { value, _ in
            value.label = "private-label-b"
            value.revealed = true
        }
        _ = runtime.frame(at: 0.1)
        var after = runtime.viewPrint()
        let change = try #require(before.firstDifference(against: after))
        #expect(change.what == "text")
        #expect(change.values?.0 == "[redacted]")
        #expect(change.values?.1 == "[redacted]")

        before = after
        runtime.update(at: 0.2) { value, _ in value.colour = .white }
        _ = runtime.frame(at: 0.2)
        after = runtime.viewPrint()
        let colour = try #require(before.firstDifference(against: after))
        #expect(colour.what == "text colour")
        #expect(colour.values?.0 == "#4080c0ff")
        #expect(colour.values?.1 == "#ffffffff")
    }

    @Test("3.8 live_check: warning names element & all 5 property/structure diffs and deduplicates repeats")
    func liveCheckExitingNodeIgnoredAndAccurateDiffFormat() {
        struct CaseS {
            var diffCase: Int
            var changed = false
        }
        func makeCaseApp(_ diffCase: Int) -> Runtime<CaseS> {
            let rt = Runtime<CaseS>(
                state: CaseS(diffCase: diffCase, changed: false),
                viewport: Vec2(400, 400),
                pixelScale: 1.0,
                systemDark: true
            ) { s, _ -> El<CaseS> in
                let on = s.changed
                var c: El<CaseS> = col()
                    .key("list")
                    .w(200)
                    .focusable(true)
                    .onKey { st, _, tx in
                        st.changed.toggle()
                        tx.liveOnly()
                        return true
                    }
                    .child(
                        el()
                            .key("box")
                            .size((on && s.diffCase == 0) ? 60 : 40, 20)
                            .bg((on && s.diffCase == 1) ? Color.white : Color.black)
                    )
                    .child(
                        text((on && s.diffCase == 2) ? "a much longer label than the one before it, cut short" : "label")
                            .key("label")
                            .size(200, 20)
                    )
                if on && s.diffCase == 3 {
                    c = c.child(el().key("extra").size(10, 10))
                }
                if !(on && s.diffCase == 4) {
                    c = c.child(el().key("tail").size(10, 10))
                }
                return c
            }
            _ = rt.frame(at: 0.0)
            let listPath = Self.elementByKey(rt, "list")!.path
            rt.focusedPath = listPath
            return rt
        }

        let want = [
            "layout rect of \"{list}/@box\" went from [0.0, 0.0, 40.0, 20.0] to [0.0, 0.0, 60.0, 20.0]",
            "fill of \"{list}/@box\" went from #000000ff to #ffffffff",
            "text of \"{list}/@label\" went from \"label\" to \"a much longer label than the one before …\"",
            "added element of \"{list}/@extra\"",
            "removed element of \"{list}/@tail\"",
        ]
        for (idx, pattern) in want.enumerated() {
            let rt = makeCaseApp(idx)
            let listPath = Self.elementByKey(rt, "list")!.path
            let expected = pattern.replacingOccurrences(of: "{list}", with: listPath)
            _ = rt.frame(at: 0.5)
            _ = rt.keyDown(KeyEvent(key: .arrowRight), at: 0.51)
            _ = rt.frame(at: 0.52)
            #expect(rt.liveOnlyWarnings.count == 1, "case \(idx): \(rt.liveOnlyWarnings.joined(separator: "; "))")
            let w = rt.liveOnlyWarnings[0]
            #expect(w.hasPrefix("rune: onKey called Tx::liveOnly, but the view built something else after it: "), "\(w)")
            #expect(w.contains(expected), "case \(idx): \(w) | expected: \(expected)")
        }

        // Deduplication & repeat only for another element/property (`the_warning_repeats_only_for_another_element_or_property`).
        let rep = makeCaseApp(1)
        var t = 0.0
        for _ in 0..<4 {
            t += 0.5
            _ = rep.frame(at: t)
            _ = rep.keyDown(KeyEvent(key: .arrowRight), at: t + 0.01)
            _ = rep.frame(at: t + 0.02)
            t += 0.02
        }
        #expect(rep.liveChecks == 4)
        #expect(rep.liveOnlyWarnings.count == 1, "Same handler/element/property must deduplicate: \(rep.liveOnlyWarnings.joined(separator: "; "))")

        rep.update { s, tx in
            s.diffCase = 0
            tx.instant()
        }
        t += 0.5
        _ = rep.frame(at: t)
        _ = rep.keyDown(KeyEvent(key: .arrowRight), at: t + 0.01)
        _ = rep.frame(at: t + 0.02)
        #expect(rep.liveOnlyWarnings.count == 2, "Second property must warn: \(rep.liveOnlyWarnings.joined(separator: "; "))")
        let listPath = Self.elementByKey(rep, "list")!.path
        #expect(rep.liveOnlyWarnings[1].contains("layout rect of \"\(listPath)/@box\""))
    }

    @Test("3.9 live_check: stale row mounted below viewport still warns after viewport grows")
    func liveCheckStaleRowMountedBelowViewportWarnsAfterViewportGrows() {
        struct LongS {
            var hovers: UInt32 = 0
            var staleFrom: Int = 30
        }
        let rowH: Float = 20
        let rt = Runtime<LongS>(
            state: LongS(),
            viewport: Vec2(400, 300),
            pixelScale: 2.0,
            systemDark: true
        ) { _, _ -> El<LongS> in
            let list: El<LongS> = col()
                .key("rows")
                .wFull()
                .growth(GrowthSpec())
                .virtualRows(2000, rowH, key: { (_: LongS, i: Int) -> String in "r\(i)" }) { (s: LongS, i: Int) -> El<LongS> in
                    let label = i >= s.staleFrom ? "\(i): \(s.hovers)" : "\(i)"
                    return col()
                        .size(400, rowH)
                        .child(
                            text(label)
                                .key("cell")
                                .wFull()
                                .h(rowH)
                                .onHoverChange { st, _, tx in
                                    if st.staleFrom < 2000 {
                                        st.hovers += 1
                                    }
                                    tx.liveOnly()
                                }
                        )
                }
            let scrollBox: El<LongS> = col()
                .key("scroll")
                .wFull()
                .grow(1)
                .minH(0)
                .scrollY()
                .child(list)
            return col()
                .sizeFull()
                .child(scrollBox)
        }
        var clock = 0.0
        _ = rt.frame(at: clock)
        for _ in 0..<60 {
            clock += 1.0 / 60.0
            _ = rt.frame(at: clock)
        }
        rt.setViewport(Vec2(400, 360), pixelScale: 2.0)
        for _ in 0..<10 {
            clock += 1.0 / 60.0
            _ = rt.frame(at: clock)
        }
        clock += 0.3
        _ = rt.frame(at: clock)
        rt.pointerMove(to: Vec2(200, 45), at: clock)
        for _ in 0..<3 {
            clock += 1.0 / 60.0
            _ = rt.frame(at: clock)
        }
        #expect(rt.liveOnlyWarnings.count == 1, "\(rt.liveOnlyWarnings.joined(separator: "; "))")
        let w = rt.liveOnlyWarnings.first ?? ""
        #expect(w.contains("text of") && w.contains("/@rows/@r30/@cell"), "\(w)")
    }

    // MARK: - 4. runtime/paint_tracks_tests.rs (6 tests)

    @Test("4.1 paint_tracks: static tree with fill, border, textColor, and shadow allocates zero tracks")
    func paintTracksStaticTreeAllocatesZeroTracks() {
        struct S {}
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(240, 140),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            text("Static")
                .key("box")
                .size(160, 48)
                .bg(Self.red)
                .border(2, Self.blue)
                .color(.white)
                .shadow(Shadow(x: 0, y: 4, blur: 8, color: Self.green))
        }

        _ = rt.frame(at: 0.0)
        #expect(rt.scene.store.trackLen == 0)

        rt.update { _, _ in }
        _ = rt.frame(at: 0.1)
        #expect(rt.scene.store.trackLen == 0)
    }

    @Test("4.2 paint_tracks: changing only fill allocates track on changed property only and settles")
    func paintTracksOnlyAnimatingFillOrBorderAllocatesChangedTrack() {
        struct S {
            var active = false
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { state, _ in
            col()
                .key("card")
                .size(120, 40)
                .bg(state.active ? Self.blue : Self.red)
                .border(2, Self.green)
        }

        _ = rt.frame(at: 0.0)
        #expect(rt.scene.store.trackLen == 0)

        rt.update { s, tx in
            s.active = true
        }
        _ = rt.frame(at: 0.05)
        let cardId = NodeId.hash(Self.elementByKey(rt, "card")!.path)
        #expect(rt.scene.store.isNodeAnimating(cardId))
        #expect(rt.scene.store.isAnimating(cardId, Props.FILL))
        #expect(!rt.scene.store.isAnimating(cardId, Props.BORDER))

        _ = rt.frame(at: 2.0)
        #expect(!rt.scene.store.isNodeAnimating(cardId))
    }

    @Test("4.3 paint_tracks: animated textColor allocates Props.TEXT_COLOR track and interpolates smoothly")
    func paintTracksTextColorAllocatesAndInterpolates() {
        struct S {
            var highlight = false
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(240, 100),
            pixelScale: 1.0,
            systemDark: true
        ) { state, _ in
            text("Colored Text")
                .key("label")
                .size(180, 32)
                .color(state.highlight ? Self.blue : Self.red)
        }

        _ = rt.frame(at: 0.0)
        let labelInfo0 = Self.elementByKey(rt, "label")!
        let labelId = NodeId.hash(labelInfo0.path)
        #expect(rt.scene.store.trackLen == 0)
        #expect(labelInfo0.textColor == Self.red)

        rt.update { s, tx in
            s.highlight = true
        }
        let midScene = rt.frame(at: 0.05)
        #expect(rt.scene.store.isAnimating(labelId, Props.TEXT_COLOR))
        #expect(rt.scene.store.isNodeAnimating(labelId))
        let midCol = Self.elementByKey(rt, "label")!.textColor!
        #expect(midCol.r < Self.red.r && midCol.r > Self.blue.r, "Midpoint textColor.r should interpolate: \(midCol.r)")
        #expect(midCol.b > Self.red.b && midCol.b < Self.blue.b, "Midpoint textColor.b should interpolate: \(midCol.b)")
        #expect(midScene.primitives.contains { $0.kind == .glyph })

        _ = rt.frame(at: 2.0)
        let endCol = Self.elementByKey(rt, "label")!.textColor!
        #expect(!rt.scene.store.isAnimating(labelId, Props.TEXT_COLOR))
        #expect(abs(endCol.b - Self.blue.b) < 1e-3)
    }

    @Test("4.4 paint_tracks: animated shadow color allocates track and interpolates dropShadow primitive")
    func paintTracksShadowColorAllocatesAndInterpolates() {
        struct S {
            var glowing = false
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(240, 120),
            pixelScale: 1.0,
            systemDark: true
        ) { state, _ in
            col()
                .key("glow-box")
                .size(120, 48)
                .bg(.black)
                .shadow(Shadow(x: 0, y: 4, blur: 10, color: state.glowing ? Self.blue : Self.red))
        }

        _ = rt.frame(at: 0.0)
        let boxId = NodeId.hash(Self.elementByKey(rt, "glow-box")!.path)
        #expect(rt.scene.store.trackLen == 0)

        rt.update { s, tx in
            s.glowing = true
        }
        let midScene = rt.frame(at: 0.05)
        #expect(rt.scene.store.isNodeAnimating(boxId))
        let midShadows = midScene.primitives.filter { $0.kind == .dropShadow }
        #expect(midShadows.count == 1)
        let sColor = midShadows[0].fill
        #expect(sColor.x > Self.blue.r && sColor.x < Self.red.r, "Interpolated shadow red: \(sColor.x)")
        #expect(sColor.z > Self.red.b && sColor.z < Self.blue.b, "Interpolated shadow blue: \(sColor.z)")

        _ = rt.frame(at: 2.0)
        #expect(!rt.scene.store.isNodeAnimating(boxId))
    }

    @Test("4.5 paint_tracks: tx.instant() and instant cuts allocate zero paint tracks")
    func paintTracksSnapAndCutAllocateZeroTracks() {
        struct S {
            var toggled = false
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(240, 120),
            pixelScale: 1.0,
            systemDark: true
        ) { state, _ in
            text("Cut")
                .key("cut-box")
                .size(120, 40)
                .bg(state.toggled ? Self.blue : Self.red)
                .border(2, state.toggled ? Self.green : Self.yellow)
                .color(state.toggled ? .white : Self.red)
                .shadow(Shadow(x: 0, y: 2, blur: 6, color: state.toggled ? Self.blue : Self.red))
        }

        _ = rt.frame(at: 0.0)
        rt.update { s, tx in
            s.toggled = true
            tx.instant()
        }
        _ = rt.frame(at: 0.05)
        let cutId = NodeId.hash(Self.elementByKey(rt, "cut-box")!.path)
        #expect(rt.scene.store.activeLen == 0)
        #expect(!rt.isAnimating)
        #expect(!rt.scene.store.isNodeAnimating(cutId))
        #expect(!rt.scene.store.has(cutId, Props.TEXT_COLOR))
        #expect(Self.elementByKey(rt, "cut-box")?.textColor == .white)

        // Pure text + shadow instant cut allocates zero paint tracks in AnimationStore too.
        struct PureTextS {
            var toggled = false
        }
        let rt2 = Runtime<PureTextS>(
            state: PureTextS(),
            viewport: Vec2(240, 120),
            pixelScale: 1.0,
            systemDark: true
        ) { state, _ in
            text("Pure Cut")
                .key("pure-cut")
                .size(120, 40)
                .color(state.toggled ? .white : Self.red)
                .shadow(Shadow(x: 0, y: 2, blur: 6, color: state.toggled ? Self.blue : Self.red))
        }
        _ = rt2.frame(at: 0.0)
        rt2.update { s, tx in
            s.toggled = true
            tx.instant()
        }
        _ = rt2.frame(at: 0.05)
        #expect(rt2.scene.store.trackLen == 0)
        #expect(Self.elementByKey(rt2, "pure-cut")?.textColor == .white)
    }

    @Test("4.6 paint_tracks: color-only change advances scene.changed without changing layout rects")
    func paintTracksColorOnlyChangeAdvancesSceneChangedWithoutLayoutMove() {
        struct S {
            var phase = false
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(240, 120),
            pixelScale: 1.0,
            systemDark: true
        ) { state, _ in
            text("Stable Rect")
                .key("paint-only")
                .size(160, 40)
                .color(state.phase ? Self.blue : Self.red)
                .shadow(Shadow(x: 0, y: 2, blur: 4, color: state.phase ? Self.green : Self.yellow))
        }

        let scene0 = rt.frame(at: 0.0)
        let r0 = Self.elementByKey(rt, "paint-only")!.rect

        rt.update { s, tx in
            s.phase = true
        }
        let midScene = rt.frame(at: 0.05)
        let r1 = Self.elementByKey(rt, "paint-only")!.rect
        #expect(r1 == r0)
        #expect(midScene.primitives != scene0.primitives)
        #expect(rt.isAnimating)

        _ = rt.frame(at: 2.0)
        #expect(!rt.isAnimating)
    }

    @Test("4.7 paint_tracks: rebuilding reuses node paths and restores focus on layout retry")
    func paintTracksRebuildingReusesNodePathsAndRestoresFocusOnLayoutRetry() {
        struct RetryS {
            var open = true
            var tick: UInt32 = 0
        }
        let rt = Runtime<RetryS>(
            state: RetryS(),
            viewport: Vec2(200, 200),
            pixelScale: 1.0,
            systemDark: true
        ) { s, cx -> El<RetryS> in
            let measured = cx.layoutSize("box").map { $0[0] * 0.5 } ?? 10.0
            var sheet: El<RetryS> = row().key("sheet").size(60, 40)
            if s.open {
                sheet = sheet
                    .child(el().key("btn").size(30, 20).focusable(true))
                    .child(el().size(0, 0).focusReturn("anchor"))
            }
            return col()
                .sizeFull()
                .child(
                    el()
                        .key("box")
                        .size(s.tick == 0 ? 80 : 120, measured)
                        .child(text("\(s.tick)"))
                )
                .child(el().key("anchor").size(40, 20).focusable(true))
                .child(sheet)
        }

        _ = rt.frame(at: 0.0)
        let path0 = Self.elementByKey(rt, "anchor")!.path
        rt.invalidate()
        _ = rt.frame(at: 1.0 / 120.0)
        let path1 = Self.elementByKey(rt, "anchor")!.path
        #expect(path0 == path1)

        // Focus "btn", then close sheet while simultaneously changing "box" width (`tick = 1`)
        // to trigger a layout-read settle retry alongside `focusReturn("anchor")`.
        let btn = Self.elementByKey(rt, "btn")!
        rt.pointerDown(at: Vec2(btn.rect[0] + 5, btn.rect[1] + 5), at: 1.0 / 120.0)
        rt.pointerUp(at: Vec2(btn.rect[0] + 5, btn.rect[1] + 5), at: 1.0 / 120.0)
        _ = rt.frame(at: 2.0 / 120.0)
        #expect(rt.focusedPath == btn.path)

        rt.update { s, _ in
            s.open = false
            s.tick = 1
        }
        _ = rt.frame(at: 3.0 / 120.0)
        let anchorPath = Self.elementByKey(rt, "anchor")!.path
        #expect(rt.focusedPath == anchorPath)
    }

    @Test("4.8 paint_tracks: changing one sibling skips resting siblings without drift")
    func paintTracksChangingOneSiblingSkipsRestingSiblingsWithoutDrift() {
        struct SibS {
            var active = 0
        }
        func makeSibView(_ s: SibS) -> El<SibS> {
            let children: [El<SibS>] = (0..<8).map { i in
                let fg: Color = (i == s.active) ? .white : .black
                return el()
                    .key("r-\(i)")
                    .wFull()
                    .h(20)
                    .bg(fg)
                    .hover(fg.alpha(0.2))
                    .focusable(true)
                    .child(text("item \(i)").color(fg))
            }
            return col().sizeFull().children(children)
        }

        let rt = Runtime<SibS>(
            state: SibS(active: 0),
            viewport: Vec2(200, 200),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            makeSibView(s)
        }
        var clock = 0.0
        _ = rt.frame(at: clock)
        while clock < 2.0 {
            clock += 1.0 / 120.0
            _ = rt.frame(at: clock)
            if !rt.isAnimating { break }
        }
        clock += 1.0 / 120.0
        rt.pointerMove(to: Vec2(20, 70), at: clock) // hover row 3
        _ = rt.frame(at: clock)
        for _ in 0..<240 {
            clock += 1.0 / 120.0
            _ = rt.frame(at: clock)
            if !rt.isAnimating { break }
        }

        rt.update { s, _ in
            s.active = 5
        }
        clock += 1.0 / 120.0
        _ = rt.frame(at: clock)
        let r5Id = NodeId.hash(Self.elementByKey(rt, "r-5")!.path)
        let r2Id = NodeId.hash(Self.elementByKey(rt, "r-2")!.path)
        #expect(rt.scene.store.isNodeAnimating(r5Id), "Changed sibling must animate its colour")
        #expect(!rt.scene.store.isNodeAnimating(r2Id), "Unchanged resting sibling must not animate")
        for _ in 0..<240 {
            clock += 1.0 / 120.0
            _ = rt.frame(at: clock)
            if !rt.isAnimating { break }
        }

        let fresh = Runtime<SibS>(
            state: SibS(active: 5),
            viewport: Vec2(200, 200),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            makeSibView(s)
        }
        var freshClock = 0.0
        _ = fresh.frame(at: freshClock)
        for _ in 0..<240 {
            freshClock += 1.0 / 120.0
            _ = fresh.frame(at: freshClock)
            if !fresh.isAnimating { break }
        }
        for k in 0..<8 {
            let key = "r-\(k)"
            let a = Self.elementByKey(rt, key)!
            let b = Self.elementByKey(fresh, key)!
            #expect(abs(a.fill.r - b.fill.r) < 1e-4 && abs(a.fill.g - b.fill.g) < 1e-4 && abs(a.fill.b - b.fill.b) < 1e-4 && abs(a.fill.a - b.fill.a) < 1e-4)
        }
    }
}
