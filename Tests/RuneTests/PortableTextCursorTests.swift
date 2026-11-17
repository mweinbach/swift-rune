import Foundation
import Testing
@testable import Rune

@Suite("Portable text cursor and wrapping")
struct PortableTextCursorTests {
    @Test func caretAndHitStayOnGraphemeBoundaries() throws {
        let text = "e\u{301}👩🏽‍💻é"
        let system = TextSystem()
        let shaped = system.shapePortable(text: text, style: TextStyle(size: 16),
                                          maxWidth: nil, pixelScale: 2, emitGlyphs: false)
        let stops = text.indices.map { text.utf8.distance(from: text.startIndex, to: $0) } + [text.utf8.count]
        for (i, byte) in stops.enumerated() {
            let caret = system.caretRect(in: shaped, utf8Offset: byte, affinity: .downstream, pixelScale: 2)
            #expect(system.hitTestUTF8OffsetPortable(in: shaped, localX: caret.x, localY: 0, pixelScale: 2) == byte)
            if i + 1 < stops.count {
                for interior in (byte + 1)..<stops[i + 1] {
                    let inside = system.caretRect(in: shaped, utf8Offset: interior, affinity: .downstream, pixelScale: 2)
                    #expect(inside == caret)
                }
            }
        }
    }

    @Test func rtlLineMovementUsesVisualColumns() throws {
        let system = TextSystem()
        let rtl = "אב"
        let shaped = ShapedText(size: Vec2(30, 32), lineCount: 2, lineHeight: 16,
                                glyphs: [], underlines: [], backgrounds: [],
                                portableLines: [(0, "AB", 0, 0, [0, 10, 30]),
                                                (3, rtl, 16, 0, [30, 30, 10, 10, 0])])
        let end = try #require(system.moveLine(in: shaped, utf8Offset: 0, delta: 1))
        #expect(end.utf8Offset == 3 + rtl.utf8.count)
        let mid = try #require(system.moveLine(in: shaped, utf8Offset: 1, delta: 1))
        #expect(mid.utf8Offset == 5 && mid.goalX == 10)
        #expect(system.caretRect(in: shaped, utf8Offset: mid.utf8Offset, affinity: mid.affinity, pixelScale: 1).x == 10)
        #expect(system.moveLine(in: shaped, utf8Offset: mid.utf8Offset, delta: -1, goalX: mid.goalX)?.utf8Offset == 1)
        #expect(system.moveLine(in: shaped, utf8Offset: mid.utf8Offset, delta: .min)?.utf8Offset == 0)
        #expect(system.moveLine(in: shaped, utf8Offset: 0, delta: .max) == nil)
    }

    @Test func wrapAffinityAndHardSeparatorsKeepTheirAuthoredBytes() throws {
        let system = TextSystem()
        let style = TextStyle(size: 16, wrap: .wrap, wrapAnywhere: true)
        let shaped = system.shapePortable(text: "ééé\r\n\nβ", style: style, maxWidth: 1,
                                          pixelScale: 1, emitGlyphs: false)
        #expect(shaped.portableLines.map(\.utf8Start) == [0, 2, 4, 8, 9])
        #expect(shaped.lineIndex(forUTF8Offset: 2, affinity: .upstream) == 0)
        #expect(shaped.lineIndex(forUTF8Offset: 2, affinity: .downstream) == 1)
        #expect(shaped.lineIndex(forUTF8Offset: 6, affinity: .downstream) == 2)
        #expect(shaped.lineIndex(forUTF8Offset: 7, affinity: .downstream) == 2)
        #expect(shaped.lineIndex(forUTF8Offset: 8, affinity: .upstream) == 3)
        #expect(shaped.lineIndex(forUTF8Offset: 9, affinity: .upstream) == 4)
        #expect(system.lineEdge(in: shaped, utf8Offset: 7, toEnd: true).utf8Offset == 6)
        let separators = system.selectionRectsPortable(in: shaped, utf8Range: 6..<9, pixelScale: 1)
        #expect(separators.map(\.y) == [shaped.portableLines[2].originY, shaped.portableLines[3].originY])
        #expect(separators.map(\.z) == [4, 4])
    }

