import Foundation
import Testing
import RuneMotion
import RuneRef
@testable import Rune

@Suite("RuneCore Upstream Parity Tests")
struct RuneCoreParityTests {

    // MARK: - Machine Parity

    @Test("Machine: Seq, Attempt, and Effects.two / Equatable / Hashable")
    func machineParity() {
        var seq = Seq()
        let t1 = seq.next()
        #expect(t1 == 1)
        #expect(seq.isCurrent(t1))

        let t2 = seq.next()
        #expect(!seq.isCurrent(t1))
        #expect(seq.isCurrent(t2))

        seq.cancel()
        #expect(!seq.isCurrent(t2))

        let idle: Attempt<Int, String> = .idle
        let loading: Attempt<Int, String> = .loading
        let ready: Attempt<Int, String> = .ready(42)
        let failed: Attempt<Int, String> = .failed("err")
        #expect(idle.isIdle && !idle.isLoading && !idle.isReady && !idle.isFailed)
        #expect(loading.isLoading && loading.value == nil && loading.error == nil)
        #expect(ready.isReady && ready.value == 42)
        #expect(failed.isFailed && failed.error == "err")

        let two = Effects<String>.two("a", "b")
        #expect(two.count == 2)
        #expect(two.array == ["a", "b"])

        var pushed = Effects<String>.none
        pushed.push("a")
        pushed.push("b")
        #expect(pushed == two)
        #expect(pushed.hashValue == two.hashValue)

        pushed.push("c")
        #expect(pushed.count == 3)
        #expect(pushed.array == ["a", "b", "c"])
    }

    // MARK: - Shape Parity

    @Test("Shape: concave L-shape triangulation preserves area and exact boundary aaMask")
    func shapeTriangulationParity() {
        var path = VectorPath()
        path.moveTo(0, 0)
        path.lineTo(20, 0)
        path.lineTo(20, 10)
        path.lineTo(10, 10)
        path.lineTo(10, 30)
        path.lineTo(0, 30)
        path.close()

        let tris = path.triangulate()
        #expect(tris.count == 4)

        let totalArea = tris.reduce(Float(0)) { acc, t in
            let cross = (t.v1.x - t.v0.x) * (t.v2.y - t.v0.y) - (t.v1.y - t.v0.y) * (t.v2.x - t.v0.x)
            return acc + abs(cross) * 0.5
        }
        #expect(abs(totalArea - 400.0) < 1e-2)

        let boundaryEdgeCount = tris.reduce(0) { $0 + $1.aaMask.nonzeroBitCount }
        #expect(boundaryEdgeCount == 6)
    }

    @Test("Shape: strokeSegments trimming respects start <= end and NaN defaults")
    func shapeTrimmingParity() {
        var path = VectorPath()
        path.moveTo(0, 0)
        path.lineTo(0, 60)
        path.lineTo(40, 60)

        // 0.25..0.75 of 100pt path => 25pt..75pt
        let segs = path.strokeSegments(trimStart: 0.25, trimEnd: 0.75)
        #expect(segs.count == 2)
        #expect(abs(segs[0].0.y - 25.0) < 1e-3)
        #expect(abs(segs[0].1.y - 60.0) < 1e-3)
        #expect(abs(segs[1].1.x - 15.0) < 1e-3)

        // Equal or inverted bounds draw nothing (upstream parity)
        #expect(path.strokeSegments(trimStart: 0.6, trimEnd: 0.6).isEmpty)
        #expect(path.strokeSegments(trimStart: 0.7, trimEnd: 0.2).isEmpty)

        // NaN defaults: start -> 0, end -> 1
        let nanSegs = path.strokeSegments(trimStart: .nan, trimEnd: .nan)
        #expect(nanSegs.count == 2)

        let shape = Shape.stroke(path, color: .white, width: 2.0)
            .viewBox(100, 100)
            .drawn(.nan)
        #expect(shape.trimStart == 0.0)
        #expect(shape.trimEnd == 1.0)
        #expect(shape.viewBox == Vec2(100, 100))
    }

    @Test("Shape: arc respects clockwise direction and roundedRect closes cleanly")
    func shapeArcAndRoundedRect() {
        var cw = VectorPath()
        cw.arc(center: Vec2(50, 50), radius: 20, startAngle: 0, endAngle: -.pi * 0.5, clockwise: true)
        let cwPts = cw.flatten().first?.points ?? []
        #expect(cwPts.count > 4)
        // Going clockwise (increasing angle in y-down) from 0 to -pi/2 (= 3pi/2) passes through +Y (bottom)
        let midY = cwPts[cwPts.count / 2].y
        #expect(midY > 50.0)

        var rr = VectorPath()
        rr.roundedRect(x: 0, y: 0, width: 100, height: 40, radius: 10)
        let tris = rr.triangulate()
        #expect(!tris.isEmpty)
    }

    // MARK: - Layout Parity

