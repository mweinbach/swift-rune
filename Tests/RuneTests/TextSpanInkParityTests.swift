import Foundation
import Testing
@testable import Rune

@Suite("Text span ink and shaping")
struct TextSpanInkParityTests {
    private let red = Color.srgb(0.9, 0.1, 0.2)
    private let blue = Color.srgb(0.1, 0.2, 0.8)

    @Test func foregroundAndEmptySpansDoNotChangeTheShapeKey() {
        func key(_ spans: [TextSpan]?) -> TextShapeKey {
            TextShapeKey(authText: "abcdef", spans: spans, pills: [], style: TextStyle(),
                         pixelScale: 1, fontEpoch: 1, languageTag: nil, maxWidth: nil)
        }
        let plain = key(nil)
        let tinted = [TextSpan("ab", color: red), TextSpan("", weight: 700), TextSpan("cdef", color: blue)]
        #expect(Set([plain, key(tinted), key([TextSpan("abcdef")])]).count == 1)
        #expect(key(tinted).spans == tinted)

        let weighted = key([TextSpan("ab"), TextSpan("cd", weight: 700), TextSpan("ef")])
        let recolored = key([TextSpan("a", color: red), TextSpan("b"), TextSpan("cd", color: blue, weight: 700),
                             TextSpan("e", color: red), TextSpan("f")])
        #expect(Set([weighted, recolored]).count == 1)
        // Overlapping syntax colors split one authored bold run in RichSpanFlattener.
        let split = key([TextSpan("ab"), TextSpan("c", color: red, weight: 700),
                         TextSpan("d", color: blue, weight: 700), TextSpan("ef")])
        #expect(weighted == split)
        #expect(weighted != plain)
        #expect(weighted != key([TextSpan("abc"), TextSpan("d", weight: 700), TextSpan("ef")]))
        for span in [TextSpan("cd", italic: true), TextSpan("cd", monospace: true), TextSpan("cd", size: 21),
                     TextSpan("cd", background: red, pad: 2), TextSpan("cd", underline: true),
                     TextSpan("cd", strikethrough: true)] {
            #expect(key([TextSpan("ab"), span, TextSpan("ef")]) != plain)
        }
    }

    #if canImport(CoreText) || os(Linux) || os(Windows)
    @Test func freshAndRetainedLabelsResolveTheirOwnCurrentInk() throws {
        // Other tests can install font faces while this sequence compares a single layout epoch.
        try withFontFamilies(sans: "", mono: "", checkRetainedLabelInks)
    }