    @Test func oppositeRunsKeepBothCaretsAndDiscontiguousSelections() {
        let system = TextSystem()
        // Logical order A, Alef, Bet, B. The RTL run is drawn as Bet, Alef.
        var shaped = ShapedText(size: Vec2(40, 16), lineCount: 1, lineHeight: 16, glyphs: [], underlines: [], backgrounds: [])
        shaped.portableLines = [(0, "AאבB", 0, 0, [0, 10, 10, 20, 20, 30, 40])]
        shaped.portableBidiCells[0] = [
                .init(range: 0..<1, left: 0, width: 10, rtl: false, space: false),
                .init(range: 3..<5, left: 10, width: 10, rtl: true, space: false),
                .init(range: 1..<3, left: 20, width: 10, rtl: true, space: false),
                .init(range: 5..<6, left: 30, width: 10, rtl: false, space: false),
        ]
        #expect(system.caretRect(in: shaped, utf8Offset: 1, affinity: .upstream, pixelScale: 1).x == 10)
        #expect(system.caretRect(in: shaped, utf8Offset: 1, affinity: .downstream, pixelScale: 1).x == 30)
        #expect(system.hitTestUTF8OffsetPortable(in: shaped, localX: 12, localY: 1, pixelScale: 1) == 5)
        #expect(system.hitTestUTF8OffsetPortable(in: shaped, localX: 28, localY: 1, pixelScale: 1) == 1)
        #expect(system.caretHit(in: shaped, on: 0, atX: 10, pixelScale: 1) == TextCursorMove(utf8Offset: 1, goalX: 10, affinity: .upstream))
        #expect(system.caretHit(in: shaped, on: 0, atX: 30, pixelScale: 1) == TextCursorMove(utf8Offset: 1, goalX: 30, affinity: .downstream))
        #expect(system.selectionRectsPortable(in: shaped, utf8Range: 0..<3, pixelScale: 1) ==
            [SIMD4(0, 0, 10, 16), SIMD4(20, 0, 10, 16)])
        let move = CaretVisualStepper.visualIn(shaped, at: 1, side: .downstream, arrow: .left, hidden: false)
        #expect(move?.0 == CaretLanding.at(3, .upstream))
        #expect(CaretVisualStepper.visualIn(shaped, at: 1, side: .downstream, arrow: .wordLeft, hidden: true) == nil)
    }

    #if os(Linux) || os(Windows)
    @Test func nativeShapingExposesBothEdgesOfReorderedGlyphs() throws {
        let system = TextSystem()
        let shaped = system.shape(text: "AאבB", style: TextStyle(size: 20), maxWidth: nil,
                                  pixelScale: 1, emitGlyphs: false)
        let cells = try #require(shaped.portableBidiCells[0])
        #expect(cells.map(\.range) == [0..<1, 3..<5, 1..<3, 5..<6])
        #expect(cells.map(\.rtl) == [false, true, true, false])
        let beforeRun = system.caretRect(in: shaped, utf8Offset: 1, affinity: .upstream, pixelScale: 1)
        let insideRun = system.caretRect(in: shaped, utf8Offset: 1, affinity: .downstream, pixelScale: 1)
        #expect(beforeRun.x < insideRun.x)
        #expect(system.selectionRects(in: shaped, utf8Range: 0..<3, pixelScale: 1).count == 2)
    }
    #endif

    @Test func nativeHitsPreserveCRLFAndGraphemesAfterPillMarkers() throws {
        let system = TextSystem()
        let prefix = "lead\n"
        let body = "A👩🏽‍💻e\u{301}"
        let text = prefix + body + "\r\nB"
        let start = prefix.utf8.count
        let end = start + body.utf8.count
        let stops = Set(text.indices.map { text.utf8.distance(from: text.startIndex, to: $0) })
        for pills: [PillChip] in [[], [PillChip(0..<4), PillChip(start..<(start + 1))]] {
            let shaped = system.shape(text: text, pills: pills, style: TextStyle(size: 15),
                                      maxWidth: nil, pixelScale: 2, emitGlyphs: false)
            #expect(shaped.lineCount == 3)
            let y = shaped.lineTopPt(1) + shaped.lineBoxHeightPt(1) / 2
            let beyond = Int(shaped.size.x.rounded(.up)) + 4
            for x in -1...beyond {
                let hit = system.hitTestUTF8Offset(in: shaped, localX: Float(x), localY: y, pixelScale: 2)
                #expect((start...end).contains(hit) && stops.contains(hit))
            }
            let move = try #require(system.moveLine(in: shaped, utf8Offset: text.utf8.count,
                                                    delta: -1, goalX: Float(beyond), pixelScale: 2))
            #expect(move.utf8Offset == end)
        }
    }

    @Test func overflowingWordsKeepTheirTrailingSpacesOnTheSameLine() {
        let system = TextSystem()
        let font = TextStyle(size: 13, lineHeight: 20, family: .monospace, wrap: .wrap)
        // Pinned Parley wraps at the UTF-8 boundary after the spaces, even when the word overflows.
        let examples = [
            Array(repeating: "word ", count: 40),
            ["    ", "word  ", "next"],
            ["word\u{00a0}word  ", "end"],
            ["e\u{0301}  ", "e\u{0301}e\u{0301} "],
            ["אבג  ", "مرحبا  ", "ד  "],
            ["a\t", "b\t  ", "c"],
            ["    "]
        ]
        let word = system.shape(text: "word", style: font, maxWidth: nil, pixelScale: 1, emitGlyphs: false)
        let text = String(repeating: "word ", count: 40)
        let narrow = system.shape(text: text, style: font, maxWidth: 1, pixelScale: 1, emitGlyphs: false)
        #expect(abs(narrow.size.x - word.size.x) <= 1.0 / 64.0)
        for lines in examples {
            let text = lines.joined()
            for width: Float in [0, 1] {
                let shaped = system.shape(text: text, style: font, maxWidth: width, pixelScale: 1, emitGlyphs: false)
                #expect(shaped.lineCount == lines.count)
                #expect(shaped.size.y == Float(lines.count) * 20)
                var byte = 0
                for (line, content) in lines.enumerated() {
                    let end = byte + content.utf8.count
                    #expect(shaped.lineUTF8Range(at: line) == (byte..<end))
                    byte = end
                }
            }
        }
    }

    @Test func portableLineWidthsHangSpacesAtSoftBreaksAndOnlyOverflowAtHardBreaks() {
        let system = TextSystem()
        let font = TextStyle(size: 13, lineHeight: 20, family: .monospace, wrap: .wrap)
        for scale: Float in [1, 2] {
            func shape(_ text: String, _ width: Float?, pills: [PillChip] = []) -> ShapedText {
                system.shapePortable(text: text, pills: pills, style: font, maxWidth: width,
                                     pixelScale: scale, emitGlyphs: false, nativeFonts: true)
            }
            let word = shape("word", nil).lastLineAdvancePx
            let full = shape("word   ", nil).lastLineAdvancePx
            let room = (word + full) / (2 * scale)
            let wrapped = shape("word   word   \nword   ", room)
            #expect(wrapped.lineCount == 3)
            #expect(wrapped.size.x == TextBoxGeometry.boxWidth(maxLineWidthPt: room, scale: scale))
            for (i, metrics) in wrapped.lineAdvancesPx.enumerated() {
                #expect(abs(metrics.widthPx - full) < 0.02)
                let expected = i == 0 ? full - word : full - room * scale
                #expect(abs(metrics.trailingWsPx - expected) < 0.02)
            }
            #expect(shape("   ", 0).size.x == 0)
            #expect(shape("word   ", nil).hangingAdvancePx == 0)
            #expect(shape("word\u{00a0}", 0).hangingAdvancePx == 0)
            let boxed = shape("word ", 0, pills: [PillChip(0..<5)])
            #expect(boxed.hangingAdvancePx == 0)
            #expect(boxed.size.x >= boxed.lastLineAdvancePx / scale - 0.001)

            // The visible word centers in the available space while its final caret
            // still includes all three spaces on the soft-wrapped line.
            var centered = font
            centered.align = .center
            let aligned = system.shapePortable(text: "word   word", style: centered, maxWidth: room,
                                               pixelScale: scale, emitGlyphs: false, nativeFonts: true)
            let first = aligned.portableLines[0]
            #expect(abs(first.originX * scale - (room * scale - word) / 2) < 0.02)
            #expect(abs((first.charOffsets.last ?? 0) * scale - full) < 0.02)
        }
    }

    @Test func wordAndEmergencyWrapKeepGraphemesAndNonbreakingSpacesIntact() {
        let system = TextSystem()
        let style = TextStyle(size: 16, wrap: .wrap)
        let word = "é\u{a0}in"
        let normal = system.shapePortable(text: word, style: style, maxWidth: 1, pixelScale: 1, emitGlyphs: false)
        #expect(normal.portableLines.map(\.text) == [word])
        let emergency = system.shapePortable(text: "e\u{301}👨‍👩‍👦", style: style.wrapAnywhere(),
                                             maxWidth: 1, pixelScale: 1, emitGlyphs: false)
        #expect(emergency.portableLines.map(\.text) == ["e\u{301}", "👨‍👩‍👦"])
        let phrase = "abc 💡猫犬"
        let ns = phrase as NSString
        #expect(PrettyLineBreaker.lineBreakOpportunities(in: ns, from: 0, to: ns.length) == [4, 6, 7])
    }

    @Test func prettyWrappingRebalancesTheLastWordWithoutAddingLines() throws {
        let system = TextSystem()
        let style = TextStyle(size: 14, wrap: .wrap)
        let text = "Careful typography avoids leaving a single short trailing word alone at the bottom of a long paragraph."
        for width in stride(from: Float(125), through: 340, by: 2) {
            let greedy = system.shapePortable(text: text, style: style, maxWidth: width, pixelScale: 1, emitGlyphs: false)
            let greedyWords = greedy.portableLines.last?.text.split(separator: " ").count
            guard greedyWords == 1 else { continue }
            let pretty = system.shapePortable(text: text, style: style, maxWidth: width, pixelScale: 1, emitGlyphs: false, pretty: true)
            if (pretty.portableLines.last?.text.split(separator: " ").count ?? 0) > 1 {
                #expect(pretty.lineCount == greedy.lineCount)
                #expect(pretty.portableLines.map(\.text).joined() == text)
                return
            }
        }
        Issue.record("No width rebalanced the orphan in this paragraph")
    }
}