    @Test("Layout: flexGrow freezes maxWidth items and redistributes leftover space")
    func layoutFlexGrowFreezeRedistribution() {
        var child1 = LayoutInputNode(style: LayoutStyle())
        child1.style.flexGrow = 1
        child1.style.flexBasis = .points(0)
        child1.style.maxWidth = .points(50)
        child1.style.height = .points(20)

        var child2 = LayoutInputNode(style: LayoutStyle())
        child2.style.flexGrow = 1
        child2.style.flexBasis = .points(0)
        child2.style.height = .points(20)

        var root = LayoutInputNode(style: LayoutStyle(direction: .row), children: [child1, child2])
        root.style.width = .points(200)
        root.style.height = .points(100)

        let result = LayoutEngine.compute(root: root, viewport: Vec2(200, 100))
        #expect(abs(result.children[0].layout.localRect.width - 50) < 0.01)
        #expect(abs(result.children[1].layout.localRect.width - 150) < 0.01)
    }

    @Test("Layout: flexShrink freezes minWidth items and redistributes remaining deficit")
    func layoutFlexShrinkFreezeRedistribution() {
        var child1 = LayoutInputNode(style: LayoutStyle())
        child1.style.width = .points(150)
        child1.style.minWidth = .points(120)
        child1.style.flexShrink = 1
        child1.style.height = .points(20)

        var child2 = LayoutInputNode(style: LayoutStyle())
        child2.style.width = .points(150)
        child2.style.minWidth = .points(0)
        child2.style.flexShrink = 1
        child2.style.height = .points(20)

        var root = LayoutInputNode(style: LayoutStyle(direction: .row), children: [child1, child2])
        root.style.width = .points(200)
        root.style.height = .points(100)

        let result = LayoutEngine.compute(root: root, viewport: Vec2(200, 100))
        #expect(abs(result.children[0].layout.localRect.width - 120) < 0.01)
        #expect(abs(result.children[1].layout.localRect.width - 80) < 0.01)
    }

    @Test("Layout: column contentSize uses horizontal margin for maxContentX")
    func layoutColumnContentSizeMargins() {
        var child = LayoutInputNode(style: LayoutStyle())
        child.style.width = .points(80)
        child.style.height = .points(40)
        child.style.margin = Sides(top: 5, right: 15, bottom: 30, left: 10)

        var root = LayoutInputNode(style: LayoutStyle(direction: .column), children: [child])
        root.style.width = .points(50)
        root.style.height = .points(50)

        let result = LayoutEngine.compute(root: root, viewport: Vec2(50, 50))
        // x = 10, w = 80, right margin = 15 => 105 (not 10 + 80 + 30 = 120)
        #expect(abs(result.layout.contentSize.x - 105) < 0.01)
        // y = 5, h = 40, bottom margin = 30 => 75
        #expect(abs(result.layout.contentSize.y - 75) < 0.01)
    }

    @Test("Layout: aspectFit fitRoom sets explicit size from maxWidth per upstream fit_room")
    func layoutAspectFitBoundedRoom() {
        var child = LayoutInputNode(style: LayoutStyle())
        child.style.aspectFit = 2.0
        child.style.maxWidth = .points(400)

        var root = LayoutInputNode(style: LayoutStyle(direction: .column), children: [child])
        root.style.width = .points(200)
        root.style.height = .points(200)

        // Upstream `fit_room` (`crates/rune/src/runtime/commit/flatten.rs:15`) sets `size: raw.max_size`,
        // so Taffy (`taffy-0.9.0/src/compute/flexbox.rs:1371,1601`) treats `size.width = 400` as a
        // definite cross size rather than clamping to `availableWidth = 200` (giving 400x200).
        let result = LayoutEngine.compute(root: root, viewport: Vec2(200, 200))
        #expect(abs(result.children[0].layout.localRect.width - 400) < 0.01)
        #expect(abs(result.children[0].layout.localRect.height - 200) < 0.01)
    }

    // MARK: - Text Parity

    @Test("Text: rich spans emit underlines, strikethroughs, and backgrounds")
    func textRichSpanDecorations() {
        let ts = TextSystem()
        let spans = [
            TextSpan("hello ", color: .white),
            TextSpan("link", color: Color(r: 0.2, g: 0.5, b: 1.0, a: 1.0), background: .black, underline: true),
            TextSpan(" old", color: Color(r: 0.5, g: 0.5, b: 0.5, a: 1.0), strikethrough: true),
        ]
        let shaped = ts.shape(text: "", spans: spans, style: TextStyle(size: 14), maxWidth: 400, pixelScale: 2.0, emitGlyphs: true)
        #expect(shaped.underlines.count == 1)
        #expect(shaped.strikethroughs.count == 1)
        #expect(shaped.backgrounds.count == 1)
        #expect(shaped.underlines[0].z > 5.0)
        #expect(shaped.strikethroughs[0].z > 5.0)
    }

