import Testing
import Foundation
@testable import Rune
import RuneRef

private final class BuildCounter: @unchecked Sendable {
    var count = 0
}

private final class RectsCapture: @unchecked Sendable {
    var rects: [[Float]] = []
}

@Suite("Slice 4 Wave 2: Selection, TextMarks, CopyHTML, Rects/Memo, Run, CaretFollow, EdgeScroll & Keys")
struct Slice4SelectionTests {

    private func click<S>(_ rt: Runtime<S>, at pos: Vec2, mods: Mods = .none, t: Double) {
        rt.pointerDown(at: pos, button: .primary, mods: mods, at: t)
        rt.pointerUp(at: pos, button: .primary, mods: mods, at: t + 0.02)
    }

    private func matchingRects(in scene: RefScene, color: Color, tol: Float = 0.05) -> [Primitive] {
        let target = color.simd4(srgb: scene.srgbBlend)
        var out: [Primitive] = []
        for p in scene.primitives where p.kind == .roundedRect {
            if abs(p.fill.x - target.x) < tol &&
                abs(p.fill.y - target.y) < tol &&
                abs(p.fill.z - target.z) < tol &&
                abs(p.fill.w - target.w) < tol {
                out.append(p)
            }
        }
        return out
    }

    // MARK: - 1. text_selection.rs (`isEmpty`, `isSelected`, `isWhole`, `key`, `len`, `text`, `backward`)

    @Test("text_selection.rs: SelectedText accessors & TextSelection.backward")
    func textSelectionAccessorsParity() throws {
        let emptyItem = SelectedText(
            path: "@root/0",
            key: "title",
            range: 0..<0,
            len: 0,
            whole: false,
            text: "",
            content: ""
        )
        #expect(emptyItem.isEmpty)
        #expect(!emptyItem.isSelected)
        #expect(!emptyItem.isWhole)
        #expect(emptyItem.key == "title")
        #expect(emptyItem.len == 0)
        #expect(emptyItem.text.isEmpty)

        let caretInText = SelectedText(path: "@root/0", range: 2..<2, len: "éx".utf8.count,
                                       whole: false, text: "", content: "")
        #expect(!caretInText.isEmpty)
        #expect(!caretInText.isSelected)

        let wholeItem = SelectedText(
            path: "@root/0",
            key: "title",
            range: 0..<11,
            len: 11,
            whole: true,
            text: "hello world",
            content: "hello world"
        )
        #expect(!wholeItem.isEmpty)
        #expect(wholeItem.isSelected)
        #expect(wholeItem.isWhole)
        #expect(wholeItem.text == "hello world")

        struct S {}
        let rt = Runtime(state: S(), viewport: Vec2(320, 120), pixelScale: 1) { (_: S, _: inout Cx<S>) -> El<S> in
            col().p(12).child(
                text("alpha beta gamma")
                    .key("lbl")
                    .font(TextStyle(size: 14))
                    .selectable()
            )
        }
        _ = rt.frame(at: 0)
        let r = try #require(rt.element(byKey: "lbl")?.rect)
        let y = r[1] + r[3] * 0.5

        // Forward drag -> backward == false
        rt.pointerDown(at: Vec2(r[0] + 2, y), at: 0.1)
        rt.pointerMove(to: Vec2(r[0] + 60, y), at: 0.12)
        rt.pointerUp(at: Vec2(r[0] + 60, y), at: 0.14)
        let fwd = try #require(rt.currentTextSelection())
        #expect(!fwd.backward)
        #expect(fwd.texts.first?.isSelected == true)
        #expect(fwd.texts.first?.isEmpty == false)
        #expect(fwd.texts.first?.key == "lbl")
        #expect(fwd.texts.first?.len == "alpha beta gamma".utf8.count)
        #expect(fwd.texts.first?.isWhole == false)

        // Backward drag -> backward == true
        rt.pointerDown(at: Vec2(r[0] + 80, y), at: 0.8)
        rt.pointerMove(to: Vec2(r[0] + 10, y), at: 0.82)
        rt.pointerUp(at: Vec2(r[0] + 10, y), at: 0.84)
        let bwd = try #require(rt.currentTextSelection())
        #expect(bwd.backward)
        #expect(!bwd.text.isEmpty)
    }

    // MARK: - 2. text_marks.rs (`mark()`, `Cx.markTexts`, lifetime across clear/edit/unmount)