    private func checkRetainedLabelInks() throws {
        let system = TextSystem()
        let style = TextStyle(size: 18)
        let source = "let café"
        let initial = [TextSpan("let", color: red, weight: 700), TextSpan(" café", color: blue)]
        let next = [TextSpan("let", color: blue, weight: 700), TextSpan(" c"), TextSpan("afé", color: red)]
        func layout(_ spans: [TextSpan], glyphs: Bool) -> TextLayoutBox {
            system.layoutKeyed(text: source, spans: spans, style: style, maxWidth: 200, pixelScale: 1,
                               emitGlyphs: glyphs)
        }
        let measured = layout(initial, glyphs: false)
        let first = layout(initial, glyphs: true)
        let count = system.shapedCount
        let later = system.layoutKeyed(retaining: measured.shapeKey, text: source, spans: next, style: style,
                                       maxWidth: 200, pixelScale: 1, emitGlyphs: true)
        let cold = TextSystem().layoutKeyed(text: source, spans: next, style: style, maxWidth: 200,
                                            pixelScale: 1, emitGlyphs: true)
        #expect(system.shapedCount == count)
        #expect(system.layoutKeys().count == 1)
        #expect(later.spans == next)
        #expect(later.shapeKey.spans == next)
        #expect(first.spans == initial)
        #expect(first.shaped.size == later.shaped.size)
        #expect(first.shaped.glyphs.map(\.utf8Offset) == later.shaped.glyphs.map(\.utf8Offset))
        #expect(later.shaped.glyphs.map(\.color) == cold.shaped.glyphs.map(\.color))
        let ink = later.shaped.glyphs
        try #require(ink.contains { $0.utf8Offset == 4 })
        try #require(ink.contains { $0.utf8Offset == 5 })
        #expect(ink.allSatisfy { glyph in
            glyph.color == (glyph.utf8Offset < 3 ? blue : glyph.utf8Offset < 5 ? nil : red)
        })
        #expect(first.shaped.glyphs.allSatisfy { $0.color == ($0.utf8Offset < 3 ? red : blue) })
        let current = layout(next, glyphs: true)
        #expect(system.shapedCount == count)
        #expect(current.shaped.glyphs.map(\.color) == ink.map(\.color))
        let neutral = layout([TextSpan("let", weight: 700), TextSpan(" café")], glyphs: true)
        #expect(neutral.shaped.glyphs.allSatisfy { $0.color == nil })
        #expect(system.shapedCount == count)
    }

    @Test func paintBoundariesInsideAClusterPreservePlainGeometryAndUseItsFirstByte() throws {
        let system = TextSystem()
        let style = TextStyle(size: 21)
        let sample = "e\u{301} אבZ"
        let spans = [TextSpan("e", color: red), TextSpan("\u{301} ", color: blue), TextSpan("א", color: blue),
                     TextSpan("ב", color: red), TextSpan("Z")]
        let baseline = system.shape(text: sample, style: style, maxWidth: nil, pixelScale: 1)
        let tinted = system.shape(text: sample, spans: spans, style: style, maxWidth: nil, pixelScale: 1)
        let cluster = tinted.glyphs.filter { $0.utf8Offset < 3 }
        try #require(!cluster.isEmpty)
        #expect(cluster.allSatisfy { $0.utf8Offset == 0 && $0.color == red })
        #expect(tinted.size == baseline.size)
        #if os(Linux)
        // Pango composites overlapping glyphs in visual order. Carets stay in logical byte space.
        #expect(tinted.glyphs.map(\.utf8Offset) == [0, 6, 4, 8])
        #expect(tinted.glyphs.map(\.utf8Offset).sorted() == baseline.glyphs.map(\.utf8Offset).sorted())
        #else
        #expect(tinted.glyphs.map(\.utf8Offset) == baseline.glyphs.map(\.utf8Offset))
        #endif
        for offset in [0, 3, 4, 6, 8, 9] {
            #expect(system.caretRect(in: tinted, utf8Offset: offset, pixelScale: 1) ==
                    system.caretRect(in: baseline, utf8Offset: offset, pixelScale: 1))
        }
        for (offset, color) in [(4, blue as Color?), (6, red), (8, nil)] {
            let glyph = try #require(tinted.glyphs.first { $0.utf8Offset == offset })
            #expect(glyph.color == color)
        }
    }

    private static let dejavu = ProcessInfo.processInfo.environment["RUNE_DEJAVU_SANS"]
        ?? "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

    @Test(.enabled(if: FileManager.default.fileExists(atPath: dejavu), "Requires DejaVu Sans"))
    func tintInsideALigatureKeepsItsSingleGlyphAndLeadingInk() async throws {
        #if os(macOS) || os(Linux) || os(Windows)
        // Native font registration changes the catalog used by every TextSystem in this process.
        await #expect(processExitsWith: .success) { try Self().checkLigatureInks() }
        #else
        try checkLigatureInks()
        #endif
    }

    private func checkLigatureInks() throws {
        HeadlessRunner.registerFonts([try Data(contentsOf: URL(fileURLWithPath: Self.dejavu))])
        let system = TextSystem()
        let style = TextStyle(size: 24, family: .custom("DejaVu Sans")).features("liga=1")
        for weight in [Float?.none, 700] {
            let base = weight.map { [TextSpan("ffi", weight: $0), TextSpan("X")] }
            let plain = system.layoutKeyed(text: "ffiX", spans: base, style: style, maxWidth: nil,
                                           pixelScale: 1, emitGlyphs: true)
            let owners = plain.shaped.glyphs.map(\.utf8Offset)
            try #require(Set(owners) == [0, 3])
            let count = system.shapedCount
            let parts = [TextSpan("f", color: red, weight: weight), TextSpan("fi", color: blue, weight: weight),
                         TextSpan("X", color: blue)]
            let colored = system.layoutKeyed(text: "ffiX", spans: parts, style: style, maxWidth: nil,
                                            pixelScale: 1, emitGlyphs: true)
            #expect(system.shapedCount == count)
            #if os(Linux)
            // A single owned mask covers the complete ligature across all three editing cells.
            #expect(colored.shaped.glyphs.map(\.utf8Offset) == [0, 3])
            #else
            #expect(colored.shaped.glyphs.map(\.utf8Offset) == owners)
            #endif
            #expect(colored.shaped.glyphs.allSatisfy { $0.color == ($0.utf8Offset == 0 ? red : blue) })
        }
    }

    #if (os(Linux) || os(Windows)) && canImport(CRuneDesktopText)
    @Test func fractionalPlacementPreservesInkForConcurrentLabels() throws {
        let system = TextSystem()
        let style = TextStyle(size: 19)
        func label(_ first: Color, _ second: Color?) -> ShapedText {
            system.layoutKeyed(text: "ABCD", spans: [TextSpan("AB", color: first), TextSpan("CD", color: second)],
                               style: style, maxWidth: nil, pixelScale: 1, emitGlyphs: true).shaped
        }
        func check(_ source: ShapedText, at pen: Float, _ first: Color, _ second: Color?) throws {
            var value = source
            let resting = try #require(source.desktopRestingText)
            #expect(resting.place(&value, at: pen, atlas: system.glyphAtlas))
            #expect(Set(value.glyphs.map(\.utf8Offset)) == [0, 1, 2, 3])
            #expect(value.glyphs.allSatisfy { $0.color == ($0.utf8Offset < 2 ? first : second) })
        }
        let original = label(red, nil)
        let count = system.shapedCount
        let recolored = label(blue, red)
        #expect(system.shapedCount == count)
        try check(original, at: 0.25, red, nil)
        try check(recolored, at: 0.25, blue, red)
        try check(recolored, at: 0.75, blue, red)
        try check(original, at: 0.25, red, nil)
    }
    #endif

    @Test func secretAndOwnedLayoutsBindInkWithoutRetainingText() throws {
        for keep in [TextKeep.secret, .owned] {
            let system = TextSystem()
            for ink in [red, blue] {
                let box = system.layoutKeyed(text: "secret", spans: [TextSpan("sec", color: ink), TextSpan("ret")],
                                             style: TextStyle(size: 17), maxWidth: nil, pixelScale: 1,
                                             emitGlyphs: true, keep: keep)
                try #require(!box.shaped.glyphs.isEmpty)
                #expect(box.shaped.glyphs.allSatisfy { $0.color == ($0.utf8Offset < 3 ? ink : nil) })
                #expect(system.layoutKeys().isEmpty)
            }
        }
    }
    #endif
}