    @Test("Text: multi-line selectionRects and SVG arc icon rasterization")
    func textSelectionRectsAndSVGArc() {
        let ts = TextSystem()
        let shaped = ts.shape(text: "first line\nsecond line", style: TextStyle(size: 14), maxWidth: 400, pixelScale: 2.0, emitGlyphs: false)
        #expect(shaped.lineCount == 2)

        let rects = ts.selectionRects(in: shaped, utf8Range: 6..<17, pixelScale: 2.0)
        #expect(rects.count == 2)
        #expect(rects[0].y < rects[1].y)

        // SVG arc icon (like Kit.Icons.search)
        let searchIcon = SVGIcon(viewBox: 16, paths: ["M7 3A4 4 0 1 1 6.99 3", "M10.2 10.2L13.2 13.2"], strokeWidth: 1.7)
        let entry = ts.glyphAtlas.rasterizeIcon(searchIcon, pixelSize: 32)
        #expect(entry.pixelSize == SIMD2<Int>(32, 32))
        #expect(entry.uv.z > entry.uv.x)
    }

    // MARK: - Edit Parity

    @Test("Edit: grapheme-safe editing, marks undo/redo, IME preedit, and Cmd+Delete")
    func editParity() {
        var ed = TextEdit("ab\u{0301}👨‍👩‍👧‍👦", multiline: true)
        let red = Color(r: 1.0, g: 0.2, b: 0.2, a: 1.0)
        let blue = Color(r: 0.2, g: 0.5, b: 1.0, a: 1.0)
        ed.marks = [TextMark(utf8Range: 0..<1, textColor: red)]
        ed.insert("!")
        #expect(ed.text == "ab\u{0301}👨‍👩‍👧‍👦!")
        #expect(ed.marks == [TextMark(utf8Range: 0..<1, textColor: red)])

        // Backspace deletes '!' then whole ZWJ family emoji
        ed.backspace()
        ed.backspace()
        #expect(ed.text == "ab\u{0301}")

        // Undo restores both text and marks (3 ops: insert '!', backspace '!', backspace emoji)
        let u1 = ed.undo()
        let u2 = ed.undo()
        let u3 = ed.undo()
        #expect(u1)
        #expect(u2)
        #expect(u3)
        #expect(ed.text == "ab\u{0301}👨‍👩‍👧‍👦")

        // Marks shift when inserting before a mark
        var marked = TextEdit("hello world", multiline: false)
        marked.marks = [TextMark(utf8Range: 6..<11, textColor: blue)]
        marked.setCursor(utf8Offset: 0)
        marked.insert("say ")
        #expect(marked.marks == [TextMark(utf8Range: 10..<15, textColor: blue)])
        let uMarked = marked.undo()
        #expect(uMarked)
        #expect(marked.marks == [TextMark(utf8Range: 6..<11, textColor: blue)])

        // IME preedit & Escape cancellation
        marked.setPreedit("nihao", cursor: 0..<5)
        #expect(marked.preedit?.text == "nihao")
        let escOutcome = marked.handleKey(KeyEvent(key: .escape))
        #expect(escOutcome == .modified)
        #expect(marked.preedit == nil)

        // Cmd+Delete deletes to line end
        var lineEd = TextEdit("first line\nsecond line", multiline: true)
        lineEd.setCursor(utf8Offset: 5)
        let delOutcome = lineEd.handleKey(KeyEvent(key: .delete, mods: Mods(cmd: true)))
        #expect(delOutcome == .modified)
        #expect(lineEd.text == "first\nsecond line")

        // Multi-line moveUp preserves grapheme column across emoji
        var emojiLines = TextEdit("👨‍👩‍👧‍👦abc\nxyz", multiline: true)
        emojiLines.setCursor(utf8Offset: emojiLines.text.utf8.count)
        emojiLines.moveUp()
        // Cursor should be after 3 graphemes ("👨‍👩‍👧‍👦", "a", "b") -> before "c"
        let beforeCursor = String(decoding: emojiLines.text.utf8.prefix(emojiLines.cursor), as: UTF8.self)
        #expect(beforeCursor == "👨‍👩‍👧‍👦ab")

        // Secure revealed state: display shows text, copy/cut/undo/IME remain blocked (crates/rune/src/edit/input.rs:300-302)
        var sec = TextEdit("secret", multiline: false)
        sec.isSecure = true
        sec.selectAll()
        #expect(sec.displayString == "••••••")
        #expect(sec.copy() == nil)
        sec.isRevealed = true
        #expect(sec.displayString == "secret")
        #expect(sec.copy() == nil)
        #expect(sec.cut() == nil)

        // Chord logo modifier matching
        let winChord = Chord(parsing: "super+space")
        #expect(winChord != nil)
        #expect(winChord!.matches(KeyEvent(key: .space, mods: Mods(logo: true))))
        #expect(!winChord!.matches(KeyEvent(key: .space, mods: Mods())))
    }

    // MARK: - El Parity

    @Test("El: builder modifiers and layout properties")
    func elParity() {
        let node: El<Int> = col()
            .wFrac(0.5)
            .maxHFrac(0.8)
            .wAuto()
            .scale(1.5, 2.0)
            .letterSpacing(0.5)
            .centerX()
            .centerY()
        #expect(node.layout.width == .auto)
        #expect(node.layout.maxHeight == .fraction(0.8))
        #expect(node.scale == Vec2(1.5, 2.0))
        #expect(node.textStyle.letterSpacing == 0.5)
        #expect(node.layout.justifyContent == .center)
        #expect(node.layout.alignItems == .center)
    }
}