    @Test("text_marks.rs: SelectedText.mark + Cx.markTexts renders square boxes & drops on edit/unmount")
    func textMarksMarkTextsLifecycle() throws {
        struct S {
            var marks: [SelectionMark] = []
            var body = "first marked phrase and tail"
            var show = true
        }
        let markColor = Color.srgb(1.0, 0.8, 0.2, 0.45)
        let rt = Runtime(state: S(), viewport: Vec2(360, 140), pixelScale: 1) { (s: S, cx: inout Cx<S>) -> El<S> in
            cx.markTexts(s.marks)
            let children: [El<S>] = s.show
                ? [text(s.body).key("doc").font(TextStyle(size: 14)).selectionStyle(SelectionStyle(highlight: markColor)).uncopied(3..<5).selectable()]
                : []
            return col().p(12).children(children)
        }
        _ = rt.frame(at: 0)
        let r = try #require(rt.element(byKey: "doc")?.rect)
        let y = r[1] + r[3] * 0.5

        rt.pointerDown(at: Vec2(r[0] + 4, y), at: 0.1)
        rt.pointerMove(to: Vec2(r[0] + 90, y), at: 0.12)
        rt.pointerUp(at: Vec2(r[0] + 90, y), at: 0.14)
        let sel = try #require(rt.currentTextSelection())
        let item = try #require(sel.texts.first)
        let drawn = String(decoding: rt.state.body.utf8.dropFirst(item.range.lowerBound).prefix(item.range.count), as: UTF8.self)
        #expect(item.text != drawn)
        #expect(item.mark().text == drawn)
        rt.update { st, _ in st.marks = [item.mark()] }

        // Clear active selection by clicking outside; mark box still renders with square corners.
        click(rt, at: Vec2(350, 130), t: 0.6)
        #expect(rt.currentTextSelection() == nil)
        let markedScene = rt.frame(at: 0.65)
        let markPrims = matchingRects(in: markedScene, color: markColor)
        #expect(!markPrims.isEmpty)
        for prim in markPrims {
            #expect(prim.radii == .zero)
        }

        // Changing text invalidates/drops marks bound to prior text.
        rt.update { st, _ in st.body = "completely replaced text" }
        let afterEdit = rt.frame(at: 0.7)
        let afterEditMarks = matchingRects(in: afterEdit, color: markColor)
        #expect(afterEditMarks.isEmpty)

        // Re-mark and verify unmount removes marks too.
        _ = rt.frame(at: 0.75)
        let r2 = try #require(rt.element(byKey: "doc")?.rect)
        rt.pointerDown(at: Vec2(r2[0] + 4, r2[1] + 7), at: 0.8)
        rt.pointerMove(to: Vec2(r2[0] + 60, r2[1] + 7), at: 0.82)
        rt.pointerUp(at: Vec2(r2[0] + 60, r2[1] + 7), at: 0.84)
        if let m = rt.currentTextSelection()?.texts.first?.mark() {
            rt.update { st, _ in st.marks = [m] }
        }
        click(rt, at: Vec2(350, 130), t: 1.3)
        rt.update { st, _ in st.show = false }
        let unmounted = rt.frame(at: 1.4)
        let unmountedMarks = matchingRects(in: unmounted, color: markColor)
        #expect(unmountedMarks.isEmpty)
    }

    // MARK: - 3. copy_html.rs (`CopyHTMLBuilder` & Cmd+C `clipboard.html`)

    @Test("copy_html.rs: semantic HTML for headings, nested lists, tables, code, inline formatting, and Cmd+C")
    func copyHtmlSemanticMarkupAndClipboard() throws {
        let nodes: [CopyHTMLBuilder.NodeSnapshot] = [
            CopyHTMLBuilder.NodeSnapshot(parentIndex: nil, roleRaw: "group"),
            CopyHTMLBuilder.NodeSnapshot(parentIndex: 0, roleRaw: "heading", a11yLevel: 1, rect: .fromXYWH(0, 0, 200, 24), text: "Heading"),
            CopyHTMLBuilder.NodeSnapshot(parentIndex: 0, roleRaw: "list"),
            CopyHTMLBuilder.NodeSnapshot(parentIndex: 2, roleRaw: "listItem"),
            CopyHTMLBuilder.NodeSnapshot(parentIndex: 3, roleRaw: "staticText", rect: .fromXYWH(0, 30, 200, 18), text: "Outer"),
            CopyHTMLBuilder.NodeSnapshot(parentIndex: 3, roleRaw: "list", a11yLevel: 2),
            CopyHTMLBuilder.NodeSnapshot(parentIndex: 5, roleRaw: "listItem"),
            CopyHTMLBuilder.NodeSnapshot(parentIndex: 6, roleRaw: "staticText", rect: .fromXYWH(12, 50, 200, 18), text: "Inner"),
            CopyHTMLBuilder.NodeSnapshot(parentIndex: 0, roleRaw: "table"),
            CopyHTMLBuilder.NodeSnapshot(parentIndex: 8, roleRaw: "row"),
            CopyHTMLBuilder.NodeSnapshot(parentIndex: 9, roleRaw: "columnHeader", rect: .fromXYWH(0, 80, 90, 20), text: "Key"),
            CopyHTMLBuilder.NodeSnapshot(parentIndex: 9, roleRaw: "cell", rect: .fromXYWH(100, 80, 90, 20), text: "Val"),
            CopyHTMLBuilder.NodeSnapshot(parentIndex: 0, roleRaw: "codeBlock", rect: .fromXYWH(0, 110, 200, 20), text: "let x = 1", baseMonospace: true),
            CopyHTMLBuilder.NodeSnapshot(
                parentIndex: 0,
                roleRaw: "staticText",
                rect: .fromXYWH(0, 140, 300, 40),
                text: "$ BoldEmSCodeLink\nNext",
                spans: [
                    CopyHTMLBuilder.SpanRun(byteRange: 2..<6, weight: 700),
                    CopyHTMLBuilder.SpanRun(byteRange: 6..<8, italic: true),
                    CopyHTMLBuilder.SpanRun(byteRange: 8..<9, strikethrough: true),
                    CopyHTMLBuilder.SpanRun(byteRange: 9..<13, monospace: true),
                ],
                links: [CopyHTMLBuilder.LinkRun(byteRange: 13..<17, id: "https://example.com")],
                uncopied: [0..<2]
            ),
        ]
        let ranges: [CopyHTMLBuilder.SelectedRange] = [
            .init(nodeIndex: 1, range: 0..<7),
            .init(nodeIndex: 4, range: 0..<5),
            .init(nodeIndex: 7, range: 0..<5),
            .init(nodeIndex: 10, range: 0..<3),
            .init(nodeIndex: 11, range: 0..<3),
            .init(nodeIndex: 12, range: 0..<9),
            .init(nodeIndex: 13, range: 0..<22),
        ]
        let html = try #require(CopyHTMLBuilder.build(nodes: nodes, ranges: ranges))
        #expect(html.contains("<h1>Heading</h1>"))
        #expect(html.contains("<ul><li>Outer<ol><li>Inner</li></ol></li></ul>") || html.contains("<ul><li>Outer<ul><li>Inner</li></ul></li></ul>"))
        #expect(html.contains("<table><tr><th>Key</th><td>Val</td></tr></table>"))
        #expect(html.contains("<pre><code>let x = 1</code></pre>"))
        #expect(html.contains("<strong>Bold</strong>"))
        #expect(html.contains("<em>Em</em>"))
        #expect(html.contains("<s>S</s>"))
        #expect(html.contains("<code>Code</code>"))
        #expect(html.contains("<a href=\"https://example.com\">Link</a>"))
        #expect(html.contains("<br>"))
        #expect(!html.contains("$ "))
        #expect(CopyHTMLBuilder.build(nodes: nodes, ranges: []) == nil)

        struct S {}
        let rt = Runtime(state: S(), viewport: Vec2(320, 120), pixelScale: 1) { (_: S, _: inout Cx<S>) -> El<S> in
            col().p(12).child(
                text("Bold link")
                    .key("p")
                    .spans([RichSpan(0..<4).bold()])
                    .link(TextLink(5..<9, id: "https://rune.dev"))
                    .selectable()
            )
        }
        _ = rt.frame(at: 0)
        let pr = try #require(rt.element(byKey: "p")?.rect)
        rt.pointerDown(at: Vec2(pr[0] + 1, pr[1] + 6), at: 0.1)
        rt.pointerMove(to: Vec2(pr[0] + pr[2] - 1, pr[1] + 6), at: 0.12)
        rt.pointerUp(at: Vec2(pr[0] + pr[2] - 1, pr[1] + 6), at: 0.14)
        #expect(rt.keyDown(KeyEvent(key: .command("c"), mods: RuneTestKey.primaryMods()), at: 0.2))
        let clipHTML = try #require(rt.clipboard.html)
        #expect(clipHTML.contains("<strong>Bold</strong>"))
        #expect(clipHTML.contains("href=\"https://rune.dev\""))
    }

