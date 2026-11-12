import Foundation
import Testing
@testable import Rune

@Suite("Text, Edit, Chord, A11y & Cursor P0 Parity Tests")
struct TextEditInputParityTests {
    @Test("TextStyle: lineHeight defaults to 1.25x unrounded and wrap defaults to noWrap")
    func textStyleDefaults() {
        let s14 = TextStyle(size: 14)
        #expect(s14.wrap == .noWrap)
        #expect(s14.resolvedLineHeight == 17.5)

        let s13 = TextStyle(size: 13)
        #expect(s13.resolvedLineHeight == 16.25)

        let custom = TextStyle(size: 14, lineHeight: 22)
        #expect(custom.resolvedLineHeight == 22)

        let zero = TextStyle(size: 14, lineHeight: 0)
        #expect(zero.resolvedLineHeight == 17.5)

        #expect(s14.wrapped().wrap == .wrap)
    }

    @Test("Portable TextSystem shapes, measures, wraps, hits, and emits selection rects")
    func portableTextShapingParity() {
        let ts = TextSystem()
        let style = TextStyle(size: 14, wrap: .wrap)
        let m = ts.measurePortable("hello world", style: style, maxWidth: 400, pixelScale: 2.0)
        #expect(m.x > 0)
        #expect(m.y == 17.5)

        let wrapped = ts.shapePortable(
            text: "abcdefghij",
            style: style,
            maxWidth: 32,
            pixelScale: 2.0,
            emitGlyphs: true
        )
        #expect(wrapped.lineCount >= 2)
        #expect(!wrapped.glyphs.isEmpty)

        let spans = [
            TextSpan("hi ", color: Color(r: 1, g: 0, b: 0, a: 1), underline: true),
            TextSpan("there", background: Color(r: 0, g: 0, b: 1, a: 1), monospace: true, strikethrough: true)
        ]
        let rich = ts.shapePortable(text: "", spans: spans, style: TextStyle(size: 14), maxWidth: 400, pixelScale: 2.0, emitGlyphs: false)
        #expect(rich.underlines.count == 3)
        #expect(rich.strikethroughs.count == 5)
        #expect(rich.backgrounds.count == 5)
        #expect(rich.glyphs.isEmpty)

        let shaped2 = ts.shapePortable(text: "abc\ndef", style: TextStyle(size: 14), maxWidth: 400, pixelScale: 2.0, emitGlyphs: false)
        let c0 = ts.caretRectPortable(in: shaped2, utf8Offset: 0, pixelScale: 2.0)
        let c4 = ts.caretRectPortable(in: shaped2, utf8Offset: 4, pixelScale: 2.0)
        #expect(c0.y == 0)
        #expect(c4.y == 17.5)

        let hitEnd = ts.hitTestUTF8OffsetPortable(in: shaped2, localX: 200, localY: 20, pixelScale: 2.0)
        #expect(hitEnd == 7)

        let rects = ts.selectionRectsPortable(in: shaped2, utf8Range: 1..<6, pixelScale: 2.0)
        #expect(rects.count == 2)
    }

    @Test("Chord: cmd/mod match macOS Mods(cmd: true, logo: true) and cross-platform equivalence")
    func chordPlatformMatching() {
        let cmdS = Chord(parsing: "cmd+s")!
        let modS = Chord(parsing: "mod+s")!
        let superS = Chord(parsing: "super+s")!
        let realMacEvent = KeyEvent(key: .command("s"), mods: Mods(cmd: true, logo: true))
        let syntheticMacEvent = KeyEvent(key: .command("s"), mods: Mods(cmd: true))

        #expect(cmdS.matches(realMacEvent, on: .mac))
        #expect(cmdS.matches(syntheticMacEvent, on: .mac))
        #expect(modS.matches(realMacEvent, on: .mac))
        #expect(modS.matches(syntheticMacEvent, on: .mac))
        #expect(superS.matches(realMacEvent, on: .mac))
        #expect(modS.sameKeys(cmdS, on: .mac))

        let modB = Chord(parsing: "mod+b")!
        let ctrlB = Chord(parsing: "ctrl+b")!
        #expect(!modB.sameKeys(ctrlB, on: .mac))
        #expect(modB.sameKeys(ctrlB, on: .linux))
        #expect(modB.sameKeys(ctrlB, on: .windows))

        #expect(modS.label(on: .mac) == "⌘S")
        #expect(modS.label(on: .linux) == "Ctrl+S")
        #expect(Chord(parsing: "mod+shift+[")?.matches(KeyEvent(key: .command("["), mods: Mods(shift: true, cmd: true, logo: true)), on: .mac) == true)
        #expect(Chord(parsing: "mod+shift+{") == Chord(parsing: "mod+shift+["))
        #expect((try? Chord.parse("trailing+")) == nil)
        #expect(Chord(parsing: "contextmenu")?.key == .contextMenu)
        #expect(Chord(parsing: "ins")?.key == .insert)
    }