    // MARK: - 4. rects.rs / selection_rects_memo.rs / selection_toolbar.rs

    @Test("rects.rs + selection_rects_memo.rs + selection_toolbar.rs: selectionRects follow scroll, memo reuse, hoverMotionWithin, no spurious rebuilds, and drag phases")
    func selectionRectsMemoAndToolbarParity() throws {
        struct S {
            var dragStates: [Bool] = []
            var backwards: [Bool] = []
        }
        let builds = BuildCounter()
        let plainMemoRects = RectsCapture()
        let hoverMemoRects = RectsCapture()
        let memoCache = MemoCache()
        let hoverMemoCache = MemoCache()

        let rt = Runtime(state: S(), viewport: Vec2(340, 180), pixelScale: 1) { (_: S, cx: inout Cx<S>) -> El<S> in
            builds.count += 1
            _ = cx.selectionRects()
            let plainMemo: El<S> = memo("m-plain", UInt64(0), cache: memoCache) {
                plainMemoRects.rects = Rune.selectionRects()
                return text("memoized line one\nmemoized line two\nmemoized line three")
                    .key("mtxt")
                    .font(TextStyle(size: 14))
                    .selectable()
            }
            let hoverMemo: El<S> = memo("m-hover", UInt64(0), cache: hoverMemoCache) {
                hoverMemoRects.rects = Rune.selectionRects()
                return text("hover motion memo line\nline five\nline six\nline seven\nline eight")
                    .key("htxt")
                    .font(TextStyle(size: 14))
                    .selectable()
            }
            return col().w(340).h(180)
                .child(
                    col().key("sc").w(320).h(90).scrollY().selectionGroup()
                        .onSelectionChange { st, change, _ in
                            st.dragStates.append(change.isDragging)
                            if let sel = change.selection {
                                st.backwards.append(sel.backward)
                            }
                        }
                        .child(plainMemo)
                        .child(
                            col().hoverMotionWithin(.tween(duration: 0.15), .tween(duration: 0.15))
                                .child(hoverMemo)
                        )
                )
        }
        _ = rt.frame(at: 0)
        let mRect = try #require(rt.element(byKey: "m-plain")?.rect)  // upstream memo.rs: keyed(build(), id) — the memo id replaces the root's key
        rt.pointerDown(at: Vec2(mRect[0] + 2, mRect[1] + 6), at: 0.1)
        rt.pointerMove(to: Vec2(mRect[0] + 70, mRect[1] + 6), at: 0.12)
        rt.pointerUp(at: Vec2(mRect[0] + 70, mRect[1] + 6), at: 0.14)
        _ = rt.frame(at: 0.16)

        #expect(!plainMemoRects.rects.isEmpty)
        #expect(!hoverMemoRects.rects.isEmpty)
        let yBeforeScroll = plainMemoRects.rects[0][1]

        // Scroll down: selectionRects must move upward by scroll delta!
        rt.wheel(WheelEvent(dx: 0, dy: -18, precise: true), at: Vec2(40, 40), now: 0.2)
        _ = rt.frame(at: 0.22)
        _ = rt.frame(at: 0.24)
        let yAfterScroll = plainMemoRects.rects[0][1]
        #expect(yAfterScroll < yBeforeScroll - 0.5)

        // Double-click drag & Shift+click keep isDragging until release!
        rt.state.dragStates.removeAll()
        let hRect = try #require(rt.element(byKey: "m-hover")?.rect)  // upstream memo.rs: keyed(build(), id) — the memo id replaces the root's key
        let hy = hRect[1] + 7
        click(rt, at: Vec2(hRect[0] + 60, hy), t: 1.0)
        rt.pointerDown(at: Vec2(hRect[0] + 60, hy), at: 1.1)
        rt.pointerMove(to: Vec2(hRect[0] + 120, hy), at: 1.12)
        #expect(rt.state.dragStates.last == true)
        rt.pointerUp(at: Vec2(hRect[0] + 120, hy), at: 1.14)
        #expect(rt.state.dragStates.last == false)

        rt.state.dragStates.removeAll()
        rt.pointerDown(at: Vec2(hRect[0] + 2, hy), mods: Mods(shift: true), at: 1.5)
        #expect(rt.state.dragStates.last == true)
        rt.pointerUp(at: Vec2(hRect[0] + 2, hy), mods: Mods(shift: true), at: 1.52)
        #expect(rt.state.dragStates.last == false)
        #expect(rt.state.backwards.contains(true))

        // View NOT reading cx.selectionRects() does not rebuild as drag moves.
        let unreadBuilds = BuildCounter()
        let rtNoRead = Runtime(state: S(), viewport: Vec2(320, 120), pixelScale: 1) { (_: S, _: inout Cx<S>) -> El<S> in
            unreadBuilds.count += 1
            return col().p(10).child(
                text("static non reading text")
                    .key("nr")
                    .font(TextStyle(size: 14))
                    .selectable()
            )
        }
        _ = rtNoRead.frame(at: 0)
        let buildsAtRest = unreadBuilds.count
        let nr = try #require(rtNoRead.element(byKey: "nr")?.rect)
        rtNoRead.pointerDown(at: Vec2(nr[0] + 2, nr[1] + 6), at: 0.1)
        rtNoRead.pointerMove(to: Vec2(nr[0] + 35, nr[1] + 6), at: 0.12)
        _ = rtNoRead.frame(at: 0.13)
        rtNoRead.pointerMove(to: Vec2(nr[0] + 70, nr[1] + 6), at: 0.14)
        _ = rtNoRead.frame(at: 0.15)
        #expect(unreadBuilds.count == buildsAtRest)
        #expect(rtNoRead.pressedKey == "nr")
        rtNoRead.pointerUp(at: Vec2(nr[0] + 70, nr[1] + 6), at: 0.16)
        _ = rtNoRead.frame(at: 0.17)
        #expect(rtNoRead.pressedKey == nil)
        #expect(rtNoRead.selectedText()?.isEmpty == false)
        #expect(unreadBuilds.count == buildsAtRest)
    }

    // MARK: - 5. selection_run.rs (words merge into 1 rect & chip bridge)

    @Test("selection_run.rs: adjacent selected words coalesce and bridge across a chip gap")
    func selectionRunMergingWordsAndChips() throws {
        var prims: [Primitive] = []
        let fillVec = SIMD4<Float>(0.2, 0.4, 0.9, 0.3)
        let clipVec = SIMD4<Float>(0, 0, 1000, 1000)
        SelectionRunExtender.appendHighlight(
            into: &prims,
            rect: SIMD4<Float>(10, 20, 40, 16),
            fill: fillVec,
            radius: 0,
            clip: clipVec,
            fade: .zero,
            reach: 40
        )
        SelectionRunExtender.appendHighlight(
            into: &prims,
            rect: SIMD4<Float>(70, 20, 45, 16),
            fill: fillVec,
            radius: 0,
            clip: clipVec,
            fade: .zero,
            reach: 40
        )
        let hlPrims = prims.filter { $0.fill == fillVec }
        #expect(hlPrims.count == 1)
        #expect(hlPrims[0].rect.x == 10)
        #expect(abs((hlPrims[0].rect.x + hlPrims[0].rect.z) - 115) < 0.01)

        // With an opaque filled chip background between highlights, a second rect bridges from previous end.
        prims.append(Primitive.roundedRect(rect: SIMD4<Float>(118, 21, 14, 14), radii: SIMD4<Float>(repeating: 3), fill: SIMD4<Float>(1, 1, 1, 1), clip: clipVec))
        SelectionRunExtender.appendHighlight(
            into: &prims,
            rect: SIMD4<Float>(135, 20, 30, 16),
            fill: fillVec,
            radius: 0,
            clip: clipVec,
            fade: .zero,
            reach: 40
        )
        #expect(prims.filter { $0.fill == fillVec }.count == 2)

        struct S {}
        let rt = Runtime(state: S(), viewport: Vec2(320, 100), pixelScale: 1) { (_: S, _: inout Cx<S>) -> El<S> in
            row().p(10).gap(4).selectionGroup()
                .selectionStyle(SelectionStyle.chromium)
                .child(text("wordOne").key("w1").font(TextStyle(size: 14)).selectable())
                .child(row().p(6).child(text("abc").key("wc").font(TextStyle(size: 11)).selectable()))
                .child(text("wordTwo").key("w2").font(TextStyle(size: 14)).selectable())
        }
        _ = rt.frame(at: 0)
        let r1 = try #require(rt.element(byKey: "w1")?.rect)
        let r2 = try #require(rt.element(byKey: "w2")?.rect)
        rt.pointerDown(at: Vec2(r1[0] + 1, r1[1] + 7), at: 0.1)
        rt.pointerMove(to: Vec2(r2[0] + r2[2] - 1, r2[1] + 7), at: 0.12)
        rt.pointerUp(at: Vec2(r2[0] + r2[2] - 1, r2[1] + 7), at: 0.14)
        let scene = rt.frame(at: 0.16)
        let renderedHls = matchingRects(in: scene, color: SelectionStyle.chromium.active)
        #expect(renderedHls.count == 1)
    }

    // MARK: - 6. caret.rs / caret_follow.rs + TextEdit multiline radii == 2 * pxScale