    @Test("TextEdit secure fields block copy/cut/undo/redo/IME/a11y even when revealed")
    func secureFieldNoLeaks() {
        var plain = TextEdit("abc", multiline: false)
        plain.insert("d")
        plain.isSecure = true
        #expect(plain.undo() == false) // prior undo stack cleared on setSecure

        var sec = TextEdit("topsecret", multiline: false)
        sec.isSecure = true
        sec.insert("!")
        sec.selectAll()
        #expect(sec.displayString == "••••••••••")
        #expect(sec.copy() == nil)
        #expect(sec.cut() == nil)
        #expect(sec.text == "topsecret!")
        #expect(sec.undo() == false)

        sec.setPreedit("kanji", cursor: 0..<5)
        #expect(sec.preedit == nil)
        sec.commitPreedit("漢字")
        #expect(sec.text == "topsecret!")

        sec.isRevealed = true
        #expect(sec.displayString == "topsecret!")
        #expect(sec.copy() == nil)
        #expect(sec.cut() == nil)
        #expect(sec.undo() == false)
        #expect(sec.redo() == false)

        sec.conceal()
        #expect(!sec.isRevealed)
        #expect(sec.text == "••••••••••")

        var multi = TextEdit("line1\nline2", multiline: true)
        multi.isSecure = true
        #expect(multi.displayString == TextEdit.multilineSecureMask)
        #expect(multi.handleKey(KeyEvent(key: .enter)) == .modified)
        #expect(multi.text == "line1\nline2\n")
        #expect(multi.handleKey(KeyEvent(key: .enter, mods: Mods(cmd: true))) == .submit)

        struct State { var pw = TextEdit("hunter2", multiline: false) }
        var state = State()
        state.pw.isSecure = true
        state.pw.isRevealed = true
        let el = textInput(key: "pw", \State.pw)
        let layout = LayoutEngine.compute(root: LayoutInputNode(style: el.layout), viewport: Vec2(200, 40))
        let node = AccessibilityTreeBuilder.project(element: el, layout: layout, state: state, focusedKey: "pw")
        #expect(node?.isSecure == true)
        #expect(node?.value == nil)
    }

    @Test("TextEdit multi-line Enter submits, Shift/Alt+Enter inserts newline, prev_backspace & Ctrl bindings")
    func multilineEnterBackspaceAndCtrlBindings() {
        var ed = TextEdit("hello", multiline: true)
        #expect(ed.handleKey(KeyEvent(key: .enter)) == .submit)
        #expect(ed.text == "hello")

        #expect(ed.handleKey(KeyEvent(key: .enter, mods: Mods(shift: true))) == .modified)
        #expect(ed.text == "hello\n")

        #expect(ed.handleKey(KeyEvent(key: .enter, mods: Mods(alt: true))) == .modified)
        #expect(ed.text == "hello\n\n")

        // prev_backspace peels combining accent while keeping base character, and deletes emoji whole
        var accent = TextEdit("e\u{0301}", multiline: false)
        accent.backspace()
        #expect(accent.text == "e")

        var flag = TextEdit("a🇯🇵", multiline: false)
        flag.backspace()
        #expect(flag.text == "a")

        #if os(macOS) || os(iOS)
        var ctrlEd = TextEdit("alpha\nbeta", multiline: true)
        #expect(ctrlEd.handleKey(KeyEvent(key: .text("a"), mods: Mods(ctrl: true))) == .navigation)
        #expect(ctrlEd.cursor == 6)
        #expect(ctrlEd.handleKey(KeyEvent(key: .text("k"), mods: Mods(ctrl: true))) == .modified)
        #expect(ctrlEd.text == "alpha\n")
        #endif
    }

    @Test("Cursor and CursorImage validate PNG dimensions and clamp hotspots")
    func cursorTypes() throws {
        // Minimal 32x32 PNG header (IHDR only)
        var bytes: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D,
            0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x20, // width = 32
            0x00, 0x00, 0x00, 0x20  // height = 32
        ]
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 9))
        let img = CursorImage(png: bytes, hot: SIMD2<Float>(99, 3))
        let size = img.pngSize()
        #expect(size?.width == 32)
        #expect(size?.height == 32)
        let css = try img.cssCursor(url: "/pencil.png")
        #expect(css == "image-set(url(\"/pencil.png\") 2x) 15 3, auto")
        let cur = Cursor.image(img)
        #expect(cur == Cursor.image(img))
    }

    @Test("SVG path parser splits adjacent decimals and terminates on truncated args")
    func svgPathTokenizerSafety() {
        let atlas = GlyphAtlas()
        let icon = SVGIcon(viewBox: 24, paths: ["M-2.3.4L10 20 M1"])
        let entry = atlas.rasterizeIcon(icon, pixelSize: 24)
        #expect(entry.uv.z > entry.uv.x)
        #expect(entry.uv.w > entry.uv.y)
    }
}