    @Test("caret.rs + caret_follow.rs: caret tracks graphemes, scrolls into view with scrollMargin, and multiline radii == 2*pxScale")
    func caretFollowAndTextFieldHighlightRadii() throws {
        struct S {
            var edit = TextEdit(
                (1...20).map { "line \($0) content" }.joined(separator: "\n"),
                multiline: true
            )
        }
        let capturedCaret = RectsCapture()
        let rt = Runtime(state: S(), viewport: Vec2(300, 120), pixelScale: 2) { (_: S, cx: inout Cx<S>) -> El<S> in
            if let c = cx.caret("ed") {
                capturedCaret.rects = [c]
            } else {
                capturedCaret.rects = []
            }
            let inp: El<S> = textInput(key: "ed", \S.edit)
            return col().key("sc").w(280).h(80).scrollY()
                .child(inp.scrollMargin(14).w(260))
        }
        _ = rt.frame(at: 0)
        let edRect = try #require(rt.element(byKey: "ed")?.rect)
        click(rt, at: Vec2(edRect[0] + 10, edRect[1] + 10), t: 0.1)
        _ = rt.frame(at: 0.14)

        let caretBefore = try #require(rt.focusedCaretRect())
        #expect(!capturedCaret.rects.isEmpty)
        #expect(rt.keyDown(KeyEvent(key: .arrowRight), at: 0.15))
        _ = rt.frame(at: 0.16)
        let caretAfterRight = try #require(rt.focusedCaretRect())
        #expect(caretAfterRight.x > caretBefore.x)

        for i in 0..<10 {
            _ = rt.keyDown(KeyEvent(key: .arrowDown), at: 0.2 + Double(i) * 0.02)
            _ = rt.frame(at: 0.21 + Double(i) * 0.02)
        }
        let scrollOffsetAfter = rt.scrollOffset(forKey: "sc").y
        #expect(scrollOffsetAfter > 0)

        #expect(rt.keyDown(KeyEvent(key: .command("a"), mods: RuneTestKey.primaryMods()), at: 0.6))
        let scene = rt.frame(at: 0.62)
        let expectedInputSelColor = Color.white.alpha(0.2)
        let inputSelPrims = matchingRects(in: scene, color: expectedInputSelColor)
        #expect(!inputSelPrims.isEmpty)
        for p in inputSelPrims {
            #expect(abs(p.radii.x - 4.0) < 0.01)
        }
    }

    // MARK: - 7. edge_scroll_tests.rs (all edge scroll state-machine & runtime checks)

    @Test("edge_scroll_tests.rs: speed proportionality, upward/downward stop, Escape/blur cancel keeping selection, stale attempt & dt clamp")
    func edgeScrollFullStateMachineParity() throws {
        var seq = EdgeScrollSeq()
        let a1 = seq.next()
        let a2 = seq.next()
        #expect(a1 != a2)
        #expect(a2.rawValue == a1.rawValue + 1)

        struct S {}
        let rows = (1...24).map { "row_\($0)_alpha_beta" }
        let rt = Runtime(state: S(), viewport: Vec2(300, 120), pixelScale: 1) { (_: S, _: inout Cx<S>) -> El<S> in
            var container: El<S> = col().key("sc").w(280).h(80).scrollY().selectionGroup()
            for (i, label) in rows.enumerated() {
                container = container.child(
                    text(label).key("r\(i)").h(20).font(TextStyle(size: 14)).selectable()
                )
            }
            return col().p(10).child(container)
        }
        _ = rt.frame(at: 0)
        let scRect = try #require(rt.element(byKey: "sc")?.rect)
        let r0 = try #require(rt.element(byKey: "r0")?.rect)

        rt.pointerDown(at: Vec2(r0[0] + 4, r0[1] + 8), at: 0.1)
        rt.pointerMove(to: Vec2(r0[0] + 30, scRect[1] + scRect[3] + 10), at: 0.12)
        _ = rt.frame(at: 0.16)
        _ = rt.frame(at: 0.20)
        let ySmallOvershoot = rt.scrollOffset(forKey: "sc").y
        #expect(ySmallOvershoot > 0)

        rt.pointerUp(at: Vec2(r0[0] + 30, scRect[1] + scRect[3] + 10), at: 0.22)
        _ = rt.frame(at: 0.24)
        let yAfterRelease = rt.scrollOffset(forKey: "sc").y
        _ = rt.frame(at: 0.30)
        #expect(rt.scrollOffset(forKey: "sc").y == yAfterRelease)

        rt.wheel(WheelEvent(dx: 0, dy: 500, precise: true), at: Vec2(scRect[0] + 10, scRect[1] + 10), now: 0.45)
        _ = rt.frame(at: 0.5)
        let r0Fresh = try #require(rt.element(byKey: "r0")?.rect)
        rt.pointerDown(at: Vec2(r0Fresh[0] + 4, r0Fresh[1] + 8), at: 0.6)
        rt.pointerMove(to: Vec2(r0Fresh[0] + 30, scRect[1] + scRect[3] + 200), at: 0.62)
        _ = rt.frame(at: 1.62)
        let clampedStepY = rt.scrollOffset(forKey: "sc").y
        #expect(clampedStepY > 0)

        #expect(rt.keyDown(KeyEvent(key: .escape), at: 1.65))
        #expect(rt.selectedText() != nil)
        let yAtEscape = rt.scrollOffset(forKey: "sc").y
        _ = rt.frame(at: 1.75)
        #expect(rt.scrollOffset(forKey: "sc").y == yAtEscape)

        rt.pointerDown(at: Vec2(r0Fresh[0] + 4, scRect[1] + 30), at: 2.0)
        rt.pointerMove(to: Vec2(r0Fresh[0] + 30, scRect[1] + scRect[3] + 300), at: 2.02)
        for k in 1...40 {
            _ = rt.frame(at: 2.02 + Double(k) * 0.04)
        }
        let maxScrolled = rt.scrollOffset(forKey: "sc").y
        #expect(maxScrolled > yAtEscape)
        #expect(rt.selectedText()?.contains("row_") == true)

        rt.pointerMove(to: Vec2(r0Fresh[0] + 30, scRect[1] - 60), at: 4.0)
        for k in 1...10 {
            _ = rt.frame(at: 4.0 + Double(k) * 0.04)
        }
        let afterUpScroll = rt.scrollOffset(forKey: "sc").y
        #expect(afterUpScroll < maxScrolled)

        rt.dispatchFocus(false, at: 4.5)
        let yAtBlur = rt.scrollOffset(forKey: "sc").y
        _ = rt.frame(at: 4.6)
        #expect(rt.scrollOffset(forKey: "sc").y == yAtBlur)
    }

    // MARK: - 8. text_keys.rs (`ElementInfo.shapeKey`)

    @Test("text_keys.rs: deterministic shapeKey, invalidates on content/scale change, omitted for secure")
    func textShapeKeyParity() throws {
        struct S { var txt = "cache-me" }
        let rt = Runtime(state: S(), viewport: Vec2(300, 120), pixelScale: 1) { (s: S, _: inout Cx<S>) -> El<S> in
            col().p(10)
                .child(text(s.txt).key("pub").font(TextStyle(size: 14)))
                .child(text("secret").key("sec").secure(true))
        }
        _ = rt.frame(at: 0)
        let k1 = try #require(rt.element(byKey: "pub")?.shapeKey)
        #expect(rt.element(byKey: "sec")?.shapeKey == nil)

        _ = rt.frame(at: 0.05)
        let k2 = try #require(rt.element(byKey: "pub")?.shapeKey)
        #expect(k1 == k2)

        rt.update { st, _ in st.txt = "replaced-text" }
        _ = rt.frame(at: 0.1)
        let k3 = try #require(rt.element(byKey: "pub")?.shapeKey)
        #expect(k3 != k1)

        let kScale2 = TextShapeKey.compute(
            text: "replaced-text",
            spans: nil,
            pills: [],
            style: TextStyle(size: 14),
            pixelScale: 2,
            wrapAnywhere: false
        )
        #expect(kScale2 != k3)
    }

    // MARK: - 9. links.rs:181 & help.rs:647,664 & selection_group.rs:153

    @Test("links.rs + help.rs: emoji/centered link hit boxes, link cursor over selectable text, and link help region")
    func linksEmojiCenteredAndHelpRegionParity() throws {
        struct S { var opened: String? = nil }
        let str = "🚀 visit docs here"
        let docsRange = (str as NSString).range(of: "docs")
        let strRange = Range(docsRange, in: str)!
        let byteStart = str.utf8.distance(from: str.utf8.startIndex, to: strRange.lowerBound)
        let byteEnd = str.utf8.distance(from: str.utf8.startIndex, to: strRange.upperBound)

        let rt = Runtime(state: S(), viewport: Vec2(360, 120), pixelScale: 1) { (_: S, _: inout Cx<S>) -> El<S> in
            let linkNode: El<S> = text(str)
                .key("emj")
                .font(TextStyle(size: 14, align: .center))
                .selectable()
                .link(TextLink(byteStart..<byteEnd, id: "docs", help: "Open docs"))
                .onLink { st, id, _ in st.opened = id }
            return col().w(340).p(10).child(linkNode)
        }
        rt.nativeHelp = true
        _ = rt.frame(at: 0)
        let docEl = try #require(rt.element(byKey: "docs"))
        #expect(docEl.help == "Open docs")

        let mid = Vec2(docEl.rect[0] + docEl.rect[2] * 0.5, docEl.rect[1] + docEl.rect[3] * 0.5)
        rt.pointerMove(to: mid, at: 0.05)
        #expect(rt.currentCursor() == Cursor.pointer)

        let regions = rt.helpRegions()
        #expect(regions.contains(where: { $0.text == "Open docs" }))

        click(rt, at: mid, t: 0.1)
        #expect(rt.state.opened == "docs")

        rt.pointerMove(to: Vec2(docEl.rect[0] + docEl.rect[2] + 18, mid.y), at: 0.2)
        #expect(rt.currentCursor() == Cursor.text || rt.currentCursor() == Cursor.default)
    }

    // MARK: - 10. selectable_text.rs & selectable_text_edges.rs

    @Test("selectable_text + edges: bidi logical words, clickable row preserves click/hover/menu, drag cancels own press, plain beside link skips focus, chords excluded")
    func selectableTextBidiAndEdgesParity() throws {
        let bidi = "hello שלום world"
        let hebrewStart = "hello ".utf8.count
        let hebrewMid = hebrewStart + 2
        let wRange = SelectionMath.unitRange(in: bidi, at: hebrewMid, unit: .word, uncopied: [])
        let bytes = Array(bidi.utf8)
        let wSlice = String(decoding: bytes[wRange.0..<wRange.1], as: UTF8.self)
        #expect(wSlice == "שלום")

        struct S {
            var rowClicks = 0
            var rowHovered = false
            var rowMenu = 0
            var textPresses = 0
            var body = "plain beside link word"
        }
        let linkByteStart = "plain beside ".utf8.count
        let linkByteEnd = linkByteStart + "link".utf8.count

        let rt = Runtime(state: S(), viewport: Vec2(360, 180), pixelScale: 1) { (s: S, _: inout Cx<S>) -> El<S> in
            col().p(10).gap(12)
                .child(
                    row().key("card").w(300).h(32).bg(.srgb(0.2, 0.2, 0.25, 1))
                        .onHover { st, hovered, _ in st.rowHovered = hovered }
                        .onClick { st, _ in st.rowClicks += 1 }
                        .onSecondaryClick { st, _, _ in st.rowMenu += 1 }
                        .child(text("card label").key("card-lbl").selectable())
                )
                .child(
                    text("pressable drag target").key("ptxt")
                        .selectable()
                        .onClickPress { st, _, _ in st.textPresses += 1 }
                )
                .child(
                    text(s.body).key("ltxt")
                        .selectable()
                        .link(TextLink(linkByteStart..<linkByteEnd, id: "go"))
                )
        }
        _ = rt.frame(at: 0)

        let cardRect = try #require(rt.element(byKey: "card")?.rect)
        let cardPt = Vec2(cardRect[0] + 150, cardRect[1] + 16)
        rt.pointerMove(to: cardPt, at: 0.05)
        #expect(rt.state.rowHovered)
        click(rt, at: cardPt, t: 0.1)
        #expect(rt.state.rowClicks == 1)
        rt.pointerDown(at: cardPt, button: .secondary, at: 0.2)
        rt.pointerUp(at: cardPt, button: .secondary, at: 0.22)
        #expect(rt.state.rowMenu == 1)

        let pRect = try #require(rt.element(byKey: "ptxt")?.rect)
        rt.pointerDown(at: Vec2(pRect[0] + 2, pRect[1] + 6), at: 0.5)
        rt.pointerMove(to: Vec2(pRect[0] + 80, pRect[1] + 6), at: 0.52)
        rt.pointerUp(at: Vec2(pRect[0] + 80, pRect[1] + 6), at: 0.54)
        #expect(rt.state.textPresses == 0)
        #expect(rt.selectedText() != nil)

        // Blur before clicking plain word inside non-focusable link-bearing text.
        click(rt, at: Vec2(5, 5), t: 0.9)
        #expect(rt.focusedKey == nil)

        let lRect = try #require(rt.element(byKey: "ltxt")?.rect)
        click(rt, at: Vec2(lRect[0] + 4, lRect[1] + 7), t: 1.0)
        #expect(rt.focusedKey == nil)

        rt.clipboard = ClipboardContent("keep-me")
        rt.pointerDown(at: Vec2(lRect[0] + 2, lRect[1] + 7), at: 1.5)
        rt.pointerMove(to: Vec2(lRect[0] + 50, lRect[1] + 7), at: 1.52)
        rt.pointerUp(at: Vec2(lRect[0] + 50, lRect[1] + 7), at: 1.54)
        _ = rt.keyDown(KeyEvent(key: .command("c"), mods: RuneTestKey.primaryMods(shift: true)), at: 1.6)
        #expect(rt.clipboard.text == "keep-me")

        rt.update { st, _ in st.body = "changed text drops selection" }
        _ = rt.frame(at: 1.65)
        #expect(rt.selectedText() == nil)
    }

    // MARK: - 11. selection_api + selection_group + selection_hidden + selection_phase

    @Test("selection_api + selection_group + selection_hidden + selection_phase parity")
    func selectionApiGroupHiddenAndPhaseParity() throws {
        struct ApiState {
            var count = 0
            var prefix = false
            var textBody = "prefix"
            var midTag = "a"
            var edit = TextEdit("static text", multiline: false)
        }
        let rt = Runtime(state: ApiState(), viewport: Vec2(360, 260), pixelScale: 1) { (s: ApiState, _: inout Cx<ApiState>) -> El<ApiState> in
            var root: El<ApiState> = col().p(10).gap(8).selectionGroup()
                .onSelectionChange { st, change, tx in
                    st.count += 1
                    if st.count == 1, let key = change.selection?.texts.first?.key {
                        tx.selectText(key, range: 0..<3)
                    }
                }
            if s.prefix {
                root = root.child(text("inserted sibling").h(16))
            }
            let ed: El<ApiState> = textInput(key: "ed", \ApiState.edit).w(200).h(28)
            return root
                .child(col().child(text(s.textBody).key("k1").selectable()))
                .child(text(s.midTag).key("mid").selectable())
                .child(text("second node").key("k2").selectable())
                .child(ed)
        }
        _ = rt.frame(at: 0)
        let k1Rect = try #require(rt.element(byKey: "k1")?.rect)
        rt.pointerDown(at: Vec2(k1Rect[0] + 1, k1Rect[1] + 6), at: 0.1)
        rt.pointerMove(to: Vec2(k1Rect[0] + 40, k1Rect[1] + 6), at: 0.12)
        rt.pointerUp(at: Vec2(k1Rect[0] + 40, k1Rect[1] + 6), at: 0.14)
        #expect(rt.state.count >= 1 && rt.state.count <= 4)

        rt.update { st, _ in
            st.prefix = true
            st.textBody = "prefix appended"
        }
        _ = rt.frame(at: 0.3)
        #expect(rt.selectedText() == "pre")

        let k2Rect = try #require(rt.element(byKey: "k2")?.rect)
        rt.pointerDown(at: Vec2(k2Rect[0] + 70, k2Rect[1] + 6), mods: Mods(shift: true), at: 0.6)
        rt.pointerUp(at: Vec2(k2Rect[0] + 70, k2Rect[1] + 6), mods: Mods(shift: true), at: 0.62)
        #expect(rt.selectedText()?.contains("second") == true)

        rt.update { st, _ in st.midTag = "b" }
        _ = rt.frame(at: 0.7)
        #expect(rt.selectedText() == nil)

        struct HideState {}
        let hideRt = Runtime(state: HideState(), viewport: Vec2(300, 200), pixelScale: 1) { (_: HideState, _: inout Cx<HideState>) -> El<HideState> in
            col().p(10).gap(6)
                .child(
                    col().key("outer").selectionGroup()
                        .child(text("outer top").key("o1").selectable())
                        .child(
                            col().key("inner").selectionGroup()
                                .child(text("inner only").key("in1").selectable())
                        )
                )
                .child(
                    col().w(200).h(22).scrollY()
                        .child(text("visible line\nhidden off bottom").key("clip").font(TextStyle(size: 16)).selectable())
                )
                .child(
                    col().key("tbl").selectionGroup()
                        .child(row().gap(10).child(text("r0c0").key("t00").selectable()).child(text("r0c1").key("t01").selectable()))
                        .child(row().gap(10).child(text("r1c0").key("t10").selectable()).child(text("r1c1").key("t11").selectable()))
                )
        }
        _ = hideRt.frame(at: 0)
        let in1 = try #require(hideRt.element(byKey: "in1")?.rect)
        let o1 = try #require(hideRt.element(byKey: "o1")?.rect)
        hideRt.pointerDown(at: Vec2(in1[0] + 2, in1[1] + 6), at: 0.1)
        hideRt.pointerMove(to: Vec2(o1[0] + 10, o1[1] + 6), at: 0.12)
        hideRt.pointerUp(at: Vec2(o1[0] + 10, o1[1] + 6), at: 0.14)
        #expect(hideRt.selectedText()?.contains("outer") == false)

        let clipRect = try #require(hideRt.element(byKey: "clip")?.rect)
        hideRt.pointerDown(at: Vec2(clipRect[0] + 2, clipRect[1] + 4), at: 0.4)
        hideRt.pointerMove(to: Vec2(clipRect[0] + 120, clipRect[1] + 4), at: 0.42)
        hideRt.pointerUp(at: Vec2(clipRect[0] + 120, clipRect[1] + 4), at: 0.44)
        #expect(hideRt.selectedText()?.contains("hidden") == false)

        let t00 = try #require(hideRt.element(byKey: "t00")?.rect)
        let t11 = try #require(hideRt.element(byKey: "t11")?.rect)
        hideRt.pointerDown(at: Vec2(t00[0] + 1, t00[1] + 6), at: 0.8)
        hideRt.pointerMove(to: Vec2(t11[0] + t11[2] - 1, t11[1] + 6), at: 0.82)
        hideRt.pointerUp(at: Vec2(t11[0] + t11[2] - 1, t11[1] + 6), at: 0.84)
        let tableText = hideRt.selectedText() ?? ""
        #expect(tableText.contains("r0c0") && tableText.contains("r1c1"))

        let utf8Text = "a🚀b"
        let clamped = SelectionMath.floorCharBoundary(in: utf8Text, offset: 3)
        #expect(clamped == 1)
    }

    // MARK: - 12. input_click_tests.rs (secure double/triple click, cancelPointer/blur/onKey clear multiclick, pill padding)

    @Test("input_click_tests.rs: secure double/triple click selects all safely; cancelPointer, blur & onKey clear multiclick; pill padding hit")
    func inputClickMultiClickSecureAndCancelParity() throws {
        struct S {
            var secret = TextEdit("top-secret-password", multiline: false)
            var plain = TextEdit("one two three", multiline: false)
            var multi = TextEdit("alpha beta\ngamma delta", multiline: true)
            var keyed = false
        }
        let rt = Runtime(state: S(), viewport: Vec2(360, 220), pixelScale: 1) { (s: S, _: inout Cx<S>) -> El<S> in
            let _ = s.keyed
            let sec: El<S> = textInput(key: "sec", \S.secret).secure(true).w(240).h(28)
            let pln: El<S> = textInput(key: "pln", \S.plain)
                .onInputKey { st, _, _ in
                    st.keyed = true
                    return true
                }
                .w(240).h(28)
            let mul: El<S> = textInput(key: "mul", \S.multi).w(240).h(60)
            return col().p(10).gap(10)
                .child(sec)
                .child(pln)
                .child(mul)
        }
        _ = rt.frame(at: 0)
        let secRect = try #require(rt.element(byKey: "sec")?.rect)
        let plnRect = try #require(rt.element(byKey: "pln")?.rect)
        let mulRect = try #require(rt.element(byKey: "mul")?.rect)

        click(rt, at: Vec2(secRect[0] + 20, secRect[1] + 14), t: 0.1)
        click(rt, at: Vec2(secRect[0] + 20, secRect[1] + 14), t: 0.2)
        #expect(rt.state.secret.selectedText == "top-secret-password")
        #expect(rt.element(byKey: "sec")?.text == nil)

        click(rt, at: Vec2(mulRect[0] + 12, mulRect[1] + 10), t: 1.0)
        rt.cancelPointer(at: 1.05)
        click(rt, at: Vec2(mulRect[0] + 12, mulRect[1] + 10), t: 1.1)
        #expect(rt.state.multi.selectedText.isEmpty)

        click(rt, at: Vec2(mulRect[0] + 12, mulRect[1] + 10), t: 2.0)
        rt.dispatchFocus(false, at: 2.05)
        rt.dispatchFocus(true, at: 2.08)
        click(rt, at: Vec2(mulRect[0] + 12, mulRect[1] + 10), t: 2.1)
        #expect(rt.state.multi.selectedText.isEmpty)

        click(rt, at: Vec2(plnRect[0] + 12, plnRect[1] + 14), t: 3.0)
        _ = rt.keyDown(KeyEvent(key: .text("x")), at: 3.05)
        #expect(rt.state.keyed)
        click(rt, at: Vec2(plnRect[0] + 12, plnRect[1] + 14), t: 3.1)
        #expect(rt.state.plain.selectedText.isEmpty)

        click(rt, at: Vec2(mulRect[0] + 12, mulRect[1] + 10), t: 4.0)
        click(rt, at: Vec2(mulRect[0] + 12, mulRect[1] + 10), t: 4.1)
        click(rt, at: Vec2(mulRect[0] + 12, mulRect[1] + 10), t: 4.18)
        let tri = rt.state.multi.selectedText
        #expect(tri.contains("alpha") && tri.contains("beta") && !tri.contains("delta"))

        var pillEdit = TextEdit("", multiline: false)
        pillEdit.insertPill(id: "file:readme", label: "@README.md")
        pillEdit.insert(" tail")
        let pillRange = try #require(pillEdit.pills.first?.range)
        #expect(pillEdit.pillAround(pillRange.upperBound - 1)?.1 == pillRange.upperBound)
    }
}
